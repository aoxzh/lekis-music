//! Android USB DAC 直出的 AAudio 流（PLY-05，只在 Android 上编译）。
//!
//! [`super::usb_direct`] 已经把 USB 设备的首选混音器属性设成比特完美格式；这里按**完全相同**的
//! 采样率 / 声道 / 编码，把流直接开到那个设备上（`setDeviceId`）。样本来自左对齐 i32 环形缓冲，
//! 在回调里用 [`super::bitperfect::pack_into`] 按容器取高位字节，不做任何算术。
//!
//! `unsafe`：AAudio 回调给的是裸指针缓冲区，必须转成切片才能写。这是本 crate 唯一需要
//! unsafe 的地方，范围只限这个模块（`ndk` crate 已经把其余 AAudio 调用包成安全接口）。
#![allow(unsafe_code)]

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use ndk::audio::{
    AudioCallbackResult, AudioDirection, AudioError, AudioFormat, AudioPerformanceMode,
    AudioSharingMode, AudioStream, AudioStreamBuilder,
};

use super::bitperfect::{pack_into, NativePacking};
use super::NativeSampleSource;
use crate::decode::PcmFormat;
use lekis_types::{ErrorCode, LekisError, Result};

/// `AAUDIO_FORMAT_PCM_I24_PACKED`（API 31）。`ndk` 0.9 的枚举没有列出，按原始值传。
const AAUDIO_FORMAT_PCM_I24_PACKED: i32 = 3;
/// `AAUDIO_FORMAT_PCM_I32`（API 31）。
const AAUDIO_FORMAT_PCM_I32: i32 = 4;

/// 回调里一次最多处理的样本数（预分配；更大的回调分块处理）。
const SCRATCH_SAMPLES: usize = 16_384;

fn aaudio_format(packing: NativePacking) -> AudioFormat {
    match packing {
        NativePacking::Int16 => AudioFormat::PCM_I16,
        NativePacking::Float32 => AudioFormat::PCM_Float,
        NativePacking::Int24Packed => AudioFormat::from(AAUDIO_FORMAT_PCM_I24_PACKED),
        NativePacking::Int24In32 | NativePacking::Int32 => AudioFormat::from(AAUDIO_FORMAT_PCM_I32),
    }
}

fn io(context: &str, e: AudioError) -> LekisError {
    LekisError::new(ErrorCode::Io, format!("{context}: {e}"))
}

/// `ndk` 0.9 的 `AudioStream` 没有实现 `Send`（裸指针），但 AAudio 句柄本身可以在任意线程上
/// 控制（start / pause / stop / close）。这里只有唯一所有者（`CpalOutput`）通过 `&self` / drop 访问它。
struct SendStream(AudioStream);

// SAFETY: AAudioStream 的控制函数是线程安全的；包装后只有一个所有者，不会被并发 close。
unsafe impl Send for SendStream {}

/// 一条打开的直出流。
pub struct AaudioDirectStream {
    stream: SendStream,
    format: PcmFormat,
    packing: NativePacking,
    disconnected: Arc<AtomicBool>,
}

impl AaudioDirectStream {
    /// 打开并启动流。实际格式和请求不一致（系统没有走比特完美混音器）时返回错误。
    pub fn start(
        device_id: i32,
        format: PcmFormat,
        packing: NativePacking,
        mut source: Box<dyn NativeSampleSource>,
    ) -> Result<Self> {
        let channels = usize::from(format.channels.max(1));
        let width = packing.container_bytes();
        let mut scratch = vec![0i32; SCRATCH_SAMPLES - SCRATCH_SAMPLES % channels];
        let disconnected = Arc::new(AtomicBool::new(false));
        let cb_disconnected = disconnected.clone();

        let stream = AudioStreamBuilder::new()
            .map_err(|e| io("AAudio builder", e))?
            .direction(AudioDirection::Output)
            .device_id(device_id)
            .sample_rate(format.sample_rate as i32)
            .channel_count(i32::from(format.channels))
            .format(aaudio_format(packing))
            .sharing_mode(AudioSharingMode::Shared)
            // 低延迟模式可能走 FAST mixer，那条路径不是比特完美的。
            .performance_mode(AudioPerformanceMode::None)
            .data_callback(Box::new(move |_stream, data, num_frames| {
                let Ok(frames) = usize::try_from(num_frames) else {
                    return AudioCallbackResult::Continue;
                };
                let total = frames * channels;
                // SAFETY: AAudio 保证 `data` 指向至少 num_frames × 每帧字节数的可写缓冲，
                // 每帧字节数 = 声道数 × 容器宽度（流格式就是我们请求并在 open 后校验过的格式）。
                let out = unsafe { std::slice::from_raw_parts_mut(data.cast::<u8>(), total * width) };
                let mut done = 0;
                while done < total {
                    let n = (total - done).min(scratch.len());
                    source.fill(&mut scratch[..n]);
                    pack_into(&scratch[..n], packing, &mut out[done * width..(done + n) * width]);
                    done += n;
                }
                AudioCallbackResult::Continue
            }))
            .error_callback(Box::new(move |_stream, error| {
                // 错误回调不在实时线程上，可以记日志。拔掉 USB 时是 Disconnected。
                cb_disconnected.store(true, Ordering::Release);
                tracing::warn!(target: "playback::usb", error = %error, "AAudio direct stream error");
            }))
            .open_stream()
            .map_err(|e| io("AAudio open", e))?;

        let actual_rate = stream.sample_rate();
        let actual_channels = stream.channel_count();
        let actual_format = stream.format();
        let actual_device = stream.device_id();
        if actual_rate != format.sample_rate as i32
            || actual_channels != i32::from(format.channels)
            || actual_format != aaudio_format(packing)
            || actual_device != device_id
        {
            return Err(LekisError::new(
                ErrorCode::Unsupported,
                format!(
                    "AAudio opened {actual_rate} Hz / {actual_channels} ch / {actual_format:?} on device {actual_device}, \
                     wanted {} Hz / {} ch / {:?} on device {device_id}",
                    format.sample_rate,
                    format.channels,
                    aaudio_format(packing)
                ),
            ));
        }
        stream.request_start().map_err(|e| io("AAudio start", e))?;
        tracing::info!(
            target: "playback::usb",
            device_id,
            rate = format.sample_rate,
            channels = format.channels,
            packing = ?packing,
            "USB bit-perfect AAudio stream started"
        );
        Ok(Self {
            stream: SendStream(stream),
            format,
            packing,
            disconnected,
        })
    }

    /// 流格式。
    pub fn format(&self) -> PcmFormat {
        self.format
    }

    /// 设备容器。
    pub fn packing(&self) -> NativePacking {
        self.packing
    }

    /// 设备是否已经断开（拔掉 USB）。
    pub fn is_disconnected(&self) -> bool {
        self.disconnected.load(Ordering::Acquire)
    }

    /// 暂停。
    pub fn pause(&self) {
        let _ = self.stream.0.request_pause();
    }

    /// 恢复。
    pub fn resume(&self) {
        let _ = self.stream.0.request_start();
    }

    /// 停止（随后 drop 会关闭流）。
    pub fn stop(&self) {
        let _ = self.stream.0.request_stop();
    }
}
