//! 被控端：一个 TCP 端口同时承载控制通道和局域网媒体流（CST-02 / CST-03）。
//!
//! 每个连接单独一个任务，看**第一个字节**分流：`{` 是控制通道（一行一个 JSON，见
//! [`protocol`]），其他按 HTTP 交给 [`stream::serve`]（`GET /stream/<令牌>`）。
//!
//! 控制通道的握手顺序见 [`protocol`] 的模块文档。这里负责被控端那一半：
//!
//! 1. 回 `Welcome`（带上本机身份、`paired`、`accepting`）；
//! 2. 已经配对过 → 校验 `Auth` 的 MAC，回 `AuthOk`；
//!    没配对过 → 生成 6 位配对码，推 [`ConnectEvent::PairingCode`] 让界面显示，
//!    等用户把码输进控制端后校验 `PairConfirm`，成功就把长期密钥存进凭据库；
//! 3. 之后处理 `Request`，并在控制端 `Subscribe` 后把播放状态当 `Event` 推过去。
//!
//! 关掉「允许其他设备控制」时，已经连着的控制端会在一个检查周期内被断开。

use super::crypto::{self, Ephemeral, Transcript};
use super::media;
use super::protocol::{
    read_msg, write_msg, Control, DenyReason, Msg, Reply, Request, TrackRef, PROTOCOL_VERSION,
};
use super::{stream, ConnectEvent, PairedPeer, RemoteState};
use crate::Services;
use base64::Engine as _;
use lekis_playback::{EngineCommand, PlaybackSnapshot};
use lekis_types::{ErrorCode, LekisError, PlaybackState, Result, TrackId};
use std::sync::{Arc, Weak};
use std::time::Duration;
use tokio::io::{AsyncWriteExt, BufReader};
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use tokio::task::JoinSet;

/// 连上来之后多久没说话就断开。
const GREETING_TIMEOUT: Duration = Duration::from_secs(10);
/// 控制端认证 / 发起配对的时限。
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(20);
/// 等用户输入配对码的时限（被控端显示配对码 → 用户在控制端输入）。
const PAIR_TIMEOUT: Duration = Duration::from_secs(120);
/// 检查「允许其他设备控制」的周期。
const CONTROL_CHECK: Duration = Duration::from_secs(1);
/// 发给控制端的待写消息上限（慢的连接不要拖住播放状态）。
const OUT_QUEUE: usize = 64;
/// 收到还没处理的请求上限。
const IN_QUEUE: usize = 16;
/// 一次 `GetQueue` 最多返回多少首。
const QUEUE_PAGE_MAX: u32 = 500;
/// 发给控制端的封面尺寸（取不小于它的最近一档）。
const ARTWORK_WIDTH: u32 = 512;

/// 接受连接的循环；`connect_stop` 通过 abort 这个任务来断开所有连接。
///
/// [`JoinSet`] 在 drop 时会中止里面所有任务，所以 abort 之后控制端和媒体流都会被断开。
pub(crate) async fn accept_loop(listener: TcpListener, s: Weak<Services>) {
    let mut connections = JoinSet::new();
    loop {
        tokio::select! {
            accepted = listener.accept() => match accepted {
                Ok((socket, addr)) => {
                    tracing::debug!(target: "connect", %addr, "incoming connection");
                    connections.spawn(handle_connection(socket, s.clone()));
                }
                Err(e) => {
                    // 句柄耗尽之类：等一会再试，不要空转。
                    tracing::warn!(target: "connect", error = %e, "accept failed");
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
            },
            // 已经结束的连接任务要收掉，否则 JoinSet 会一直攒着它们。
            Some(_) = connections.join_next(), if !connections.is_empty() => {}
        }
    }
}

async fn handle_connection(socket: TcpStream, s: Weak<Services>) {
    let mut first = [0u8; 1];
    let control = match tokio::time::timeout(GREETING_TIMEOUT, socket.peek(&mut first)).await {
        Ok(Ok(1)) => first[0] == b'{',
        Ok(Ok(_)) => return,
        Ok(Err(e)) => {
            tracing::debug!(target: "connect", error = %e, "connection failed");
            return;
        }
        Err(_) => {
            tracing::debug!(target: "connect", "connection idled before saying anything");
            return;
        }
    };
    let Some(s) = s.upgrade() else { return };
    let _ = socket.set_nodelay(true);
    if control {
        if let Err(e) = serve_control(socket, s).await {
            tracing::debug!(target: "connect", error = %e, "control connection ended");
        }
    } else {
        stream::serve(socket, s).await;
    }
}

/// 跑完一条控制连接：握手 + 请求 / 推送，直到任一方断开。
async fn serve_control(socket: TcpStream, s: Arc<Services>) -> Result<()> {
    let (read_half, write_half) = socket.into_split();
    let (out, out_rx) = mpsc::channel::<Msg>(OUT_QUEUE);
    let writer = tokio::spawn(write_loop(write_half, out_rx));
    // 读和写各用一个任务：主循环用通道收消息，这样请求处理、状态推送和「允许控制」检查
    // 都不会把读到一半的行丢掉（`read_msg` 本身不能被取消）。
    let (incoming, incoming_rx) = mpsc::channel::<Result<Msg>>(IN_QUEUE);
    let reader = tokio::spawn(read_loop(read_half, incoming));

    let result = session(&s, incoming_rx, &out).await;

    // 收尾：断开读任务（它可能还卡在套接字上），再把写任务剩下的写完。
    reader.abort();
    drop(out);
    let _ = writer.await;
    result
}

async fn read_loop(read_half: OwnedReadHalf, tx: mpsc::Sender<Result<Msg>>) {
    let mut reader = BufReader::new(read_half);
    loop {
        match read_msg(&mut reader).await {
            Ok(Some(msg)) => {
                if tx.send(Ok(msg)).await.is_err() {
                    return;
                }
            }
            Ok(None) => return,
            // 读坏了就把错误交上去，让主循环收尾（它决定回不回 `Denied`）。
            Err(e) => {
                let _ = tx.send(Err(e)).await;
                return;
            }
        }
    }
}

async fn write_loop(mut out: OwnedWriteHalf, mut rx: mpsc::Receiver<Msg>) {
    while let Some(msg) = rx.recv().await {
        if write_msg(&mut out, &msg).await.is_err() {
            break;
        }
    }
    let _ = out.shutdown().await;
}

/// 等一条消息；超时 / 对方关闭都变成错误（调用方决定要不要回 `Denied`）。
async fn expect(incoming: &mut mpsc::Receiver<Result<Msg>>, wait: Duration) -> Result<Msg> {
    match tokio::time::timeout(wait, incoming.recv()).await {
        Ok(Some(Ok(msg))) => Ok(msg),
        Ok(Some(Err(e))) => Err(e),
        Ok(None) => Err(LekisError::new(ErrorCode::Network, "connection closed")),
        Err(_) => Err(LekisError::new(ErrorCode::Network, "timed out")),
    }
}

async fn deny(out: &mpsc::Sender<Msg>, reason: DenyReason) {
    let _ = out.send(Msg::Denied { reason }).await;
}

/// 握手阶段拿到的对方身份和会话随机数。
struct Peer {
    device_id: String,
    name: String,
    platform: String,
    transcript: Transcript,
}

/// 握手完成后进入请求循环。返回 `Ok` 表示这条连接正常结束，`Err` 表示协议错误。
async fn session(
    s: &Arc<Services>,
    mut incoming: mpsc::Receiver<Result<Msg>>,
    out: &mpsc::Sender<Msg>,
) -> Result<()> {
    let Msg::Hello {
        device_id,
        name,
        platform,
        version,
        nonce,
    } = expect(&mut incoming, GREETING_TIMEOUT).await?
    else {
        return Err(LekisError::invalid("expected hello"));
    };
    if version != PROTOCOL_VERSION {
        deny(out, DenyReason::Incompatible).await;
        return Ok(());
    }
    if device_id.trim().is_empty() || device_id == s.device_id.0 {
        return Err(LekisError::invalid("bad device id in hello"));
    }
    let key = s.connect.peers().key(&device_id);
    let accepting = s.connect.allow_control();
    let server_nonce = crypto::random_hex(16)?;
    let welcome = Msg::Welcome {
        device_id: s.device_id.0.clone(),
        name: s
            .connect
            .settings()
            .map(|c| c.device_name)
            .unwrap_or_else(|| s.config.device_name.clone()),
        platform: super::platform_name(s),
        version: PROTOCOL_VERSION,
        nonce: server_nonce.clone(),
        paired: key.is_some(),
        accepting,
    };
    if out.send(welcome).await.is_err() {
        return Ok(());
    }
    if !accepting {
        deny(out, DenyReason::NotAccepting).await;
        return Ok(());
    }
    let peer = Peer {
        transcript: Transcript {
            client_id: device_id.clone(),
            server_id: s.device_id.0.clone(),
            client_nonce: nonce,
            server_nonce,
        },
        device_id,
        name,
        platform,
    };
    // Dispatch on what the controller actually sends, not only on whether a
    // key is stored here: if the controller lost its key (reinstall, cleared
    // data) while this side kept one, it starts pairing again. Re-pairing
    // still needs the code shown on this screen, and replaces the old key.
    let authenticated = match expect(&mut incoming, HANDSHAKE_TIMEOUT).await? {
        Msg::Auth { mac } => match &key {
            Some(key) => authenticate(&peer, key, &mac, out).await,
            None => {
                deny(out, DenyReason::Protocol).await;
                false
            }
        },
        Msg::PairStart { public_key } => {
            if key.is_some() {
                tracing::info!(target: "connect", peer = %peer.device_id, "controller lost its key; pairing again");
            }
            pair(s, &peer, public_key, &mut incoming, out).await?
        }
        _ => {
            deny(out, DenyReason::Protocol).await;
            false
        }
    };
    if !authenticated {
        return Ok(());
    }
    tracing::info!(target: "connect", peer = %peer.device_id, name = %peer.name, "controller connected");
    let controller = s.connect.controller_joined(peer.name.clone());
    let result = control(s, &peer, &mut incoming, out).await;
    s.connect.controller_left(controller);
    tracing::info!(target: "connect", peer = %peer.device_id, "controller disconnected");
    result
}

/// 已经配对过：校验控制端 `Auth` 里的 [mac]，回 `AuthOk`。
async fn authenticate(peer: &Peer, key: &[u8], mac: &str, out: &mpsc::Sender<Msg>) -> bool {
    if !crypto::mac_eq(&crypto::auth_mac(key, "c", &peer.transcript), mac) {
        tracing::info!(target: "connect", peer = %peer.device_id, "control authentication failed");
        deny(out, DenyReason::AuthFailed).await;
        return false;
    }
    let reply = Msg::AuthOk {
        mac: crypto::auth_mac(key, "s", &peer.transcript),
    };
    out.send(reply).await.is_ok()
}

/// 配对进行中（被控端这一半）的临时材料。
struct Pairing {
    /// 界面上显示的 6 位配对码。
    code: String,
    /// 本机的临时 X25519 密钥。
    eph: Ephemeral,
    /// 控制端的临时公钥（`PairStart`）。
    client_public: String,
    /// 本机的临时公钥（`PairChallenge`）。
    server_public: String,
}

/// 没配对过：被控端显示 6 位配对码，用户把它输进控制端后两边各自存下长期密钥。
async fn pair(
    s: &Services,
    peer: &Peer,
    public_key: String,
    incoming: &mut mpsc::Receiver<Result<Msg>>,
    out: &mpsc::Sender<Msg>,
) -> Result<bool> {
    if !s.connect.allow_pair_attempt() {
        deny(out, DenyReason::RateLimited).await;
        return Ok(false);
    }
    let eph = Ephemeral::generate()?;
    let server_public = eph.public_hex.clone();
    let code = crypto::pairing_code()?;
    if out
        .send(Msg::PairChallenge {
            public_key: server_public.clone(),
        })
        .await
        .is_err()
    {
        return Ok(false);
    }
    s.connect.emit(ConnectEvent::PairingCode {
        peer_id: peer.device_id.clone(),
        peer_name: peer.name.clone(),
        code: code.clone(),
    });
    let pairing = Pairing {
        code,
        eph,
        client_public: public_key,
        server_public,
    };
    let outcome = confirm_pairing(s, peer, pairing, incoming, out).await;
    // 只要配对码已经显示出去过，就一定要告诉界面收起来（成功或失败）。
    s.connect.emit(ConnectEvent::PairingFinished {
        peer_id: peer.device_id.clone(),
        peer_name: peer.name.clone(),
        success: matches!(outcome, Ok(true)),
    });
    outcome
}

async fn confirm_pairing(
    s: &Services,
    peer: &Peer,
    pairing: Pairing,
    incoming: &mut mpsc::Receiver<Result<Msg>>,
    out: &mpsc::Sender<Msg>,
) -> Result<bool> {
    let Pairing {
        code,
        eph,
        client_public,
        server_public,
    } = pairing;
    let Msg::PairConfirm { mac } = expect(incoming, PAIR_TIMEOUT).await? else {
        deny(out, DenyReason::Protocol).await;
        return Ok(false);
    };
    let shared = eph.agree(&client_public)?;
    let pair_key = crypto::pair_key(
        &shared,
        &code,
        &peer.transcript,
        &client_public,
        &server_public,
    );
    if !crypto::mac_eq(&crypto::pair_confirm(&pair_key, "c"), &mac) {
        deny(out, DenyReason::WrongCode).await;
        return Ok(false);
    }
    if out
        .send(Msg::PairOk {
            mac: crypto::pair_confirm(&pair_key, "s"),
        })
        .await
        .is_err()
    {
        return Ok(false);
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
    tracing::info!(target: "connect", peer = %peer.device_id, "paired");
    Ok(true)
}

/// 已认证：处理请求，并把状态推给订阅过的控制端。
async fn control(
    s: &Services,
    peer: &Peer,
    incoming: &mut mpsc::Receiver<Result<Msg>>,
    out: &mpsc::Sender<Msg>,
) -> Result<()> {
    let mut states = s.engine.subscribe();
    let mut subscribed = false;
    let started = tokio::time::Instant::now() + CONTROL_CHECK;
    let mut check = tokio::time::interval_at(started, CONTROL_CHECK);
    loop {
        tokio::select! {
            next = incoming.recv() => {
                let Some(msg) = next else { return Ok(()) };
                let Msg::Request { id, req } = msg? else {
                    // 认证之后只接受 Request（控制端不会主动发别的）。
                    return Err(LekisError::invalid("unexpected control message"));
                };
                if matches!(req, Request::Subscribe) {
                    // 先把当前快照标成已读，免得刚订阅就推一条和 GetState 重复的旧状态。
                    subscribed = true;
                    let _ = states.borrow_and_update();
                }
                let reply = handle_request(s, req).await;
                respond(out, id, reply).await?;
            }
            changed = states.changed(), if subscribed => {
                if changed.is_err() {
                    return Ok(());
                }
                let snap = states.borrow_and_update().clone();
                let state = remote_state(s, &snap).await;
                if out.send(Msg::Event { state }).await.is_err() {
                    return Ok(());
                }
            }
            _ = check.tick() => {
                if !s.connect.allow_control() {
                    tracing::info!(target: "connect", peer = %peer.device_id, "control revoked, closing");
                    deny(out, DenyReason::NotAccepting).await;
                    return Ok(());
                }
            }
        }
    }
}

async fn respond(out: &mpsc::Sender<Msg>, id: u64, reply: Result<Reply>) -> Result<()> {
    let msg = match reply {
        Ok(result) => Msg::Response {
            id,
            result: Some(result),
            error: None,
        },
        // 线上只有字符串；控制端拿到后按内部错误处理，够用。
        Err(e) => Msg::Response {
            id,
            result: None,
            error: Some(e.message),
        },
    };
    out.send(msg)
        .await
        .map_err(|_| LekisError::new(ErrorCode::Network, "connection closed"))
}

async fn handle_request(s: &Services, req: Request) -> Result<Reply> {
    match req {
        Request::GetState => Ok(Reply::State {
            state: remote_state(s, &s.engine.snapshot()).await,
        }),
        // 订阅状态在 `control` 里只要置个标记；回复就是 Ok。
        Request::Subscribe => Ok(Reply::Ok),
        Request::Control { action } => {
            apply_control(s, action)?;
            Ok(Reply::Ok)
        }
        Request::SetQueue {
            items,
            start,
            position_ms,
            play,
        } => set_queue(s, &items, start, position_ms, play).await,
        Request::GetQueue { offset, limit } => queue_page(s, offset, limit).await,
        Request::GetArtwork { track_id } => Ok(Reply::Artwork {
            data_base64: artwork_bytes(s, TrackId(track_id))
                .await
                .map(|bytes| base64::engine::general_purpose::STANDARD.encode(bytes)),
        }),
    }
}

/// 控制端推过来的队列：按「同一音源 → 自己的资料库 → 控制端的局域网流」逐首解析。
async fn set_queue(
    s: &Services,
    items: &[TrackRef],
    start: u32,
    position_ms: u64,
    play: bool,
) -> Result<Reply> {
    if items.is_empty() {
        return Err(LekisError::invalid("queue must not be empty"));
    }
    let (tracks, start, report) = media::resolve_queue(s, items, start).await?;
    if tracks.is_empty() {
        return Ok(Reply::Queued { report });
    }
    let engine = &s.engine;
    // 装队列会立刻打开输出流：不自动播放时先把音量压到 0，暂停 / 跳转之后再还原，
    // 免得控制端在自己家里先听到一小段声音。
    let volume = engine.snapshot().volume;
    if !play {
        engine.send(EngineCommand::SetVolume(0.0))?;
    }
    engine.send(EngineCommand::SetQueue { tracks, start })?;
    if position_ms > 0 {
        engine.send(EngineCommand::Seek(position_ms))?;
    }
    if !play {
        engine.send(EngineCommand::Pause)?;
        engine.send(EngineCommand::SetVolume(volume))?;
    }
    Ok(Reply::Queued { report })
}

async fn queue_page(s: &Services, offset: u32, limit: u32) -> Result<Reply> {
    let snap = s.engine.snapshot();
    let skip = offset as usize;
    let take = limit.min(QUEUE_PAGE_MAX) as usize;
    let mut items = Vec::new();
    for id in snap.queue.iter().skip(skip).take(take) {
        items.push(media::remote_track(s, *id).await);
    }
    Ok(Reply::Queue { items })
}

fn apply_control(s: &Services, action: Control) -> Result<()> {
    let engine = &s.engine;
    match action {
        Control::Play => engine.send(EngineCommand::Play),
        Control::Pause => engine.send(EngineCommand::Pause),
        Control::Toggle => match engine.snapshot().state {
            PlaybackState::Playing | PlaybackState::Buffering => engine.send(EngineCommand::Pause),
            _ => engine.send(EngineCommand::Play),
        },
        Control::Next => engine.send(EngineCommand::Next),
        Control::Previous => engine.send(EngineCommand::Previous),
        Control::Seek { position_ms } => engine.send(EngineCommand::Seek(position_ms)),
        Control::Volume { volume } => engine.send(EngineCommand::SetVolume(volume.clamp(0.0, 1.0))),
        Control::Repeat { mode } => engine.send(EngineCommand::SetRepeat(mode)),
        Control::Shuffle { mode } => engine.send(EngineCommand::SetShuffle(mode)),
        Control::PlayIndex { index } => {
            // 引擎没有"跳到播放顺序第 N 首"的命令：拿同一份队列重新装一次，效果一样。
            let snap = engine.snapshot();
            if snap.queue.is_empty() {
                return Err(LekisError::invalid("queue is empty"));
            }
            let start = (index as usize).min(snap.queue.len() - 1);
            engine.send(EngineCommand::SetQueue {
                tracks: snap.queue.to_vec(),
                start,
            })
        }
    }
}

/// 本机播放状态 → 发给控制端的快照。
async fn remote_state(s: &Services, snap: &PlaybackSnapshot) -> RemoteState {
    let track = match snap.track_id {
        Some(id) => Some(media::remote_track(s, id).await),
        None => None,
    };
    RemoteState {
        state: snap.state,
        track,
        position_ms: snap.position_ms,
        duration_ms: snap.duration_ms,
        volume: snap.volume,
        queue_len: snap.queue_len,
        queue_index: snap.queue_index,
        repeat: snap.repeat,
        shuffle: snap.shuffle,
        queue_version: snap.queue_version,
    }
}

/// 一首歌的封面字节（控制端拿不到时用它自己资料库里同一首歌的封面兜底）。
pub(crate) async fn artwork_bytes(s: &Services, id: TrackId) -> Option<Vec<u8>> {
    let artwork = s.library.effective_artwork(id).await.ok().flatten()?;
    let path = crate::enrich::artwork_file_path(&s.config, &artwork.hash, ARTWORK_WIDTH);
    tokio::fs::read(&path)
        .await
        .ok()
        .filter(|bytes| !bytes.is_empty())
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::config::CoreConfig;
    use crate::{LekisCore, PlatformServices};
    use lekis_types::{SourceConfig, SourceKind, TrackQuery, TrackSort};
    use std::sync::Mutex;
    use std::time::Instant;

    use super::super::{
        ConnectDevice, ConnectEvent, ConnectListener, ConnectStartOptions, PairStart,
    };

    struct Events(Mutex<Vec<ConnectEvent>>);

    impl Events {
        fn collect(&self) -> Vec<ConnectEvent> {
            self.0.lock().map(|e| e.clone()).unwrap_or_default()
        }
    }

    impl ConnectListener for Events {
        fn on_connect_event(&self, event: ConnectEvent) {
            if let Ok(mut list) = self.0.lock() {
                list.push(event);
            }
        }
    }

    /// 一台测试用的核心，数据目录独占。
    fn core(name: &str) -> LekisCore {
        let root = std::env::temp_dir().join(format!(
            "lekis-connect-{name}-{}-{}",
            std::process::id(),
            lekis_types::now_ms()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("data dir");
        LekisCore::new(CoreConfig::for_tests(&root), PlatformServices::in_memory()).expect("core")
    }

    /// 等到界面拿到配对码（配对码是通过事件推给界面的）。
    fn wait_for_code(events: &Events, deadline: Duration) -> Option<String> {
        let started = Instant::now();
        while started.elapsed() < deadline {
            for event in events.collect() {
                if let ConnectEvent::PairingCode { code, .. } = event {
                    return Some(code);
                }
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        None
    }

    fn device_named(devices: &[ConnectDevice], id: &str) -> Option<ConnectDevice> {
        devices.iter().find(|d| d.device_id == id).cloned()
    }

    /// 两台核心之间的完整一轮：手动添加 → 配对码 → 认证连接 → 遥控。
    #[test]
    fn pairing_then_remote_control_over_a_real_socket() {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("runtime");
        let server = core("server");
        let client = core("client");
        let events = Arc::new(Events(Mutex::new(Vec::new())));
        server.add_connect_listener(events.clone());

        let port = rt
            .block_on(server.connect_start(ConnectStartOptions {
                port: Some(0),
                mdns: false,
            }))
            .expect("listen");
        assert!(port > 0);
        // 控制端自己也要跑起来（设备列表挂在它的 Connect 状态上）。
        rt.block_on(client.connect_start(ConnectStartOptions {
            port: Some(0),
            mdns: false,
        }))
        .expect("client listen");

        // 1. 手动添加（mDNS 关掉时界面走这条路）：读回对方的名字和平台。
        let added = rt
            .block_on(client.connect_add_device("127.0.0.1".into(), port))
            .expect("probe");
        assert_eq!(added.device_id, server.device_id().0);
        assert_eq!(added.name, "test");
        assert!(!added.paired);

        // 2. 配对：被控端把 6 位配对码推给界面，用户把它输进控制端。
        let device_id = added.device_id.clone();
        let start = rt
            .block_on(client.connect_pair(device_id.clone()))
            .expect("pair start");
        assert_eq!(start, PairStart::NeedsCode);
        let code = wait_for_code(&events, Duration::from_secs(5)).expect("pairing code");
        assert_eq!(code.len(), 6);
        rt.block_on(client.connect_pair_confirm(device_id.clone(), code))
            .expect("pair confirm");
        assert!(events
            .collect()
            .iter()
            .any(|e| matches!(e, ConnectEvent::PairingFinished { success: true, .. })));

        // 3. 遥控：读状态、发命令、拿队列。
        let state = rt
            .block_on(client.connect_remote_state(device_id.clone()))
            .expect("remote state");
        assert_eq!(state.state, PlaybackState::Idle);
        rt.block_on(client.connect_control(device_id.clone(), Control::Pause))
            .expect("control");
        let queue = rt
            .block_on(client.connect_remote_queue(device_id.clone(), 0, 10))
            .expect("queue");
        assert!(queue.is_empty());

        // 4. 断线重连走长期密钥那条路（不是配对码）。
        rt.block_on(client.connect_disconnect(device_id.clone()))
            .expect("disconnect");
        rt.block_on(client.connect_remote_state(device_id.clone()))
            .expect("reconnect");
        assert!(
            device_named(&client.connect_devices(), &device_id)
                .expect("device")
                .paired
        );

        rt.block_on(client.connect_stop()).expect("stop client");
        rt.block_on(server.connect_stop()).expect("stop server");
    }

    /// 控制端丢了密钥（重装 / 清数据 / 在控制端上"忘记"），被控端还记着：
    /// 控制端重新发起配对必须能成功（仍然要输入新的配对码），而不是被当成
    /// 协议错误拒掉——真机上 Fold5 → Windows 就卡在这里。
    #[test]
    fn controller_that_lost_its_key_can_pair_again() {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("runtime");
        let server = core("server-repair");
        let client = core("client-repair");
        let events = Arc::new(Events(Mutex::new(Vec::new())));
        server.add_connect_listener(events.clone());
        let opts = || ConnectStartOptions {
            port: Some(0),
            mdns: false,
        };
        let port = rt.block_on(server.connect_start(opts())).expect("listen");
        rt.block_on(client.connect_start(opts()))
            .expect("client listen");
        let device_id = rt
            .block_on(client.connect_add_device("127.0.0.1".into(), port))
            .expect("probe")
            .device_id;

        let pair_once = |events: &Events| {
            if let Ok(mut list) = events.0.lock() {
                list.clear();
            }
            let start = rt
                .block_on(client.connect_pair(device_id.clone()))
                .expect("pair start");
            assert_eq!(start, PairStart::NeedsCode);
            let code = wait_for_code(events, Duration::from_secs(5)).expect("pairing code");
            rt.block_on(client.connect_pair_confirm(device_id.clone(), code))
                .expect("pair confirm");
        };
        pair_once(&events);

        // Only the controller forgets; the server still holds its key.
        rt.block_on(client.connect_forget(device_id.clone()))
            .expect("forget");
        assert!(
            !device_named(&client.connect_devices(), &device_id)
                .expect("device")
                .paired
        );

        // Pairing again shows a new code and succeeds.
        pair_once(&events);
        rt.block_on(client.connect_remote_state(device_id.clone()))
            .expect("controls after re-pairing");

        // And the fresh key is the one that authenticates from now on.
        rt.block_on(client.connect_disconnect(device_id.clone()))
            .expect("disconnect");
        rt.block_on(client.connect_remote_state(device_id.clone()))
            .expect("reconnect with the new key");

        rt.block_on(client.connect_stop()).expect("stop client");
        rt.block_on(server.connect_stop()).expect("stop server");
    }

    /// 同一个端口既跑控制通道也跑媒体流：靠第一个字节分流。
    #[test]
    fn the_same_port_serves_stream_tokens() {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("runtime");
        let core = core("stream");
        let root = core.config().data_dir.clone();
        let music = root.join("music");
        std::fs::create_dir_all(&music).expect("music dir");
        std::fs::write(music.join("01. Track.flac"), b"not really audio").expect("write");

        let port = rt
            .block_on(core.connect_start(ConnectStartOptions {
                port: Some(0),
                mdns: false,
            }))
            .expect("listen");
        let source = rt
            .block_on(core.add_source(SourceConfig {
                id: None,
                kind: SourceKind::Local,
                name: "Music".into(),
                addresses: vec![music.to_string_lossy().into_owned()],
                root_path: String::new(),
                credential_ref: None,
                options: Default::default(),
                enabled: true,
            }))
            .expect("source");
        rt.block_on(core.start_scan(source)).expect("scan");
        // 扫描在后台任务里跑，等它把文件收进库里。
        let mut scanned = 0;
        for _ in 0..200 {
            scanned = rt.block_on(core.count_tracks()).expect("count");
            if scanned > 0 {
                break;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        assert_eq!(scanned, 1, "scan should index the file");
        let track = rt
            .block_on(core.list_tracks(TrackQuery {
                sort: TrackSort::Title,
                offset: 0,
                limit: 10,
            }))
            .expect("tracks")
            .first()
            .map(|row| row.id)
            .expect("scanned track");
        let token = core
            .services
            .connect
            .tokens
            .issue(track)
            .expect("stream token");

        use std::io::{Read, Write};
        let mut socket = std::net::TcpStream::connect(("127.0.0.1", port)).expect("connect");
        socket
            .set_read_timeout(Some(Duration::from_secs(5)))
            .expect("timeout");
        socket
            .write_all(
                format!("GET /stream/{token}.flac HTTP/1.1\r\nHost: x\r\nRange: bytes=0-3\r\n\r\n")
                    .as_bytes(),
            )
            .expect("request");
        let mut response = Vec::new();
        socket.read_to_end(&mut response).expect("response");
        let text = String::from_utf8_lossy(&response);
        assert!(text.starts_with("HTTP/1.1 206"), "{text}");
        assert!(text.ends_with("not "), "{text}");

        rt.block_on(core.connect_stop()).expect("stop");
    }
}
