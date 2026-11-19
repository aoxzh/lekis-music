//! 播放引擎（REQUIREMENTS 3.4 节，PLY-01~13）。
//!
//! ```text
//! MediaSource（VFS Range 读 / HTTP 流）→ 预读缓冲
//!   → Decoder（symphonia；长尾格式用 FFmpeg）→ f32 交错样本
//!   → DSP 链：ReplayGain → EQ → 淡入淡出混音 → 限幅器
//!   → 重采样（只在需要时）→ AudioOutput（cpal / WASAPI 独占 / AAudio / ALSA hw）
//! ```
//!
//! **实时线程规则**（docs/ARCHITECTURE.md 第 3 节）：输出回调里不能分配内存、加锁、做 IO、写日志。
//! 解码线程把样本写进无锁环形缓冲区，输出回调只从里面读。
//!
//! 引擎不决定"播哪个文件"：lekis-core 把曲目解析成 [`MediaSource`] 之后再交给引擎。

pub mod decode;
pub mod dsp;
pub mod engine;
pub mod gapless;
pub mod output;
pub mod queue;
pub mod resample;
pub mod session;
pub mod vfs_access;

#[cfg(test)]
pub(crate) mod test_support;

pub use decode::{
    open_decoder, Decoder, HttpRangeSource, PcmFormat, SymphoniaDecoder, VfsMediaSource,
};
pub use engine::{list_output_devices, EngineCommand, PlaybackEngine, PlaybackSnapshot};
pub use gapless::{AudibleTrack, TrackTimeline};
pub use output::{AudioOutput, CpalOutput, OutputDevice, OutputMode, SampleSource};
pub use queue::Queue;
pub use resample::FormatConverter;
pub use session::{CpalOutputFactory, OutputFactory, Session};

use lekis_types::TrackId;

/// 一首可以播放的媒体（已经选好源）。
#[derive(Debug, Clone, PartialEq)]
pub struct MediaSource {
    /// 对应的曲目。
    pub track_id: TrackId,
    /// 读取方式。
    pub location: MediaLocation,
    /// 已知时长（毫秒），用于进度条；解码后会用实际值覆盖。
    pub duration_hint_ms: u64,
    /// ReplayGain（dB），由 core 根据用户设置选好"曲目增益"还是"专辑增益"。
    pub gain_db: Option<f32>,
}

/// 媒体位置。
#[derive(Debug, Clone, PartialEq)]
pub enum MediaLocation {
    /// 某个文件系统类源里的文件（由 core 注入的读取器负责 Range 读取）。
    Vfs {
        /// 源 ID。
        source_id: lekis_types::SourceId,
        /// 路径。
        path: String,
    },
    /// HTTP(S) 地址（服务器源、插件源、网络电台）。
    Url {
        /// 地址。
        url: String,
        /// 请求头。
        headers: Vec<(String, String)>,
    },
    /// 本地缓存 / 离线文件的绝对路径。
    CachedFile {
        /// 路径。
        path: String,
    },
}
