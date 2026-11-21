//! 基于 cpal 的音频输出后端。
//!
//! Windows 上默认走 WASAPI 共享模式。共享模式的流由 cpal 驱动，f32 样本在这里转成设备格式。
//! 独占 / 比特完美（PLY-05）走 wasapi_exclusive：会话层调用 [`CpalOutput::plan_native`]
//! 协商格式，再调用 [`CpalOutput::start_native`] 打开真正的 WASAPI 独占流；那条链路完全不经过
//! 这个文件的 f32 回调。直接调用 [`AudioOutput::start`] 并传 [`OutputMode::Exclusive`] 时，
//! 因为没有原生样本源，会降级成共享模式并打日志。
//!
//! **实时线程规则**：cpal 的 data callback 里只做两件事——
//! 从 [`SampleSource`]（无锁环形缓冲的读端）`fill` 一块 f32，再逐样本转成设备采样格式。
//! 不分配内存（scratch 缓冲区在 `start()` 时预分配好并按块复用）、不加锁、不做 IO、不写日志。

use super::bitperfect::NativePlan;
use super::{AudioOutput, NativeSampleSource, OutputDevice, OutputMode, SampleSource};
use crate::decode::{NativeSampleFormat, PcmFormat};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, Sample, SampleFormat, SizedSample, SupportedStreamConfig};
use lekis_types::{ErrorCode, LekisError, Result};

/// 默认的 scratch 缓冲区帧数（约 8192 帧 ≈ 170 ms @48k，足够覆盖任何合理的回调块大小）。
const SCRATCH_FRAMES: usize = 8_192;

/// cpal 输出后端。
pub struct CpalOutput {
    host: cpal::Host,
    stream: Option<cpal::Stream>,
    /// Windows 独占流（PLY-05）。COM 对象在它自己的音频线程里。
    #[cfg(windows)]
    wasapi: Option<super::wasapi_exclusive::WasapiExclusiveStream>,
    /// Android USB DAC 直出流（PLY-05，`usb_direct` 已设好比特完美混音器属性）。
    #[cfg(target_os = "android")]
    usb: Option<super::aaudio_direct::AaudioDirectStream>,
    playing: bool,
    /// 当前流实际使用的格式。
    format: Option<PcmFormat>,
    /// 当前流**实际**使用的模式。请求独占但失败时为 `Shared`。
    mode: OutputMode,
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
            #[cfg(windows)]
            wasapi: None,
            #[cfg(target_os = "android")]
            usb: None,
            playing: false,
            format: None,
            mode: OutputMode::Shared,
        }
    }

    /// 当前流实际使用的格式。
    pub fn format(&self) -> Option<PcmFormat> {
        self.format
    }

    /// 当前流**实际**使用的模式（独占请求失败后会变成共享）。
    pub fn output_mode(&self) -> OutputMode {
        self.mode
    }

    /// 当前流是否在播放。
    pub fn is_playing(&self) -> bool {
        self.playing
    }

    /// 当前独占流使用的样本容器（共享模式为 `None`）。
    pub fn native_packing(&self) -> Option<super::NativePacking> {
        #[cfg(windows)]
        {
            self.wasapi.as_ref().map(|stream| stream.packing())
        }
        #[cfg(target_os = "android")]
        {
            self.usb.as_ref().map(|stream| stream.packing())
        }
        #[cfg(not(any(windows, target_os = "android")))]
        {
            None
        }
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

    /// 协商 WASAPI 独占格式（PLY-05）。不会打开流，只查驱动。
    ///
    /// 返回 `Ok(None)` 表示本平台没有独占后端；`Err` 表示设备不接受该源格式。
    /// 非 Windows 平台始终返回 `Ok(None)`，调用方据此退回共享模式。
    #[cfg(windows)]
    pub fn plan_native(
        &self,
        device_id: Option<&str>,
        requested: PcmFormat,
        native: NativeSampleFormat,
    ) -> Result<Option<NativePlan>> {
        super::wasapi_exclusive::plan(device_id, requested, native).map(Some)
    }

    /// Android：USB DAC 直出（Android 14+ 比特完美混音器）。没开 / 没 USB 设备时 `Ok(None)`。
    #[cfg(target_os = "android")]
    pub fn plan_native(
        &self,
        _device_id: Option<&str>,
        requested: PcmFormat,
        native: NativeSampleFormat,
    ) -> Result<Option<NativePlan>> {
        super::usb_direct::plan_global(requested, native).map(|plan| plan.map(|p| p.native_plan()))
    }

    /// 其他平台：没有比特完美后端。
    #[cfg(not(any(windows, target_os = "android")))]
    pub fn plan_native(
        &self,
        _device_id: Option<&str>,
        _requested: PcmFormat,
        _native: NativeSampleFormat,
    ) -> Result<Option<NativePlan>> {
        Ok(None)
    }

    /// 打开 WASAPI 独占流（PLY-05）。`source` 必须是左对齐 i32 / f32 位模式。
    #[cfg(windows)]
    pub fn start_native(
        &mut self,
        device_id: Option<&str>,
        requested: PcmFormat,
        native: NativeSampleFormat,
        source: Box<dyn NativeSampleSource>,
    ) -> Result<PcmFormat> {
        self.stop()?;
        let stream = super::wasapi_exclusive::WasapiExclusiveStream::start(
            device_id, requested, native, source,
        )?;
        let format = stream.format();
        self.wasapi = Some(stream);
        self.playing = true;
        self.format = Some(format);
        self.mode = OutputMode::Exclusive;
        Ok(format)
    }

    /// Android：设置首选混音器属性，再按同一格式把 AAudio 流开到 USB 设备上。
    /// 任何一步失败都清掉首选属性并返回错误，会话层随后退回普通输出。
    #[cfg(target_os = "android")]
    pub fn start_native(
        &mut self,
        _device_id: Option<&str>,
        requested: PcmFormat,
        native: NativeSampleFormat,
        source: Box<dyn NativeSampleSource>,
    ) -> Result<PcmFormat> {
        self.stop()?;
        let plan = super::usb_direct::prepare_global(requested, native)?;
        match super::aaudio_direct::AaudioDirectStream::start(
            plan.device_id,
            plan.format,
            plan.packing,
            source,
        ) {
            Ok(stream) => {
                let format = stream.format();
                self.usb = Some(stream);
                self.playing = true;
                self.format = Some(format);
                self.mode = OutputMode::Exclusive;
                super::usb_direct::mark_active_global();
                Ok(format)
            }
            Err(e) => {
                super::usb_direct::mark_failed_global(&e.message);
                Err(e)
            }
        }
    }

    /// 其他平台：没有比特完美后端。
    #[cfg(not(any(windows, target_os = "android")))]
    pub fn start_native(
        &mut self,
        _device_id: Option<&str>,
        _requested: PcmFormat,
        _native: NativeSampleFormat,
        _source: Box<dyn NativeSampleSource>,
    ) -> Result<PcmFormat> {
        Err(LekisError::new(
            ErrorCode::Unsupported,
            "exclusive WASAPI output is only available on Windows",
        ))
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
        // Windows 上还要探测哪些 endpoint 能开独占（PLY-05）。raw_ids 与 out 一一对应。
        #[cfg(windows)]
        let mut raw_ids = Vec::new();
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
            #[cfg(windows)]
            raw_ids.push(super::wasapi_exclusive::raw_device_id(&id));
            out.push(OutputDevice {
                is_default: default_id.as_deref() == Some(id.as_str()),
                id,
                name,
                // 先报 false，下面用 IsFormatSupported 逐个探测后再覆盖。
                supports_exclusive: false,
            });
        }

        #[cfg(windows)]
        {
            let supported = super::wasapi_exclusive::probe_exclusive_support(&raw_ids);
            for (device, exclusive) in out.iter_mut().zip(supported) {
                device.supports_exclusive = exclusive;
            }
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

        // 这个入口只接收 f32 样本源，没有原生格式可直送；独占请求在这里没有意义。
        // 会话层会在有原生格式时先走 `start_native`。走到这里说明必须降级。
        let actual_mode = if mode == OutputMode::Exclusive {
            tracing::warn!(
                target: "playback::output",
                "no native sample source for exclusive output, falling back to shared mode"
            );
            OutputMode::Shared
        } else {
            mode
        };

        // Android：普通输出不能停在 USB 比特完美混音器上（否则别的声音会被静音、格式被锁住）。
        #[cfg(target_os = "android")]
        super::usb_direct::on_shared_output_global();

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
            mode = ?actual_mode,
            "output stream started"
        );
        self.stream = Some(stream);
        self.playing = true;
        self.format = Some(actual);
        self.mode = actual_mode;
        Ok(actual)
    }

    fn start_native(
        &mut self,
        device_id: Option<&str>,
        requested: PcmFormat,
        native: NativeSampleFormat,
        source: Box<dyn NativeSampleSource>,
    ) -> Result<PcmFormat> {
        // 显式调用固有方法：它负责真正的 WASAPI 独占流；trait 方法只是让
        // `Box<dyn AudioOutput>` / 测试工厂也能走同一条入口。
        CpalOutput::start_native(self, device_id, requested, native, source)
    }

    fn output_mode(&self) -> OutputMode {
        CpalOutput::output_mode(self)
    }

    fn pause(&mut self) -> Result<()> {
        #[cfg(windows)]
        if let Some(stream) = self.wasapi.as_ref() {
            if self.playing {
                stream.pause();
                self.playing = false;
            }
            return Ok(());
        }
        #[cfg(target_os = "android")]
        if let Some(stream) = self.usb.as_ref() {
            if self.playing {
                stream.pause();
                self.playing = false;
            }
            return Ok(());
        }
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
        #[cfg(windows)]
        if let Some(stream) = self.wasapi.as_ref() {
            if !self.playing {
                stream.resume();
                self.playing = true;
            }
            return Ok(());
        }
        #[cfg(target_os = "android")]
        if let Some(stream) = self.usb.as_ref() {
            if !self.playing {
                stream.resume();
                self.playing = true;
            }
            return Ok(());
        }
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
        #[cfg(windows)]
        if let Some(mut stream) = self.wasapi.take() {
            stream.stop();
        }
        // 只关流；首选混音器属性留着，下一首同格式时不用重新切路由（关闭开关 / 改走普通输出时才清）。
        #[cfg(target_os = "android")]
        if let Some(stream) = self.usb.take() {
            stream.stop();
        }
        self.playing = false;
        self.format = None;
        self.mode = OutputMode::Shared;
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
    /// 真机上 `supports_exclusive` 由驱动探测决定，不能再硬编码 false。
    #[test]
    fn devices_never_panics() {
        let out = CpalOutput::new();
        match out.devices() {
            Ok(list) => {
                for d in list {
                    assert!(!d.id.is_empty());
                    assert!(!d.name.is_empty());
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
