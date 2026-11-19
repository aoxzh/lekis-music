//! 播放会话：把「解码线程 + 无锁环形缓冲 + 输出后端」拼成一首歌的完整播放链路。
//!
//! ```text
//! 解码线程                                        实时回调（cpal）
//! Decoder ──► 增益/限幅 ──► 格式转换 ──► RingSourceWriter ──► RingSource ──► 设备
//!   (内容格式)              (声道映射+重采样)  │                 ▲
//!                            (设备格式)       └── RingProgress（原子计数：已推送 / 已播放 / 欠载 / 清空握手）
//! ```
//!
//! 线程模型（docs/ARCHITECTURE.md 第 3 节）：
//! - 解码在专用 `std::thread` 上跑（`open_decoder` 需要 `Handle::block_on`，不能待在 tokio worker 上）；
//! - 实时回调只从环形缓冲里 `pop_slice`，不分配、不加锁、不做 IO、不打日志；
//! - 引擎（tokio 任务）只读 [`RingProgress`] 里的原子量来算播放位置。
//!
//! 采样率转换（PLY-07）在**解码线程**上做（[`crate::resample::FormatConverter`]），
//! 所以环形缓冲里的样本已经是设备格式。这也是为什么会话要同时记住两个格式：
//! **内容格式**决定时间轴（时长、seek 目标都是内容时间），**设备格式**决定
//! 每毫秒多少样本（进度条按它换算）。
//!
//! 播放位置由「已播放样本数 ÷ 每毫秒样本数」算出，再加上 seek 后的基准位置 —— 所以进度条
//! 跟的是真正从缓冲里被设备取走的样本，而不是解码线程解到哪儿了（解码总是领先几百毫秒）。

use crate::decode::{open_decoder, Decoder, PcmFormat};
use crate::dsp::{db_to_linear, DspNode, SoftClipper};
use crate::output::ring_source::{ring_buffer, RingProgress, RingSourceWriter};
use crate::output::{AudioOutput, CpalOutput, OutputMode};
use crate::resample::FormatConverter;
use crate::MediaSource;
use lekis_types::{AudioProps, LekisError, Result};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, Sender, TryRecvError};
use std::sync::Arc;
use std::time::Duration;
use tokio::runtime::Handle;
use tokio::sync::oneshot;

/// 环形缓冲目标时长（毫秒）。解码线程领先输出这么多，够抵消调度抖动。
const BUFFER_MS: u64 = 300;

/// 解码线程等待缓冲腾地方时的轮询间隔。
const PUMP_INTERVAL: Duration = Duration::from_millis(3);

/// 发给解码线程的命令。
enum WorkerCmd {
    /// 跳转到指定毫秒并清空缓冲里的旧样本。
    Seek(u64),
    /// 立即结束解码线程。
    Stop,
}

/// 解码线程持有的共享句柄。
struct WorkerCtx {
    writer: RingSourceWriter,
    progress: RingProgress,
    stop: Arc<AtomicBool>,
    /// 音量（f32 的位模式，实时线程/解码线程只读）。
    volume: Arc<AtomicU32>,
    /// seek 之后的播放位置基准（毫秒）。
    base_ms: Arc<AtomicU64>,
    /// 解码器已到达流结尾。
    eof: Arc<AtomicBool>,
}

/// 一首歌的播放会话。
///
/// 生命周期：`Session::start()`（打开解码器 → 协商设备格式 → 建模环形缓冲 → 起输出流
/// → 起解码线程） → `pause` / `resume` / `seek` / `set_volume` → `stop`（或 `Drop`）干净收尾。
pub struct Session {
    output: CpalOutput,
    progress: RingProgress,
    stop: Arc<AtomicBool>,
    volume: Arc<AtomicU32>,
    base_ms: Arc<AtomicU64>,
    eof: Arc<AtomicBool>,
    commands: Sender<WorkerCmd>,
    thread: Option<std::thread::JoinHandle<()>>,
    /// 解码器输出格式（内容时间轴按它算）。
    format: PcmFormat,
    /// 环形缓冲与输出设备实际使用的格式（进度换算按它算）。
    device_format: PcmFormat,
    duration_ms: Option<u64>,
    /// 每毫秒的设备样本数（设备采样率 × 设备声道数 / 1000）。
    samples_per_ms: f64,
}

impl Session {
    /// 开始播放一份媒体。
    ///
    /// `volume`、`device_id`、`mode` 直接透给输出后端；`handle` 用于解码线程里的 VFS 阻塞读。
    /// 失败时保证已经建起来的线程/流都被清掉，不会留下悬挂资源。
    ///
    /// 设备格式由后端协商，可能和内容格式不同（共享模式下 WASAPI 常常固定 48 kHz）：
    /// 这时解码线程会插一级 [`FormatConverter`] 做声道映射 + 重采样。
    pub async fn start(
        media: &MediaSource,
        device_id: Option<&str>,
        mode: OutputMode,
        volume: f32,
        handle: Handle,
    ) -> Result<Self> {
        let stop = Arc::new(AtomicBool::new(false));
        let volume_atom = Arc::new(AtomicU32::new(volume.clamp(0.0, 1.0).to_bits()));
        let eof = Arc::new(AtomicBool::new(false));
        let base_ms = Arc::new(AtomicU64::new(0));
        let gain_linear = media.gain_db.map(db_to_linear).unwrap_or(1.0);

        // 解码线程先把「打开解码器」做完再回报格式，这样引擎能按真实格式建缓冲和输出流。
        let (ready_tx, ready_rx) =
            oneshot::channel::<Result<(PcmFormat, Option<u64>, AudioProps)>>();
        // 引擎侧协商完设备格式后，把写端交给解码线程，然后它才开始解。
        let (wire_tx, wire_rx) = mpsc::channel::<(RingSourceWriter, RingProgress, PcmFormat)>();
        let (cmd_tx, cmd_rx) = mpsc::channel::<WorkerCmd>();

        let thread_media = media.clone();
        let t_stop = stop.clone();
        let t_volume = volume_atom.clone();
        let t_base = base_ms.clone();
        let t_eof = eof.clone();
        let join = std::thread::Builder::new()
            .name("lekis-decode".to_string())
            .spawn(move || {
                let decoder = match open_decoder(&thread_media, &handle) {
                    Ok(decoder) => decoder,
                    Err(e) => {
                        let _ = ready_tx.send(Err(e));
                        return;
                    }
                };
                let format = decoder.format();
                let duration = decoder.duration_ms();
                let props = decoder.props().clone();
                if ready_tx.send(Ok((format, duration, props))).is_err() {
                    return;
                }
                let Ok((writer, progress, device_format)) = wire_rx.recv() else {
                    return;
                };
                let mut ctx = WorkerCtx {
                    writer,
                    progress,
                    stop: t_stop,
                    volume: t_volume,
                    base_ms: t_base,
                    eof: t_eof,
                };
                // 转换级在解码线程上建（rubato 构造要分配，不能放实时线程），失败就直通。
                let converter = match FormatConverter::new(format, device_format) {
                    Ok(converter) => converter,
                    Err(e) => {
                        tracing::warn!(
                            target: "playback",
                            error = %e,
                            "cannot build format converter, playing without conversion"
                        );
                        None
                    }
                };
                decode_loop(decoder, &mut ctx, cmd_rx, gain_linear, converter);
            })
            .map_err(|e| LekisError::internal(format!("cannot spawn decode thread: {e}")))?;

        // 等解码线程回报格式（或失败）。
        let ready = match ready_rx.await {
            Ok(result) => result,
            Err(_) => {
                let _ = join.join();
                return Err(LekisError::internal("decode thread exited during startup"));
            }
        };
        let (format, duration_ms, props) = match ready {
            Ok(v) => v,
            Err(e) => {
                let _ = join.join();
                return Err(e);
            }
        };
        if format.sample_rate == 0 || format.channels == 0 {
            drop(wire_tx);
            let _ = join.join();
            return Err(LekisError::invalid("decoder reported an empty pcm format"));
        }

        // 先问后端「这份内容格式最终会用哪个设备格式」，再按设备格式建环形缓冲：
        // 缓冲里的样本已经转换过了，容量必须按设备格式算。
        let mut output = CpalOutput::new();
        let planned = match output.plan_format(device_id, format) {
            Ok(planned) => planned,
            Err(e) => {
                // 没有音频设备（headless / CI）：把解码线程也收掉，向上返回 Unsupported。
                drop(wire_tx);
                let _ = join.join();
                return Err(e);
            }
        };
        if planned.sample_rate == 0 || planned.channels == 0 {
            drop(wire_tx);
            let _ = join.join();
            return Err(LekisError::invalid("output reported an empty pcm format"));
        }

        // 环形缓冲按 300 ms 容量建（设备格式）。
        let samples =
            u64::from(planned.sample_rate) * u64::from(planned.channels) / 1_000 * BUFFER_MS;
        let capacity = usize::try_from(samples.max(4_096)).unwrap_or(4_096);
        let (writer, source, progress) = ring_buffer(capacity, planned.channels);

        let actual = match output.start(device_id, format, mode, Box::new(source)) {
            Ok(actual) => actual,
            Err(e) => {
                drop(wire_tx);
                let _ = join.join();
                return Err(e);
            }
        };
        if actual != planned {
            // 两次协商之间设备配置变了：缓冲容量按旧格式算的，只影响缓冲时长，不影响正确性。
            tracing::warn!(
                target: "playback",
                planned_rate = planned.sample_rate,
                planned_channels = planned.channels,
                actual_rate = actual.sample_rate,
                actual_channels = actual.channels,
                "device format changed between negotiation and stream start"
            );
        }
        if actual != format {
            tracing::debug!(
                target: "playback",
                content_rate = format.sample_rate,
                content_channels = format.channels,
                device_rate = actual.sample_rate,
                device_channels = actual.channels,
                "converting content format to the device format (PLY-07)"
            );
        }

        if wire_tx.send((writer, progress.clone(), actual)).is_err() {
            let _ = join.join();
            let _ = output.stop();
            return Err(LekisError::internal(
                "decode thread died before playback started",
            ));
        }
        drop(wire_tx);

        tracing::debug!(
            target: "playback",
            track = %media.track_id,
            codec = ?props.codec,
            sample_rate = props.sample_rate,
            channels = props.channels,
            bit_depth = ?props.bit_depth,
            "playback session started"
        );

        // 进度换算用设备格式：环形缓冲里是设备格式的样本。
        let samples_per_ms = samples_per_ms(actual);
        Ok(Self {
            output,
            progress,
            stop,
            volume: volume_atom,
            base_ms,
            eof,
            commands: cmd_tx,
            thread: Some(join),
            format,
            device_format: actual,
            duration_ms,
            samples_per_ms,
        })
    }

    /// 解码器输出格式（内容格式）。
    pub fn format(&self) -> PcmFormat {
        self.format
    }

    /// 输出设备实际使用的格式。
    ///
    /// 和 [`Self::format`] 不同意味着解码线程正在做声道映射 / 重采样。
    pub fn device_format(&self) -> PcmFormat {
        self.device_format
    }

    /// 解码器给出的时长（毫秒）。
    pub fn duration_ms(&self) -> Option<u64> {
        self.duration_ms
    }

    /// 当前播放位置（毫秒）：已经真正被设备取走的样本对应的内容时间。
    pub fn position_ms(&self) -> u64 {
        let base = self.base_ms.load(Ordering::Acquire) as f64;
        if self.samples_per_ms <= 0.0 {
            return base as u64;
        }
        let played = self.progress.played_samples() as f64;
        let pos = (base + played / self.samples_per_ms).max(0.0);
        match self.duration_ms {
            Some(duration) if duration > 0 => (pos as u64).min(duration),
            _ => pos as u64,
        }
    }

    /// 跳转到指定位置。真正的解码器 seek 在解码线程上做，这里只投递命令。
    pub fn seek(&mut self, position_ms: u64) -> Result<()> {
        self.commands
            .send(WorkerCmd::Seek(position_ms))
            .map_err(|_| LekisError::internal("decode thread has stopped"))
    }

    /// 调音量（实时生效，无需重建流）。
    pub fn set_volume(&mut self, volume: f32) {
        self.volume
            .store(volume.clamp(0.0, 1.0).to_bits(), Ordering::Release);
    }

    /// 暂停输出流（保留缓冲内容）。
    pub fn pause(&mut self) -> Result<()> {
        self.output.pause()
    }

    /// 继续播放。
    pub fn resume(&mut self) -> Result<()> {
        self.output.resume()
    }

    /// 这首是否已经播完（解码器到达结尾**且**缓冲被播放空）。
    pub fn finished(&self) -> bool {
        self.eof.load(Ordering::Acquire) && self.progress.drained()
    }

    /// 解码线程是否已经退出。
    pub fn worker_finished(&self) -> bool {
        self.thread
            .as_ref()
            .map(|t| t.is_finished())
            .unwrap_or(true)
    }

    /// 欠载次数（诊断用）。
    pub fn underruns(&self) -> u64 {
        self.progress.underruns()
    }

    /// 干净收尾：停下解码线程、关掉输出流。
    ///
    /// 解码线程每 3 ms 检查一次停止标志，`push_blocking` 也会被同一个标志打断，
    /// 所以这里的 `join` 最多阻塞几毫秒（VFS 上一次 Range 读可能更久）。
    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::Release);
        let _ = self.commands.send(WorkerCmd::Stop);
        if let Some(handle) = self.thread.take() {
            let _ = handle.join();
        }
        let _ = self.output.stop();
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.stop();
    }
}

/// 解码线程主循环。
///
/// `converter` 为 `Some` 时，解出来的内容样本会先做声道映射 / 重采样再进环形缓冲；
/// 为 `None` 时走直通（内容格式 = 设备格式）。
fn decode_loop(
    mut decoder: Box<dyn Decoder>,
    ctx: &mut WorkerCtx,
    commands: Receiver<WorkerCmd>,
    gain_linear: f32,
    mut converter: Option<FormatConverter>,
) {
    let channels = decoder.format().channels.max(1);
    // 环形缓冲里的声道数（有转换级时是设备声道数）。
    let device_channels = converter
        .as_ref()
        .map(|c| c.device().channels)
        .unwrap_or(channels)
        .max(1);
    let mut buffer: Vec<f32> = Vec::with_capacity(usize::from(channels) * 4_096);
    let mut converted: Vec<f32> = Vec::with_capacity(usize::from(device_channels) * 8_192);
    let mut clipper = SoftClipper;
    let pump_threshold = usize::from(device_channels) * 1_024;

    loop {
        if ctx.stop.load(Ordering::Relaxed) {
            return;
        }
        // 1) 处理控制命令（seek / stop）。
        loop {
            match commands.try_recv() {
                Ok(WorkerCmd::Seek(ms)) => {
                    apply_seek(&mut *decoder, ctx, ms);
                    // seek 后重采样器里的 overlap 和残留样本都是上一段的，必须清掉。
                    if let Some(converter) = converter.as_mut() {
                        converter.reset();
                    }
                }
                Ok(WorkerCmd::Stop) | Err(TryRecvError::Disconnected) => return,
                Err(TryRecvError::Empty) => break,
            }
        }
        // 2) 缓冲快满了就等消费者腾地方。
        if ctx.writer.vacant_len() < pump_threshold {
            std::thread::sleep(PUMP_INTERVAL);
            continue;
        }
        // 3) 解一块，套上增益/限幅，转成设备格式，写进环形缓冲。
        buffer.clear();
        match decoder.decode_next(&mut buffer) {
            Ok(true) => {}
            Ok(false) => {
                // 正常结尾：等缓冲被播空后引擎会收到 finished。
                ctx.eof.store(true, Ordering::Release);
                return;
            }
            Err(e) => {
                // 坏包/坏文件不阻塞播放：记录后当作本曲结束，让引擎自动跳下一首。
                tracing::warn!(target: "playback", error = %e, "decode failed, ending track");
                ctx.eof.store(true, Ordering::Release);
                return;
            }
        }
        if buffer.is_empty() {
            continue;
        }
        apply_gain(
            &mut buffer,
            gain_linear,
            ctx.volume.load(Ordering::Acquire),
            channels,
            &mut clipper,
        );
        // 重采样在解码线程上做，实时回调只拿已经转好的设备格式样本。
        let to_push: &[f32] = match converter.as_mut() {
            Some(converter) => {
                converted.clear();
                converter.process(&buffer, &mut converted);
                &converted
            }
            None => &buffer,
        };
        if to_push.is_empty() {
            continue;
        }
        let written = ctx.writer.push_blocking(to_push, &ctx.stop);
        ctx.progress.add_pushed(written as u64);
    }
}

/// 每毫秒的样本数（采样率 × 声道数 / 1000），用于把「已播放样本数」换算成毫秒。
///
/// **必须传设备格式**：环形缓冲里存的是转换后的设备格式样本。传错格式的话
/// 进度条会按采样率比例偏快或偏慢（44.1 kHz 内容错用设备采样率时差 8.8%）。
fn samples_per_ms(format: PcmFormat) -> f64 {
    f64::from(format.sample_rate) * f64::from(format.channels) / 1_000.0
}

/// 对一块样本套上 ReplayGain + 用户音量，再过软限幅（PLY-03）。
fn apply_gain(
    samples: &mut [f32],
    gain_linear: f32,
    volume_bits: u32,
    channels: u16,
    clipper: &mut SoftClipper,
) {
    let volume = f32::from_bits(volume_bits).clamp(0.0, 1.0);
    let gain = gain_linear * volume;
    if (gain - 1.0).abs() > f32::EPSILON {
        for sample in samples.iter_mut() {
            *sample *= gain;
        }
    }
    clipper.process(samples, channels);
}

/// 在解码线程上执行一次 seek：先跳解码器，再清空缓冲里还没播的旧样本。
fn apply_seek(decoder: &mut dyn Decoder, ctx: &mut WorkerCtx, position_ms: u64) {
    match decoder.seek(position_ms) {
        Ok(actual) => {
            // 让实时回调丢掉旧数据（回调若没在跑，握手会超时，也照样继续）。
            let seq = ctx.progress.request_flush();
            let acked = ctx
                .progress
                .wait_flush_ack(seq, &ctx.stop, Duration::from_millis(250));
            ctx.progress.reset_samples();
            ctx.base_ms.store(actual, Ordering::Release);
            if !acked {
                tracing::debug!(
                    target: "playback",
                    position_ms = actual,
                    "flush was not acknowledged by the audio callback in time"
                );
            }
        }
        Err(e) => {
            tracing::warn!(target: "playback", position_ms, error = %e, "seek failed");
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    /// 增益与限幅的组合不能把样本推出 [-1, 1]。
    #[test]
    fn gain_and_clip_stays_in_range() {
        let mut samples = vec![0.5f32, -0.5, 0.99, -0.99];
        let mut clipper = SoftClipper;
        // 音量 1.0、ReplayGain +6 dB。
        apply_gain(
            &mut samples,
            db_to_linear(6.0),
            1.0f32.to_bits(),
            2,
            &mut clipper,
        );
        assert!(samples.iter().all(|s| s.abs() <= 1.0), "越界: {samples:?}");
    }

    /// 音量 0 时输出必须静音（静音不是"跳过处理"）。
    #[test]
    fn zero_volume_is_silent() {
        let mut samples = vec![0.8f32, -0.8];
        let mut clipper = SoftClipper;
        apply_gain(&mut samples, 1.0, 0.0f32.to_bits(), 2, &mut clipper);
        assert!(samples.iter().all(|s| *s == 0.0));
    }

    /// 进度换算必须按设备格式算：44.1 kHz 内容 + 48 kHz 设备时，
    /// 用内容格式算会让进度条快 8.8%（PLY-07 的关键点）。
    #[test]
    fn progress_uses_device_format_not_content_format() {
        let content = PcmFormat {
            sample_rate: 44_100,
            channels: 2,
        };
        let device = PcmFormat {
            sample_rate: 48_000,
            channels: 2,
        };
        // 设备每秒取走 48000 帧 = 96000 样本 → 1000 ms。
        assert!((samples_per_ms(device) * 1_000.0 - 96_000.0).abs() < 1e-6);
        assert!((samples_per_ms(content) * 1_000.0 - 88_200.0).abs() < 1e-6);
        // 两者相差 96000/88200 ≈ 8.8%：一小时内容会差出 5 分钟以上，所以必须用设备格式。
        let ratio = samples_per_ms(device) / samples_per_ms(content);
        assert!((ratio - 48_000.0 / 44_100.0).abs() < 1e-9);
        assert!(ratio > 1.08 && ratio < 1.09);
    }

    /// 单声道设备格式的每毫秒样本数也要对。
    #[test]
    fn samples_per_ms_handles_mono() {
        let mono = PcmFormat {
            sample_rate: 48_000,
            channels: 1,
        };
        assert!((samples_per_ms(mono) * 1_000.0 - 48_000.0).abs() < 1e-6);
    }
}
