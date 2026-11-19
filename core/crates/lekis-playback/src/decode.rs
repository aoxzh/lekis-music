//! 解码。
//!
//! 主解码器：symphonia（纯 Rust：MP3、AAC、ALAC、FLAC、WAV、AIFF、Vorbis……）。
//! 长尾格式（APE、TTA、DSD、WMA）：可选的 FFmpeg 组件（LGPL，动态链接）。
//!
//! 无缝播放（PLY-01）要求：解码器必须去掉 MP3 / AAC 的编码器延迟（encoder delay）和尾部填充（padding），
//! 信息来自 LAME/Xing 头或 iTunSMPB。symphonia 的 `AudioDecoderOptions::gapless`（默认开启）
//! 会按 demuxer 给出的 `Packet::trim_start` / `trim_end` 自动裁掉这些帧，所以这里不用再手算。

pub mod media_source;
pub mod symphonia_decoder;
pub mod url_source;

pub use media_source::VfsMediaSource;
pub use symphonia_decoder::SymphoniaDecoder;
pub use url_source::HttpRangeSource;

use crate::vfs_access;
use crate::{MediaLocation, MediaSource};
use lekis_types::{ErrorCode, LekisError, Result};
use tokio::runtime::Handle;

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
    fn props(&self) -> &lekis_types::AudioProps;

    /// 输出格式。
    fn format(&self) -> PcmFormat;

    /// 总时长（毫秒），未知时为 `None`（网络电台）。
    fn duration_ms(&self) -> Option<u64>;

    /// 解码下一块样本，追加到 `out`。返回 `Ok(false)` 表示到达结尾。
    fn decode_next(&mut self, out: &mut Vec<f32>) -> Result<bool>;

    /// 跳转到指定位置（毫秒）。返回实际跳到的位置。
    fn seek(&mut self, position_ms: u64) -> Result<u64>;
}

/// 按 [`MediaSource`] 打开解码器。
///
/// - `CachedFile`：直接读本地文件（`std::fs::File` 已经实现 symphonia 的 `MediaSource`）。
/// - `Vfs`：通过宿主注册的 VFS 解析器（[`vfs_access::install_vfs_resolver`]）分块读取，
///   见 [`VfsMediaSource`]。
/// - `Url`：HTTP Range 分块读取（[`HttpRangeSource`]），`MediaLocation` 里的请求头会
///   附加到每个请求上（服务器源的 token 在头里）。
///
/// **必须在一个没有 tokio 运行时上下文的线程上调用**：VFS 的 `read_range` 是异步的，
/// 这里用 `Handle::block_on` 同步等待；HTTP 用的是 reqwest 的 blocking 客户端。
/// 在 tokio worker 线程上这两者都会出问题，所以引擎总是把解码器开在专用的解码线程里。
pub fn open_decoder(media: &MediaSource, handle: &Handle) -> Result<Box<dyn Decoder>> {
    match &media.location {
        MediaLocation::CachedFile { path } => {
            let file = std::fs::File::open(path)
                .map_err(|e| LekisError::new(ErrorCode::Io, format!("cannot open {path}: {e}")))?;
            let ext = extension_of(path);
            Ok(Box::new(SymphoniaDecoder::open_file(file, ext.as_deref())?))
        }
        MediaLocation::Vfs { source_id, path } => {
            let Some(vfs) = vfs_access::resolve(*source_id) else {
                return Err(LekisError::not_implemented(
                    "vfs playback: no vfs resolver installed",
                ));
            };
            let Some(vfs_path) = lekis_vfs::VfsPath::parse(path) else {
                return Err(LekisError::invalid(format!("invalid vfs path: {path}")));
            };
            let ext = vfs_path.extension().map(|e| e.to_ascii_lowercase());
            let len = match handle.block_on(vfs.stat(&vfs_path)) {
                Ok(meta) => Some(meta.size),
                Err(e) => {
                    tracing::debug!(
                        target: "playback::decode",
                        source = %source_id,
                        path = %path,
                        error = %e,
                        "stat failed, byte length unknown"
                    );
                    None
                }
            };
            let source = VfsMediaSource::new(vfs, vfs_path, len, handle.clone());
            Ok(Box::new(SymphoniaDecoder::open_source(
                Box::new(source),
                ext.as_deref(),
            )?))
        }
        MediaLocation::Url { url, headers } => {
            let ext = extension_of_url(url);
            let source = HttpRangeSource::new(url.clone(), headers.clone())?;
            tracing::debug!(
                target: "playback::decode",
                %url,
                byte_len = ?source.byte_len(),
                seekable = source.is_seekable(),
                headers = headers.len(),
                "opened http range source"
            );
            Ok(Box::new(SymphoniaDecoder::open_source(
                Box::new(source),
                ext.as_deref(),
            )?))
        }
    }
}

/// 从路径里取小写扩展名（symphonia 用它猜容器格式）。
fn extension_of(path: &str) -> Option<String> {
    std::path::Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
}

/// 从 URL 里取小写扩展名：去掉 query / fragment 之后再看路径的最后一段。
///
/// `https://host/a/b.flac?token=x` → `Some("flac")`；电台地址（没有扩展名）→ `None`，
/// symphonia 会退回按内容探测。
fn extension_of_url(url: &str) -> Option<String> {
    let without_fragment = url.split('#').next().unwrap_or(url);
    let without_query = without_fragment
        .split('?')
        .next()
        .unwrap_or(without_fragment);
    extension_of(without_query)
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    /// URL 的扩展名要从路径里取，query / fragment 不能干扰。
    #[test]
    fn url_extension_ignores_query_and_fragment() {
        assert_eq!(
            extension_of_url("https://host/music/a.flac?token=abc"),
            Some("flac".to_string())
        );
        assert_eq!(
            extension_of_url("https://host/music/a.mp3#t=10"),
            Some("mp3".to_string())
        );
        assert_eq!(extension_of_url("https://host/radio/stream"), None);
        assert_eq!(extension_of_url("https://host/a.b/c"), None);
    }
}
