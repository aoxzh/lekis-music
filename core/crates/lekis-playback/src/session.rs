//! 播放会话：把「解码线程 + 无锁环形缓冲 + 输出后端」拼成一条连续播放链路。
//!
//! 一条会话可以播多首（PLY-01 无缝播放）：下一首在当前曲目 EOF 之前预装好，
//! EOF 时直接在同一个环形缓冲里接着写，输出流不重建、不插入静音。
//!
//! ```text
//! 共享模式                                          实时回调（cpal）
//! Decoder ──► 增益/限幅 ──► 格式转换 ──► RingSourceWriter<f32> ──► RingSource<f32> ──► 设备
//!             （ReplayGain × 音量，只乘一次）              （20 ms 淡入淡出包络）
//!
//! 比特完美（PLY-05，Windows WASAPI 独占）           WASAPI 音频线程
//! Decoder ──► decode_next_native ──► RingSourceWriter<i32> ──► RingSource<i32> ──► 设备
//!             （左对齐 i32，无增益/无重采样）                    （只做字节打包，无淡入淡出）
//! ```
//!
//! 淡入淡出只在共享链路的输出回调里做：播放 / 恢复时从静音淡入，暂停 / seek /
//! 手动切歌前淡出。自然无缝拼接**不插入**淡入淡出，拼接点的样本保持逐样本精确。
//! 比特完美独占链路完全跳过这一步，否则样本位模式就不再是"位完美"了。
//!
//! 独占 / 比特完美链路目前**不是无缝的**：WASAPI 独占格式按每首歌协商，曲目结束时
//! 引擎会重建会话（有缝回退）。共享模式仍然保持样本级无缝（PLY-01）。
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

use crate::decode::{open_decoder, Decoder, NativeSampleFormat, PcmFormat};
use crate::dsp::{db_to_linear, DspNode, FadeControl, SoftClipper, DEFAULT_FADE_MS};
use crate::eq::{EqControl, ParametricEq};
use crate::gapless::{AudibleTrack, TrackTimeline};
use crate::output::bitperfect::{choose_decode_path, DecodePath, NativePlan};
use crate::output::ring_source::{
    ring_buffer_faded, ring_buffer_of, RingProgress, RingSourceWriter,
};
use crate::output::{AudioOutput, CpalOutput, OutputMode};
use crate::resample::FormatConverter;
use crate::MediaSource;
use lekis_types::{AudioProps, LekisError, Result, TrackId};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, Sender, TryRecvError};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::runtime::Handle;
use tokio::sync::oneshot;

/// 会话输出后端的创建方式。
///
/// 生产路径总是 cpal；测试注入一个「空输出」把样本按真实速度拉走并记录下来，
/// 这样不用声卡也能验证无缝拼接的样本序列（PLY-01）。
pub trait OutputFactory: Send + Sync + 'static {
    /// 事先协商设备格式（建环形缓冲之前就要知道）。
    fn plan_format(&self, device_id: Option<&str>, requested: PcmFormat) -> Result<PcmFormat>;

    /// 协商独占 / 比特完美格式。`Ok(None)` 表示本平台或后端没有独占路径。
    ///
    /// 默认实现不支持：测试注入的空输出仍然只走共享链路。
    fn plan_native(
        &self,
        _device_id: Option<&str>,
        _requested: PcmFormat,
        _native: NativeSampleFormat,
    ) -> Result<Option<NativePlan>> {
        Ok(None)
    }

    /// 创建输出后端实例。
    fn create(&self) -> Box<dyn AudioOutput>;
}

/// 默认输出工厂：cpal（Windows 上是 WASAPI 共享模式，独占请求走 WASAPI 独占）。
#[derive(Debug, Default, Clone, Copy)]
pub struct CpalOutputFactory;

impl OutputFactory for CpalOutputFactory {
    fn plan_format(&self, device_id: Option<&str>, requested: PcmFormat) -> Result<PcmFormat> {
        CpalOutput::new().plan_format(device_id, requested)
    }

    fn plan_native(
        &self,
        device_id: Option<&str>,
        requested: PcmFormat,
        native: NativeSampleFormat,
    ) -> Result<Option<NativePlan>> {
        CpalOutput::new().plan_native(device_id, requested, native)
    }

    fn create(&self) -> Box<dyn AudioOutput> {
        Box::new(CpalOutput::new())
    }
}

/// 环形缓冲目标时长（毫秒）。解码线程领先输出这么多，够抵消调度抖动。
const BUFFER_MS: u64 = 300;

/// 解码线程等待缓冲腾地方时的轮询间隔。
const PUMP_INTERVAL: Duration = Duration::from_millis(3);

/// 发给解码线程的命令。
enum WorkerCmd {
    /// 跳转到指定毫秒并清空缓冲里的旧样本。
    Seek(u64),
    /// 预装下一首：解码线程在当前曲目结束前打开解码器，EOF 时直接接着写同一条缓冲。
    ///
    /// `token` 是引擎侧生成的序号；解码线程在真正拼接前会再核对一次，
    /// 避免队列被用户改过之后还播旧歌。
    QueueNext {
        /// 下一首媒体。
        media: Box<MediaSource>,
        /// 预装序号。
        token: u64,
    },
    /// 取消预装（队列被编辑、关闭无缝播放、手动切歌）。
    ClearNext,
    /// 立即结束解码线程。
    Stop,
}

/// 解码线程持有的共享句柄。
struct WorkerCtx<T = f32> {
    writer: RingSourceWriter<T>,
    progress: RingProgress,
    stop: Arc<AtomicBool>,
    /// 音量（f32 的位模式，实时线程/解码线程只读）。
    volume: Arc<AtomicU32>,
    /// seek 之后的播放位置基准（毫秒）。
    base_ms: Arc<AtomicU64>,
    /// 解码器已到达流结尾。
    eof: Arc<AtomicBool>,
    /// 曲目边界时间轴（PLY-01）。
    timeline: TrackTimeline,
    /// 已完成的自然拼接次数。
    splices: Arc<AtomicU64>,
    /// 引擎侧的预装序号。
    next_token: Arc<AtomicU64>,
}

/// 引擎侧交给解码线程的链路配置。
///
/// 共享链路是 f32（可选重采样，支持样本级无缝拼接）；比特完美链路是左对齐 i32
/// （设备格式必须与内容一致，不做 DSP，也暂不支持无缝拼接）。
enum WorkerWire {
    Shared {
        writer: RingSourceWriter<f32>,
        progress: RingProgress,
        device_format: PcmFormat,
        timeline: TrackTimeline,
    },
    Native {
        writer: RingSourceWriter<i32>,
        progress: RingProgress,
        timeline: TrackTimeline,
    },
}

/// 一条输出流的播放会话（可以跨多首连续播放）。
///
/// 生命周期：`Session::start()`（打开解码器 → 协商设备格式 → 建模环形缓冲 → 起输出流
/// → 起解码线程） → `queue_next` 预装下一首 → `pause` / `resume` / `seek` / `set_volume`
/// → `stop`（或 `Drop`）干净收尾。
pub struct Session {
    output: Box<dyn AudioOutput>,
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
    /// 曲目边界时间轴：引擎按「已播放样本数」取当前可听曲目。
    timeline: TrackTimeline,
    /// 自然拼接次数（诊断 / 引擎判断是否需要推进队列）。
    splices: Arc<AtomicU64>,
    /// 预装下一首的序号（取消 / 替换时递增）。
    next_token: Arc<AtomicU64>,
    /// 是否真的走了 WASAPI 独占比特完美链路（而不是降级后的共享链路）。
    native_bit_perfect: bool,
    /// 输出流**实际**使用的模式：独占打开失败时是 [`OutputMode::Shared`]。
    output_mode: OutputMode,
    /// 共享链路的淡入淡出控制；比特完美链路为 `None`（样本必须逐位不变）。
    fade: Option<FadeControl>,
    /// 输出流当前是否被暂停（暂停时不再做淡出等待）。
    paused: bool,
    /// 输出流已经关掉（`stop()` 幂等）。
    output_stopped: bool,
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
        Self::start_with_factory(
            media,
            device_id,
            mode,
            volume,
            handle,
            Arc::new(CpalOutputFactory),
        )
        .await
    }

    /// 和 [`Self::start`] 一样，但输出后端由调用方提供（测试注入空输出）。
    ///
    /// 均衡器默认旁路；需要实时 EQ 时用 [`Self::start_with_factory_and_eq`]。
    pub async fn start_with_factory(
        media: &MediaSource,
        device_id: Option<&str>,
        mode: OutputMode,
        volume: f32,
        handle: Handle,
        output_factory: Arc<dyn OutputFactory>,
    ) -> Result<Self> {
        Self::start_with_factory_and_eq(
            media,
            device_id,
            mode,
            volume,
            handle,
            Arc::new(EqControl::default()),
            output_factory,
        )
        .await
    }

    /// 和 [`Self::start_with_factory`] 一样，但把共享的均衡器参数接进解码线程。
    ///
    /// 参数通过 [`EqControl`] 无锁传递，运行中改设置会在下一个解码块生效。
    /// 比特完美独占链路不经过 DSP，EQ 会被跳过并记录一条 warn。
    #[allow(clippy::too_many_arguments)]
    pub async fn start_with_factory_and_eq(
        media: &MediaSource,
        device_id: Option<&str>,
        mode: OutputMode,
        volume: f32,
        handle: Handle,
        eq: Arc<EqControl>,
        output_factory: Arc<dyn OutputFactory>,
    ) -> Result<Self> {
        let stop = Arc::new(AtomicBool::new(false));
        let volume_atom = Arc::new(AtomicU32::new(volume.clamp(0.0, 1.0).to_bits()));
        let eof = Arc::new(AtomicBool::new(false));
        let base_ms = Arc::new(AtomicU64::new(0));
        let splices = Arc::new(AtomicU64::new(0));
        let next_token = Arc::new(AtomicU64::new(0));
        let gain_linear = media.gain_db.map(db_to_linear).unwrap_or(1.0);

        // 解码线程先把「打开解码器」做完再回报格式，这样引擎能按真实格式建缓冲和输出流。
        // 同时回报 `native_format()`：只有解码器能给出原生样本时才可能走比特完美链路。
        let (ready_tx, ready_rx) = oneshot::channel::<
            Result<(
                PcmFormat,
                Option<NativeSampleFormat>,
                Option<u64>,
                AudioProps,
            )>,
        >();
        // 引擎侧协商完设备格式后，把写端交给解码线程，然后它才开始解。
        let (wire_tx, wire_rx) = mpsc::channel::<WorkerWire>();
        let (cmd_tx, cmd_rx) = mpsc::channel::<WorkerCmd>();
        // 预装下一首的「打开解码器」在独立线程里做：网络源探测可能很慢，
        // 不能卡住正在给环形缓冲供样本的解码线程。
        let (prepare_tx, prepare_rx) = mpsc::channel::<PreparedResult>();

        let thread_media = media.clone();
        let t_stop = stop.clone();
        let t_volume = volume_atom.clone();
        let t_base = base_ms.clone();
        let t_eof = eof.clone();
        let t_splices = splices.clone();
        let t_next_token = next_token.clone();
        let t_eq = eq.clone();
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
                let native = decoder.native_format();
                let duration = decoder.duration_ms();
                let props = decoder.props().clone();
                if ready_tx
                    .send(Ok((format, native, duration, props)))
                    .is_err()
                {
                    return;
                }
                let Ok(wire) = wire_rx.recv() else {
                    return;
                };
                match wire {
                    WorkerWire::Shared {
                        writer,
                        progress,
                        device_format,
                        timeline,
                    } => {
                        let mut ctx = WorkerCtx {
                            writer,
                            progress,
                            stop: t_stop,
                            volume: t_volume,
                            base_ms: t_base,
                            eof: t_eof,
                            timeline,
                            splices: t_splices,
                            next_token: t_next_token,
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
                        let active = ActiveTrack {
                            track_id: thread_media.track_id,
                            decoder,
                            converter,
                            format,
                            duration_ms: duration,
                            gain_linear,
                        };
                        // EQ 在设备采样率上运行，所以要在格式转换之后处理。
                        let mut equalizer = ParametricEq::new(
                            t_eq.clone(),
                            device_format.sample_rate,
                            device_format.channels,
                        );
                        decode_loop(
                            active,
                            &mut ctx,
                            cmd_rx,
                            device_format,
                            handle,
                            prepare_tx,
                            prepare_rx,
                            &mut equalizer,
                        );
                    }
                    WorkerWire::Native {
                        writer,
                        progress,
                        timeline,
                    } => {
                        // 比特完美：设备格式与内容格式一致，不建重采样器、不套增益。
                        if t_eq.enabled() {
                            tracing::warn!(
                                target: "playback::eq",
                                "equalizer is bypassed on bit-perfect exclusive output; switch to shared mode to use EQ"
                            );
                        }
                        let mut ctx = WorkerCtx::<i32> {
                            writer,
                            progress,
                            stop: t_stop,
                            volume: t_volume,
                            base_ms: t_base,
                            eof: t_eof,
                            timeline,
                            splices: t_splices,
                            next_token: t_next_token,
                        };
                        decode_loop_native(decoder, &mut ctx, cmd_rx);
                    }
                }
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
        let (format, native_format, duration_ms, props) = match ready {
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

        // 初始曲目也是时间轴上的第一条边界（从样本 0 开始）。
        // 独占 / 比特完美链路只播一首，也用它来算时长和进度。
        let timeline = TrackTimeline::new(
            media.track_id,
            duration_ms.or(Some(media.duration_hint_ms).filter(|hint| *hint > 0)),
            format,
        );

        let mut output = output_factory.create();

        // PLY-05：独占请求先协商原生格式。只有「独占 + 解码器有原生格式 + 设备接受该格式」
        // 三条同时成立才建 i32 缓冲；否则用共享 f32 链路并记下原因。
        let mut native_candidate: Option<(NativeSampleFormat, NativePlan)> = None;
        if mode == OutputMode::Exclusive {
            match native_format {
                Some(native) => match output_factory.plan_native(device_id, format, native) {
                    Ok(Some(plan)) => native_candidate = Some((native, plan)),
                    Ok(None) => tracing::warn!(
                        target: "playback::output",
                        "no native exclusive backend on this platform, falling back to shared mode"
                    ),
                    Err(e) => tracing::warn!(
                        target: "playback::output",
                        error = %e,
                        "device rejected the source format in exclusive mode, falling back to shared mode"
                    ),
                },
                None => tracing::warn!(
                    target: "playback::output",
                    "decoder has no native sample format, falling back to shared mode"
                ),
            }
        }
        let decode_path = choose_decode_path(mode, native_format, native_candidate.is_some());
        let native_setup = match decode_path {
            DecodePath::BitPerfect => native_candidate,
            DecodePath::Shared => None,
        };

        let (actual, progress, wire, native_bit_perfect, fade) = match native_setup {
            Some((native, plan)) => {
                match setup_native_output(
                    &mut *output,
                    device_id,
                    format,
                    native,
                    plan,
                    timeline.clone(),
                ) {
                    Ok((actual, progress, wire)) => {
                        if actual != plan.format {
                            tracing::warn!(
                                target: "playback::output",
                                planned_rate = plan.format.sample_rate,
                                planned_channels = plan.format.channels,
                                actual_rate = actual.sample_rate,
                                actual_channels = actual.channels,
                                "exclusive device format changed between negotiation and stream start"
                            );
                        }
                        if (volume - 1.0).abs() > f32::EPSILON || media.gain_db.is_some() {
                            // 比特完美路径不做任何增益运算；这里明确告诉用户音量/ReplayGain 不生效。
                            tracing::warn!(
                                target: "playback::output",
                                volume,
                                replay_gain = ?media.gain_db,
                                "bit-perfect exclusive output ignores volume and ReplayGain"
                            );
                        }
                        tracing::info!(
                            target: "playback::gapless",
                            "bit-perfect exclusive output is not gapless; the engine restarts the stream between tracks"
                        );
                        if eq.enabled() {
                            tracing::warn!(
                                target: "playback::eq",
                                "equalizer is bypassed on bit-perfect exclusive output; switch to shared mode to use EQ"
                            );
                        }
                        // 比特完美链路不建淡入淡出包络：任何增益都会破坏位模式。
                        (actual, progress, wire, true, None)
                    }
                    Err(e) => {
                        tracing::warn!(
                            target: "playback::output",
                            error = %e,
                            "WASAPI exclusive open failed (device busy or unsupported), falling back to shared mode"
                        );
                        let _ = output.stop();
                        match setup_shared_output(
                            output_factory.as_ref(),
                            &mut *output,
                            device_id,
                            format,
                            timeline.clone(),
                        ) {
                            Ok((actual, progress, wire, fade)) => {
                                (actual, progress, wire, false, Some(fade))
                            }
                            Err(e) => {
                                drop(wire_tx);
                                let _ = join.join();
                                let _ = output.stop();
                                return Err(e);
                            }
                        }
                    }
                }
            }
            None => match setup_shared_output(
                output_factory.as_ref(),
                &mut *output,
                device_id,
                format,
                timeline.clone(),
            ) {
                Ok((actual, progress, wire, fade)) => (actual, progress, wire, false, Some(fade)),
                Err(e) => {
                    // 没有音频设备（headless / CI）：把解码线程也收掉，向上返回 Unsupported。
                    drop(wire_tx);
                    let _ = join.join();
                    let _ = output.stop();
                    return Err(e);
                }
            },
        };

        let actual_mode = output.output_mode();
        if mode == OutputMode::Exclusive && actual_mode != OutputMode::Exclusive {
            tracing::warn!(
                target: "playback::output",
                "playback snapshot will reflect shared mode because exclusive output is unavailable"
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

        if wire_tx.send(wire).is_err() {
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
            bit_perfect = native_bit_perfect,
            mode = ?actual_mode,
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
            timeline,
            splices,
            next_token,
            native_bit_perfect,
            output_mode: actual_mode,
            fade,
            paused: false,
            output_stopped: false,
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

    /// 输出流**实际**使用的模式（独占打开失败时是共享）。
    pub fn output_mode(&self) -> OutputMode {
        self.output_mode
    }

    /// 是否真的走了比特完美链路（独占 + 原生格式 + 无 DSP）。
    pub fn native_bit_perfect(&self) -> bool {
        self.native_bit_perfect
    }

    /// 当前曲目的时长（毫秒）。无缝切换后是下一首的时长。
    pub fn duration_ms(&self) -> Option<u64> {
        self.audible_track()
            .and_then(|track| track.duration_ms)
            .or(self.duration_ms)
    }

    /// 当前播放位置（毫秒）：已经真正被设备取走的样本对应的内容时间。
    ///
    /// 无缝拼接后位置从下一首的第一个样本重新计时（边界之前解码线程提前推送的
    /// 上一首尾巴不算下一首的时间）。
    pub fn position_ms(&self) -> u64 {
        let track = self.audible_track();
        let base = self.base_ms.load(Ordering::Acquire) as f64;
        if self.samples_per_ms <= 0.0 {
            return base as u64;
        }
        let played = self.progress.played_samples();
        let start = track.as_ref().map(|t| t.start_sample).unwrap_or(0);
        let in_track = played.saturating_sub(start) as f64;
        let pos = (base + in_track / self.samples_per_ms).max(0.0);
        match track.and_then(|t| t.duration_ms.or(self.duration_ms)) {
            Some(duration) if duration > 0 => (pos as u64).min(duration),
            _ => pos as u64,
        }
    }

    /// 当前**听得见**的曲目边界（不是解码线程提前切到的那首）。
    pub fn audible_track(&self) -> Option<AudibleTrack> {
        self.timeline.audible(self.progress.played_samples())
    }

    /// 解码线程正在解的曲目（可能领先可听位置约 300 ms）。
    pub fn active_track_id(&self) -> Option<TrackId> {
        self.timeline.active().map(|track| track.track_id)
    }

    /// 已完成的自然拼接次数（PLY-01 诊断 / 引擎推进队列用）。
    pub fn splice_count(&self) -> u64 {
        self.splices.load(Ordering::Acquire)
    }

    /// 预装下一首：解码线程会在当前曲目结束前打开它，EOF 时直接接着写同一条缓冲。
    ///
    /// 只是「预备」；队列语义仍由引擎控制。再次调用会替换上一首预装。
    ///
    /// 比特完美独占会话不是无缝的：这里直接忽略，曲目结束时引擎会重建输出流。
    pub fn queue_next(&mut self, media: MediaSource) {
        if self.native_bit_perfect {
            tracing::debug!(
                target: "playback::gapless",
                track = %media.track_id,
                "bit-perfect exclusive session is not gapless; next track will start a new stream"
            );
            return;
        }
        let token = self.next_token.fetch_add(1, Ordering::AcqRel) + 1;
        if self
            .commands
            .send(WorkerCmd::QueueNext {
                media: Box::new(media),
                token,
            })
            .is_err()
        {
            tracing::debug!(target: "playback::gapless", "decode thread has stopped, cannot queue next");
        }
    }

    /// 取消预装（队列被编辑 / 关闭无缝播放）。已经拼进缓冲的样本无法撤回，
    /// 但解码线程会在真正切换前核对序号，不会把过期的下一首接上去。
    pub fn clear_next(&mut self) {
        if self.native_bit_perfect {
            return;
        }
        self.next_token.fetch_add(1, Ordering::AcqRel);
        let _ = self.commands.send(WorkerCmd::ClearNext);
    }

    /// 跳转到指定位置。真正的解码器 seek 在解码线程上做，这里只投递命令。
    ///
    /// 共享模式先让输出回调把 20 ms 淡出走完，再投递 seek；flush 会把包络重置到
    /// 静音，等新位置的第一块样本到达后再淡入。比特完美链路不淡入淡出。
    pub fn seek(&mut self, position_ms: u64) -> Result<()> {
        if self.native_bit_perfect {
            tracing::debug!(
                target: "playback",
                position_ms,
                "bit-perfect exclusive output: skipping fade around seek to keep samples bit-exact"
            );
        } else if !self.paused {
            self.fade_out_and_wait();
        }
        let result = self
            .commands
            .send(WorkerCmd::Seek(position_ms))
            .map_err(|_| LekisError::internal("decode thread has stopped"));
        if !self.native_bit_perfect {
            // flush 在回调里还会再 reset 一次；这里保证暂停中 seek 之后恢复能淡入。
            self.fade_in();
        }
        result
    }

    /// 调音量（实时生效，无需重建流）。
    ///
    /// 比特完美独占链路不做任何增益运算，音量/ReplayGain 会被忽略（保持源码位模式）。
    pub fn set_volume(&mut self, volume: f32) {
        if self.native_bit_perfect {
            if (volume.clamp(0.0, 1.0) - 1.0).abs() > f32::EPSILON {
                tracing::warn!(
                    target: "playback",
                    volume,
                    "bit-perfect exclusive output ignores volume changes"
                );
            }
            return;
        }
        self.volume
            .store(volume.clamp(0.0, 1.0).to_bits(), Ordering::Release);
    }

    /// 暂停输出流（保留缓冲内容）。
    ///
    /// 共享模式：先请求淡出并等回调把 20 ms 斜坡走完，再真正暂停，避免波形被
    /// 硬切成静音产生"咔哒"。比特完美链路直接暂停（淡入淡出会改样本位模式）。
    pub fn pause(&mut self) -> Result<()> {
        if self.paused {
            return Ok(());
        }
        if self.native_bit_perfect {
            tracing::debug!(
                target: "playback",
                "bit-perfect exclusive output: pausing without a fade to keep samples bit-exact"
            );
        } else {
            self.fade_out_and_wait();
        }
        match self.output.pause() {
            Ok(()) => {
                self.paused = true;
                Ok(())
            }
            Err(e) => {
                // 没暂停成功：把音量斜坡恢复到 1，别让音乐继续响着却越来越轻。
                if !self.native_bit_perfect {
                    self.fade_in();
                }
                Err(e)
            }
        }
    }

    /// 继续播放。
    ///
    /// 共享模式从静音淡入；比特完美链路保持原始样本。
    pub fn resume(&mut self) -> Result<()> {
        if !self.native_bit_perfect {
            self.fade_in();
        } else {
            tracing::debug!(
                target: "playback",
                "bit-perfect exclusive output: resuming without a fade to keep samples bit-exact"
            );
        }
        match self.output.resume() {
            Ok(()) => {
                self.paused = false;
                Ok(())
            }
            Err(e) => {
                if !self.native_bit_perfect {
                    self.fade_out();
                }
                Err(e)
            }
        }
    }

    /// 请求淡出并等实时回调真正消费完斜坡（只用于共享模式）。
    ///
    /// 不看墙钟而是看 [`RingProgress`]：设备块大小不固定，只要已播放样本数
    /// 增加了「20 ms 对应的设备帧数」，就说明回调已经把整条斜坡渲染出去了。
    /// 缓冲已经播空时直接返回，避免在曲目结束后白等。
    fn fade_out_and_wait(&self) {
        let Some(fade) = self.fade.as_ref() else {
            return;
        };
        if self.progress.drained() {
            return;
        }
        fade.fade_out();
        let channels = u64::from(self.device_format.channels.max(1));
        let frames =
            crate::dsp::fade_frames(self.device_format.sample_rate, DEFAULT_FADE_MS) as u64;
        let needed = frames.saturating_mul(channels);
        let start = self.progress.played_samples();
        let deadline = Instant::now() + Duration::from_millis(60);
        while self.progress.played_samples() < start.saturating_add(needed)
            && Instant::now() < deadline
        {
            std::thread::sleep(Duration::from_millis(1));
        }
    }

    /// 请求淡入（只用于共享模式）。
    fn fade_in(&self) {
        if let Some(fade) = self.fade.as_ref() {
            fade.fade_in();
        }
    }

    /// 请求淡出但不等待（恢复失败时回滚用）。
    fn fade_out(&self) {
        if let Some(fade) = self.fade.as_ref() {
            fade.fade_out();
        }
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
        if self.output_stopped {
            return;
        }
        self.output_stopped = true;
        if self.native_bit_perfect {
            tracing::debug!(
                target: "playback",
                "bit-perfect exclusive output: stopping without a fade to keep samples bit-exact"
            );
        } else if !self.paused {
            // 手动切歌 / 关设备：先淡出，避免旧波形被硬切。自然无缝拼接不经过
            // 这里（解码线程直接把下一首接进同一条缓冲），所以拼接点仍然逐样本精确。
            self.fade_out_and_wait();
        }
        self.stop.store(true, Ordering::Release);
        let _ = self.commands.send(WorkerCmd::Stop);
        if let Some(handle) = self.thread.take() {
            let _ = handle.join();
        }
        let _ = self.output.stop();
    }
}

/// 环形缓冲按 300 ms 容量建（设备格式）。
fn buffer_capacity(format: PcmFormat) -> usize {
    let samples = u64::from(format.sample_rate) * u64::from(format.channels) / 1_000 * BUFFER_MS;
    usize::try_from(samples.max(4_096)).unwrap_or(4_096)
}

/// 共享模式链路：f32 环形缓冲 + cpal 流（支持样本级无缝拼接）。
fn setup_shared_output(
    factory: &dyn OutputFactory,
    output: &mut dyn AudioOutput,
    device_id: Option<&str>,
    content_format: PcmFormat,
    timeline: TrackTimeline,
) -> Result<(PcmFormat, RingProgress, WorkerWire, FadeControl)> {
    let planned = factory.plan_format(device_id, content_format)?;
    if planned.sample_rate == 0 || planned.channels == 0 {
        return Err(LekisError::invalid("output reported an empty pcm format"));
    }
    // 20 ms 淡入淡出在输出回调里执行；ReplayGain / 音量仍然只在解码线程算一次。
    let (writer, source, progress, fade) = ring_buffer_faded(
        buffer_capacity(planned),
        planned.channels,
        planned.sample_rate,
    );
    let actual = output.start(
        device_id,
        content_format,
        OutputMode::Shared,
        Box::new(source),
    )?;
    let wire = WorkerWire::Shared {
        writer,
        progress: progress.clone(),
        device_format: actual,
        timeline,
    };
    Ok((actual, progress, wire, fade))
}

/// 比特完美链路：左对齐 i32 环形缓冲 + WASAPI 独占流。
fn setup_native_output(
    output: &mut dyn AudioOutput,
    device_id: Option<&str>,
    content_format: PcmFormat,
    native: NativeSampleFormat,
    plan: NativePlan,
    timeline: TrackTimeline,
) -> Result<(PcmFormat, RingProgress, WorkerWire)> {
    if plan.format.sample_rate == 0 || plan.format.channels == 0 {
        return Err(LekisError::invalid(
            "exclusive output reported an empty pcm format",
        ));
    }
    let (writer, source, progress) =
        ring_buffer_of::<i32>(buffer_capacity(plan.format), plan.format.channels);
    let actual = output.start_native(device_id, content_format, native, Box::new(source))?;
    let wire = WorkerWire::Native {
        writer,
        progress: progress.clone(),
        timeline,
    };
    Ok((actual, progress, wire))
}

impl Drop for Session {
    fn drop(&mut self) {
        self.stop();
    }
}

/// 解码线程当前正在解的一首。
struct ActiveTrack {
    track_id: TrackId,
    decoder: Box<dyn Decoder>,
    converter: Option<FormatConverter>,
    format: PcmFormat,
    duration_ms: Option<u64>,
    gain_linear: f32,
}

/// 已经预装好、等当前曲目 EOF 就接上的下一首。
struct PreparedTrack {
    /// 引擎侧序号：拼接前再核对一次，防止队列被改过还播旧歌。
    token: u64,
    track_id: TrackId,
    decoder: Box<dyn Decoder>,
    converter: PreparedConverter,
    format: PcmFormat,
    duration_ms: Option<u64>,
    gain_linear: f32,
}

/// 预装线程的返回结果。
struct PreparedResult {
    token: u64,
    result: Result<PreparedTrack>,
}

/// 下一首使用哪个转换级。
enum PreparedConverter {
    /// 内容格式和当前曲目相同：沿用当前转换级（连重采样器的 overlap 一起复用，
    /// 边界处完全连续，不丢一个样本）。
    Reuse,
    /// 内容格式不同，但新曲目格式就是设备格式：直通。
    Direct,
    /// 内容格式不同：新建转换级。
    Convert(Box<FormatConverter>),
}

/// 解码线程主循环。
///
/// 当前曲目 EOF 时，如果下一首已经预装好，就在**同一条环形缓冲**里直接接着写，
/// 输出流和会话都不重建（PLY-01）。只有拿不到预装（关闭无缝、解析失败、坏文件、
/// 队列被改）时才把 EOF 报给引擎，退回「重建会话」的有缝路径。
// 这里是内部装配函数，参数多但都是解码线程必须的上下文；拆结构体反而更吵。
#[allow(clippy::too_many_arguments)]
fn decode_loop(
    mut active: ActiveTrack,
    ctx: &mut WorkerCtx,
    commands: Receiver<WorkerCmd>,
    device_format: PcmFormat,
    handle: Handle,
    prepare_tx: Sender<PreparedResult>,
    prepare_rx: Receiver<PreparedResult>,
    equalizer: &mut ParametricEq,
) {
    let device_channels = usize::from(device_format.channels.max(1));
    let mut buffer: Vec<f32> = Vec::with_capacity(device_channels * 4_096);
    let mut converted: Vec<f32> = Vec::with_capacity(device_channels * 8_192);
    let mut clipper = SoftClipper;
    let pump_threshold = device_channels * 1_024;

    // 已经预装好、等当前曲目 EOF 的下一首。
    let mut prepared: Option<PreparedTrack> = None;

    loop {
        if ctx.stop.load(Ordering::Relaxed) {
            return;
        }
        // 0) 收预装线程的结果（打开解码器可能很慢，不能卡住这里）。
        while let Ok(message) = prepare_rx.try_recv() {
            let token_now = ctx.next_token.load(Ordering::Acquire);
            if message.token != token_now {
                // 队列已经改过 / 被取消：丢掉过期的预装结果。
                continue;
            }
            match message.result {
                Ok(track) => {
                    tracing::debug!(
                        target: "playback::gapless",
                        from = %active.track_id,
                        to = %track.track_id,
                        content_rate = track.format.sample_rate,
                        content_channels = track.format.channels,
                        device_rate = device_format.sample_rate,
                        device_channels = device_format.channels,
                        "next track pre-opened for gapless splice"
                    );
                    prepared = Some(track);
                }
                Err(e) => {
                    tracing::warn!(
                        target: "playback::gapless",
                        error = %e,
                        "cannot pre-open next track; track boundary will fall back to a session restart"
                    );
                }
            }
        }

        // 1) 处理控制命令（seek / 预装 / 取消预装 / stop）。
        loop {
            match commands.try_recv() {
                Ok(WorkerCmd::Seek(ms)) => {
                    apply_seek(
                        &mut *active.decoder,
                        ctx,
                        ms,
                        active.track_id,
                        active.duration_ms,
                        active.format,
                    );
                    // seek 后重采样器里的 overlap 和残留样本都是上一段的，必须清掉。
                    if let Some(converter) = active.converter.as_mut() {
                        converter.reset();
                    }
                    // 滤波器历史同样属于上一段音频，清掉避免 seek 后的爆音。
                    equalizer.reset();
                }
                Ok(WorkerCmd::QueueNext { media, token }) => {
                    prepared = None;
                    let media = *media;
                    let content_format = active.format;
                    let handle = handle.clone();
                    let results = prepare_tx.clone();
                    let spawned = std::thread::Builder::new()
                        .name("lekis-prepare".to_string())
                        .spawn(move || {
                            let result =
                                prepare_next(&media, token, content_format, device_format, &handle);
                            let _ = results.send(PreparedResult { token, result });
                        });
                    if let Err(e) = spawned {
                        tracing::warn!(
                            target: "playback::gapless",
                            error = %e,
                            "cannot spawn pre-open thread; track boundary will fall back to a session restart"
                        );
                    } else {
                        tracing::debug!(
                            target: "playback::gapless",
                            token,
                            "next track queued for gapless playback"
                        );
                    }
                }
                Ok(WorkerCmd::ClearNext) => {
                    prepared = None;
                    tracing::debug!(target: "playback::gapless", "gapless next track cleared");
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
        let at_end = match active.decoder.decode_next(&mut buffer) {
            Ok(true) => false,
            Ok(false) => true,
            Err(e) => {
                // 坏包/坏文件不阻塞播放：记录后当作本曲结束，能接下一首就接。
                tracing::warn!(target: "playback", error = %e, "decode failed, ending track");
                true
            }
        };

        if at_end {
            let token_now = ctx.next_token.load(Ordering::Acquire);
            let fresh = prepared
                .as_ref()
                .is_some_and(|track| track.token == token_now);
            if fresh {
                if let Some(next) = prepared.take() {
                    if splice_next(
                        &mut active,
                        next,
                        ctx,
                        device_format,
                        &mut converted,
                        equalizer,
                        &mut clipper,
                    ) {
                        continue;
                    }
                    // 停止标志在拼接过程中被置位：直接收尾。
                    return;
                }
            }
            // 没有可用的下一首：把转换器尾巴吐完，再把 EOF 报给引擎（有缝回退）。
            flush_converter_tail(
                &mut active,
                ctx,
                device_format.channels,
                equalizer,
                &mut clipper,
            );
            ctx.eof.store(true, Ordering::Release);
            return;
        }

        if buffer.is_empty() {
            continue;
        }
        let content_channels = active.format.channels.max(1);
        apply_gain(
            &mut buffer,
            active.gain_linear,
            ctx.volume.load(Ordering::Acquire),
            content_channels,
        );
        // 重采样在解码线程上做，实时回调只拿已经转好的设备格式样本。
        let to_push: &mut [f32] = match active.converter.as_mut() {
            Some(converter) => {
                converted.clear();
                converter.process(&buffer, &mut converted);
                &mut converted
            }
            None => &mut buffer,
        };
        if to_push.is_empty() {
            continue;
        }
        // EQ 必须按设备采样率运行，所以放在重采样 / 声道映射之后；
        // 限幅也放在 EQ 之后，才能拦住均衡器带来的正增益削波。
        process_output(to_push, device_format.channels, equalizer, &mut clipper);
        let written = ctx.writer.push_blocking(to_push, &ctx.stop);
        ctx.progress.add_pushed(written as u64);
    }
}

/// 比特完美解码循环（PLY-05）。
///
/// 与 [`decode_loop`] 的区别：**不**套 ReplayGain、音量、限幅器，也**不**重采样。
/// 解码器原生样本直接进 i32 环形缓冲，输出线程只做字节打包。
///
/// 独占链路暂不拼接下一首：`QueueNext` / `ClearNext` 在这里被忽略，曲目结束时
/// 解码线程报 EOF，引擎会重建会话（共享模式仍然是真正无缝的）。
fn decode_loop_native(
    mut decoder: Box<dyn Decoder>,
    ctx: &mut WorkerCtx<i32>,
    commands: Receiver<WorkerCmd>,
) {
    let channels = decoder.format().channels.max(1);
    let mut buffer: Vec<i32> = Vec::with_capacity(usize::from(channels) * 4_096);
    let pump_threshold = usize::from(channels) * 1_024;

    loop {
        if ctx.stop.load(Ordering::Relaxed) {
            return;
        }
        // 1) 控制命令：seek 同样要清空旧缓冲；比特完美链路没有重采样器要重置。
        loop {
            match commands.try_recv() {
                Ok(WorkerCmd::Seek(ms)) => {
                    apply_seek_native(&mut *decoder, ctx, ms);
                }
                Ok(WorkerCmd::QueueNext { media, .. }) => {
                    tracing::debug!(
                        target: "playback::gapless",
                        track = %media.track_id,
                        "bit-perfect exclusive session is not gapless; ignoring queue_next"
                    );
                }
                Ok(WorkerCmd::ClearNext) => {}
                Ok(WorkerCmd::Stop) | Err(TryRecvError::Disconnected) => return,
                Err(TryRecvError::Empty) => break,
            }
        }
        // 2) 缓冲快满了就等消费者腾地方。
        if ctx.writer.vacant_len() < pump_threshold {
            std::thread::sleep(PUMP_INTERVAL);
            continue;
        }
        // 3) 解一块原生样本，原样写进 i32 环形缓冲。
        buffer.clear();
        match decoder.decode_next_native(&mut buffer) {
            Ok(true) => {}
            Ok(false) => {
                ctx.eof.store(true, Ordering::Release);
                return;
            }
            Err(e) => {
                tracing::warn!(target: "playback", error = %e, "native decode failed, ending track");
                ctx.eof.store(true, Ordering::Release);
                return;
            }
        }
        if buffer.is_empty() {
            continue;
        }
        let written = ctx.writer.push_blocking(&buffer, &ctx.stop);
        ctx.progress.add_pushed(written as u64);
    }
}

/// 打开下一首并准备好它的转换级（在解码线程上调用，可以分配 / 做 IO）。
fn prepare_next(
    media: &MediaSource,
    token: u64,
    active_format: PcmFormat,
    device_format: PcmFormat,
    handle: &Handle,
) -> Result<PreparedTrack> {
    let decoder = open_decoder(media, handle)?;
    let format = decoder.format();
    if format.sample_rate == 0 || format.channels == 0 {
        return Err(LekisError::invalid(
            "next track reported an empty pcm format",
        ));
    }
    let duration_ms = decoder
        .duration_ms()
        .or(Some(media.duration_hint_ms).filter(|hint| *hint > 0));
    let converter = if format == active_format {
        PreparedConverter::Reuse
    } else {
        match FormatConverter::new(format, device_format)? {
            Some(converter) => PreparedConverter::Convert(Box::new(converter)),
            None => PreparedConverter::Direct,
        }
    };
    Ok(PreparedTrack {
        token,
        track_id: media.track_id,
        decoder,
        converter,
        format,
        duration_ms,
        gain_linear: media.gain_db.map(db_to_linear).unwrap_or(1.0),
    })
}

/// 把预装好的下一首接进同一条环形缓冲。返回 `false` 表示播放正在停止。
fn splice_next(
    active: &mut ActiveTrack,
    next: PreparedTrack,
    ctx: &mut WorkerCtx,
    device_format: PcmFormat,
    converted: &mut Vec<f32>,
    equalizer: &mut ParametricEq,
    clipper: &mut SoftClipper,
) -> bool {
    let format_changed = next.format != active.format;
    let (converter, mut flushed) = match next.converter {
        PreparedConverter::Reuse => (active.converter.take(), None),
        PreparedConverter::Direct => {
            let mut tail = Vec::new();
            if let Some(mut old) = active.converter.take() {
                old.finish(&mut tail);
            }
            (None, Some(tail))
        }
        PreparedConverter::Convert(converter) => {
            let mut tail = Vec::new();
            if let Some(mut old) = active.converter.take() {
                old.finish(&mut tail);
            }
            (Some(*converter), Some(tail))
        }
    };
    // 换格式时先把上一首转换器里的尾巴（最多一个重采样块）补零翻出去，
    // 不能直接丢掉；同格式复用转换器时没有尾巴，边界完全连续。
    if let Some(tail) = flushed.as_mut() {
        if !tail.is_empty() {
            // 尾巴也是设备格式，必须走同一级 EQ + 限幅，否则拼接点会不一致。
            process_output(tail, device_format.channels, equalizer, clipper);
            let written = ctx.writer.push_blocking(tail, &ctx.stop);
            ctx.progress.add_pushed(written as u64);
            if ctx.stop.load(Ordering::Relaxed) {
                return false;
            }
        }
    }
    converted.clear();

    // 时间轴上的拼接点 = 下一首第一个样本的设备样本序号。
    let start_pushed = ctx.progress.pushed_samples();
    let splice_count = ctx.splices.fetch_add(1, Ordering::AcqRel) + 1;
    let generation = ctx.timeline.push_boundary(
        start_pushed,
        next.track_id,
        next.duration_ms,
        next.format,
        splice_count,
    );
    ctx.base_ms.store(0, Ordering::Release);
    ctx.eof.store(false, Ordering::Release);

    let buffered_samples = ctx.writer.occupied_len();
    let device_spm = samples_per_ms(device_format);
    let buffered_ms = if device_spm > 0.0 {
        buffered_samples as f64 / device_spm
    } else {
        0.0
    };
    tracing::info!(
        target: "playback::gapless",
        from = %active.track_id,
        to = %next.track_id,
        splice_sample = start_pushed,
        generation,
        splice_count,
        buffered_samples,
        buffered_ms,
        gap_ms = 0.0,
        format_changed,
        "gapless splice: next track continues in the same output stream"
    );

    *active = ActiveTrack {
        track_id: next.track_id,
        decoder: next.decoder,
        converter,
        format: next.format,
        duration_ms: next.duration_ms,
        gain_linear: next.gain_linear,
    };
    true
}

/// 曲目结束且没有下一首可接时，把转换器里不足一块的尾巴吐出来。
fn flush_converter_tail(
    active: &mut ActiveTrack,
    ctx: &mut WorkerCtx,
    device_channels: u16,
    equalizer: &mut ParametricEq,
    clipper: &mut SoftClipper,
) {
    let Some(mut converter) = active.converter.take() else {
        return;
    };
    let mut tail = Vec::new();
    converter.finish(&mut tail);
    if !tail.is_empty() {
        process_output(&mut tail, device_channels, equalizer, clipper);
        let written = ctx.writer.push_blocking(&tail, &ctx.stop);
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

/// 对一块样本套上 ReplayGain + 用户音量（PLY-03）。
///
/// 这是共享链路里**唯一**乘 ReplayGain 的地方：`media.gain_db` 由 lekis-core 的
/// resolver 按 `playback.replaygain`（track / album / off）选好，这里和用户音量合成
/// 一个线性系数后只遍历一次。输出回调里的 20 ms 淡入淡出是另一层包络，不会再次
/// 乘 ReplayGain，所以不会出现"双倍增益"。
///
/// 限幅不在这里做：EQ 在格式转换之后运行，必须排在 EQ 之后才能拦住均衡器增益。
fn apply_gain(samples: &mut [f32], gain_linear: f32, volume_bits: u32, _channels: u16) {
    let volume = f32::from_bits(volume_bits).clamp(0.0, 1.0);
    let gain = gain_linear * volume;
    if (gain - 1.0).abs() > f32::EPSILON {
        for sample in samples.iter_mut() {
            *sample *= gain;
        }
    }
}

/// 设备格式样本的最后一级：EQ 后接软限幅。
fn process_output(
    samples: &mut [f32],
    channels: u16,
    equalizer: &mut ParametricEq,
    clipper: &mut SoftClipper,
) {
    equalizer.process(samples, channels);
    clipper.process(samples, channels);
}

/// 在解码线程上执行一次 seek：先跳解码器，再清空缓冲里还没播的旧样本。
///
/// `track_id` / `duration` / `format` 是解码线程**正在解**的那一首。它可能已经拼接了
/// 下一首（缓冲里还有上一首的尾巴），所以 seek 后时间轴要直接落到这一首上，
/// 把还没播到的旧边界清掉。
fn apply_seek(
    decoder: &mut dyn Decoder,
    ctx: &mut WorkerCtx,
    position_ms: u64,
    track_id: TrackId,
    duration_ms: Option<u64>,
    format: PcmFormat,
) {
    if seek_decoder(decoder, &ctx.progress, &ctx.base_ms, &ctx.stop, position_ms).is_some() {
        let splice_count = ctx.splices.load(Ordering::Acquire);
        ctx.timeline
            .rebase(track_id, duration_ms, format, splice_count);
    }
}

/// 比特完美链路的 seek：只重置缓冲与位置基准；独占链路只有一首，时间轴无需重建。
fn apply_seek_native(decoder: &mut dyn Decoder, ctx: &mut WorkerCtx<i32>, position_ms: u64) {
    seek_decoder(decoder, &ctx.progress, &ctx.base_ms, &ctx.stop, position_ms);
}

/// 公共 seek 实现，返回解码器实际落到的位置（失败时 `None`）。
fn seek_decoder(
    decoder: &mut dyn Decoder,
    progress: &RingProgress,
    base_ms: &AtomicU64,
    stop: &AtomicBool,
    position_ms: u64,
) -> Option<u64> {
    match decoder.seek(position_ms) {
        Ok(actual) => {
            // 让实时回调丢掉旧数据（回调若没在跑，握手会超时，也照样继续）。
            let seq = progress.request_flush();
            let acked = progress.wait_flush_ack(seq, stop, Duration::from_millis(250));
            progress.reset_samples();
            base_ms.store(actual, Ordering::Release);
            if !acked {
                tracing::debug!(
                    target: "playback",
                    position_ms = actual,
                    "flush was not acknowledged by the audio callback in time"
                );
            }
            Some(actual)
        }
        Err(e) => {
            tracing::warn!(target: "playback", position_ms, error = %e, "seek failed");
            None
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
        // 音量 1.0、ReplayGain +6 dB；限幅级现在在 EQ 之后，单独套一次。
        apply_gain(&mut samples, db_to_linear(6.0), 1.0f32.to_bits(), 2);
        let mut clipper = SoftClipper;
        clipper.process(&mut samples, 2);
        assert!(samples.iter().all(|s| s.abs() <= 1.0), "越界: {samples:?}");
    }

    /// 音量 0 时输出必须静音（静音不是"跳过处理"）。
    #[test]
    fn zero_volume_is_silent() {
        let mut samples = vec![0.8f32, -0.8];
        apply_gain(&mut samples, 1.0, 0.0f32.to_bits(), 2);
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

    use crate::test_support::{nonzero_span, temp_dir, write_wav, NullOutputFactory};
    use crate::MediaLocation;
    use std::path::Path;
    use std::time::Instant;

    use crate::output::bitperfect::pack_into;
    use crate::output::{NativePacking, NativeSampleSource, OutputDevice};

    /// 测试用「原生空输出」：只接受比特完美链路，按真实时间拉走 i32 样本并记录。
    struct NativeNullFactory {
        planned: PcmFormat,
        bits: u8,
        packing: NativePacking,
        capture: Arc<std::sync::Mutex<Vec<i32>>>,
    }

    impl NativeNullFactory {
        fn new(planned: PcmFormat) -> Self {
            Self::with_native(planned, 16, NativePacking::Int16)
        }

        fn with_native(planned: PcmFormat, bits: u8, packing: NativePacking) -> Self {
            Self {
                planned,
                bits,
                packing,
                capture: Arc::new(std::sync::Mutex::new(Vec::new())),
            }
        }

        fn captured(&self) -> Vec<i32> {
            self.capture
                .lock()
                .map(|samples| samples.clone())
                .unwrap_or_default()
        }
    }

    impl OutputFactory for NativeNullFactory {
        fn plan_format(
            &self,
            _device_id: Option<&str>,
            _requested: PcmFormat,
        ) -> Result<PcmFormat> {
            Ok(self.planned)
        }

        fn plan_native(
            &self,
            _device_id: Option<&str>,
            requested: PcmFormat,
            native: NativeSampleFormat,
        ) -> Result<Option<NativePlan>> {
            assert_eq!(requested, self.planned);
            assert_eq!(native, NativeSampleFormat::Int { bits: self.bits });
            Ok(Some(NativePlan {
                format: self.planned,
                packing: self.packing,
            }))
        }

        fn create(&self) -> Box<dyn AudioOutput> {
            Box::new(NativeNullOutput {
                planned: self.planned,
                capture: self.capture.clone(),
                stop: Arc::new(AtomicBool::new(false)),
                thread: None,
            })
        }
    }

    struct NativeNullOutput {
        planned: PcmFormat,
        capture: Arc<std::sync::Mutex<Vec<i32>>>,
        stop: Arc<AtomicBool>,
        thread: Option<std::thread::JoinHandle<()>>,
    }

    impl AudioOutput for NativeNullOutput {
        fn devices(&self) -> Result<Vec<OutputDevice>> {
            Ok(Vec::new())
        }

        fn start(
            &mut self,
            _device_id: Option<&str>,
            _requested: PcmFormat,
            _mode: OutputMode,
            _source: Box<dyn crate::output::SampleSource>,
        ) -> Result<PcmFormat> {
            Err(LekisError::invalid(
                "shared output must not be used by the native session test",
            ))
        }

        fn start_native(
            &mut self,
            _device_id: Option<&str>,
            _requested: PcmFormat,
            _native: NativeSampleFormat,
            mut source: Box<dyn NativeSampleSource>,
        ) -> Result<PcmFormat> {
            let stop = self.stop.clone();
            let capture = self.capture.clone();
            let format = self.planned;
            let frames = 800usize;
            let channels = usize::from(format.channels.max(1));
            let rate = u64::from(format.sample_rate.max(1));
            let period = Duration::from_nanos(frames as u64 * 1_000_000_000 / rate);
            self.thread = Some(
                std::thread::Builder::new()
                    .name("lekis-native-null-output".to_string())
                    .spawn(move || {
                        // 给解码线程一点时间先把环形缓冲填起来。
                        std::thread::sleep(Duration::from_millis(50));
                        let mut block = vec![0i32; frames * channels];
                        while !stop.load(Ordering::Relaxed) {
                            let _ = source.fill(&mut block);
                            if let Ok(mut out) = capture.lock() {
                                out.extend_from_slice(&block);
                            }
                            std::thread::sleep(period);
                        }
                    })
                    .expect("spawn native null output thread"),
            );
            Ok(format)
        }

        fn output_mode(&self) -> OutputMode {
            OutputMode::Exclusive
        }

        fn pause(&mut self) -> Result<()> {
            Ok(())
        }

        fn resume(&mut self) -> Result<()> {
            Ok(())
        }

        fn stop(&mut self) -> Result<()> {
            self.stop.store(true, Ordering::Release);
            if let Some(thread) = self.thread.take() {
                let _ = thread.join();
            }
            Ok(())
        }
    }

    fn cached_media(track: i64, path: &Path, duration_hint_ms: u64) -> MediaSource {
        cached_media_with_gain(track, path, duration_hint_ms, None)
    }

    fn cached_media_with_gain(
        track: i64,
        path: &Path,
        duration_hint_ms: u64,
        gain_db: Option<f32>,
    ) -> MediaSource {
        MediaSource {
            track_id: TrackId(track),
            location: MediaLocation::CachedFile {
                path: path.to_string_lossy().into_owned(),
            },
            duration_hint_ms,
            gain_db,
        }
    }

    /// 找一个 20 ms 淡入的稳定段：跳过前 `fade_frames` 帧再取均值。
    fn steady_mean(samples: &[f32], fade_frames: usize) -> f32 {
        let tail = &samples[fade_frames.min(samples.len())..];
        if tail.is_empty() {
            return 0.0;
        }
        tail.iter().sum::<f32>() / tail.len() as f32
    }

    /// 最长连续零样本数（真正的断点检测）。
    fn longest_zero_run(samples: &[f32]) -> usize {
        let mut run = 0usize;
        let mut longest = 0usize;
        for sample in samples {
            if *sample == 0.0 {
                run += 1;
                longest = longest.max(run);
            } else {
                run = 0;
            }
        }
        longest
    }

    /// PLY-05 集成用例：独占会话必须走 i32 原生链路，样本位模式一字节不改；
    /// 同时 `queue_next` 在比特完美会话里必须是无操作（独占暂不无缝）。
    #[tokio::test]
    async fn exclusive_session_uses_native_i32_path_and_ignores_gapless_queue() {
        let dir = temp_dir("native");
        let frames = 3_200usize; // 400 ms @ 8 kHz
        let path = write_wav(&dir, "native.wav", 8_000, 1, frames, -8_000);
        let format = PcmFormat {
            sample_rate: 8_000,
            channels: 1,
        };
        let factory = Arc::new(NativeNullFactory::new(format));
        let media = cached_media(1, &path, 400);

        let mut session = Session::start_with_factory(
            &media,
            None,
            OutputMode::Exclusive,
            1.0,
            Handle::current(),
            factory.clone(),
        )
        .await
        .expect("start native session");

        assert!(session.native_bit_perfect(), "必须走原生比特完美链路");
        assert_eq!(session.output_mode(), OutputMode::Exclusive);
        assert_eq!(session.format(), format);
        assert_eq!(session.duration_ms(), Some(400));

        // 独占链路暂不拼接下一首：预装必须被忽略，不能假装成功。
        session.queue_next(cached_media(2, &path, 400));
        session.clear_next();

        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline && !session.finished() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert!(session.finished(), "独占会话应该在超时前播完");
        assert_eq!(session.splice_count(), 0, "独占会话不能发生无缝拼接");
        session.stop();

        let captured = factory.captured();
        let first = captured
            .iter()
            .position(|sample| *sample != 0)
            .expect("必须录到原生样本");
        let span = &captured[first..];
        assert!(span.len() >= frames, "录到的样本不足：{}", span.len());
        let expected = i32::from(-8_000i16) << 16;
        assert!(
            span[..frames].iter().all(|sample| *sample == expected),
            "16 bit 原生样本必须保持左对齐 i32 位模式"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 写一个任意位深（16 / 24）的整数 PCM WAV，返回路径和 data 块原始字节。
    fn write_pcm_wav(
        dir: &Path,
        name: &str,
        rate: u32,
        channels: u16,
        bits: u16,
        samples: &[i32],
    ) -> (std::path::PathBuf, Vec<u8>) {
        let bytes_per = usize::from(bits / 8);
        let mut data = Vec::with_capacity(samples.len() * bytes_per);
        for v in samples {
            data.extend_from_slice(&v.to_le_bytes()[..bytes_per]);
        }
        let block_align = channels * bits / 8;
        let mut buf = Vec::new();
        buf.extend_from_slice(b"RIFF");
        buf.extend_from_slice(&(36 + data.len() as u32).to_le_bytes());
        buf.extend_from_slice(b"WAVEfmt ");
        buf.extend_from_slice(&16u32.to_le_bytes());
        buf.extend_from_slice(&1u16.to_le_bytes());
        buf.extend_from_slice(&channels.to_le_bytes());
        buf.extend_from_slice(&rate.to_le_bytes());
        buf.extend_from_slice(&(rate * u32::from(block_align)).to_le_bytes());
        buf.extend_from_slice(&block_align.to_le_bytes());
        buf.extend_from_slice(&bits.to_le_bytes());
        buf.extend_from_slice(b"data");
        buf.extend_from_slice(&(data.len() as u32).to_le_bytes());
        buf.extend_from_slice(&data);
        std::fs::create_dir_all(dir).expect("create temp dir");
        let path = dir.join(name);
        std::fs::write(&path, &buf).expect("write wav");
        (path, data)
    }

    /// 可复现的"音乐"：伪随机满量程样本，夹着正负满幅、±1 和 0，左右声道不同。
    fn bit_exact_signal(frames: usize, channels: usize, bits: u32) -> Vec<i32> {
        let max = (1i64 << (bits - 1)) - 1;
        let min = -(1i64 << (bits - 1));
        let mut state = 0x2545_f491_4f6c_dd1du64;
        let mut out = Vec::with_capacity(frames * channels);
        for i in 0..frames * channels {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            let v = match i % 97 {
                0 if i > 0 => max,
                13 => min,
                29 => 1,
                41 => -1,
                53 if i > 0 => 0,
                _ => ((state >> 11) as i64 % (max - min + 1)) + min,
            };
            out.push(v as i32);
        }
        // 第一个样本必须非零：用它在录到的流里定位起点（前面可能有静音预填充）。
        if out[0] == 0 {
            out[0] = 1;
        }
        out
    }

    /// PLY-05 逐位验证：16 / 24 bit 立体声 WAV 经独占链路送到输出端，
    /// 每个样本的位模式都和源文件一致，按设备格式打包后的字节和文件 data 块逐字节相同。
    #[tokio::test]
    async fn exclusive_output_is_bit_identical_to_the_source() {
        for (bits, packing) in [
            (16u16, NativePacking::Int16),
            (24u16, NativePacking::Int24Packed),
        ] {
            let dir = temp_dir(&format!("bit-exact-{bits}"));
            let rate = 8_000u32;
            let channels = 2u16;
            let frames = 4_000usize; // 500 ms
            let source = bit_exact_signal(frames, usize::from(channels), u32::from(bits));
            let (path, data) = write_pcm_wav(&dir, "src.wav", rate, channels, bits, &source);
            let format = PcmFormat {
                sample_rate: rate,
                channels,
            };
            let factory = Arc::new(NativeNullFactory::with_native(format, bits as u8, packing));
            let mut session = Session::start_with_factory(
                &cached_media(1, &path, 500),
                None,
                OutputMode::Exclusive,
                1.0,
                Handle::current(),
                factory.clone(),
            )
            .await
            .expect("start native session");
            assert!(session.native_bit_perfect(), "{bits} bit 必须走原生链路");
            let deadline = Instant::now() + Duration::from_secs(10);
            while Instant::now() < deadline && !session.finished() {
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            assert!(session.finished(), "{bits} bit 会话应该播完");
            session.stop();

            let captured = factory.captured();
            let shift = 32 - u32::from(bits);
            let first = captured.iter().position(|s| *s != 0).expect("必须录到样本");
            let got = &captured[first..];
            assert!(
                got.len() >= source.len(),
                "{bits} bit 录到的样本不够：{}",
                got.len()
            );
            for (i, (g, s)) in got.iter().zip(&source).enumerate() {
                assert_eq!(*g, s << shift, "{bits} bit 第 {i} 个样本位模式不同");
            }
            let mut packed = vec![0u8; data.len()];
            let written = pack_into(&got[..source.len()], packing, &mut packed);
            assert_eq!(written, data.len());
            assert!(
                packed == data,
                "{bits} bit 打包后的字节必须和源文件 data 块一致"
            );
            let _ = std::fs::remove_dir_all(&dir);
        }
    }

    /// 共享模式开播必须淡入：第一帧接近静音，20 ms 后回到原幅度。
    #[tokio::test]
    async fn shared_session_fades_in_at_start() {
        let dir = temp_dir("fade-in");
        let frames = 3_200usize; // 400 ms @ 8 kHz
        let path = write_wav(&dir, "fade.wav", 8_000, 1, frames, 8_000);
        let format = PcmFormat {
            sample_rate: 8_000,
            channels: 1,
        };
        let factory = Arc::new(NullOutputFactory::new(format));
        let mut session = Session::start_with_factory(
            &cached_media(1, &path, 400),
            None,
            OutputMode::Shared,
            1.0,
            Handle::current(),
            factory.clone(),
        )
        .await
        .expect("start shared session");

        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline && !session.finished() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        session.stop();

        let captured = factory.captured();
        let span = nonzero_span(&captured);
        let fade = crate::dsp::fade_frames(8_000, crate::dsp::DEFAULT_FADE_MS);
        assert_eq!(fade, 160, "8 kHz 下 20 ms 应为 160 帧");
        let level = 8_000.0f32 / 32_768.0;
        let first = span[0];
        let step = 1.0 / fade as f32;
        assert!(
            (first - level * step).abs() < 1e-5,
            "首帧应约为 {:.6}，实际 {first:.6}",
            level * step
        );
        assert!(
            span[..fade].windows(2).all(|w| w[1] >= w[0]),
            "淡入不能回头"
        );
        assert!(
            (span[fade - 1] - level).abs() < 1e-5,
            "第 {fade} 帧应回到原幅度，实际 {:.6}",
            span[fade - 1]
        );
        let steady = steady_mean(span, fade);
        assert!(
            (steady - level).abs() < 1e-5,
            "稳定段必须是原始幅度，实际 {steady}"
        );
        eprintln!(
            "fade measurement: {} frames ramp ({:.3} ms) @ 8 kHz; first {:.6}, steady {:.6}, captured {} frames",
            fade,
            fade as f64 / 8.0,
            first,
            steady,
            span.len()
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// ReplayGain 必须在共享链路里生效，而且只乘一次（不是淡入淡出再乘一次）。
    #[tokio::test]
    async fn shared_session_applies_replaygain_exactly_once() {
        let dir = temp_dir("replaygain");
        let frames = 3_200usize;
        let path = write_wav(&dir, "rg.wav", 8_000, 1, frames, 8_000);
        let format = PcmFormat {
            sample_rate: 8_000,
            channels: 1,
        };
        let factory = Arc::new(NullOutputFactory::new(format));
        // -6.0206 dB ≈ 0.5 线性增益。
        let gain_db = -6.020_6f32;
        let mut session = Session::start_with_factory(
            &cached_media_with_gain(1, &path, 400, Some(gain_db)),
            None,
            OutputMode::Shared,
            1.0,
            Handle::current(),
            factory.clone(),
        )
        .await
        .expect("start shared session");

        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline && !session.finished() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        session.stop();

        let captured = factory.captured();
        let span = nonzero_span(&captured);
        let fade = crate::dsp::fade_frames(8_000, crate::dsp::DEFAULT_FADE_MS);
        let steady = steady_mean(span, fade);
        let level = 8_000.0f32 / 32_768.0;
        let expected = level * db_to_linear(gain_db);
        assert!(
            (steady - expected).abs() < 1e-4,
            "ReplayGain 应只乘一次：期望 {expected:.6}，实际 {steady:.6}（双倍增益会是 {:.6}）",
            level * db_to_linear(gain_db) * db_to_linear(gain_db)
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// PLY-04：共享链路里的 EQ 在格式转换之后生效，preamp 改变实际输出幅度。
    #[tokio::test]
    async fn shared_session_applies_equalizer_preamp() {
        let dir = temp_dir("eq-preamp");
        let frames = 3_200usize;
        let path = write_wav(&dir, "eq.wav", 8_000, 1, frames, 8_000);
        let format = PcmFormat {
            sample_rate: 8_000,
            channels: 1,
        };
        let factory = Arc::new(NullOutputFactory::new(format));
        let eq = Arc::new(EqControl::new(crate::eq::EqSettings::new(
            true,
            6.0,
            &[0.0; crate::eq::BAND_COUNT],
        )));
        let mut session = Session::start_with_factory_and_eq(
            &cached_media(1, &path, 400),
            None,
            OutputMode::Shared,
            1.0,
            Handle::current(),
            eq,
            factory.clone(),
        )
        .await
        .expect("start shared session with EQ");

        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline && !session.finished() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        session.stop();

        let captured = factory.captured();
        let span = nonzero_span(&captured);
        let fade = crate::dsp::fade_frames(8_000, crate::dsp::DEFAULT_FADE_MS);
        let steady = steady_mean(span, fade);
        let level = 8_000.0f32 / 32_768.0;
        let expected = level * db_to_linear(6.0);
        assert!(
            (steady - expected).abs() < 1e-4,
            "EQ preamp 应生效：期望 {expected:.6}，实际 {steady:.6}"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// PLY-04 / PLY-05：比特完美独占链路必须跳过 EQ，样本逐位不变。
    #[tokio::test]
    async fn native_session_ignores_equalizer() {
        let dir = temp_dir("native-eq");
        let frames = 3_200usize;
        let path = write_wav(&dir, "native-eq.wav", 8_000, 1, frames, -8_000);
        let format = PcmFormat {
            sample_rate: 8_000,
            channels: 1,
        };
        let factory = Arc::new(NativeNullFactory::new(format));
        let eq = Arc::new(EqControl::new(crate::eq::EqSettings::new(
            true,
            12.0,
            &[12.0; crate::eq::BAND_COUNT],
        )));
        let mut session = Session::start_with_factory_and_eq(
            &cached_media(1, &path, 400),
            None,
            OutputMode::Exclusive,
            1.0,
            Handle::current(),
            eq,
            factory.clone(),
        )
        .await
        .expect("start native session");
        assert!(session.native_bit_perfect());

        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline && !session.finished() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        session.stop();

        let captured = factory.captured();
        let first = captured
            .iter()
            .position(|sample| *sample != 0)
            .expect("必须录到原生样本");
        let expected = i32::from(-8_000i16) << 16;
        assert!(
            captured[first..first + frames]
                .iter()
                .all(|sample| *sample == expected),
            "比特完美链路不能被 EQ 改动"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 比特完美链路即使带 ReplayGain 也必须逐位原样输出（淡入淡出同样跳过）。
    #[tokio::test]
    async fn native_session_ignores_replaygain_and_fades() {
        let dir = temp_dir("native-rg");
        let frames = 3_200usize;
        let path = write_wav(&dir, "native-rg.wav", 8_000, 1, frames, -8_000);
        let format = PcmFormat {
            sample_rate: 8_000,
            channels: 1,
        };
        let factory = Arc::new(NativeNullFactory::new(format));
        let mut session = Session::start_with_factory(
            &cached_media_with_gain(1, &path, 400, Some(-6.020_6)),
            None,
            OutputMode::Exclusive,
            1.0,
            Handle::current(),
            factory.clone(),
        )
        .await
        .expect("start native session");
        assert!(session.native_bit_perfect());

        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline && !session.finished() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        session.stop();

        let captured = factory.captured();
        let first = captured
            .iter()
            .position(|sample| *sample != 0)
            .expect("必须录到原生样本");
        let span = &captured[first..];
        let expected = i32::from(-8_000i16) << 16;
        assert!(
            span[..frames].iter().all(|sample| *sample == expected),
            "比特完美链路不能套 ReplayGain / 淡入淡出"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// PLY-01 核心用例：两首同格式 WAV 顺序播放，样本必须一帧不差地接上。
    ///
    /// 第一首全是 +0.25，第二首全是 -0.25；如果中间有任何静音（哪怕一帧），
    /// 非零区间里就会出现 0，长度也会多出来。
    #[tokio::test]
    async fn gapless_splices_two_wav_tracks_without_a_zero_gap() {
        let dir = temp_dir("splice");
        let frames = 3_200usize; // 400 ms @ 8 kHz
        let path_a = write_wav(&dir, "a.wav", 8_000, 1, frames, 8_000);
        let path_b = write_wav(&dir, "b.wav", 8_000, 1, frames, -8_000);
        let format = PcmFormat {
            sample_rate: 8_000,
            channels: 1,
        };
        let factory = Arc::new(NullOutputFactory::new(format));

        let media_a = cached_media(1, &path_a, 400);
        let mut session = Session::start_with_factory(
            &media_a,
            None,
            OutputMode::Shared,
            1.0,
            Handle::current(),
            factory.clone(),
        )
        .await
        .expect("start first track");
        session.queue_next(cached_media(2, &path_b, 400));

        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline && !session.finished() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert!(session.finished(), "两首应该在超时前播完");
        assert_eq!(session.splice_count(), 1, "必须发生一次样本级拼接");
        session.stop();

        let captured = factory.captured();
        let span = nonzero_span(&captured);
        assert_eq!(
            span.len(),
            frames * 2,
            "输出总帧数必须等于两首之和（{}），实际 {}（含中间静音？）",
            frames * 2,
            span.len()
        );
        let gap_frames = longest_zero_run(span);
        // 设备格式 8 kHz：1 帧 = 0.125 ms。这个数字就是实测的拼接空隙。
        eprintln!(
            "PLY-01 measurement: {} frames total, splice at frame {}, gap {} frames ({:.3} ms)",
            span.len(),
            frames,
            gap_frames,
            gap_frames as f64 / 8.0
        );
        assert_eq!(gap_frames, 0, "拼接点不能有任何零样本");
        // 拼接点必须正好在第一首的最后一帧之后。
        assert!(
            span[..frames].iter().all(|s| *s > 0.0),
            "前 {} 帧必须全部来自第一首",
            frames
        );
        assert!(
            span[frames..].iter().all(|s| *s < 0.0),
            "第 {} 帧开始必须全部来自第二首",
            frames
        );
        // 拼接点两侧必须是原始幅度（淡入淡出不能侵入无缝边界）。
        let level = 8_000.0f32 / 32_768.0;
        assert!(
            (span[frames - 1] - level).abs() < 1e-6,
            "拼接前最后一帧被改动了：{}",
            span[frames - 1]
        );
        assert!(
            (span[frames] + level).abs() < 1e-6,
            "拼接后第一帧被改动了：{}",
            span[frames]
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 预装之后队列被改：`clear_next` 必须让这一首在 EOF 时结束，不能偷偷接上。
    #[tokio::test]
    async fn clear_next_cancels_a_pending_splice() {
        let dir = temp_dir("splice-clear");
        let frames = 3_200usize;
        let path_a = write_wav(&dir, "a.wav", 8_000, 1, frames, 8_000);
        let path_b = write_wav(&dir, "b.wav", 8_000, 1, frames, -8_000);
        let format = PcmFormat {
            sample_rate: 8_000,
            channels: 1,
        };
        let factory = Arc::new(NullOutputFactory::new(format));
        let media_a = cached_media(1, &path_a, 400);
        let mut session = Session::start_with_factory(
            &media_a,
            None,
            OutputMode::Shared,
            1.0,
            Handle::current(),
            factory.clone(),
        )
        .await
        .expect("start first track");
        session.queue_next(cached_media(2, &path_b, 400));
        session.clear_next();

        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline && !session.finished() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert!(session.finished());
        assert_eq!(session.splice_count(), 0, "取消后不能再拼接");
        session.stop();

        let captured = factory.captured();
        let span = nonzero_span(&captured);
        assert_eq!(span.len(), frames, "只应该播出第一首");
        assert!(span.iter().all(|s| *s > 0.0));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 不同采样率 / 声道数：解码线程重采样到设备格式，仍然接在同一条输出流里。
    ///
    /// 第二首 16 kHz 立体声，设备是 8 kHz 单声道：期望 1600 个设备帧，
    /// 总输出 3200 + 1600 = 4800 帧，误差只允许重采样器滤波的个位数样本。
    #[tokio::test]
    async fn gapless_resamples_a_different_format_track_into_the_same_stream() {
        let dir = temp_dir("splice-resample");
        let frames_a = 3_200usize;
        let frames_b = 3_200usize; // 16 kHz → 8 kHz 后是一半
        let path_a = write_wav(&dir, "a.wav", 8_000, 1, frames_a, 8_000);
        let path_b = write_wav(&dir, "b.wav", 16_000, 2, frames_b, -8_000);
        let format = PcmFormat {
            sample_rate: 8_000,
            channels: 1,
        };
        let factory = Arc::new(NullOutputFactory::new(format));

        let media_a = cached_media(1, &path_a, 400);
        let mut session = Session::start_with_factory(
            &media_a,
            None,
            OutputMode::Shared,
            1.0,
            Handle::current(),
            factory.clone(),
        )
        .await
        .expect("start first track");
        session.queue_next(cached_media(2, &path_b, 200));

        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline && !session.finished() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert!(session.finished());
        assert_eq!(session.splice_count(), 1);
        session.stop();

        let captured = factory.captured();
        let span = nonzero_span(&captured);
        let expected = frames_a + frames_b / 2;
        assert!(
            span.len().abs_diff(expected) <= 4,
            "重采样后总帧数 {}，期望 {expected}（±4）",
            span.len()
        );
        // 重采样器的初始滤波器可能有 1–2 个接近零的样本，不能要求绝对非零；
        // 但绝不允许出现可听级别的静音断点（> 4 个样本）。
        assert!(
            longest_zero_run(span) <= 4,
            "不同格式拼接后出现了 {} 帧静音",
            longest_zero_run(span)
        );
        // 第二首是负信号。FFT 重采样器在阶跃处会有短暂的滤波振铃（幅值很小），
        // 跳过起始的 256 帧后，绝大多数样本必须已经是第二首的负信号。
        let tail = &span[frames_a + 256..];
        let negative = tail.iter().filter(|s| **s < 0.0).count();
        assert!(
            negative * 100 >= tail.len() * 98,
            "第二首必须已经在播放：负样本 {negative}/{}",
            tail.len()
        );
        let mean = tail.iter().sum::<f32>() / tail.len() as f32;
        assert!(mean < -0.1, "第二首的均值应该接近 -0.244，实际 {mean}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
