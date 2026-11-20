//! 在其他设备上播放 / 遥控其他设备（Lekis Connect，CST-01~06）。
//!
//! 和核心的 `LekisCore::connect_*` 一一对应。除了 [`connect_port`]、
//! [`connect_devices`]、[`connect_paired_devices`]、[`connect_pair_cancel`] 是同步的，
//! 其余都要先 [`super::core::init_core`] 过，并且大多数需要 [`connect_start`] 之后才可用
//! （没启动时报 `Unsupported: connect is not started`）。

use std::sync::Arc;

use flutter_rust_bridge::frb;

use crate::api::dto::*;
use crate::api::error::CoreError;
use crate::frb_generated::StreamSink;
use crate::internal::{core, SinkConnectListener};

/// 开始监听控制连接、在局域网广播本机并浏览其他设备。返回监听端口；重复调用直接返回端口。
pub async fn connect_start(port: Option<u16>, mdns: bool) -> Result<u16, CoreError> {
    Ok(core()
        .connect_start(lekis_core::connect::ConnectStartOptions { port, mdns })
        .await?)
}

/// 停止（App 退出或进入后台很久时）。已有的控制连接一并断开。
pub async fn connect_stop() -> Result<(), CoreError> {
    Ok(core().connect_stop().await?)
}

/// 本机监听端口（未启动时为 0）。
#[frb(sync)]
pub fn connect_port() -> u16 {
    core().connect_port()
}

/// 当前设置（没启动时读的是保存的值）。
pub async fn connect_settings() -> Result<ConnectSettingsDto, CoreError> {
    Ok(core().connect_settings().await?.into())
}

/// 修改设置：改名后重新广播；关掉"允许控制"会停止广播并断开所有控制端。
pub async fn connect_set_settings(
    device_name: String,
    allow_control: bool,
) -> Result<(), CoreError> {
    Ok(core()
        .connect_set_settings(lekis_core::connect::ConnectSettings {
            device_name,
            allow_control,
        })
        .await?)
}

/// 局域网里的其他 Lekis（含手动添加的）。
#[frb(sync)]
pub fn connect_devices() -> Vec<ConnectDeviceDto> {
    core().connect_devices().into_iter().map(Into::into).collect()
}

/// 已配对的设备（包括当前不在线的）。
#[frb(sync)]
pub fn connect_paired_devices() -> Vec<PairedPeerDto> {
    core()
        .connect_paired_devices()
        .into_iter()
        .map(Into::into)
        .collect()
}

/// 手动按地址添加一台设备（组播不通时）。会连上去读一下对方的名字。
pub async fn connect_add_device(host: String, port: u16) -> Result<ConnectDeviceDto, CoreError> {
    Ok(core().connect_add_device(host, port).await?.into())
}

/// 连接一台设备：配对过就直接认证；没配对过就请对方显示配对码。
///
/// 返回 `true` 表示对方屏幕上出现了配对码，用户输入后要调 [`connect_pair_confirm`]。
pub async fn connect_pair(device_id: String) -> Result<bool, CoreError> {
    Ok(matches!(
        core().connect_pair(device_id).await?,
        lekis_core::connect::PairStart::NeedsCode
    ))
}

/// 输入对方屏幕上的配对码，完成配对。
pub async fn connect_pair_confirm(device_id: String, code: String) -> Result<(), CoreError> {
    Ok(core().connect_pair_confirm(device_id, code).await?)
}

/// 放弃正在进行的配对。
#[frb(sync)]
pub fn connect_pair_cancel(device_id: String) {
    core().connect_pair_cancel(device_id);
}

/// 删除配对（之后需要重新输入配对码）。
pub async fn connect_forget(device_id: String) -> Result<(), CoreError> {
    Ok(core().connect_forget(device_id).await?)
}

/// 断开和某台设备的控制连接（不删除配对）。
pub async fn connect_disconnect(device_id: String) -> Result<(), CoreError> {
    Ok(core().connect_disconnect(device_id).await?)
}

/// 远端设备的当前状态（同时开始接收它的状态推送）。
pub async fn connect_remote_state(device_id: String) -> Result<RemoteStateDto, CoreError> {
    Ok(core().connect_remote_state(device_id).await?.into())
}

/// 遥控：播放 / 暂停 / 切歌 / 跳转 / 音量……
pub async fn connect_control(
    device_id: String,
    action: ControlActionDto,
) -> Result<(), CoreError> {
    Ok(core().connect_control(device_id, action.into()).await?)
}

/// 远端队列的一页。
pub async fn connect_remote_queue(
    device_id: String,
    offset: u32,
    limit: u32,
) -> Result<Vec<RemoteTrackDto>, CoreError> {
    Ok(core()
        .connect_remote_queue(device_id, offset, limit)
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// 远端曲目的封面（字节）。对方没有时，用 `uid` 在本机资料库里找同一首歌的封面。
pub async fn connect_remote_artwork(
    device_id: String,
    track_id: i64,
    uid: Option<String>,
) -> Result<Option<Vec<u8>>, CoreError> {
    Ok(core()
        .connect_remote_artwork(device_id, track_id, uid)
        .await?)
}

/// 转移播放：把本机当前队列和进度交给另一台设备，成功后本机暂停（`pause_local`）。
pub async fn connect_transfer(
    device_id: String,
    pause_local: bool,
) -> Result<QueueReportDto, CoreError> {
    Ok(core().connect_transfer(device_id, pause_local).await?.into())
}

/// 让另一台设备播放一组本机曲目（"在 xx 上播放"）。
pub async fn connect_play_on(
    device_id: String,
    track_ids: Vec<i64>,
    start: u32,
    position_ms: u64,
    play: bool,
) -> Result<QueueReportDto, CoreError> {
    let tracks = track_ids.into_iter().map(lekis_types::TrackId).collect();
    Ok(core()
        .connect_play_on(device_id, tracks, start, position_ms, play)
        .await?
        .into())
}

/// Connect 事件流（设备列表、配对码、远端状态……）。
pub fn connect_events(sink: StreamSink<ConnectEventDto>) {
    core().add_connect_listener(Arc::new(SinkConnectListener(sink)));
}
