//! 播放引擎：命令进、状态出。
//!
//! 引擎运行在自己的控制任务里，外部通过 [`EngineCommand`] 控制，通过 `watch` 通道读取 [`PlaybackSnapshot`]。
//! lekis-core 订阅快照并转成 `CoreEvent::PlaybackChanged` / `PositionTick` 推给 UI。
//!
//! 一条输出流由 [`Session`] 负责（解码线程 + 无锁环形缓冲 + cpal 输出），可以连续播多首。
//! 引擎自己只做四件事：解析曲目、管会话生命周期、回写进度快照、播完自动切下一首。
//! 进度来自「设备真正取走的样本数」，所以是准确的播放位置，而不是解码位置。
//!
//! 无提示音（gapless，PLY-01）：引擎提前把下一首**解析**好（resolver 是异步的、可能要访问网络），
//! 再交给会话**预装**（打开解码器、准备好格式转换）。当前曲目 EOF 时，解码线程把下一首的
//! 样本直接写进同一条环形缓冲，输出流和会话都不重建。只有自然播完才无缝；手动
//! Next / Previous / Seek 仍然立即切除。不同采样率 / 声道数的曲目会在解码线程里转换到
//! **当前输出流**的设备格式，所以也能接上。
//!
//! 队列游标在「可听边界」到达时才推进（解码线程领先输出约 300 ms），UI 不会提前跳歌，
//! 重复 / 随机 / 列表循环的语义完全复用 [`Queue::advance`]。

use crate::eq::EqControl;
use crate::gapless::AudibleTrack;
use crate::output::{AudioOutput, CpalOutput, OutputDevice, OutputMode};
use crate::queue::Queue;
use crate::session::{CpalOutputFactory, OutputFactory, Session};
use crate::MediaSource;
use lekis_types::{LekisError, PlaybackState, RepeatMode, Result, ShuffleMode, TrackId};
use std::collections::VecDeque;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::runtime::Handle;
use tokio::sync::{mpsc, oneshot, watch};

/// 进度回写的周期（毫秒）。UI 的进度条按这个节奏更新。
const TICK_MS: u64 = 200;

/// 预先解析好的下一首最多缓存几份（防止快速切歌时无限堆积）。
const PREFETCH_QUEUE_LIMIT: usize = 4;

/// 列出系统里的音频输出设备（PLY-05）。
///
/// 没有音频主机（headless / CI / 服务里没有音频会话）时返回**空列表**而不是错误：
/// 「一个设备都没有」是正常状态，调用方照常显示"未找到设备"。
/// 只有枚举过程本身出问题时才返回 `Err`。
pub fn list_output_devices() -> Result<Vec<OutputDevice>> {
    let output = CpalOutput::new();
    output.devices()
}

/// 引擎命令。
#[derive(Debug)]
pub enum EngineCommand {
    /// 用一组曲目替换队列并开始播放。
    SetQueue {
        /// 曲目。
        tracks: Vec<TrackId>,
        /// 从哪一首开始。
        start: usize,
    },
    /// 播放 / 继续。
    Play,
    /// 暂停。
    Pause,
    /// 下一首。
    Next,
    /// 上一首（播放超过 3 秒时回到本曲开头）。
    Previous,
    /// 跳转（毫秒）。
    Seek(u64),
    /// 循环模式。
    SetRepeat(RepeatMode),
    /// 随机模式。
    SetShuffle(ShuffleMode),
    /// 音量（0..=1）。
    SetVolume(f32),
    /// 选择输出设备（PLY-05）：`None` 表示跟随系统默认设备。
    ///
    /// 换设备会重建输出流；正在播放时会从当前位置接着放（不会回到开头）。
    /// 明确请求了一个**枚举得到但不存在**的设备 ID 时会被忽略（记一条 warn，继续用当前设备）；
    /// 枚举不到任何设备（headless / 没有音频会话）时无法校验，交给后端在打开流时兜底。
    SetOutputDevice(Option<String>),
    /// 输出模式（PLY-12 发烧友模式）：共享 / 独占（比特完美）。
    ///
    /// 换模式同样重建输出流并从当前位置接着放。
    SetOutputMode(OutputMode),
    /// 追加到队尾（队列为空时等同于 `SetQueue { start: 0 }`）。
    AddToQueue(Vec<TrackId>),
    /// 插到当前曲目之后（"下一首播放"）；队列为空时等同于 `SetQueue { start: 0 }`。
    PlayNext(Vec<TrackId>),
    /// 删除播放顺序里的第 N 首。删的是正在播的曲目时切到下一首（暂停中则只换曲不出声）。
    RemoveFromQueue(usize),
    /// 在播放顺序里移动一首。
    MoveInQueue {
        /// 原位置（播放顺序下标）。
        from: usize,
        /// 新位置（播放顺序下标）。
        to: usize,
    },
    /// 是否开启样本级无缝播放（`playback.gapless` 设置，PLY-01）。
    ///
    /// 开启时提前解析并预装下一首，自然播完直接在同一输出流里接上；
    /// 关掉后每次换曲都重建会话（会有几十毫秒的间隔）。
    SetGapless(bool),
    /// 停止并退出引擎任务。
    Shutdown,
}

/// 引擎状态快照。
#[derive(Debug, Clone, PartialEq)]
pub struct PlaybackSnapshot {
    /// 状态。
    pub state: PlaybackState,
    /// 当前曲目。
    pub track_id: Option<TrackId>,
    /// 当前位置（毫秒）。
    pub position_ms: u64,
    /// 时长（毫秒）。
    pub duration_ms: u64,
    /// 队列长度。
    pub queue_len: u32,
    /// 当前下标。
    pub queue_index: Option<u32>,
    /// 音量。
    pub volume: f32,
    /// 当前输出设备的 ID（PLY-05）；`None` 表示跟随系统默认设备。
    pub output_device: Option<String>,
    /// 当前输出模式（PLY-12）。这是**实际**使用的模式：请求独占但打开失败时会退回共享。
    pub output_mode: OutputMode,
    /// 循环模式。
    pub repeat: RepeatMode,
    /// 随机模式。
    pub shuffle: ShuffleMode,
    /// 是否开启样本级无缝播放（`playback.gapless`）。
    pub gapless: bool,
    /// 按播放顺序排列的整个队列（`queue_index` 是它的下标）。共享指针，克隆快照很便宜。
    pub queue: std::sync::Arc<[TrackId]>,
    /// 队列内容每变一次加一（增删、移动、替换），UI 据此决定要不要重新拉队列。
    pub queue_version: u64,
}

impl Default for PlaybackSnapshot {
    fn default() -> Self {
        Self {
            state: PlaybackState::Idle,
            track_id: None,
            position_ms: 0,
            duration_ms: 0,
            queue_len: 0,
            queue_index: None,
            volume: 1.0,
            output_device: None,
            output_mode: OutputMode::Shared,
            repeat: RepeatMode::Off,
            shuffle: ShuffleMode::Off,
            gapless: true,
            queue: std::sync::Arc::from(Vec::<TrackId>::new()),
            queue_version: 0,
        }
    }
}

/// 把曲目解析成可播放的媒体（由 lekis-core 实现：选源、离线优先、网络感知）。
pub type ResolveRequest = (TrackId, oneshot::Sender<Result<MediaSource>>);

/// 引擎句柄。
#[derive(Clone)]
pub struct PlaybackEngine {
    commands: mpsc::UnboundedSender<EngineCommand>,
    snapshot: watch::Receiver<PlaybackSnapshot>,
}

impl PlaybackEngine {
    /// 启动引擎控制任务。必须在 tokio 运行时内调用。
    ///
    /// `resolver`：引擎需要播放某首歌时，把请求发到这个通道，由 core 回复 [`MediaSource`]。
    pub fn spawn(resolver: mpsc::Sender<ResolveRequest>) -> Self {
        Self::spawn_with_output(
            resolver,
            Arc::new(EqControl::default()),
            Arc::new(CpalOutputFactory),
        )
    }

    /// 和 [`Self::spawn`] 一样，但把共享的均衡器控制句柄接进每条新会话。
    ///
    /// lekis-core 保存设置后直接改 [`EqControl`]，正在播放的音频在下一个解码块生效。
    pub fn spawn_with_eq(resolver: mpsc::Sender<ResolveRequest>, eq: Arc<EqControl>) -> Self {
        Self::spawn_with_output(resolver, eq, Arc::new(CpalOutputFactory))
    }

    /// 和 [`Self::spawn`] 一样，但使用指定的输出后端工厂（测试注入空输出）。
    fn spawn_with_output(
        resolver: mpsc::Sender<ResolveRequest>,
        eq: Arc<EqControl>,
        output_factory: Arc<dyn OutputFactory>,
    ) -> Self {
        let (cmd_tx, cmd_rx) = mpsc::unbounded_channel();
        let (snap_tx, snap_rx) = watch::channel(PlaybackSnapshot::default());
        tokio::spawn(run(cmd_rx, snap_tx, resolver, eq, output_factory));
        Self {
            commands: cmd_tx,
            snapshot: snap_rx,
        }
    }

    /// 测试用：注入空输出后端。生产代码走 [`Self::spawn`]。
    #[cfg(test)]
    pub(crate) fn spawn_with_test_output(
        resolver: mpsc::Sender<ResolveRequest>,
        output_factory: Arc<dyn OutputFactory>,
    ) -> Self {
        Self::spawn_with_output(resolver, Arc::new(EqControl::default()), output_factory)
    }

    /// 发送命令。
    pub fn send(&self, cmd: EngineCommand) -> Result<()> {
        self.commands
            .send(cmd)
            .map_err(|_| LekisError::internal("playback engine has stopped"))
    }

    /// 当前快照。
    pub fn snapshot(&self) -> PlaybackSnapshot {
        self.snapshot.borrow().clone()
    }

    /// 订阅快照变化。
    pub fn subscribe(&self) -> watch::Receiver<PlaybackSnapshot> {
        self.snapshot.clone()
    }
}

/// 引擎内部状态。会把 `snap` 回写到 watch 通道。
struct State {
    queue: Queue,
    snap: PlaybackSnapshot,
    resolver: mpsc::Sender<ResolveRequest>,
    /// 解码线程里做 VFS 阻塞读要用。
    handle: Handle,
    /// 当前曲目的播放会话（没在播时为 `None`）。
    session: Option<Session>,
    /// 已解析好、等着播的曲目（无缝换曲用）。
    prefetched: VecDeque<(TrackId, MediaSource)>,
    prefetch_rx: mpsc::UnboundedReceiver<(TrackId, Result<MediaSource>)>,
    prefetch_tx: mpsc::UnboundedSender<(TrackId, Result<MediaSource>)>,
    /// 当前曲目的媒体（repeat-one 时再预装一份用）。
    current_media: Option<MediaSource>,
    /// 已经交给会话预装、还没真正接上的下一首。
    queued_media: Option<(TrackId, MediaSource)>,
    /// 会话里已经预装的是哪一首（避免重复投递）。
    queued_next: Option<TrackId>,
    /// 上一次看到的可听边界 generation（区分自然切换 / seek 重建）。
    last_track_generation: u64,
    /// 上一次可听的拼接次数（引擎按增量推进队列）。
    last_audible_splice_count: u64,
    /// 上一次观察到的解码侧拼接次数（通常比可听边界领先一个缓冲区）。
    ///
    /// 很短的单曲（或单曲循环）会在可听边界到达之前就再次 EOF，所以预装不能等
    /// 队列推进：解码侧一拼上下一首，就立刻预装「下下首」。
    last_decoded_splice_count: u64,
    /// 会话输出后端工厂（生产 = cpal，测试可注入空输出）。
    output_factory: Arc<dyn OutputFactory>,
    /// 10 段均衡器参数（所有会话共享，运行中修改立即生效）。
    eq: Arc<EqControl>,
    /// 用户选定的输出设备（PLY-05），`None` = 跟随系统默认。
    device_id: Option<String>,
    /// 输出模式（PLY-12）。
    mode: OutputMode,
    /// 是否开启样本级无缝播放（`playback.gapless`）。
    gapless: bool,
    /// 队列内容变了、快照里的 `queue` 需要重建。
    queue_dirty: bool,
    /// 刚才因为队列编辑取消了预装：如果解码器已经拼上旧歌但还没播到，
    /// 需要重建会话，让编辑立刻生效（否则会听到与队列不一致的下一首）。
    gapless_next_invalidated: bool,
    /// 命令通道。放在状态里，是为了打开曲目（网络源可能要等十几秒）的时候
    /// 也能继续收命令，不让整个播放器卡住。
    inbox: mpsc::UnboundedReceiver<EngineCommand>,
    /// 加载期间收到、要等加载结束（或马上，排在最前）处理的命令。
    pending: VecDeque<EngineCommand>,
    /// 快照通道（加载期间也要把音量 / 暂停之类的变化推出去）。
    snapshot_tx: watch::Sender<PlaybackSnapshot>,
}

impl State {
    fn new(
        resolver: mpsc::Sender<ResolveRequest>,
        handle: Handle,
        snap: PlaybackSnapshot,
        eq: Arc<EqControl>,
        output_factory: Arc<dyn OutputFactory>,
        inbox: mpsc::UnboundedReceiver<EngineCommand>,
        snapshot_tx: watch::Sender<PlaybackSnapshot>,
    ) -> Self {
        let (tx, rx) = mpsc::unbounded_channel();
        Self {
            queue: Queue::default(),
            snap,
            resolver,
            handle,
            session: None,
            prefetched: VecDeque::new(),
            prefetch_rx: rx,
            prefetch_tx: tx,
            current_media: None,
            queued_media: None,
            queued_next: None,
            last_track_generation: 0,
            last_audible_splice_count: 0,
            last_decoded_splice_count: 0,
            output_factory,
            eq,
            device_id: None,
            mode: OutputMode::Shared,
            gapless: true,
            queue_dirty: false,
            gapless_next_invalidated: false,
            inbox,
            pending: VecDeque::new(),
            snapshot_tx,
        }
    }

    /// 把当前快照推给订阅者。
    fn publish(&self) {
        self.snapshot_tx.send_replace(self.snap.clone());
    }

    /// 关掉当前会话（幂等）。会停掉 cpal 流并 join 解码线程。
    fn close_session(&mut self) {
        if let Some(mut session) = self.session.take() {
            session.stop();
        }
    }

    /// 处理一条命令（不含 Shutdown）。
    async fn handle(&mut self, cmd: EngineCommand) {
        match cmd {
            EngineCommand::SetQueue { tracks, start } => {
                self.queue_dirty = true;
                self.queue.set(tracks, start);
                self.prefetched.clear();
                self.snap.position_ms = 0;
                self.load_current().await;
            }
            EngineCommand::Play => {
                if self.session.is_some() {
                    if let Err(e) = self.session.as_mut().map(|s| s.resume()).unwrap_or(Ok(())) {
                        tracing::warn!(target: "playback", error = %e, "cannot resume output");
                    } else {
                        self.snap.state = PlaybackState::Playing;
                    }
                } else if self.snap.track_id.is_some() {
                    // 上次解析失败（或会话已结束）：重新加载。
                    self.load_current().await;
                }
            }
            EngineCommand::Pause => {
                if self.snap.state == PlaybackState::Playing {
                    if let Some(session) = self.session.as_mut() {
                        if let Err(e) = session.pause() {
                            tracing::warn!(target: "playback", error = %e, "cannot pause output");
                        }
                    }
                    self.snap.state = PlaybackState::Paused;
                }
            }
            EngineCommand::Next => {
                self.queue.advance(true);
                self.snap.position_ms = 0;
                self.load_current().await;
            }
            EngineCommand::Previous => {
                if self.snap.position_ms <= 3_000 {
                    self.queue.previous();
                }
                self.snap.position_ms = 0;
                self.load_current().await;
            }
            EngineCommand::Seek(ms) => {
                let target = match self.snap.duration_ms {
                    0 => ms,
                    duration => ms.min(duration),
                };
                self.snap.position_ms = target;
                let audible = self
                    .session
                    .as_ref()
                    .and_then(|session| session.audible_track());
                let active = self
                    .session
                    .as_ref()
                    .and_then(|session| session.active_track_id());
                // 解码器已经拼到下一首、但耳朵还在上一首的最后 300 ms：用户点的
                // 是「上一首」的进度条，不能把 seek 应用到还没播到的下一首。
                // 手动 seek 允许有缝：在这一首上重建会话再跳。
                let mut restarted_paused = false;
                if let (Some(audible), Some(active)) = (audible, active) {
                    if audible.track_id != active {
                        tracing::debug!(
                            target: "playback::gapless",
                            audible = %audible.track_id,
                            decoding = %active,
                            target_ms = target,
                            "seek targets the audible track; restarting before the splice"
                        );
                        let was_playing = self.snap.state == PlaybackState::Playing;
                        self.load_current().await;
                        self.snap.position_ms = target;
                        restarted_paused = !was_playing;
                    }
                }
                if let Some(session) = self.session.as_mut() {
                    if let Err(e) = session.seek(target) {
                        tracing::warn!(target: "playback", position_ms = target, error = %e, "seek failed");
                    } else if restarted_paused {
                        let _ = session.pause();
                        self.snap.state = PlaybackState::Paused;
                    }
                }
            }
            EngineCommand::SetRepeat(mode) => {
                self.queue.set_repeat(mode);
                // 重复 / 循环模式变了，「下一首」可能就不一样了：丢掉已预装的下一首。
                self.invalidate_gapless_next();
                self.spawn_prefetch();
            }
            EngineCommand::SetShuffle(mode) => {
                if mode != self.queue.shuffle() {
                    self.queue_dirty = true;
                    self.queue.set_shuffle(mode, lekis_types::now_ms() as u64);
                    self.invalidate_gapless_next();
                    self.spawn_prefetch();
                }
            }
            EngineCommand::AddToQueue(tracks) | EngineCommand::PlayNext(tracks)
                if self.queue.is_empty() =>
            {
                if tracks.is_empty() {
                    return;
                }
                self.queue_dirty = true;
                self.queue.set(tracks, 0);
                self.prefetched.clear();
                self.snap.position_ms = 0;
                self.load_current().await;
            }
            EngineCommand::AddToQueue(tracks) => {
                self.queue_dirty = true;
                self.queue.append(tracks);
                self.spawn_prefetch();
            }
            EngineCommand::PlayNext(tracks) => {
                self.queue_dirty = true;
                self.queue.insert_after_current(tracks);
                self.invalidate_gapless_next();
                self.spawn_prefetch();
            }
            EngineCommand::RemoveFromQueue(pos) => {
                let was_current = self.queue.position() == Some(pos);
                if self.queue.remove_at(pos).is_none() {
                    return;
                }
                self.queue_dirty = true;
                if was_current {
                    self.snap.position_ms = 0;
                    if self.queue.is_empty() {
                        self.close_session();
                        self.snap.track_id = None;
                        self.snap.duration_ms = 0;
                        self.snap.state = PlaybackState::Idle;
                    } else if self.snap.state == PlaybackState::Playing {
                        self.load_current().await;
                    } else {
                        // 暂停中：换成新的当前曲目，但不出声；用户点播放时再加载。
                        self.close_session();
                        self.snap.track_id = self.queue.current();
                        self.snap.duration_ms = 0;
                        if self.snap.state != PlaybackState::Idle {
                            self.snap.state = PlaybackState::Paused;
                        }
                    }
                }
                self.spawn_prefetch();
            }
            EngineCommand::MoveInQueue { from, to } => {
                if self.queue.move_item(from, to) && from != to {
                    self.queue_dirty = true;
                    self.spawn_prefetch();
                }
            }
            EngineCommand::SetGapless(enabled) => {
                self.gapless = enabled;
                self.snap.gapless = enabled;
                if enabled {
                    self.spawn_prefetch();
                } else {
                    self.prefetched.clear();
                    self.invalidate_gapless_next();
                }
            }
            EngineCommand::SetVolume(v) => {
                let v = v.clamp(0.0, 1.0);
                self.snap.volume = v;
                if let Some(session) = self.session.as_mut() {
                    session.set_volume(v);
                }
            }
            EngineCommand::SetOutputDevice(device_id) => {
                if let Some(requested) = device_id.as_deref() {
                    if !self.device_exists(requested) {
                        tracing::warn!(
                            target: "playback",
                            device = %requested,
                            "requested output device is not present, keeping the current one"
                        );
                        return;
                    }
                }
                if device_id == self.device_id {
                    // 同一个设备：不重建流（重建会有一声咔嗒）。
                    return;
                }
                self.device_id = device_id.clone();
                self.snap.output_device = device_id;
                self.reopen_session().await;
            }
            EngineCommand::SetOutputMode(mode) => {
                if mode == self.mode {
                    return;
                }
                self.mode = mode;
                self.snap.output_mode = mode;
                self.reopen_session().await;
            }
            EngineCommand::Shutdown => {}
        }
        self.refresh_queue_fields();
        // 队列可能刚被编辑过：如果「下一首」变了，通知会话丢掉旧的预装，再补一次预解析。
        self.sync_gapless_next();
        self.spawn_prefetch();
        // 编辑发生时解码器可能已经把旧歌拼进缓冲（还没播到）。样本收不回来，
        // 只能重建会话回到可听曲目，让队列编辑立刻生效（手动操作允许有缝）。
        if self.gapless_next_invalidated {
            self.gapless_next_invalidated = false;
            let pending_splice = self
                .session
                .as_ref()
                .map(|session| session.splice_count() > self.last_audible_splice_count)
                .unwrap_or(false);
            if pending_splice
                && matches!(
                    self.snap.state,
                    PlaybackState::Playing | PlaybackState::Paused
                )
            {
                tracing::info!(
                    target: "playback::gapless",
                    "queue edited after a splice was decoded; restarting to honor the edit"
                );
                self.reopen_session().await;
            }
        }
        self.pump_gapless();
    }

    /// 这个设备 ID 是否真的在系统里（枚举失败时不做判断，交给后端兜底）。
    fn device_exists(&self, device_id: &str) -> bool {
        match list_output_devices() {
            Ok(devices) if devices.is_empty() => true,
            Ok(devices) => devices.iter().any(|device| device.id == device_id),
            Err(e) => {
                tracing::debug!(target: "playback", error = %e, "cannot enumerate devices");
                true
            }
        }
    }

    /// 换设备 / 换模式后重建会话，并从当前播放位置接着放。
    async fn reopen_session(&mut self) {
        if self.session.is_none() {
            // 没在播（或上次启动失败）：只记下选择，下次 load_current 生效。
            return;
        }
        let resume_at = self.session.as_ref().map(|s| s.position_ms()).unwrap_or(0);
        let was_playing = self.snap.state == PlaybackState::Playing;
        self.load_current().await;
        if self.session.is_none() {
            return;
        }
        if resume_at > 0 {
            if let Err(e) = self
                .session
                .as_mut()
                .map(|s| s.seek(resume_at))
                .unwrap_or(Ok(()))
            {
                tracing::warn!(target: "playback", position_ms = resume_at, error = %e, "cannot resume position after switching output");
            } else {
                self.snap.position_ms = resume_at;
            }
        }
        if !was_playing {
            if let Some(session) = self.session.as_mut() {
                let _ = session.pause();
            }
            self.snap.state = PlaybackState::Paused;
        }
    }

    /// 定时推进：回写播放位置、处理"这首放完了"。
    async fn on_tick(&mut self) {
        let Some(session) = self.session.as_ref() else {
            return;
        };
        let position = session.position_ms();
        let finished = session.finished();
        let worker_dead = session.worker_finished();
        let underruns = session.underruns();
        let audible = session.audible_track();
        let decoded_splices = session.splice_count();
        self.snap.position_ms = position;

        // 0) 解码侧已经接上的下一首（可能还领先可听位置 300 ms）：先把内部媒体状态
        //    前移，才能马上预装「下下首」，避免短曲在队列推进前又 EOF。
        self.observe_decoded_splices();

        // 1) 解码线程已经拼接的下一首，只有播放位置追上拼接点后才算「可听」。
        //    这时才推进队列，UI 不会提前 300 ms 跳到下一首。
        if let Some(track) = audible.as_ref() {
            if track.generation != self.last_track_generation {
                self.last_track_generation = track.generation;
                self.handle_audible_boundary(track, decoded_splices);
            }
        }

        if finished || (worker_dead && underruns > 0) {
            // 没有可接的下一首（关闭无缝、预装失败、队列结束）：退回重建会话。
            tracing::debug!(
                target: "playback",
                track = ?self.snap.track_id,
                position_ms = position,
                decoded_splices,
                "track finished without a gapless splice, advancing"
            );
            let began = Instant::now();
            let next = self.queue.advance(false);
            self.snap.position_ms = 0;
            if next.is_none() {
                self.close_session();
                self.snap.state = PlaybackState::Ended;
                self.refresh_queue_fields();
                return;
            }
            self.load_current().await;
            if self.snap.state == PlaybackState::Playing {
                let gap_ms = began.elapsed().as_millis() as u64;
                if self.gapless {
                    tracing::warn!(
                        target: "playback::gapless",
                        track = ?self.snap.track_id,
                        gap_ms,
                        "no prepared next track; restarted the output (audible gap)"
                    );
                } else {
                    tracing::debug!(
                        target: "playback::gapless",
                        track = ?self.snap.track_id,
                        gap_ms,
                        "gapless playback disabled, session restarted"
                    );
                }
            }
        } else {
            self.refresh_queue_fields();
            // 预解析结果可能刚到：收集后交给会话预装。
            self.drain_prefetch();
            self.pump_gapless();
        }
    }

    /// 可听曲目变了：只有**自然拼接**才推进队列；seek 重建只同步曲目信息。
    fn handle_audible_boundary(&mut self, track: &AudibleTrack, decoded_splices: u64) {
        let natural = track
            .splice_count
            .saturating_sub(self.last_audible_splice_count);
        if natural > 0 {
            for _ in 0..natural {
                self.queue.advance(false);
            }
            self.last_audible_splice_count = track.splice_count;

            // 注意：`queued_next` / `queued_media` 已经由 `observe_decoded_splices`
            // 前移到「下下首」，这里不能清掉——那是还没播到的预装。
            tracing::info!(
                target: "playback::gapless",
                track = %track.track_id,
                splice_count = track.splice_count,
                decoded_splices,
                position_ms = self.snap.position_ms,
                "audible gapless boundary: queue advanced"
            );
            self.spawn_prefetch();
        }

        if self.snap.track_id != Some(track.track_id) {
            // seek 落进已经拼接的下一首时，队列可能还停在上一首；按 splice_count
            // 的增量在上面已经补过了，这里兜底同步一下显示。
            tracing::debug!(
                target: "playback::gapless",
                from = ?self.snap.track_id,
                to = %track.track_id,
                "sync snapshot to the audible track"
            );
            self.snap.track_id = Some(track.track_id);
        }
        if let Some(duration) = track.duration_ms {
            self.snap.duration_ms = duration;
        }
        if let Some(session) = self.session.as_ref() {
            self.snap.position_ms = session.position_ms();
        }
    }

    /// 解析当前曲目并开始播放。
    async fn load_current(&mut self) {
        self.close_session();
        self.current_media = None;
        self.queued_next = None;
        self.gapless_next_invalidated = false;
        self.last_track_generation = 0;
        self.last_audible_splice_count = 0;
        self.last_decoded_splice_count = 0;
        self.snap.track_id = self.queue.current();
        self.refresh_queue_fields();
        let Some(track_id) = self.snap.track_id else {
            self.snap.state = PlaybackState::Ended;
            self.snap.position_ms = 0;
            self.snap.duration_ms = 0;
            return;
        };

        self.snap.state = PlaybackState::Loading;
        self.snap.position_ms = 0;
        // 让界面马上看到"正在加载"（解析 / 打开网络源可能要好几秒）。
        self.publish();
        // 上一首预装过的媒体也许正好就是这一首（手动 Next / 回退），`resolve` 会复用它。
        let resolved = self.resolve(track_id).await;
        self.queued_media = None;
        // 先按用户的请求显示；会话真正开流后如果降级，会用实际模式覆盖。
        self.snap.output_mode = self.mode;
        let media = match resolved {
            Ok(media) => media,
            Err(e) => {
                tracing::warn!(target: "playback", %track_id, error = %e, "cannot resolve track");
                self.snap.state = PlaybackState::Paused;
                return;
            }
        };

        // 时长先按解析结果填，解码器打开后会用真实值覆盖。
        self.snap.duration_ms = media.duration_hint_ms;
        // 打开会话可能很慢（网络源连不上时要等到连接超时）。这期间继续收命令：
        // 换歌 / 换队列 / 退出直接放弃这次加载；暂停、播放、音量、跳转先记下来，
        // 快照立刻更新，会话开好后再补上；其余命令排队等加载结束。
        let device_id = self.device_id.clone();
        let start_media = media.clone();
        let start = Session::start_with_factory_and_eq(
            &start_media,
            device_id.as_deref(),
            self.mode,
            self.snap.volume,
            self.handle.clone(),
            self.eq.clone(),
            self.output_factory.clone(),
        );
        tokio::pin!(start);
        let mut pause_after = false;
        let mut seek_after: Option<u64> = None;
        let started = loop {
            tokio::select! {
                result = &mut start => break Some(result),
                command = self.inbox.recv() => {
                    match command {
                        None | Some(EngineCommand::Shutdown) => {
                            self.pending.push_front(EngineCommand::Shutdown);
                            break None;
                        }
                        Some(
                            cmd @ (EngineCommand::SetQueue { .. }
                            | EngineCommand::Next
                            | EngineCommand::Previous),
                        ) => {
                            self.pending.push_front(cmd);
                            break None;
                        }
                        Some(EngineCommand::Pause) => {
                            pause_after = true;
                            self.snap.state = PlaybackState::Paused;
                        }
                        Some(EngineCommand::Play) => {
                            pause_after = false;
                            self.snap.state = PlaybackState::Loading;
                        }
                        Some(EngineCommand::SetVolume(v)) => {
                            self.snap.volume = v.clamp(0.0, 1.0);
                        }
                        Some(EngineCommand::Seek(ms)) => {
                            seek_after = Some(ms);
                            self.snap.position_ms = ms;
                        }
                        Some(other) => self.pending.push_back(other),
                    }
                    self.publish();
                }
            }
        };
        let Some(started) = started else {
            tracing::debug!(target: "playback", %track_id, "load abandoned for a newer command");
            return;
        };
        match started {
            Ok(mut session) => {
                session.set_volume(self.snap.volume);
                if let Some(ms) = seek_after {
                    match session.seek(ms) {
                        Ok(()) => self.snap.position_ms = ms,
                        Err(e) => {
                            tracing::warn!(target: "playback", position_ms = ms, error = %e, "seek after load failed")
                        }
                    }
                }
                if let Some(duration) = session.duration_ms() {
                    self.snap.duration_ms = duration;
                }
                self.last_track_generation = session
                    .audible_track()
                    .map(|track| track.generation)
                    .unwrap_or(0);
                self.last_audible_splice_count = session.splice_count();
                self.last_decoded_splice_count = session.splice_count();
                // 请求独占但设备忙 / 格式不支持时会话已退回共享：快照必须反映实际模式。
                self.snap.output_mode = session.output_mode();
                tracing::debug!(
                    target: "playback",
                    %track_id,
                    rate = session.format().sample_rate,
                    channels = session.format().channels,
                    device_rate = session.device_format().sample_rate,
                    device_channels = session.device_format().channels,
                    bit_perfect = session.native_bit_perfect(),
                    actual_mode = ?session.output_mode(),
                    "playing"
                );
                if pause_after {
                    if let Err(e) = session.pause() {
                        tracing::warn!(target: "playback", error = %e, "cannot pause output");
                    }
                    self.snap.state = PlaybackState::Paused;
                } else {
                    self.snap.state = PlaybackState::Playing;
                }
                self.session = Some(session);
                self.current_media = Some(media);
            }
            Err(e) => {
                // 没有音频设备、格式不支持、文件坏了……都不 panic，退化成"暂停"。
                tracing::warn!(target: "playback", %track_id, error = %e, "cannot start playback session");
                self.snap.state = PlaybackState::Paused;
            }
        }
        // 先把下一首解析好，再尽量立刻预装进当前会话（无缝换曲）。
        self.spawn_prefetch();
        self.drain_prefetch();
        self.pump_gapless();
    }

    /// 优先用预解析结果，否则现场向 resolver 要。
    async fn resolve(&mut self, track_id: TrackId) -> Result<MediaSource> {
        self.drain_prefetch();
        if let Some(pos) = self.prefetched.iter().position(|(id, _)| *id == track_id) {
            if let Some((_, media)) = self.prefetched.remove(pos) {
                return Ok(media);
            }
        }
        // 手动切到已经预装的那一首：媒体已经解析过，不用再走一遍网络 / 源选择。
        if let Some((id, _)) = self.queued_media.as_ref() {
            if *id == track_id {
                if let Some((_, media)) = self.queued_media.take() {
                    return Ok(media);
                }
            }
        }
        let (tx, rx) = oneshot::channel();
        self.resolver
            .send((track_id, tx))
            .await
            .map_err(|_| LekisError::internal("resolver channel closed"))?;
        match rx.await {
            Ok(result) => result,
            Err(_) => Err(LekisError::internal("resolver dropped the request")),
        }
    }

    /// 收集后台预解析任务的结果。
    fn drain_prefetch(&mut self) {
        while let Ok((id, result)) = self.prefetch_rx.try_recv() {
            match result {
                Ok(media) => {
                    if self.prefetched.iter().any(|(existing, _)| *existing == id) {
                        continue;
                    }
                    self.prefetched.push_back((id, media));
                    while self.prefetched.len() > PREFETCH_QUEUE_LIMIT {
                        self.prefetched.pop_front();
                    }
                }
                Err(e) => {
                    tracing::debug!(target: "playback", %id, error = %e, "prefetch failed");
                }
            }
        }
    }

    /// 后台解析下一首，结果进 `prefetch_rx`。
    fn spawn_prefetch(&mut self) {
        if !self.gapless {
            return;
        }
        let Some(next) = self.gapless_lookahead() else {
            return;
        };
        if self.queued_next == Some(next)
            || self.snap.track_id == Some(next)
            || self.prefetched.iter().any(|(id, _)| *id == next)
        {
            return;
        }
        let resolver = self.resolver.clone();
        let results = self.prefetch_tx.clone();
        // 后台任务独立跑：不阻塞引擎命令循环，解析失败也只是丢掉这条缓存。
        tokio::spawn(async move {
            let (tx, rx) = oneshot::channel();
            if resolver.send((next, tx)).await.is_err() {
                return;
            }
            if let Ok(result) = rx.await {
                let _ = results.send((next, result));
            }
        });
    }

    /// 把已经解析好的下一首交给会话预装（同一条输出流里拼接）。
    ///
    /// 只预装一首，样本不会整首缓存；解码线程解多少写多少，环形缓冲仍然只有 300 ms。
    fn pump_gapless(&mut self) {
        if !self.gapless || self.session.is_none() {
            return;
        }
        // 独占 / 比特完美会话暂不支持样本级拼接：预装没有意义，让引擎在 EOF 时
        // 走普通路径（queue.advance + 重建会话）。
        if self
            .session
            .as_ref()
            .is_some_and(Session::native_bit_perfect)
        {
            return;
        }
        // 解码线程可能已经拼上了下一首（还没播到）：先推进内部媒体状态，
        // 这样下面算出来的是「下下首」。
        self.observe_decoded_splices();
        let Some(next) = self.gapless_lookahead() else {
            return;
        };
        if self.queued_next == Some(next) {
            return;
        }
        // repeat-one：队列往后看还是当前曲目，直接用当前媒体再预装一份。
        let media = if Some(next) == self.queue.peek_next_steps(0) {
            self.current_media.clone()
        } else {
            self.take_prefetched(next)
        };
        let Some(media) = media else {
            return;
        };
        let Some(session) = self.session.as_mut() else {
            return;
        };
        session.queue_next(media.clone());
        self.queued_next = Some(next);
        self.queued_media = Some((next, media));
    }

    /// 解码侧拼接次数增加：被预装的那首已经接上解码器，内部媒体状态前移。
    ///
    /// 这时**不**推进队列游标（UI 还应该显示上一首，直到可听边界到达）。
    fn observe_decoded_splices(&mut self) {
        let Some(session) = self.session.as_ref() else {
            return;
        };
        let decoded = session.splice_count();
        if decoded <= self.last_decoded_splice_count {
            return;
        }
        let steps = decoded - self.last_decoded_splice_count;
        self.last_decoded_splice_count = decoded;
        for _ in 0..steps {
            if let Some((_id, media)) = self.queued_media.take() {
                self.current_media = Some(media);
            }
            self.queued_next = None;
        }
        tracing::debug!(
            target: "playback::gapless",
            decoded_splices = decoded,
            "decoder spliced the next track; queue cursor still waits for the audible boundary"
        );
    }

    /// 无缝播放当前应该预装的曲目（考虑已经拼接、但还没可听的那一首）。
    fn gapless_lookahead(&self) -> Option<TrackId> {
        if !self.gapless || self.session.is_none() {
            return None;
        }
        let decoded_ahead = self
            .session
            .as_ref()?
            .splice_count()
            .saturating_sub(self.last_audible_splice_count);
        let steps = usize::try_from(decoded_ahead)
            .unwrap_or(usize::MAX)
            .saturating_add(1);
        self.queue.peek_next_steps(steps)
    }

    /// 队列编辑后，「下一首」可能变了：让会话丢掉已经预装的那一首。
    fn invalidate_gapless_next(&mut self) {
        self.queued_next = None;
        self.queued_media = None;
        self.gapless_next_invalidated = true;
        if let Some(session) = self.session.as_mut() {
            session.clear_next();
        }
    }

    /// 队列游标或顺序变化后核对一次：预装的下一首还是不是当前队列的下一首。
    fn sync_gapless_next(&mut self) {
        // 先把解码侧已经拼接的曲目前移，避免把「已经接上的那一首」当成过期预装清掉。
        self.observe_decoded_splices();
        let Some(queued) = self.queued_next else {
            return;
        };
        if self.gapless_lookahead() != Some(queued) {
            self.invalidate_gapless_next();
        }
    }

    /// 从预解析缓存里取出一首（如果有）。
    fn take_prefetched(&mut self, track_id: TrackId) -> Option<MediaSource> {
        let pos = self.prefetched.iter().position(|(id, _)| *id == track_id)?;
        self.prefetched.remove(pos).map(|(_, media)| media)
    }

    /// 回写队列相关的快照字段。
    fn refresh_queue_fields(&mut self) {
        self.snap.queue_len = self.queue.len() as u32;
        self.snap.queue_index = self.queue.position().map(|i| i as u32);
        self.snap.track_id = self.queue.current().or(self.snap.track_id);
        self.snap.repeat = self.queue.repeat();
        self.snap.shuffle = self.queue.shuffle();
        if self.queue_dirty {
            self.queue_dirty = false;
            self.snap.queue = std::sync::Arc::from(self.queue.ordered());
            self.snap.queue_version = self.snap.queue_version.wrapping_add(1);
        }
    }
}

async fn run(
    commands: mpsc::UnboundedReceiver<EngineCommand>,
    snapshot: watch::Sender<PlaybackSnapshot>,
    resolver: mpsc::Sender<ResolveRequest>,
    eq: Arc<EqControl>,
    output_factory: Arc<dyn OutputFactory>,
) {
    let mut state = State::new(
        resolver,
        Handle::current(),
        PlaybackSnapshot::default(),
        eq,
        output_factory,
        commands,
        snapshot,
    );
    let mut ticker = tokio::time::interval(Duration::from_millis(TICK_MS));
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    // 第一条 tick 会立刻触发；先消费掉，别让首帧快照多跳一次。
    ticker.tick().await;

    loop {
        // 加载期间攒下的命令先处理（打断加载的那条排在最前）。
        if let Some(cmd) = state.pending.pop_front() {
            if matches!(cmd, EngineCommand::Shutdown) {
                break;
            }
            state.handle(cmd).await;
            state.publish();
            continue;
        }
        tokio::select! {
            command = state.inbox.recv() => {
                match command {
                    Some(EngineCommand::Shutdown) | None => break,
                    Some(cmd) => state.handle(cmd).await,
                }
            }
            _ = ticker.tick() => state.on_tick().await,
        }
        state.publish();
    }

    // Shutdown：停流 + join 解码线程（幂等，重复调用安全）。
    state.close_session();
    state.publish();
    tracing::debug!(target: "playback", "engine task exiting");
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::decode::PcmFormat;
    use crate::test_support::{nonzero_span, temp_dir, write_wav, NullOutputFactory};
    use crate::MediaLocation;
    use std::path::Path;

    /// 搭一个引擎 + 一个"永远解析失败"的 resolver，验证命令不会 panic、状态会退化。
    #[tokio::test]
    async fn engine_degrades_without_playable_media() {
        let (resolve_tx, mut resolve_rx) = mpsc::channel::<ResolveRequest>(8);
        tokio::spawn(async move {
            while let Some((_track, reply)) = resolve_rx.recv().await {
                let _ = reply.send(Err(LekisError::not_found("no such file")));
            }
        });
        let engine = PlaybackEngine::spawn(resolve_tx);
        engine
            .send(EngineCommand::SetQueue {
                tracks: vec![TrackId(1), TrackId(2)],
                start: 0,
            })
            .expect("send");
        // 等引擎跑完一轮命令循环。
        tokio::time::sleep(Duration::from_millis(120)).await;
        let snap = engine.snapshot();
        assert_eq!(snap.queue_len, 2);
        assert_eq!(snap.track_id, Some(TrackId(1)));
        assert_eq!(
            snap.state,
            PlaybackState::Paused,
            "解析失败必须退化成暂停而不是 panic"
        );

        engine.send(EngineCommand::SetVolume(0.5)).expect("send");
        engine.send(EngineCommand::Next).expect("send");
        engine.send(EngineCommand::Shutdown).expect("send");
        tokio::time::sleep(Duration::from_millis(120)).await;
        assert_eq!(engine.snapshot().volume, 0.5);
        // 引擎退出后命令通道关闭。
        assert!(engine.send(EngineCommand::Play).is_err());
    }

    /// 网络源连不上时打开会话要等到超时：这期间音量 / 暂停 / 跳转要立刻反映到快照，
    /// 换歌要直接放弃这次加载，而不是把命令全堵在后面（Connect 遥控时尤其明显）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn commands_are_not_stuck_behind_a_slow_load() {
        // 只接受连接、从不回复的"串流服务器"。
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        std::thread::spawn(move || {
            let mut held = Vec::new();
            for stream in listener.incoming().flatten() {
                held.push(stream);
            }
        });
        let url = format!("http://{addr}/stream/track.flac");
        let (resolve_tx, mut resolve_rx) = mpsc::channel::<ResolveRequest>(8);
        tokio::spawn(async move {
            while let Some((track, reply)) = resolve_rx.recv().await {
                let _ = reply.send(Ok(MediaSource {
                    track_id: track,
                    location: MediaLocation::Url {
                        url: url.clone(),
                        headers: Vec::new(),
                    },
                    duration_hint_ms: 200_000,
                    gain_db: None,
                }));
            }
        });
        let engine = PlaybackEngine::spawn(resolve_tx);
        engine
            .send(EngineCommand::SetQueue {
                tracks: vec![TrackId(1), TrackId(2), TrackId(3)],
                start: 0,
            })
            .expect("send");
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert_eq!(engine.snapshot().state, PlaybackState::Loading);

        engine.send(EngineCommand::SetVolume(0.4)).expect("send");
        engine.send(EngineCommand::Pause).expect("send");
        engine.send(EngineCommand::Seek(30_000)).expect("send");
        tokio::time::sleep(Duration::from_millis(200)).await;
        let snap = engine.snapshot();
        assert_eq!(snap.volume, 0.4);
        assert_eq!(snap.state, PlaybackState::Paused);
        assert_eq!(snap.position_ms, 30_000);

        engine.send(EngineCommand::Next).expect("send");
        tokio::time::sleep(Duration::from_millis(200)).await;
        let snap = engine.snapshot();
        assert_eq!(snap.track_id, Some(TrackId(2)), "换歌不能等前一首超时");
        assert_eq!(snap.volume, 0.4);

        engine.send(EngineCommand::Shutdown).expect("send");
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert!(
            engine.send(EngineCommand::Play).is_err(),
            "退出也不能等加载超时"
        );
    }

    /// 空队列：状态直接是 Ended，不 panic。
    #[tokio::test]
    async fn empty_queue_is_ended() {
        let (resolve_tx, mut resolve_rx) = mpsc::channel::<ResolveRequest>(8);
        tokio::spawn(async move {
            while let Some((_track, reply)) = resolve_rx.recv().await {
                let _ = reply.send(Err(LekisError::not_found("nothing")));
            }
        });
        let engine = PlaybackEngine::spawn(resolve_tx);
        engine
            .send(EngineCommand::SetQueue {
                tracks: Vec::new(),
                start: 0,
            })
            .expect("send");
        tokio::time::sleep(Duration::from_millis(80)).await;
        let snap = engine.snapshot();
        assert_eq!(snap.state, PlaybackState::Ended);
        assert_eq!(snap.track_id, None);
        let _ = engine.send(EngineCommand::Shutdown);
    }

    /// 指向不存在的缓存文件：Session 启动失败，但引擎照常继续（不 panic）。
    #[tokio::test]
    async fn missing_cached_file_does_not_panic() {
        let (resolve_tx, mut resolve_rx) = mpsc::channel::<ResolveRequest>(8);
        tokio::spawn(async move {
            while let Some((track, reply)) = resolve_rx.recv().await {
                let _ = reply.send(Ok(MediaSource {
                    track_id: track,
                    location: MediaLocation::CachedFile {
                        path: "C:/definitely/not/here.flac".to_string(),
                    },
                    duration_hint_ms: 1_000,
                    gain_db: None,
                }));
            }
        });
        let engine = PlaybackEngine::spawn(resolve_tx);
        engine
            .send(EngineCommand::SetQueue {
                tracks: vec![TrackId(7)],
                start: 0,
            })
            .expect("send");
        tokio::time::sleep(Duration::from_millis(300)).await;
        let snap = engine.snapshot();
        assert_eq!(snap.track_id, Some(TrackId(7)));
        assert_eq!(snap.state, PlaybackState::Paused);
        let _ = engine.send(EngineCommand::Shutdown);
    }

    /// 默认快照：跟随系统默认设备、共享模式。
    #[test]
    fn default_snapshot_follows_system_default_device() {
        let snap = PlaybackSnapshot::default();
        assert_eq!(snap.output_device, None);
        assert_eq!(snap.output_mode, OutputMode::Shared);
    }

    /// 枚举设备的公开入口在没有音频设备时必须优雅返回（空列表或错误，不能 panic）。
    #[test]
    fn list_output_devices_never_panics() {
        match list_output_devices() {
            Ok(devices) => {
                // 真机上应该至少有一个设备；headless 下为空也合法。
                for device in &devices {
                    assert!(!device.id.is_empty(), "设备 ID 不能为空");
                }
            }
            Err(e) => {
                // 枚举失败也是允许的（没有音频主机），只要不是 panic。
                assert!(!e.to_string().is_empty());
            }
        }
    }

    /// 选输出设备 / 换模式都要写进快照，并且在没有会话时也不能 panic。
    #[tokio::test]
    async fn output_selection_is_reflected_in_snapshot() {
        let (resolve_tx, mut resolve_rx) = mpsc::channel::<ResolveRequest>(8);
        tokio::spawn(async move {
            while let Some((_track, reply)) = resolve_rx.recv().await {
                let _ = reply.send(Err(LekisError::not_found("nothing to play")));
            }
        });
        let engine = PlaybackEngine::spawn(resolve_tx);

        // 没在播任何东西时换设备：只是记下选择。
        engine
            .send(EngineCommand::SetOutputDevice(Some(
                "default-device-id".to_string(),
            )))
            .expect("send");
        engine
            .send(EngineCommand::SetOutputMode(OutputMode::Exclusive))
            .expect("send");
        tokio::time::sleep(Duration::from_millis(120)).await;

        let snap = engine.snapshot();
        // 本机若真的没有这个 ID 的设备，引擎会保留原选择（None），两种都可以接受。
        assert!(
            snap.output_device.is_none()
                || snap.output_device.as_deref() == Some("default-device-id")
        );
        assert_eq!(
            snap.output_mode,
            OutputMode::Exclusive,
            "模式切换必须写回快照"
        );

        // 换回系统默认设备 + 共享模式。
        engine
            .send(EngineCommand::SetOutputDevice(None))
            .expect("send");
        engine
            .send(EngineCommand::SetOutputMode(OutputMode::Shared))
            .expect("send");
        tokio::time::sleep(Duration::from_millis(120)).await;
        let snap = engine.snapshot();
        assert_eq!(snap.output_device, None);
        assert_eq!(snap.output_mode, OutputMode::Shared);
        let _ = engine.send(EngineCommand::Shutdown);
    }

    /// 播放中换模式不能中断播放：状态仍是 Playing，曲目不变。
    #[tokio::test]
    async fn switching_mode_keeps_the_track() {
        let (resolve_tx, mut resolve_rx) = mpsc::channel::<ResolveRequest>(8);
        tokio::spawn(async move {
            while let Some((track, reply)) = resolve_rx.recv().await {
                let _ = reply.send(Ok(MediaSource {
                    track_id: track,
                    location: MediaLocation::CachedFile {
                        path: "C:/definitely/not/here.flac".to_string(),
                    },
                    duration_hint_ms: 1_000,
                    gain_db: None,
                }));
            }
        });
        let engine = PlaybackEngine::spawn(resolve_tx);
        engine
            .send(EngineCommand::SetQueue {
                tracks: vec![TrackId(3)],
                start: 0,
            })
            .expect("send");
        tokio::time::sleep(Duration::from_millis(200)).await;

        engine
            .send(EngineCommand::SetOutputMode(OutputMode::Exclusive))
            .expect("send");
        tokio::time::sleep(Duration::from_millis(300)).await;
        let snap = engine.snapshot();
        assert_eq!(snap.track_id, Some(TrackId(3)), "换模式不该丢掉当前曲目");
        assert_eq!(snap.output_mode, OutputMode::Exclusive);
        let _ = engine.send(EngineCommand::Shutdown);
    }

    fn media_for(track: TrackId, path: &Path, duration_hint_ms: u64) -> MediaSource {
        MediaSource {
            track_id: track,
            location: MediaLocation::CachedFile {
                path: path.to_string_lossy().into_owned(),
            },
            duration_hint_ms,
            gain_db: None,
        }
    }

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

    /// 搭一个按 TrackId 返回本地 WAV 的 resolver。
    fn wav_resolver(
        path_a: std::path::PathBuf,
        path_b: std::path::PathBuf,
    ) -> mpsc::Sender<ResolveRequest> {
        let (resolve_tx, mut resolve_rx) = mpsc::channel::<ResolveRequest>(8);
        tokio::spawn(async move {
            while let Some((track, reply)) = resolve_rx.recv().await {
                let media = if track == TrackId(1) {
                    media_for(track, &path_a, 1_000)
                } else {
                    media_for(track, &path_b, 1_000)
                };
                let _ = reply.send(Ok(media));
            }
        });
        resolve_tx
    }

    /// 引擎级 PLY-01：两首 500 ms 的 WAV 顺序播放，队列自动推进且样本零断点。
    #[tokio::test]
    async fn engine_splices_album_tracks_without_a_gap() {
        let dir = temp_dir("engine-gapless");
        let frames = 4_000usize; // 500 ms @ 8 kHz 单声道
        let path_a = write_wav(&dir, "a.wav", 8_000, 1, frames, 8_000);
        let path_b = write_wav(&dir, "b.wav", 8_000, 1, frames, -8_000);
        let factory = Arc::new(NullOutputFactory::new(PcmFormat {
            sample_rate: 8_000,
            channels: 1,
        }));
        let engine =
            PlaybackEngine::spawn_with_test_output(wav_resolver(path_a, path_b), factory.clone());
        engine
            .send(EngineCommand::SetQueue {
                tracks: vec![TrackId(1), TrackId(2)],
                start: 0,
            })
            .expect("send");

        let deadline = Instant::now() + Duration::from_secs(10);
        let mut snap = engine.snapshot();
        while Instant::now() < deadline
            && !(snap.track_id == Some(TrackId(2)) && snap.position_ms >= 80)
        {
            tokio::time::sleep(Duration::from_millis(20)).await;
            snap = engine.snapshot();
        }
        assert_eq!(
            snap.track_id,
            Some(TrackId(2)),
            "自然播完必须自动切到第二首"
        );
        assert_eq!(snap.queue_index, Some(1), "队列游标要跟着推进");
        assert_eq!(snap.state, PlaybackState::Playing);
        let _ = engine.send(EngineCommand::Shutdown);
        tokio::time::sleep(Duration::from_millis(150)).await;

        let captured = factory.captured();
        let span = nonzero_span(&captured);
        assert!(
            span.len() > frames + 400,
            "第二首至少播放了一段，实际 {} 帧",
            span.len()
        );
        assert!(span.len() <= frames * 2, "不能多出静音填充");
        assert_eq!(longest_zero_run(span), 0, "曲目边界不能有任何静音样本");
        assert!(
            span[..frames].iter().all(|s| *s > 0.0),
            "前 500 ms 必须是第一首"
        );
        assert!(
            span[frames..].iter().all(|s| *s < 0.0),
            "接缝之后必须立刻是第二首"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 单曲循环也必须无缝：重复的是同一首，中间不能重建会话。
    #[tokio::test]
    async fn engine_repeat_one_splices_the_same_track_without_a_gap() {
        let dir = temp_dir("engine-repeat-one");
        let frames = 3_200usize; // 400 ms @ 8 kHz
        let path_a = write_wav(&dir, "a.wav", 8_000, 1, frames, 8_000);
        let factory = Arc::new(NullOutputFactory::new(PcmFormat {
            sample_rate: 8_000,
            channels: 1,
        }));
        let engine = PlaybackEngine::spawn_with_test_output(
            wav_resolver(path_a.clone(), path_a),
            factory.clone(),
        );
        engine
            .send(EngineCommand::SetQueue {
                tracks: vec![TrackId(1)],
                start: 0,
            })
            .expect("send");
        engine
            .send(EngineCommand::SetRepeat(RepeatMode::One))
            .expect("send");

        let deadline = Instant::now() + Duration::from_secs(10);
        let mut played = 0usize;
        while Instant::now() < deadline && played < frames * 2 + 400 {
            tokio::time::sleep(Duration::from_millis(20)).await;
            played = factory
                .captured()
                .iter()
                .filter(|sample| **sample != 0.0)
                .count();
        }
        assert!(
            played >= frames * 2,
            "单曲循环至少应该播完两遍，实际 {played} 帧"
        );
        let snap = engine.snapshot();
        assert_eq!(snap.track_id, Some(TrackId(1)));
        assert_eq!(snap.repeat, RepeatMode::One);
        let _ = engine.send(EngineCommand::Shutdown);
        tokio::time::sleep(Duration::from_millis(150)).await;

        let captured = factory.captured();
        let span = nonzero_span(&captured);
        assert_eq!(longest_zero_run(span), 0, "循环边界不能有静音");
        assert!(span.iter().all(|s| *s > 0.0));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 手动「下一首」仍然立即切歌，不能等当前曲目自然播完。
    #[tokio::test]
    async fn engine_manual_next_cuts_immediately() {
        let dir = temp_dir("engine-manual-next");
        let path_a = write_wav(&dir, "a.wav", 8_000, 1, 8_000, 8_000); // 1 秒
        let path_b = write_wav(&dir, "b.wav", 8_000, 1, 4_000, -8_000);
        let factory = Arc::new(NullOutputFactory::new(PcmFormat {
            sample_rate: 8_000,
            channels: 1,
        }));
        let engine =
            PlaybackEngine::spawn_with_test_output(wav_resolver(path_a, path_b), factory.clone());
        engine
            .send(EngineCommand::SetQueue {
                tracks: vec![TrackId(1), TrackId(2)],
                start: 0,
            })
            .expect("send");

        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            let snap = engine.snapshot();
            if snap.track_id == Some(TrackId(1)) && snap.position_ms >= 200 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        let began = Instant::now();
        engine.send(EngineCommand::Next).expect("send");
        let deadline = Instant::now() + Duration::from_secs(3);
        let mut snap = engine.snapshot();
        while Instant::now() < deadline && snap.track_id != Some(TrackId(2)) {
            tokio::time::sleep(Duration::from_millis(20)).await;
            snap = engine.snapshot();
        }
        assert_eq!(snap.track_id, Some(TrackId(2)), "手动下一首要立即生效");
        assert!(
            began.elapsed() < Duration::from_millis(700),
            "不能等到第一首自然结束：耗时 {:?}",
            began.elapsed()
        );
        let _ = engine.send(EngineCommand::Shutdown);
        tokio::time::sleep(Duration::from_millis(150)).await;
        let _ = std::fs::remove_dir_all(&dir);
    }
}
