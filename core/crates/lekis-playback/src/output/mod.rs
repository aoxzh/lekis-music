//! 音频输出。
//!
//! | 平台 | 默认后端 | 发烧友模式（PLY-05）|
//! |---|---|---|
//! | Windows | cpal（WASAPI 共享）| WASAPI 独占；以后 ASIO |
//! | Android | AAudio（低延迟、省电）| USB DAC 直出（Android 14+ 的 `AudioMixerAttributes` bit-perfect）|
//! | Linux | cpal（PipeWire / PulseAudio）| ALSA `hw:` 直出 |
//!
//! 输出后端自己创建实时线程，从 [`SampleSource`] 拉数据。
//! 实时线程里只允许从无锁环形缓冲区读（[`ring_source`]），不能分配、加锁、做 IO、写日志。

pub mod cpal_output;
pub mod ring_source;

pub use cpal_output::CpalOutput;
pub use ring_source::{ring_buffer, RingSource, RingSourceWriter};

use crate::decode::PcmFormat;
use lekis_types::Result;

/// 输出设备信息。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutputDevice {
    /// 稳定 ID（用于记住用户的选择和"每个设备一套 EQ"）。
    pub id: String,
    /// 显示名称。
    pub name: String,
    /// 是否是系统默认设备。
    pub is_default: bool,
    /// 是否支持独占 / 比特完美。
    pub supports_exclusive: bool,
}

/// 输出模式。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutputMode {
    /// 共享模式（系统混音）。
    Shared,
    /// 独占 / 比特完美：设备按音源的采样率和位深打开，跳过 DSP。
    Exclusive,
}

/// 实时线程从这里拉样本。**实现必须是无锁、无分配的**（通常是环形缓冲区的读端）。
pub trait SampleSource: Send {
    /// 填满 `out`；数据不够时补静音，并返回实际写入的样本数。
    fn fill(&mut self, out: &mut [f32]) -> usize;
}

/// 输出后端。
pub trait AudioOutput: Send {
    /// 列出可用设备。
    fn devices(&self) -> Result<Vec<OutputDevice>>;

    /// 打开设备并开始从 `source` 拉数据。返回设备实际使用的格式（共享模式下可能和请求的不同，需要重采样）。
    fn start(
        &mut self,
        device_id: Option<&str>,
        requested: PcmFormat,
        mode: OutputMode,
        source: Box<dyn SampleSource>,
    ) -> Result<PcmFormat>;

    /// 暂停（保持设备打开）。
    fn pause(&mut self) -> Result<()>;

    /// 恢复。
    fn resume(&mut self) -> Result<()>;

    /// 关闭设备。
    fn stop(&mut self) -> Result<()>;
}
