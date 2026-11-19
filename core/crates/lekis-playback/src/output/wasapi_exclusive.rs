//! Windows WASAPI 独占（比特完美）输出，PLY-05。
//!
//! 为什么不能直接用 cpal：cpal 没有暴露 `AUDCLNT_SHAREMODE_EXCLUSIVE`，也无法指定
//! 音源自己的采样率/位深。这里直接用 `wasapi` crate 的 IAudioClient 封装：
//!
//! 1. 用 `IsFormatSupported`（`is_supported_exclusive_with_quirks`）协商设备真正接受的
//!    容器：16 / 24 packed / 24-in-32 / 32 bit / float32；
//! 2. `Initialize` 时传 `AUDCLNT_SHAREMODE_EXCLUSIVE`，设备按音源采样率打开；
//! 3. 专用轮询线程从无锁环形缓冲取**左对齐 i32**，只做高位字节打包，
//!    不重采样、不转 f32、不加音量/ReplayGain/限幅。
//!
//! COM 对象不是 `Send`，所以枚举探测、格式协商和播放线程都各自在专用线程里创建对象；
//! 引擎侧只持有控制通道和线程句柄。实时线程里不分配、不加锁、不做 IO、不打日志。
//!
//! 独占打开失败（设备被占用、驱动拒绝格式等）由调用方退回共享模式：
//! [`super::CpalOutput::start_native`] 返回错误，会话层记一条明确的 warning。

use super::bitperfect::{pack_into, packing_candidates, NativePacking, NativePlan};
use super::NativeSampleSource;
use crate::decode::{NativeSampleFormat, PcmFormat};
use lekis_types::{ErrorCode, LekisError, Result};
use std::sync::mpsc::{self, Receiver, Sender, SyncSender, TryRecvError};
use std::thread::JoinHandle;
use std::time::Duration;
use wasapi::{
    AudioClient, AudioRenderClient, Device, DeviceEnumerator, Direction, SampleType, StreamMode,
    WaveFormat,
};

/// 独占流句柄。COM 对象都在音频线程里，这里只有控制通道。
pub struct WasapiExclusiveStream {
    control: Sender<Control>,
    thread: Option<JoinHandle<()>>,
    format: PcmFormat,
    packing: NativePacking,
}

impl WasapiExclusiveStream {
    /// 打开并启动独占流。失败时线程已经收尾，不留下设备占用。
    pub fn start(
        device_id: Option<&str>,
        requested: PcmFormat,
        native: NativeSampleFormat,
        source: Box<dyn NativeSampleSource>,
    ) -> Result<Self> {
        if requested.sample_rate == 0 || requested.channels == 0 {
            return Err(LekisError::invalid("invalid requested pcm format"));
        }
        let device_id = device_id.map(str::to_owned);
        let (ready_tx, ready_rx) = mpsc::sync_channel::<Result<StreamInfo>>(1);
        let (control_tx, control_rx) = mpsc::channel::<Control>();

        let join = std::thread::Builder::new()
            .name("lekis-wasapi".to_string())
            .spawn(move || {
                audio_thread(device_id, requested, native, source, &ready_tx, &control_rx)
            })
            .map_err(|e| LekisError::internal(format!("cannot spawn WASAPI thread: {e}")))?;

        let opened = match ready_rx.recv_timeout(Duration::from_secs(5)) {
            Ok(result) => result,
            Err(e) => Err(LekisError::new(
                ErrorCode::Unsupported,
                format!("WASAPI exclusive stream did not start: {e}"),
            )),
        };
        let info = match opened {
            Ok(info) => info,
            Err(e) => {
                let _ = control_tx.send(Control::Stop);
                let _ = join.join();
                return Err(e);
            }
        };

        tracing::debug!(
            target: "playback::output",
            rate = info.format.sample_rate,
            channels = info.format.channels,
            packing = ?info.packing,
            "WASAPI exclusive stream started"
        );
        Ok(Self {
            control: control_tx,
            thread: Some(join),
            format: info.format,
            packing: info.packing,
        })
    }

    /// 设备实际使用的格式。
    pub fn format(&self) -> PcmFormat {
        self.format
    }

    /// 设备实际使用的样本容器。
    pub fn packing(&self) -> NativePacking {
        self.packing
    }

    /// 暂停（`IAudioClient::Stop`，保留已写入的缓冲）。
    pub fn pause(&self) {
        let _ = self.control.send(Control::Pause);
    }

    /// 继续。
    pub fn resume(&self) {
        let _ = self.control.send(Control::Resume);
    }

    /// 停止并 join 音频线程。
    pub fn stop(&mut self) {
        let _ = self.control.send(Control::Stop);
        if let Some(handle) = self.thread.take() {
            let _ = handle.join();
        }
    }
}

impl Drop for WasapiExclusiveStream {
    fn drop(&mut self) {
        self.stop();
    }
}

/// 协商设备能接受的独占格式，但不打开流。可在没有独占硬件的机器上安全调用（只查询驱动）。
pub fn plan(
    device_id: Option<&str>,
    requested: PcmFormat,
    native: NativeSampleFormat,
) -> Result<NativePlan> {
    if requested.sample_rate == 0 || requested.channels == 0 {
        return Err(LekisError::invalid("invalid requested pcm format"));
    }
    let device_id = device_id.map(str::to_owned);
    let join = std::thread::Builder::new()
        .name("lekis-wasapi-plan".to_string())
        .spawn(move || -> Result<NativePlan> {
            let _com = ComGuard::new();
            let enumerator = DeviceEnumerator::new().map_err(|e| {
                LekisError::new(ErrorCode::Unsupported, format!("WASAPI enumerator: {e}"))
            })?;
            let device = open_device(&enumerator, device_id.as_deref())?;
            let client = device.get_iaudioclient().map_err(|e| {
                LekisError::new(ErrorCode::Unsupported, format!("WASAPI audio client: {e}"))
            })?;
            let (packing, wave) = negotiate(&client, requested, native)?;
            Ok(NativePlan {
                format: format_of(&wave),
                packing,
            })
        })
        .map_err(|e| LekisError::internal(format!("cannot spawn WASAPI plan thread: {e}")))?;

    join.join()
        .map_err(|_| LekisError::internal("WASAPI exclusive plan thread panicked"))?
}

/// 探测一批 render endpoint 是否能以独占模式打开。
///
/// `raw_ids` 是 `IMMDevice::GetId()` 的原始字符串（不是 cpal 的 `wasapi:` 前缀形式）。
/// 返回值与输入一一对应；线程创建失败时返回空列表，调用方按 false 处理。
pub(crate) fn probe_exclusive_support(raw_ids: &[String]) -> Vec<bool> {
    if raw_ids.is_empty() {
        return Vec::new();
    }
    let ids = raw_ids.to_vec();
    let join = std::thread::Builder::new()
        .name("lekis-wasapi-probe".to_string())
        .spawn(move || {
            let _com = ComGuard::new();
            let Ok(enumerator) = DeviceEnumerator::new() else {
                return Vec::new();
            };
            ids.iter().map(|id| probe_device(&enumerator, id)).collect()
        });
    match join {
        Ok(handle) => handle.join().unwrap_or_default(),
        Err(_) => Vec::new(),
    }
}

/// 从一个 cpal 设备 ID（`wasapi:{IMMDevice ID}`）取出 WASAPI 的原始端点 ID。
pub(crate) fn raw_device_id(id: &str) -> String {
    match id.parse::<cpal::DeviceId>() {
        Ok(parsed) => parsed.id().to_owned(),
        Err(_) => id.to_owned(),
    }
}

/// 探测单个设备：用设备自己的 mix format 和几种常见格式查询驱动。
///
/// 这里的 `is_supported_exclusive_with_quirks` 只查驱动（`IsFormatSupported`），不打开流，
/// 所以不会打断正在播放的其他应用。
fn probe_device(enumerator: &DeviceEnumerator, raw_id: &str) -> bool {
    let Ok(device) = enumerator.get_device(raw_id) else {
        return false;
    };
    let Ok(client) = device.get_iaudioclient() else {
        return false;
    };

    // 设备自己的共享 mix format 是最有代表性的候选（能独占播共享格式通常就能独占）。
    let mut channels = 2u16;
    if let Ok(mix) = client.get_mixformat() {
        channels = mix.get_nchannels().max(1);
        if client.is_supported_exclusive_with_quirks(&mix).is_ok() {
            return true;
        }
    }

    // 有些设备拒绝 float mix format，但接受整数 PCM；再试几组常见的采样率/容器。
    for rate in [48_000u32, 44_100, 96_000] {
        let requested = PcmFormat {
            sample_rate: rate,
            channels,
        };
        for packing in [
            NativePacking::Int16,
            NativePacking::Int24In32,
            NativePacking::Int24Packed,
            NativePacking::Float32,
        ] {
            let wave = wave_format_for(packing, requested);
            if client.is_supported_exclusive_with_quirks(&wave).is_ok() {
                return true;
            }
        }
    }
    false
}

/// 按优先级协商：packing 候选由源位深决定，最终使用驱动接受的那个容器。
fn negotiate(
    client: &AudioClient,
    requested: PcmFormat,
    native: NativeSampleFormat,
) -> Result<(NativePacking, WaveFormat)> {
    let candidates = packing_candidates(native);
    if candidates.is_empty() {
        return Err(LekisError::new(
            ErrorCode::Unsupported,
            format!(
                "source bit depth {:?} has no lossless exclusive container",
                native
            ),
        ));
    }

    let mut last_error = String::new();
    for packing in candidates {
        let wave = wave_format_for(*packing, requested);
        match client.is_supported_exclusive_with_quirks(&wave) {
            Ok(accepted) => return Ok((*packing, accepted)),
            Err(e) => last_error = e.to_string(),
        }
    }
    Err(LekisError::new(
        ErrorCode::Unsupported,
        format!(
            "device does not accept exclusive {} Hz / {} ch / {:?}: {}",
            requested.sample_rate, requested.channels, native, last_error
        ),
    ))
}

/// 源格式 + 容器 → WASAPI 的 WAVEFORMATEXTENSIBLE。
///
/// 整数样本在容器里是**左对齐**的，与解码器输出的左对齐 i32 一致，所以打包只是取高位字节。
fn wave_format_for(packing: NativePacking, requested: PcmFormat) -> WaveFormat {
    let (store_bits, valid_bits, sample_type) = match packing {
        NativePacking::Int16 => (16, 16, SampleType::Int),
        NativePacking::Int24Packed => (24, 24, SampleType::Int),
        NativePacking::Int24In32 => (32, 24, SampleType::Int),
        NativePacking::Int32 => (32, 32, SampleType::Int),
        NativePacking::Float32 => (32, 32, SampleType::Float),
    };
    WaveFormat::new(
        store_bits,
        valid_bits,
        sample_type,
        requested.sample_rate as usize,
        usize::from(requested.channels),
        None,
    )
}

/// `WaveFormat` → 领域里的 [`PcmFormat`]。
fn format_of(wave: &WaveFormat) -> PcmFormat {
    PcmFormat {
        sample_rate: wave.get_samplespersec(),
        channels: wave.get_nchannels(),
    }
}

/// 按 cpal ID 找设备；找不到就退回系统默认设备（与共享后端行为一致）。
fn open_device(enumerator: &DeviceEnumerator, device_id: Option<&str>) -> Result<Device> {
    if let Some(id) = device_id {
        let raw = raw_device_id(id);
        match enumerator.get_device(&raw) {
            Ok(device) => return Ok(device),
            Err(e) => {
                tracing::warn!(
                    target: "playback::output",
                    device = %id,
                    error = %e,
                    "WASAPI exclusive device not found, falling back to default"
                );
            }
        }
    }
    enumerator
        .get_default_device(Direction::Render)
        .map_err(|e| LekisError::new(ErrorCode::Unsupported, format!("no render device: {e}")))
}

/// COM 初始化。`initialize_mta` 返回失败时（线程已经是 STA）不调用 `CoUninitialize`，
/// 避免破坏其他库的 COM 引用计数。
struct ComGuard {
    initialized: bool,
}

impl ComGuard {
    fn new() -> Self {
        let hr = wasapi::initialize_mta();
        Self {
            initialized: hr.is_ok(),
        }
    }
}

impl Drop for ComGuard {
    fn drop(&mut self) {
        if self.initialized {
            wasapi::deinitialize();
        }
    }
}

/// 音频线程命令。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Control {
    Pause,
    Resume,
    Stop,
}

/// 音频线程回报给 `start()` 的实际格式。
struct StreamInfo {
    format: PcmFormat,
    packing: NativePacking,
}

/// 音频线程入口：建立流 → 把结果回报给 `start()` → 进入轮询循环。
fn audio_thread(
    device_id: Option<String>,
    requested: PcmFormat,
    native: NativeSampleFormat,
    source: Box<dyn NativeSampleSource>,
    ready: &SyncSender<Result<StreamInfo>>,
    control: &Receiver<Control>,
) {
    let _com = ComGuard::new();
    match DeviceStream::open(device_id.as_deref(), requested, native, source) {
        Ok(mut stream) => {
            if let Err(e) = stream.start() {
                let _ = ready.send(Err(e));
                return;
            }
            let info = StreamInfo {
                format: stream.format,
                packing: stream.packing,
            };
            if ready.send(Ok(info)).is_err() {
                return;
            }
            if let Err(e) = stream.run(control) {
                // 运行期错误不在实时循环里，记录一条即可；下一首/重开会重新建流。
                tracing::debug!(
                    target: "playback::output",
                    error = %e,
                    "WASAPI exclusive stream stopped on error"
                );
            }
        }
        Err(e) => {
            let _ = ready.send(Err(e));
        }
    }
}

/// 音频线程独占持有的 WASAPI 对象与预分配缓冲。
struct DeviceStream {
    client: AudioClient,
    render: AudioRenderClient,
    source: Box<dyn NativeSampleSource>,
    packing: NativePacking,
    channels: usize,
    format: PcmFormat,
    chunk_frames: usize,
    period_hns: i64,
    scratch: Vec<i32>,
    bytes: Vec<u8>,
    playing: bool,
}

impl DeviceStream {
    fn open(
        device_id: Option<&str>,
        requested: PcmFormat,
        native: NativeSampleFormat,
        source: Box<dyn NativeSampleSource>,
    ) -> Result<Self> {
        let enumerator = DeviceEnumerator::new().map_err(|e| {
            LekisError::new(ErrorCode::Unsupported, format!("WASAPI enumerator: {e}"))
        })?;
        let device = open_device(&enumerator, device_id)?;
        let mut client = device.get_iaudioclient().map_err(|e| {
            LekisError::new(ErrorCode::Unsupported, format!("WASAPI audio client: {e}"))
        })?;
        let (packing, wave) = negotiate(&client, requested, native)?;
        let channels = usize::from(wave.get_nchannels());
        if channels == 0 {
            return Err(LekisError::new(
                ErrorCode::Unsupported,
                "WASAPI reported zero channels",
            ));
        }

        // 独占 + 轮询模式：比事件模式兼容更多 USB 设备（wasapi crate 文档明确提到事件模式
        // 在标准 USB 音频驱动上可能爆音）。一个 period 约 10 ms，缓冲 4 个 period。
        let (default_period, min_period) = client
            .get_device_period()
            .map_err(|e| LekisError::new(ErrorCode::Unsupported, format!("WASAPI period: {e}")))?;
        let desired_period = default_period.max(min_period.saturating_mul(2)).max(1);
        let period_hns = client
            .calculate_aligned_period_near(desired_period, Some(128), &wave)
            .map_err(|e| {
                LekisError::new(
                    ErrorCode::Unsupported,
                    format!("WASAPI period alignment: {e}"),
                )
            })?;
        let buffer_hns = period_hns.saturating_mul(4);
        client
            .initialize_client(
                &wave,
                Direction::Render,
                StreamMode::PollingExclusive {
                    buffer_duration_hns: buffer_hns,
                    period_hns,
                },
                None,
            )
            .map_err(|e| {
                LekisError::new(
                    ErrorCode::Unsupported,
                    format!("WASAPI exclusive initialize failed: {e}"),
                )
            })?;
        let render = client
            .get_audiorenderclient()
            .map_err(|e| LekisError::new(ErrorCode::Unsupported, format!("WASAPI render: {e}")))?;
        let buffer_frames = client
            .get_buffer_size()
            .map_err(|e| LekisError::new(ErrorCode::Unsupported, format!("WASAPI buffer: {e}")))?
            .max(1) as usize;
        let period_frames = ((period_hns as f64) * f64::from(wave.get_samplespersec()) / 1e7)
            .round()
            .max(1.0) as usize;
        let chunk_frames = period_frames.clamp(1, buffer_frames);
        let sample_count = chunk_frames.saturating_mul(channels);

        Ok(Self {
            client,
            render,
            source,
            packing,
            channels,
            format: format_of(&wave),
            chunk_frames,
            period_hns,
            scratch: vec![0i32; sample_count],
            bytes: vec![0u8; sample_count.saturating_mul(packing.container_bytes())],
            playing: false,
        })
    }

    /// 预填缓冲（静音）后启动。见 Microsoft "Rendering a Stream"。
    fn start(&mut self) -> Result<()> {
        for _ in 0..1_024 {
            let available = self
                .client
                .get_available_space_in_frames()
                .map_err(|e| LekisError::new(ErrorCode::Io, format!("WASAPI space: {e}")))?
                as usize;
            let frames = available.min(self.chunk_frames);
            if frames == 0 {
                break;
            }
            self.write_silence(frames)?;
        }
        self.client
            .start_stream()
            .map_err(|e| LekisError::new(ErrorCode::Io, format!("WASAPI start: {e}")))?;
        self.playing = true;
        Ok(())
    }

    fn write_silence(&mut self, frames: usize) -> Result<()> {
        let samples = frames.saturating_mul(self.channels);
        self.scratch[..samples].fill(0);
        let written = pack_into(&self.scratch[..samples], self.packing, &mut self.bytes);
        if written == 0 {
            return Err(LekisError::internal("WASAPI silence buffer is too small"));
        }
        self.render
            .write_to_device(&self.bytes[..written], None)
            .map_err(|e| LekisError::new(ErrorCode::Io, format!("WASAPI write: {e}")))
    }

    /// 写一块数据；缓冲已满时返回 `Ok(false)`。
    fn pump(&mut self) -> Result<bool> {
        let available = self
            .client
            .get_available_space_in_frames()
            .map_err(|e| LekisError::new(ErrorCode::Io, format!("WASAPI space: {e}")))?
            as usize;
        if available == 0 {
            return Ok(false);
        }
        let frames = available.min(self.chunk_frames);
        let samples = frames.saturating_mul(self.channels);
        let filled = self.source.fill(&mut self.scratch[..samples]).min(samples);
        if filled < samples {
            self.scratch[filled..samples].fill(0);
        }
        let written = pack_into(&self.scratch[..samples], self.packing, &mut self.bytes);
        if written == 0 {
            return Err(LekisError::internal("WASAPI sample buffer is too small"));
        }
        self.render
            .write_to_device(&self.bytes[..written], None)
            .map_err(|e| LekisError::new(ErrorCode::Io, format!("WASAPI write: {e}")))?;
        Ok(true)
    }

    /// 轮询循环。设备缓冲满时短暂休眠；暂停时只等控制命令。
    ///
    /// 调用前必须已经 [`Self::start`] 过。
    fn run(&mut self, control: &Receiver<Control>) -> Result<()> {
        let sleep = Duration::from_micros((self.period_hns / 80).clamp(250, 5_000) as u64);

        loop {
            // 先处理控制命令（不阻塞）。
            let mut fatal = false;
            loop {
                match control.try_recv() {
                    Ok(Control::Pause) => {
                        if self.playing {
                            let _ = self.client.stop_stream();
                            self.playing = false;
                        }
                    }
                    Ok(Control::Resume) => {
                        if !self.playing {
                            if let Err(e) = self.client.start_stream() {
                                tracing::debug!(
                                    target: "playback::output",
                                    error = %e,
                                    "WASAPI exclusive resume failed"
                                );
                                fatal = true;
                            } else {
                                self.playing = true;
                            }
                        }
                    }
                    Ok(Control::Stop) | Err(TryRecvError::Disconnected) => {
                        let _ = self.client.stop_stream();
                        return Ok(());
                    }
                    Err(TryRecvError::Empty) => break,
                }
            }
            if fatal {
                let _ = self.client.stop_stream();
                return Ok(());
            }

            if self.playing {
                match self.pump() {
                    Ok(true) => {}
                    Ok(false) => std::thread::sleep(sleep),
                    Err(e) => {
                        let _ = self.client.stop_stream();
                        return Err(e);
                    }
                }
            } else {
                match control.recv_timeout(Duration::from_millis(100)) {
                    Ok(Control::Resume) => {
                        if let Err(e) = self.client.start_stream() {
                            tracing::debug!(
                                target: "playback::output",
                                error = %e,
                                "WASAPI exclusive resume failed"
                            );
                            return Ok(());
                        }
                        self.playing = true;
                    }
                    Ok(Control::Stop) | Err(mpsc::RecvTimeoutError::Disconnected) => {
                        let _ = self.client.stop_stream();
                        return Ok(());
                    }
                    Ok(Control::Pause) | Err(mpsc::RecvTimeoutError::Timeout) => {}
                }
            }
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    /// 16 bit 源必须协商成 16 bit 容器。
    #[test]
    fn wave_format_16_bit() {
        let wave = wave_format_for(
            NativePacking::Int16,
            PcmFormat {
                sample_rate: 44_100,
                channels: 2,
            },
        );
        assert_eq!(wave.get_samplespersec(), 44_100);
        assert_eq!(wave.get_nchannels(), 2);
        assert_eq!(wave.get_bitspersample(), 16);
        assert_eq!(wave.get_validbitspersample(), 16);
        assert_eq!(wave.get_blockalign(), 4);
        assert_eq!(wave.get_subformat().unwrap(), SampleType::Int);
    }

    /// 24 bit 源：packed 是 3 字节，24-in-32 是 4 字节容器、24 有效位（高位对齐）。
    #[test]
    fn wave_format_24_bit_packings() {
        let requested = PcmFormat {
            sample_rate: 96_000,
            channels: 2,
        };
        let packed = wave_format_for(NativePacking::Int24Packed, requested);
        assert_eq!(packed.get_bitspersample(), 24);
        assert_eq!(packed.get_validbitspersample(), 24);
        assert_eq!(packed.get_blockalign(), 6);

        let in32 = wave_format_for(NativePacking::Int24In32, requested);
        assert_eq!(in32.get_bitspersample(), 32);
        assert_eq!(in32.get_validbitspersample(), 24);
        assert_eq!(in32.get_blockalign(), 8);
        assert_eq!(in32.get_subformat().unwrap(), SampleType::Int);
    }

    /// 浮点源用 float32 容器，不能误报成整数。
    #[test]
    fn wave_format_float32() {
        let wave = wave_format_for(
            NativePacking::Float32,
            PcmFormat {
                sample_rate: 48_000,
                channels: 2,
            },
        );
        assert_eq!(wave.get_bitspersample(), 32);
        assert_eq!(wave.get_subformat().unwrap(), SampleType::Float);
    }

    /// cpal 的 `wasapi:` 前缀只用于它自己的设备表，WASAPI 端点 ID 要去掉前缀。
    #[test]
    fn strips_cpal_device_prefix() {
        let raw = "{0.0.0.00000000}.{deadbeef-dead-beef-dead-beefdeadbeef}";
        let cpal_id = format!("wasapi:{raw}");
        assert_eq!(raw_device_id(&cpal_id), raw);
        // 已经是原始 ID 时原样返回。
        assert_eq!(raw_device_id(raw), raw);
    }
}
