//! Android USB DAC 直出（PLY-05）：开关、状态。
//!
//! 开关打开时引擎切到独占模式；每首歌开始前 `lekis_playback::output::usb_direct` 按曲目格式
//! 设置 USB 设备的比特完美混音器属性并按同一格式开 AAudio 流，不支持时自动退回普通输出。
//! 其他平台上这些函数都是空操作，状态恒为 `Unavailable`。

use flutter_rust_bridge::frb;
use lekis_playback::output::usb_direct::{self, UsbDirectState, UsbDirectStatus};

use crate::api::dto::OutputModeDto;
use crate::api::error::CoreError;
use crate::internal::core;
use crate::usb_audio::{apply, USB_BIT_PERFECT_SETTING};

/// USB 直出状态。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UsbBitPerfectStateDto {
    /// 没开。
    Disabled,
    /// 本平台不支持（非 Android，或还没初始化）。
    Unavailable,
    /// 开了，但没有连接 USB 音频设备。
    NoDevice,
    /// 系统低于 Android 14，或设备不支持比特完美混音器。
    Unsupported,
    /// 设备支持比特完美，但不支持当前曲目的格式，本曲已回退普通输出。
    FormatFallback,
    /// 就绪，下一首开始直出。
    Ready,
    /// 正在比特完美输出。
    Active,
    /// 设置失败，本曲已回退普通输出。
    Failed,
}

/// USB 直出状态快照。
#[derive(Debug, Clone)]
pub struct UsbBitPerfectStatusDto {
    /// 当前平台是否有这个功能（Android）。
    pub available: bool,
    /// 用户是否打开。
    pub enabled: bool,
    /// 状态。
    pub state: UsbBitPerfectStateDto,
    /// USB 设备名。
    pub device_name: Option<String>,
    /// 设备是否报告了任何比特完美格式。
    pub device_supports_bit_perfect: bool,
    /// Android SDK 版本（0 = 未知）。
    pub sdk_int: i32,
    /// 采样率（正在直出 / 最近尝试的曲目）。
    pub sample_rate: Option<u32>,
    /// 声道数。
    pub channels: Option<u16>,
    /// 源位深（浮点为 32）。
    pub source_bits: Option<u8>,
    /// 源是否为浮点。
    pub source_float: bool,
    /// 设备容器位宽（16 / 24 / 32）。
    pub container_bits: Option<u8>,
    /// 回退 / 失败原因（英文诊断信息）。
    pub message: Option<String>,
}

impl From<UsbDirectStatus> for UsbBitPerfectStatusDto {
    fn from(s: UsbDirectStatus) -> Self {
        let state = match s.state {
            UsbDirectState::Disabled => UsbBitPerfectStateDto::Disabled,
            UsbDirectState::Unavailable => UsbBitPerfectStateDto::Unavailable,
            UsbDirectState::NoDevice => UsbBitPerfectStateDto::NoDevice,
            UsbDirectState::Unsupported => UsbBitPerfectStateDto::Unsupported,
            UsbDirectState::FormatFallback => UsbBitPerfectStateDto::FormatFallback,
            UsbDirectState::Ready => UsbBitPerfectStateDto::Ready,
            UsbDirectState::Active => UsbBitPerfectStateDto::Active,
            UsbDirectState::Failed => UsbBitPerfectStateDto::Failed,
        };
        Self {
            available: cfg!(target_os = "android"),
            enabled: s.enabled,
            state,
            device_name: s.device_name,
            device_supports_bit_perfect: s.device_supports_bit_perfect,
            sdk_int: s.sdk_int,
            sample_rate: s.format.map(|f| f.sample_rate),
            channels: s.format.map(|f| f.channels),
            source_bits: s.format.map(|f| f.source_bits),
            source_float: s.format.is_some_and(|f| f.source_float),
            container_bits: s.format.map(|f| f.packing.container_bytes() as u8 * 8),
            message: s.message,
        }
    }
}

/// 当前 USB 直出状态。
#[frb(sync)]
pub fn usb_bit_perfect_status() -> UsbBitPerfectStatusDto {
    usb_direct::usb_direct_status().into()
}

/// 打开 / 关闭 USB 直出并持久化。打开时引擎切到独占模式（播放中会从当前位置续播），
/// 关闭时清掉首选混音器属性并切回共享模式。
///
/// 返回引擎随之使用的输出模式（非 Android 上为 `None`，模式不变），界面据此同步「输出模式」。
pub async fn set_usb_bit_perfect(enabled: bool) -> Result<Option<OutputModeDto>, CoreError> {
    let mode = apply(enabled)?;
    core()
        .set_setting(
            USB_BIT_PERFECT_SETTING.to_string(),
            if enabled { "true" } else { "false" }.to_string(),
        )
        .await?;
    Ok(mode.map(Into::into))
}

/// 重新探测 USB 设备（设置页打开时调用，拿到最新的设备和支持情况）。
#[frb(sync)]
pub fn refresh_usb_bit_perfect() -> UsbBitPerfectStatusDto {
    usb_direct::usb_devices_changed();
    usb_direct::usb_direct_status().into()
}
