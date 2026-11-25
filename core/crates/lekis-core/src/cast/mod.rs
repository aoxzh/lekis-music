//! 媒体投放：Chromecast（Google Cast v2）与 DLNA / UPnP 音箱、功放。
//!
//! 媒体流直接复用 Lekis Connect 已有的局域网 HTTP Range 服务（`connect::stream`）：
//! - `http://<本机局域网 IP>:<端口>/stream/<令牌>.<扩展名>`
//! - `http://<本机局域网 IP>:<端口>/artwork/<令牌>`

pub mod chromecast;
pub mod dlna;

use crate::{LekisCore, Services};
use lekis_types::{ErrorCode, LekisError, Result, TrackId};
use std::net::{IpAddr, SocketAddr, UdpSocket};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Mutex;

/// 投放协议类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CastKind {
    /// Google Cast / Chromecast。
    Chromecast,
    /// DLNA / UPnP MediaRenderer（网络音箱、Hi-Fi 功放、数播、电视）。
    Dlna,
}

/// 局域网里发现的一台可投放设备。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CastDevice {
    /// 稳定设备标识（Chromecast UUID / DLNA UDN）。
    pub id: String,
    /// 显示名称。
    pub name: String,
    /// 型号（可选）。
    pub model: Option<String>,
    /// 投放协议类型。
    pub kind: CastKind,
    /// 设备 IP 或主机名。
    pub host: String,
    /// 端口（Chromecast 默认 8009，DLNA 为设备描述 URL 端口）。
    pub port: u16,
    /// DLNA 设备描述 XML 地址（Chromecast 为 `None`）。
    pub location_url: Option<String>,
}

/// 投送到远端设备时的曲目元数据。
#[derive(Debug, Clone)]
pub(crate) struct CastMediaItem {
    pub track_id: TrackId,
    pub stream_url: String,
    pub artwork_url: Option<String>,
    pub mime_type: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration_ms: u64,
    pub start_position_ms: u64,
}

/// 当前投放会话的状态快照。
#[derive(Debug, Clone, PartialEq)]
pub struct CastPlaybackState {
    /// 目标设备 ID。
    pub device_id: String,
    /// 目标设备名。
    pub device_name: String,
    /// 协议类型。
    pub kind: CastKind,
    /// 是否正在播放。
    pub is_playing: bool,
    /// 当前播放进度（毫秒）。
    pub position_ms: u64,
    /// 曲目总时长（毫秒）。
    pub duration_ms: u64,
    /// 目标设备音量（`0.0..=1.0`）。
    pub volume: f32,
    /// 正在投放的曲目 ID。
    pub track_id: Option<TrackId>,
    /// 标题。
    pub title: String,
    /// 艺人。
    pub artist: String,
    /// 专辑。
    pub album: String,
}

#[allow(clippy::large_enum_variant)]
enum ActiveBackend {
    Chromecast(chromecast::CastSession),
    Dlna(dlna::DlnaSession),
}

struct ActiveCast {
    backend: ActiveBackend,
    state: CastPlaybackState,
}

/// 核心持有的投放管理器。
#[derive(Default)]
pub(crate) struct CastHub {
    active: Mutex<Option<ActiveCast>>,
}

impl CastHub {
    pub(crate) fn new() -> Self {
        Self::default()
    }
}

/// 探测本机用来访问目标设备的最佳局域网 IP（通过 OS 路由表，不发送任何数据包）。
fn local_ip_for(remote_host: &str, remote_port: u16) -> Result<IpAddr> {
    let target: SocketAddr = format!("{remote_host}:{remote_port}")
        .parse()
        .or_else(|_| -> std::result::Result<SocketAddr, ()> {
            use std::net::ToSocketAddrs;
            (remote_host, remote_port)
                .to_socket_addrs()
                .ok()
                .and_then(|mut it| it.find(SocketAddr::is_ipv4))
                .ok_or(())
        })
        .map_err(|_| LekisError::invalid(format!("invalid cast host: {remote_host}")))?;
    let bind_addr = if target.is_ipv4() {
        "0.0.0.0:0"
    } else {
        "[::]:0"
    };
    let sock = UdpSocket::bind(bind_addr)
        .map_err(|e| LekisError::new(ErrorCode::Network, format!("bind udp probe: {e}")))?;
    sock.connect(target)
        .map_err(|e| LekisError::new(ErrorCode::Network, format!("route probe: {e}")))?;
    let local = sock
        .local_addr()
        .map_err(|e| LekisError::new(ErrorCode::Network, format!("local addr: {e}")))?;
    Ok(local.ip())
}

fn mime_for_ext(ext: &str) -> &'static str {
    match ext.to_ascii_lowercase().as_str() {
        "flac" => "audio/flac",
        "mp3" => "audio/mpeg",
        "m4a" | "mp4" | "aac" | "alac" => "audio/mp4",
        "ogg" | "oga" | "opus" => "audio/ogg",
        "wav" => "audio/wav",
        "aif" | "aiff" => "audio/aiff",
        "dsf" => "audio/dsd",
        "dff" => "audio/x-dff",
        "ape" => "audio/x-ape",
        "wv" => "audio/x-wavpack",
        _ => "audio/mpeg",
    }
}

/// 为指定曲目准备局域网可访问的 HTTP 流地址和封面地址（复用 Connect HTTP 服务）。
async fn prepare_media_item(
    core: &LekisCore,
    s: &Arc<Services>,
    device: &CastDevice,
    track_id: TrackId,
    position_ms: u64,
) -> Result<CastMediaItem> {
    // 确保 Connect HTTP 流服务已经启动（不强制开 mDNS）。
    let mut port = s.connect.port();
    if port == 0 {
        port = core
            .connect_start(crate::connect::ConnectStartOptions {
                port: None,
                mdns: false,
            })
            .await?;
    }
    let ip = local_ip_for(&device.host, device.port)?;
    let track = s.library.get_track(track_id).await?;
    let files = s.library.track_files(track_id).await?;
    let ext = files
        .first()
        .and_then(|f| crate::connect::stream::extension_of(&f.path))
        .unwrap_or("flac")
        .to_ascii_lowercase();
    let token = s.connect.tokens.issue(track_id)?;
    let host_part = match ip {
        IpAddr::V4(v4) => v4.to_string(),
        IpAddr::V6(v6) => format!("[{v6}]"),
    };
    let stream_url = format!("http://{host_part}:{port}/stream/{token}.{ext}");
    let artwork_url = Some(format!("http://{host_part}:{port}/artwork/{token}"));
    let artist = track
        .artists
        .iter()
        .map(|a| a.name.as_str())
        .collect::<Vec<_>>()
        .join(" / ");
    Ok(CastMediaItem {
        track_id,
        stream_url,
        artwork_url,
        mime_type: mime_for_ext(&ext).to_string(),
        title: track.title,
        artist,
        album: track.album_title.unwrap_or_default(),
        duration_ms: track.duration_ms,
        start_position_ms: position_ms,
    })
}

impl LekisCore {
    /// 扫描局域网里的 Chromecast 与 DLNA / UPnP 音箱、功放。
    pub async fn cast_discover(&self, timeout_ms: u32) -> Result<Vec<CastDevice>> {
        let timeout = Duration::from_millis(u64::from(timeout_ms.clamp(500, 10_000)));
        self.run(async move {
            let (cc_res, dlna_res) =
                tokio::join!(chromecast::discover(timeout), dlna::discover(timeout),);
            let mut out = Vec::new();
            match cc_res {
                Ok(list) => out.extend(list),
                Err(e) => {
                    tracing::debug!(target: "core::cast", error = %e, "chromecast discovery failed")
                }
            }
            match dlna_res {
                Ok(list) => out.extend(list),
                Err(e) => {
                    tracing::debug!(target: "core::cast", error = %e, "dlna discovery failed")
                }
            }
            out.sort_by_key(|a| a.name.to_lowercase());
            out.dedup_by(|a, b| a.id == b.id && a.kind == b.kind);
            Ok(out)
        })
        .await
    }

    /// 把指定曲目投放到 Chromecast 或 DLNA 设备播放，成功后暂停本机播放。
    pub async fn cast_play_track(
        &self,
        device: CastDevice,
        track_id: TrackId,
        position_ms: u64,
    ) -> Result<CastPlaybackState> {
        let s = self.services.clone();
        let item = prepare_media_item(self, &s, &device, track_id, position_ms).await?;

        let active_cast = self
            .run(async move {
                // 先停掉之前的投放会话（若有）。
                {
                    let mut guard = s.cast.active.lock().await;
                    if let Some(mut old) = guard.take() {
                        match &mut old.backend {
                            ActiveBackend::Chromecast(sess) => {
                                let _ = sess.stop().await;
                            }
                            ActiveBackend::Dlna(sess) => {
                                let _ = sess.stop().await;
                            }
                        }
                    }
                }

                let backend = match device.kind {
                    CastKind::Chromecast => {
                        let sess = chromecast::CastSession::connect_and_load(
                            &device.host,
                            device.port,
                            &item,
                        )
                        .await?;
                        ActiveBackend::Chromecast(sess)
                    }
                    CastKind::Dlna => {
                        let loc = device.location_url.as_deref().ok_or_else(|| {
                            LekisError::invalid("DLNA device is missing location URL")
                        })?;
                        let sess = dlna::DlnaSession::connect_and_load(loc, &item).await?;
                        ActiveBackend::Dlna(sess)
                    }
                };

                let state = CastPlaybackState {
                    device_id: device.id,
                    device_name: device.name,
                    kind: device.kind,
                    is_playing: true,
                    position_ms: item.start_position_ms,
                    duration_ms: item.duration_ms,
                    volume: 0.8,
                    track_id: Some(item.track_id),
                    title: item.title,
                    artist: item.artist,
                    album: item.album,
                };
                let mut guard = s.cast.active.lock().await;
                *guard = Some(ActiveCast {
                    backend,
                    state: state.clone(),
                });
                Ok::<_, LekisError>(state)
            })
            .await?;

        let _ = self.pause();
        Ok(active_cast)
    }

    /// 暂停当前投放播放。
    pub async fn cast_pause(&self) -> Result<()> {
        let s = self.services.clone();
        self.run(async move {
            let mut guard = s.cast.active.lock().await;
            let Some(active) = guard.as_mut() else {
                return Err(LekisError::not_found("no active cast session"));
            };
            match &mut active.backend {
                ActiveBackend::Chromecast(sess) => sess.pause().await?,
                ActiveBackend::Dlna(sess) => sess.pause().await?,
            }
            active.state.is_playing = false;
            Ok(())
        })
        .await
    }

    /// 恢复当前投放播放。
    pub async fn cast_resume(&self) -> Result<()> {
        let s = self.services.clone();
        self.run(async move {
            let mut guard = s.cast.active.lock().await;
            let Some(active) = guard.as_mut() else {
                return Err(LekisError::not_found("no active cast session"));
            };
            match &mut active.backend {
                ActiveBackend::Chromecast(sess) => sess.play().await?,
                ActiveBackend::Dlna(sess) => sess.play().await?,
            }
            active.state.is_playing = true;
            Ok(())
        })
        .await
    }

    /// 投放进度跳转（毫秒）。
    pub async fn cast_seek(&self, position_ms: u64) -> Result<()> {
        let s = self.services.clone();
        self.run(async move {
            let mut guard = s.cast.active.lock().await;
            let Some(active) = guard.as_mut() else {
                return Err(LekisError::not_found("no active cast session"));
            };
            match &mut active.backend {
                ActiveBackend::Chromecast(sess) => sess.seek(position_ms).await?,
                ActiveBackend::Dlna(sess) => sess.seek(position_ms).await?,
            }
            active.state.position_ms = position_ms;
            Ok(())
        })
        .await
    }

    /// 设置投放设备音量（`0.0..=1.0`）。
    pub async fn cast_set_volume(&self, volume: f32) -> Result<()> {
        let v = volume.clamp(0.0, 1.0);
        let s = self.services.clone();
        self.run(async move {
            let mut guard = s.cast.active.lock().await;
            let Some(active) = guard.as_mut() else {
                return Err(LekisError::not_found("no active cast session"));
            };
            match &mut active.backend {
                ActiveBackend::Chromecast(sess) => sess.set_volume(v).await?,
                ActiveBackend::Dlna(sess) => sess.set_volume(v).await?,
            }
            active.state.volume = v;
            Ok(())
        })
        .await
    }

    /// 停止并断开当前投放会话。
    pub async fn cast_stop(&self) -> Result<()> {
        let s = self.services.clone();
        self.run(async move {
            let mut guard = s.cast.active.lock().await;
            if let Some(mut active) = guard.take() {
                match &mut active.backend {
                    ActiveBackend::Chromecast(sess) => {
                        let _ = sess.stop().await;
                    }
                    ActiveBackend::Dlna(sess) => {
                        let _ = sess.stop().await;
                    }
                }
            }
            Ok(())
        })
        .await
    }

    /// 获取当前投放会话的最新状态（刷新设备端播放进度与状态）。
    pub async fn cast_status(&self) -> Result<Option<CastPlaybackState>> {
        let s = self.services.clone();
        self.run(async move {
            let mut guard = s.cast.active.lock().await;
            let Some(active) = guard.as_mut() else {
                return Ok(None);
            };
            match &mut active.backend {
                ActiveBackend::Chromecast(sess) => {
                    if let Ok(Some((playing, pos_ms))) = sess.poll_status().await {
                        active.state.is_playing = playing;
                        active.state.position_ms = pos_ms;
                    }
                }
                ActiveBackend::Dlna(sess) => {
                    if let Ok((playing, pos_ms, dur_ms)) = sess.poll_status().await {
                        active.state.is_playing = playing;
                        active.state.position_ms = pos_ms;
                        if dur_ms > 0 {
                            active.state.duration_ms = dur_ms;
                        }
                    }
                    if let Ok(vol) = sess.get_volume().await {
                        active.state.volume = vol;
                    }
                }
            }
            Ok(Some(active.state.clone()))
        })
        .await
    }
}
