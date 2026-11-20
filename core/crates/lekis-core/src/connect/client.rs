//! 控制端：连接、配对、认证，以及之后的请求 / 推送分发。

use super::crypto::{self, Ephemeral, Transcript};
use super::protocol::{read_msg, write_msg, DenyReason, Msg, Reply, Request, PROTOCOL_VERSION};
use super::{ConnectEvent, Discovered, PairedPeer};
use crate::Services;
use lekis_types::{ErrorCode, LekisError, Result};
use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::BufReader;
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::TcpStream;
use tokio::sync::oneshot;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const REPLY_TIMEOUT: Duration = Duration::from_secs(20);

type Reader = BufReader<OwnedReadHalf>;

/// 一条已认证的控制连接。
pub(crate) struct Session {
    device_id: String,
    writer: tokio::sync::Mutex<OwnedWriteHalf>,
    pending: Mutex<HashMap<u64, oneshot::Sender<Result<Reply>>>>,
    next_id: AtomicU64,
    local_ip: IpAddr,
    alive: AtomicBool,
    subscribed: AtomicBool,
    reader_task: Mutex<Option<tokio::task::AbortHandle>>,
}

/// 等用户输入配对码的半截连接。
pub(crate) struct PendingPair {
    reader: Reader,
    writer: OwnedWriteHalf,
    local_ip: IpAddr,
    eph: Ephemeral,
    server_public: String,
    transcript: Transcript,
    peer: Discovered,
}

pub(crate) enum Opened {
    Session(Arc<Session>),
    NeedsCode(PendingPair),
}

fn deny_error(reason: DenyReason) -> LekisError {
    match reason {
        DenyReason::NotAccepting => LekisError::new(
            ErrorCode::PermissionDenied,
            "the device does not allow being controlled",
        ),
        DenyReason::AuthFailed => LekisError::new(ErrorCode::Auth, "pairing is no longer valid"),
        DenyReason::WrongCode => LekisError::new(ErrorCode::Auth, "wrong pairing code"),
        DenyReason::RateLimited => {
            LekisError::new(ErrorCode::RateLimited, "too many pairing attempts")
        }
        DenyReason::Incompatible => {
            LekisError::new(ErrorCode::Unsupported, "incompatible Lekis version")
        }
        DenyReason::Protocol => LekisError::invalid("protocol error"),
    }
}

async fn expect(reader: &mut Reader) -> Result<Msg> {
    match tokio::time::timeout(REPLY_TIMEOUT, read_msg(reader)).await {
        Ok(Ok(Some(Msg::Denied { reason }))) => Err(deny_error(reason)),
        Ok(Ok(Some(msg))) => Ok(msg),
        Ok(Ok(None)) => Err(LekisError::new(ErrorCode::Network, "connection closed")),
        Ok(Err(e)) => Err(e),
        Err(_) => Err(LekisError::new(ErrorCode::Network, "timed out")),
    }
}

struct Greeted {
    reader: Reader,
    writer: OwnedWriteHalf,
    local_ip: IpAddr,
    transcript: Transcript,
    peer: Discovered,
    paired_remote: bool,
}

async fn greet(s: &Services, host: &str, port: u16) -> Result<Greeted> {
    let stream = tokio::time::timeout(CONNECT_TIMEOUT, TcpStream::connect((host, port)))
        .await
        .map_err(|_| LekisError::new(ErrorCode::Network, "connect timed out"))??;
    let _ = stream.set_nodelay(true);
    let local_ip = stream.local_addr()?.ip();
    let (r, mut writer) = stream.into_split();
    let mut reader = BufReader::new(r);
    let name = s
        .connect
        .settings()
        .map(|c| c.device_name)
        .unwrap_or_else(|| s.config.device_name.clone());
    let nonce = crypto::random_hex(16)?;
    write_msg(
        &mut writer,
        &Msg::Hello {
            device_id: s.device_id.0.clone(),
            name,
            platform: super::platform_name(s),
            version: PROTOCOL_VERSION,
            nonce: nonce.clone(),
        },
    )
    .await?;
    let Msg::Welcome {
        device_id,
        name,
        platform,
        version,
        nonce: server_nonce,
        paired,
        accepting,
    } = expect(&mut reader).await?
    else {
        return Err(LekisError::invalid("expected welcome"));
    };
    if version != PROTOCOL_VERSION {
        return Err(deny_error(DenyReason::Incompatible));
    }
    if device_id == s.device_id.0 {
        return Err(LekisError::invalid("that is this device"));
    }
    if !accepting {
        return Err(deny_error(DenyReason::NotAccepting));
    }
    Ok(Greeted {
        reader,
        writer,
        local_ip,
        transcript: Transcript {
            client_id: s.device_id.0.clone(),
            server_id: device_id.clone(),
            client_nonce: nonce,
            server_nonce,
        },
        peer: Discovered {
            device_id,
            name,
            platform,
            host: host.to_string(),
            port,
            fullname: String::new(),
        },
        paired_remote: paired,
    })
}

/// 只握个手读出对方的身份（手动添加设备用），不认证。
pub(crate) async fn probe(s: &Services, host: &str, port: u16) -> Result<Discovered> {
    let g = greet(s, host, port).await?;
    Ok(g.peer)
}

/// 连接并认证；`allow_pairing` 时对没配对过的设备发起配对。
pub(crate) async fn open(s: &Arc<Services>, target: &Discovered, allow_pairing: bool) -> Result<Opened> {
    let mut g = greet(s, &target.host, target.port).await?;
    if g.peer.device_id != target.device_id {
        return Err(LekisError::invalid("a different device answered at that address"));
    }
    let key = s.connect.peers().key(&g.peer.device_id);
    match key {
        Some(key) if g.paired_remote => {
            let mac = crypto::auth_mac(&key, "c", &g.transcript);
            write_msg(&mut g.writer, &Msg::Auth { mac }).await?;
            let Msg::AuthOk { mac } = expect(&mut g.reader).await? else {
                return Err(LekisError::invalid("expected auth ok"));
            };
            if !crypto::mac_eq(&crypto::auth_mac(&key, "s", &g.transcript), &mac) {
                return Err(LekisError::new(ErrorCode::Auth, "device failed authentication"));
            }
            Ok(Opened::Session(Session::start(s, g.peer, g.reader, g.writer, g.local_ip)))
        }
        _ => {
            if key.is_some() {
                // 对方已经不认识本机了（删了配对 / 重装）：本机这边也作废。
                let _ = s.connect.peers().forget(&g.peer.device_id);
            }
            if !allow_pairing {
                return Err(LekisError::new(ErrorCode::Auth, "device is not paired"));
            }
            let eph = Ephemeral::generate()?;
            write_msg(
                &mut g.writer,
                &Msg::PairStart {
                    public_key: eph.public_hex.clone(),
                },
            )
            .await?;
            let Msg::PairChallenge { public_key } = expect(&mut g.reader).await? else {
                return Err(LekisError::invalid("expected pair challenge"));
            };
            Ok(Opened::NeedsCode(PendingPair {
                reader: g.reader,
                writer: g.writer,
                local_ip: g.local_ip,
                eph,
                server_public: public_key,
                transcript: g.transcript,
                peer: g.peer,
            }))
        }
    }
}

/// 用用户输入的配对码完成配对。
pub(crate) async fn finish_pair(s: &Arc<Services>, p: PendingPair, code: &str) -> Result<Arc<Session>> {
    let PendingPair {
        mut reader,
        mut writer,
        local_ip,
        eph,
        server_public,
        transcript,
        peer,
    } = p;
    let client_public = eph.public_hex.clone();
    let shared = eph.agree(&server_public)?;
    let pair_key = crypto::pair_key(&shared, code, &transcript, &client_public, &server_public);
    write_msg(
        &mut writer,
        &Msg::PairConfirm {
            mac: crypto::pair_confirm(&pair_key, "c"),
        },
    )
    .await?;
    let Msg::PairOk { mac } = expect(&mut reader).await? else {
        return Err(LekisError::invalid("expected pair ok"));
    };
    if !crypto::mac_eq(&crypto::pair_confirm(&pair_key, "s"), &mac) {
        return Err(LekisError::new(ErrorCode::Auth, "device failed pairing confirmation"));
    }
    s.connect.peers().save(
        PairedPeer {
            device_id: peer.device_id.clone(),
            name: peer.name.clone(),
            platform: peer.platform.clone(),
            paired_at_ms: lekis_types::now_ms(),
        },
        &crypto::long_term_key(&pair_key),
    )?;
    Ok(Session::start(s, peer, reader, writer, local_ip))
}

impl Session {
    fn start(
        s: &Arc<Services>,
        peer: Discovered,
        reader: Reader,
        writer: OwnedWriteHalf,
        local_ip: IpAddr,
    ) -> Arc<Self> {
        let session = Arc::new(Self {
            device_id: peer.device_id,
            writer: tokio::sync::Mutex::new(writer),
            pending: Mutex::new(HashMap::new()),
            next_id: AtomicU64::new(1),
            local_ip,
            alive: AtomicBool::new(true),
            subscribed: AtomicBool::new(false),
            reader_task: Mutex::new(None),
        });
        let task = tokio::spawn(read_loop(Arc::downgrade(s), session.clone(), reader));
        if let Ok(mut t) = session.reader_task.lock() {
            *t = Some(task.abort_handle());
        }
        session
    }

    pub(crate) fn local_ip(&self) -> IpAddr {
        self.local_ip
    }

    pub(crate) fn is_alive(&self) -> bool {
        self.alive.load(Ordering::Relaxed)
    }

    pub(crate) async fn request(&self, req: Request) -> Result<Reply> {
        if !self.is_alive() {
            return Err(LekisError::new(ErrorCode::Network, "connection closed"));
        }
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        if let Ok(mut p) = self.pending.lock() {
            p.insert(id, tx);
        }
        {
            let mut w = self.writer.lock().await;
            if let Err(e) = write_msg(&mut *w, &Msg::Request { id, req }).await {
                if let Ok(mut p) = self.pending.lock() {
                    p.remove(&id);
                }
                return Err(e);
            }
        }
        match tokio::time::timeout(REPLY_TIMEOUT, rx).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err(LekisError::new(ErrorCode::Network, "connection closed")),
            Err(_) => {
                if let Ok(mut p) = self.pending.lock() {
                    p.remove(&id);
                }
                Err(LekisError::new(ErrorCode::Network, "timed out"))
            }
        }
    }

    /// 开始接收状态推送（每个连接只需要一次）。
    pub(crate) async fn subscribe(&self) -> Result<()> {
        if self.subscribed.swap(true, Ordering::Relaxed) {
            return Ok(());
        }
        if let Err(e) = self.request(Request::Subscribe).await {
            self.subscribed.store(false, Ordering::Relaxed);
            return Err(e);
        }
        Ok(())
    }

    pub(crate) async fn close(&self) {
        self.alive.store(false, Ordering::Relaxed);
        if let Ok(mut t) = self.reader_task.lock() {
            if let Some(t) = t.take() {
                t.abort();
            }
        }
        let mut w = self.writer.lock().await;
        let _ = tokio::io::AsyncWriteExt::shutdown(&mut *w).await;
        self.fail_pending();
    }

    fn fail_pending(&self) {
        if let Ok(mut p) = self.pending.lock() {
            for (_, tx) in p.drain() {
                let _ = tx.send(Err(LekisError::new(ErrorCode::Network, "connection closed")));
            }
        }
    }
}

async fn read_loop(s: std::sync::Weak<Services>, session: Arc<Session>, mut reader: Reader) {
    let reason = loop {
        match read_msg(&mut reader).await {
            Ok(Some(Msg::Response { id, result, error })) => {
                let tx = session.pending.lock().ok().and_then(|mut p| p.remove(&id));
                if let Some(tx) = tx {
                    let r = match (result, error) {
                        (Some(reply), None) => Ok(reply),
                        (_, Some(e)) => Err(LekisError::new(ErrorCode::Internal, e)),
                        (None, None) => Err(LekisError::invalid("empty response")),
                    };
                    let _ = tx.send(r);
                }
            }
            Ok(Some(Msg::Event { state })) => {
                if let Some(s) = s.upgrade() {
                    s.connect.emit(ConnectEvent::RemoteState {
                        device_id: session.device_id.clone(),
                        state,
                    });
                }
            }
            Ok(Some(_)) => {}
            Ok(None) => break "closed".to_string(),
            Err(e) => break e.message,
        }
    };
    session.alive.store(false, Ordering::Relaxed);
    session.fail_pending();
    if let Some(s) = s.upgrade() {
        s.connect.session_closed(&session.device_id, &session, &reason);
    }
}
