//! 解码。
//!
//! 主解码器：symphonia（纯 Rust：MP3、AAC、ALAC、FLAC、WAV、AIFF、Vorbis……）。
//! 长尾格式（APE、TTA、DSD、WMA）：可选的 FFmpeg 组件（LGPL，动态链接）。
//!
//! 无缝播放（PLY-01）要求：解码器必须去掉 MP3 / AAC 的编码器延迟（encoder delay）和尾部填充（padding），
//! 信息来自 LAME/Xing 头或 iTunSMPB。

use lekis_types::{AudioProps, Result};

/// 解码输出的音频格式。引擎内部统一用 f32 交错样本。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PcmFormat {
    /// 采样率。
    pub sample_rate: u32,
    /// 声道数。
    pub channels: u16,
}

/// 解码器。在解码线程上使用，不能在实时线程上调用。
pub trait Decoder: Send {
    /// 流信息。
    fn props(&self) -> &AudioProps;

    /// 输出格式。
    fn format(&self) -> PcmFormat;

    /// 总时长（毫秒），未知时为 `None`（网络电台）。
    fn duration_ms(&self) -> Option<u64>;

    /// 解码下一块样本，追加到 `out`。返回 `Ok(false)` 表示到达结尾。
    fn decode_next(&mut self, out: &mut Vec<f32>) -> Result<bool>;

    /// 跳转到指定位置（毫秒）。返回实际跳到的位置。
    fn seek(&mut self, position_ms: u64) -> Result<u64>;
}
