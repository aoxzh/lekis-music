//! 基于 cpal 的音频输出后端。
//!
//! Windows 上是 WASAPI 共享模式。独占模式（PLY-05）尚未实现：cpal 没有暴露 session 独占开关，
//! 需要直接调 IAudioClient::Initialize 并自己驱动事件回调，属于 P1 的独立任务。
//! 传 [`OutputMode::Exclusive`] 时会降级成共享模式并打日志，不会失败。
//!
//! **实时线程规则**：cpal 的 data callback 里只做两件事——
//! 从 [`SampleSource`]（无锁环形缓冲的读端）`fill` 一块 f32，再逐样本转成设备采样格式。
//! 不分配内存（scratch 缓冲区在 `start()` 时预分配好并按块复用）、不加锁、不做 IO、不写日志。

use super::{AudioOutput, OutputDevice, OutputMode, SampleSource};
use crate::decode::PcmFormat;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, Sample, SampleFormat, SizedSample, SupportedStreamConfig};
use lekis_types::{ErrorCode, LekisError, Result};

/// 默认的 scratch 缓冲区帧数（约 8192 帧 ≈ 170 ms @48k，足够覆盖任何合理的回调块大小）。
const SCRATCH_FRAMES: usize = 8_192;

/// cpal 输出后端。
pub struct CpalOutput {
    host: cpal::Host,
    stream: Option<cpal::Stream>,
    playing: bool,
    /// 当前流实际使用的格式。
    format: Option<PcmFormat>,
}

impl Default for CpalOutput {
    fn default() -> Self {
        Self::new()
    }
}

impl CpalOutput {
    /// 用默认主机（Windows: WASAPI，Linux: 编译期选择的后端）创建。
    pub fn new() -> Self {
        Self {
            host: cpal::default_host(),
            stream: None,
            playing: false,
            format: None,
        }
    }

    /// 当前流实际使用的格式。
    pub fn format(&self) -> Option<PcmFormat> {
        self.format
    }

    /// 流是否在播放。
    pub fn is_playing(&self) -> bool {
        self.playing
    }

    /// 事先算出「这份请求格式最终会用哪个设备格式」，但不打开流。
    ///
    /// 会话层需要在建环形缓冲**之前**就知道设备格式（缓冲里的样本是转换后的设备格式），
    /// 所以把协商拆出来单独可用。挑设备与协商都和 [`AudioOutput::start`] 走同一条路径，
    /// 因此这里的结果与真正 `start` 时返回的格式一致。
    pub fn plan_format(&self, device_id: Option<&str>, requested: PcmFormat) -> Result<PcmFormat> {
        let device = self.find_device(device_id)?;
        let cfg = Self::negotiate(&device, requested)?;
        Ok(PcmFormat {
            sample_rate: cfg.sample_rate(),
            channels: cfg.channels(),
        })
    }

    /// 按 ID 找设备；找不到或没给就退回系统默认设备。
    fn find_device(&self, device_id: Option<&str>) -> Result<cpal::Device> {
        if let Some(id) = device_id {
            if let Ok(parsed) = id.parse::<cpal::DeviceId>() {
                if let Some(device) = self.host.device_by_id(&parsed) {
                    return Ok(device);
                }
            }
            tracing::warn!(
                target: "playback::output",
                device = %id,
                "requested output device not found, falling back to default"
            );
        }
        self.host
            .default_output_device()
            .ok_or_else(|| LekisError::new(ErrorCode::Unsupported, "no audio output device"))
    }

    /// 协商出一份流配置：优先满足请求的采样率 + 声道数，其次退到设备默认配置。
    fn negotiate(device: &cpal::Device, requested: PcmFormat) -> Result<SupportedStreamConfig> {
        let ranges = device.supported_output_configs().map_err(|e| {
            LekisError::new(
                ErrorCode::Unsupported,
                format!("cannot query output configs: {e}"),
            )
        })?;

        // 1) 完全匹配：声道数 + 采样率都对得上，优先 f32（免转换），其次 i16。
        let mut best: Option<(u8, SupportedStreamConfig)> = None;
        for range in ranges {
            if range.channels() != requested.channels || !range.contains_rate(requested.sample_rate)
            {
                continue;
            }
            let Some(cfg) = range.try_with_sample_rate(requested.sample_rate) else {
                continue;
            };
            let rank = match cfg.sample_format() {
                SampleFormat::F32 => 0u8,
                SampleFormat::I16 => 1,
                SampleFormat::I32 => 2,
                SampleFormat::U16 => 3,
                _ => 4,
            };
            if best.as_ref().map(|(r, _)| rank < *r).unwrap_or(true) {
                best = Some((rank, cfg));
            }
        }
        if let Some((_, cfg)) = best {
            return Ok(cfg);
        }

        // 2) 退而求其次：设备默认配置（采样率/声道数可能和请求不同，调用方需要重采样）。
        let cfg = device.default_output_config().map_err(|e| {
            LekisError::new(
                ErrorCode::Unsupported,
                format!("cannot get default output config: {e}"),
            )
        })?;
        tracing::warn!(
            target: "playback::output",
            requested_rate = requested.sample_rate,
            requested_channels = requested.channels,
            actual_rate = cfg.sample_rate(),
            actual_channels = cfg.channels(),
            "no exact output config match, using device default (resampling required)"
        );
        Ok(cfg)
    }

    /// 按配置建立并启动 cpal 流。
    fn build_stream(
        device: &cpal::Device,
        cfg: &SupportedStreamConfig,
        source: Box<dyn SampleSource>,
    ) -> Result<cpal::Stream> {
        let channels = usize::from(cfg.channels());
        let stream_cfg = cfg.config();
        // scratch 在实时线程之外分配好；回调里按块复用（不够就分多次 fill，绝不 realloc）。
        let mut scratch = vec![0.0f32; SCRATCH_FRAMES * channels];

        let format = cfg.sample_format();
        let result = match format {
            SampleFormat::F32 => build_typed::<f32>(
                device,
                &stream_cfg,
                source,
                std::mem::take(&mut scratch),
                channels,
            ),
            SampleFormat::I16 => build_typed::<i16>(
                device,
                &stream_cfg,
                source,
                std::mem::take(&mut scratch),
                channels,
            ),
            SampleFormat::I32 => build_typed::<i32>(
                device,
                &stream_cfg,
                source,
                std::mem::take(&mut scratch),
                channels,
            ),
            SampleFormat::I8 => build_typed::<i8>(
                device,
                &stream_cfg,
                source,
                std::mem::take(&mut scratch),
                channels,
            ),
            SampleFormat::U8 => build_typed::<u8>(
                device,
                &stream_cfg,
                source,
                std::mem::take(&mut scratch),
                channels,
            ),
            SampleFormat::U16 => build_typed::<u16>(
                device,
                &stream_cfg,
                source,
                std::mem::take(&mut scratch),
                channels,
            ),
            SampleFormat::U32 => build_typed::<u32>(
                device,
                &stream_cfg,
                source,
                std::mem::take(&mut scratch),
                channels,
            ),
            SampleFormat::F64 => build_typed::<f64>(
                device,
                &stream_cfg,
                source,
                std::mem::take(&mut scratch),
                channels,
            ),
            other => Err(LekisError::new(
                ErrorCode::Unsupported,
                format!("unsupported sample format: {other:?}"),
            )),
        };
        result
    }
}

/// 用具体的采样类型建流。回调里只做 fill + 逐样本转换。
fn build_typed<T>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    mut source: Box<dyn SampleSource>,
    mut scratch: Vec<f32>,
    channels: usize,
) -> Result<cpal::Stream>
where
    T: SizedSample + FromSample<f32>,
{
    let chunk = scratch.len().max(channels);
    device
        .build_output_stream(
            *config,
            move |data: &mut [T], _info: &cpal::OutputCallbackInfo| {
                // 实时线程：不分配、不加锁、不 IO、不打日志。
                let mut offset = 0usize;
                while offset < data.len() {
                    let end = (offset + chunk).min(data.len());
                    let frames_slice = end - offset;
                    let target: &mut [f32] = &mut scratch[..frames_slice];
                    let filled = source.fill(target);
                    // fill 承诺补齐静音，但万一没补齐，这里兜底清零，避免设备播到旧数据。
                    if filled < target.len() {
                        for s in &mut target[filled..] {
                            *s = 0.0;
                        }
                    }
                    for (dst, src) in data[offset..end].iter_mut().zip(target.iter()) {
                        // 浮点 → 整型转换要求 |x| < 1.0，削到安全范围避免溢出。
                        let v = src.clamp(-1.0, 0.999_969);
                        *dst = T::from_sample(v);
                    }
                    offset = end;
                }
            },
            move |err| {
                // 错误回调不在实时音频路径上，可以打日志。
                tracing::warn!(target: "playback::output", error = %err, "output stream error");
            },
            None,
        )
        .map_err(|e| LekisError::new(ErrorCode::Unsupported, format!("cannot open stream: {e}")))
}

impl AudioOutput for CpalOutput {
    fn devices(&self) -> Result<Vec<OutputDevice>> {
        if !cpal::Host::is_available() {
            tracing::debug!(target: "playback::output", "no audio host available");
            return Ok(Vec::new());
        }
        // 列出设备失败（headless / 服务里没有音频会话）不算错误：返回空列表让上层优雅降级。
        let default_id = self
            .host
            .default_output_device()
            .and_then(|d| d.id().ok())
            .map(|id| id.to_string());

        let devices = match self.host.output_devices() {
            Ok(devices) => devices,
            Err(e) => {
                tracing::debug!(target: "playback::output", error = %e, "cannot enumerate output devices");
                return Ok(Vec::new());
            }
        };

        let mut out = Vec::new();
        for device in devices {
            let id = match device.id() {
                Ok(id) => id.to_string(),
                Err(e) => {
                    tracing::debug!(target: "playback::output", error = %e, "device has no id");
                    continue;
                }
            };
            let name = match device.description() {
                Ok(desc) => desc.name().to_string(),
                Err(_) => id.clone(),
            };
            out.push(OutputDevice {
                is_default: default_id.as_deref() == Some(id.as_str()),
                id,
                name,
                // TODO(PLY-05)：WASAPI 独占 / 比特完美本次不做，统一报 false。
                supports_exclusive: false,
            });
        }
        Ok(out)
    }

    fn start(
        &mut self,
        device_id: Option<&str>,
        requested: PcmFormat,
        mode: OutputMode,
        source: Box<dyn SampleSource>,
    ) -> Result<PcmFormat> {
        if requested.sample_rate == 0 || requested.channels == 0 {
            return Err(LekisError::invalid("invalid requested pcm format"));
        }
        // 换设备/换歌时先干净地关掉旧流。
        self.stop()?;

        if mode == OutputMode::Exclusive {
            // TODO(PLY-05)：WASAPI 独占 / ASIO 直出。
            tracing::warn!(
                target: "playback::output",
                "exclusive mode is not implemented yet, falling back to shared mode"
            );
        }

        let device = self.find_device(device_id)?;
        let cfg = Self::negotiate(&device, requested)?;
        let actual = PcmFormat {
            sample_rate: cfg.sample_rate(),
            channels: cfg.channels(),
        };
        let stream = Self::build_stream(&device, &cfg, source)?;
        stream
            .play()
            .map_err(|e| LekisError::new(ErrorCode::Io, format!("cannot start stream: {e}")))?;

        tracing::debug!(
            target: "playback::output",
            rate = actual.sample_rate,
            channels = actual.channels,
            sample_format = ?cfg.sample_format(),
            "output stream started"
        );
        self.stream = Some(stream);
        self.playing = true;
        self.format = Some(actual);
        Ok(actual)
    }

    fn pause(&mut self) -> Result<()> {
        if let Some(stream) = &self.stream {
            if self.playing {
                stream.pause().map_err(|e| {
                    LekisError::new(ErrorCode::Io, format!("cannot pause stream: {e}"))
                })?;
                self.playing = false;
            }
        }
        Ok(())
    }

    fn resume(&mut self) -> Result<()> {
        if let Some(stream) = &self.stream {
            if !self.playing {
                stream.play().map_err(|e| {
                    LekisError::new(ErrorCode::Io, format!("cannot resume stream: {e}"))
                })?;
                self.playing = true;
            }
        }
        Ok(())
    }

    fn stop(&mut self) -> Result<()> {
        // cpal 没有 stop()：丢掉 Stream 就停掉并释放设备。
        if let Some(stream) = self.stream.take() {
            let _ = stream.pause();
            drop(stream);
        }
        self.playing = false;
        self.format = None;
        Ok(())
    }
}

impl CpalOutput {
    /// 判断某个采样格式能否被本后端打开（供测试/诊断用）。
    pub fn is_supported_format(format: SampleFormat) -> bool {
        matches!(
            format,
            SampleFormat::F32
                | SampleFormat::F64
                | SampleFormat::I8
                | SampleFormat::I16
                | SampleFormat::I32
                | SampleFormat::U8
                | SampleFormat::U16
                | SampleFormat::U32
        )
    }
}

/// 编译期确认 `cpal::Sample` 的 `EQUILIBRIUM` 可用（用于文档/测试里的静音值）。
#[allow(dead_code)]
fn silence<T: Sample>() -> T {
    T::EQUILIBRIUM
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    /// headless / CI 环境：`devices()` 必须返回 `Ok`（空列表），绝不能 panic。
    #[test]
    fn devices_never_panics() {
        let out = CpalOutput::new();
        match out.devices() {
            Ok(list) => {
                for d in list {
                    assert!(!d.id.is_empty());
                    assert!(!d.supports_exclusive, "PLY-05 未实现，必须报 false");
                }
            }
            Err(e) => panic!("devices() 不应该返回错误：{e}"),
        }
    }

    /// 没有设备时 `start()` 必须返回 Unsupported，而不是 panic。
    #[test]
    fn start_without_device_is_unsupported() {
        let mut out = CpalOutput::new();
        if !out.devices().map(|d| d.is_empty()).unwrap_or(true) {
            // 机器有设备，这个用例不适用（真的开流会有声音，测试里不启动）。
            return;
        }
        let source: Box<dyn SampleSource> =
            Box::new(super::super::ring_source::ring_buffer(4096, 2).1);
        let err = out
            .start(
                None,
                PcmFormat {
                    sample_rate: 44_100,
                    channels: 2,
                },
                OutputMode::Shared,
                source,
            )
            .expect_err("没有设备时必须报错");
        assert_eq!(err.code, ErrorCode::Unsupported);
    }

    #[test]
    fn clamps_and_converts_f32_to_i16() {
        // 与 build_typed 里同样的转换路径：1.0 不能溢出成负数。
        let v = 1.0f32.clamp(-1.0, 0.999_969);
        let s: i16 = i16::from_sample(v);
        assert!(s > 32_000, "i16 = {s}");
        let v = -1.0f32.clamp(-1.0, 0.999_969);
        let s: i16 = i16::from_sample(v);
        assert!(s <= -32_000, "i16 = {s}");
    }
}
