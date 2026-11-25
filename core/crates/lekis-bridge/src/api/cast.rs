//! 媒体投放（Chromecast / DLNA）桥接 API。

use crate::api::error::CoreError;
use crate::internal::core;

/// 投放协议类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CastKindDto {
    /// Google Cast / Chromecast。
    Chromecast,
    /// DLNA / UPnP 音箱、功放、数播。
    Dlna,
}

impl From<lekis_core::CastKind> for CastKindDto {
    fn from(v: lekis_core::CastKind) -> Self {
        match v {
            lekis_core::CastKind::Chromecast => Self::Chromecast,
            lekis_core::CastKind::Dlna => Self::Dlna,
        }
    }
}

impl From<CastKindDto> for lekis_core::CastKind {
    fn from(v: CastKindDto) -> Self {
        match v {
            CastKindDto::Chromecast => Self::Chromecast,
            CastKindDto::Dlna => Self::Dlna,
        }
    }
}

/// 发现的投放设备。
#[derive(Debug, Clone)]
pub struct CastDeviceDto {
    /// 稳定设备标识。
    pub id: String,
    /// 显示名称。
    pub name: String,
    /// 型号（可选）。
    pub model: Option<String>,
    /// 协议类型。
    pub kind: CastKindDto,
    /// IP / 主机名。
    pub host: String,
    /// 端口。
    pub port: u16,
    /// DLNA 设备描述 XML 地址（Chromecast 为 `None`）。
    pub location_url: Option<String>,
}

impl From<lekis_core::CastDevice> for CastDeviceDto {
    fn from(d: lekis_core::CastDevice) -> Self {
        Self {
            id: d.id,
            name: d.name,
            model: d.model,
            kind: d.kind.into(),
            host: d.host,
            port: d.port,
            location_url: d.location_url,
        }
    }
}

impl From<CastDeviceDto> for lekis_core::CastDevice {
    fn from(d: CastDeviceDto) -> Self {
        Self {
            id: d.id,
            name: d.name,
            model: d.model,
            kind: d.kind.into(),
            host: d.host,
            port: d.port,
            location_url: d.location_url,
        }
    }
}

/// 当前投放播放状态。
#[derive(Debug, Clone)]
pub struct CastPlaybackStateDto {
    /// 设备 ID。
    pub device_id: String,
    /// 设备名。
    pub device_name: String,
    /// 协议类型。
    pub kind: CastKindDto,
    /// 是否正在播放。
    pub is_playing: bool,
    /// 当前位置（毫秒）。
    pub position_ms: u64,
    /// 总时长（毫秒）。
    pub duration_ms: u64,
    /// 音量（`0.0..=1.0`）。
    pub volume: f32,
    /// 正在播放的曲目 ID。
    pub track_id: Option<i64>,
    /// 标题。
    pub title: String,
    /// 艺人。
    pub artist: String,
    /// 专辑。
    pub album: String,
}

impl From<lekis_core::CastPlaybackState> for CastPlaybackStateDto {
    fn from(s: lekis_core::CastPlaybackState) -> Self {
        Self {
            device_id: s.device_id,
            device_name: s.device_name,
            kind: s.kind.into(),
            is_playing: s.is_playing,
            position_ms: s.position_ms,
            duration_ms: s.duration_ms,
            volume: s.volume,
            track_id: s.track_id.map(|t| t.0),
            title: s.title,
            artist: s.artist,
            album: s.album,
        }
    }
}

/// 扫描局域网内的 Chromecast 与 DLNA 音箱、功放。
pub async fn cast_discover(timeout_ms: u32) -> Result<Vec<CastDeviceDto>, CoreError> {
    Ok(core()
        .cast_discover(timeout_ms)
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// 将指定曲目投放到 Chromecast 或 DLNA 设备播放。
pub async fn cast_play_track(
    device: CastDeviceDto,
    track_id: i64,
    position_ms: u64,
) -> Result<CastPlaybackStateDto, CoreError> {
    Ok(core()
        .cast_play_track(device.into(), lekis_types::TrackId(track_id), position_ms)
        .await?
        .into())
}

/// 暂停投放播放。
pub async fn cast_pause() -> Result<(), CoreError> {
    Ok(core().cast_pause().await?)
}

/// 恢复投放播放。
pub async fn cast_resume() -> Result<(), CoreError> {
    Ok(core().cast_resume().await?)
}

/// 投放进度跳转（毫秒）。
pub async fn cast_seek(position_ms: u64) -> Result<(), CoreError> {
    Ok(core().cast_seek(position_ms).await?)
}

/// 调节投放设备音量（`0.0..=1.0`）。
pub async fn cast_set_volume(volume: f32) -> Result<(), CoreError> {
    Ok(core().cast_set_volume(volume).await?)
}

/// 停止并断开当前投放。
pub async fn cast_stop() -> Result<(), CoreError> {
    Ok(core().cast_stop().await?)
}

/// 获取当前投放会话状态。
pub async fn cast_status() -> Result<Option<CastPlaybackStateDto>, CoreError> {
    Ok(core().cast_status().await?.map(Into::into))
}
