//! 音频输出。
//!
//! | 平台 | 默认后端 | 发烧友模式（PLY-05）|
//! |---|---|---|
//! | Windows | cpal（WASAPI 共享）| WASAPI 独占（wasapi_exclusive）；以后 ASIO |
//! | Android | AAudio（低延迟、省电）| USB DAC 直出（Android 14+ 的 `AudioMixerAttributes` bit-perfect）|
//! | Linux | cpal（PipeWire / PulseAudio）| ALSA `hw:` 直出 |
//!
//! 输出后端自己创建实时线程，从 [`SampleSource`] 拉数据。
//! 实时线程里只允许从无锁环形缓冲区读（[`ring_source`]），不能分配、加锁、做 IO、写日志。
//!
//! 比特完美链路（PLY-05）不走 f32：解码器输出左对齐 i32（[`NativeSampleSource`]），
//! 经 i32 环形缓冲直接打包成设备字节，见 [`bitperfect`]。

pub mod bitperfect;
pub mod cpal_output;
pub mod ring_source;
#[cfg(windows)]
pub mod wasapi_exclusive;

pub use bitperfect::{packing_candidates, NativePacking, NativePlan};
pub use cpal_output::CpalOutput;
pub use ring_source::{ring_buffer, ring_buffer_of, RingSource, RingSourceWriter};

use crate::decode::{NativeSampleFormat, PcmFormat};
use lekis_types::{ErrorCode, LekisError, Result};

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

/// 比特完美输出用的样本源（PLY-05）。
///
/// 样本是**左对齐 i32**：整数源的有效位在高位、低位为零；浮点源是 `f32::to_bits` 的位模式。
/// 与 [`SampleSource`] 一样，实现必须无锁、无分配，数据不够时补零并返回实际写入数。
pub trait NativeSampleSource: Send {
    /// 填满 `out`；数据不够时补零，并返回实际写入的样本数。
    fn fill(&mut self, out: &mut [i32]) -> usize;
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

    /// 打开**比特完美**输出流（PLY-05）：样本是左对齐 i32 / f32 位模式。
    ///
    /// 默认实现返回 Unsupported；只有真正支持独占 / 直通的后端（Windows WASAPI）覆盖它。
    fn start_native(
        &mut self,
        _device_id: Option<&str>,
        _requested: PcmFormat,
        _native: NativeSampleFormat,
        _source: Box<dyn NativeSampleSource>,
    ) -> Result<PcmFormat> {
        Err(LekisError::new(
            ErrorCode::Unsupported,
            "native bit-perfect output is not supported by this backend",
        ))
    }

    /// 当前流**实际**使用的模式（独占请求失败后会降级成共享）。
    fn output_mode(&self) -> OutputMode {
        OutputMode::Shared
    }

    /// 暂停（保持设备打开）。
    fn pause(&mut self) -> Result<()>;

    /// 恢复。
    fn resume(&mut self) -> Result<()>;

    /// 关闭设备。
    fn stop(&mut self) -> Result<()>;
}
