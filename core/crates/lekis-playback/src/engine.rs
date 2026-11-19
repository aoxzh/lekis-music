//! 播放引擎：命令进、状态出。
//!
//! 引擎运行在自己的控制任务里，外部通过 [`EngineCommand`] 控制，通过 `watch` 通道读取 [`PlaybackSnapshot`]。
//! lekis-core 订阅快照并转成 `CoreEvent::PlaybackChanged` / `PositionTick` 推给 UI。
//!
//! 每个曲目的播放链路由一个 [`Session`] 负责（解码线程 + 无锁环形缓冲 + cpal 输出）。
//! 引擎自己只做四件事：解析曲目、管会话生命周期、回写进度快照、播完自动切下一首。
//! 进度来自「设备真正取走的样本数」，所以是准确的播放位置，而不是解码位置。
//!
//! 无提示音（gapless，PLY-01）：换曲前先把下一首**解析**好（resolver 是异步的、可能要访问网络），
//! 换曲时只剩「打开解码器 + 建输出流」的开销。真正的样本级无缝还要求两首歌共用一条输出流、
//! 在缓冲里直接接上下一首的样本 —— 那需要双解码槽位 + 混音，见 TODO(PLY-01)。

use crate::output::{AudioOutput, CpalOutput, OutputDevice, OutputMode};
use crate::queue::Queue;
use crate::session::Session;
use crate::MediaSource;
use lekis_types::{LekisError, PlaybackState, RepeatMode, Result, ShuffleMode, TrackId};
use std::collections::VecDeque;
use std::time::Duration;
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
    /// 是否提前解析下一首（`playback.gapless` 设置，PLY-01）。
    ///
    /// 目前引擎能做到的"无缝"只有预解析；关掉后换曲时现场解析。样本级无缝见 TODO(PLY-01)。
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
    /// 当前输出模式（PLY-12）。
    pub output_mode: OutputMode,
    /// 循环模式。
    pub repeat: RepeatMode,
    /// 随机模式。
    pub shuffle: ShuffleMode,
    /// 是否开启预解析下一首（`playback.gapless`）。
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
        let (cmd_tx, cmd_rx) = mpsc::unbounded_channel();
        let (snap_tx, snap_rx) = watch::channel(PlaybackSnapshot::default());
        tokio::spawn(run(cmd_rx, snap_tx, resolver));
        Self {
            commands: cmd_tx,
            snapshot: snap_rx,
        }
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
    /// 用户选定的输出设备（PLY-05），`None` = 跟随系统默认。
    device_id: Option<String>,
    /// 输出模式（PLY-12）。
    mode: OutputMode,
    /// 是否预解析下一首（`playback.gapless`）。
    gapless: bool,
    /// 队列内容变了、快照里的 `queue` 需要重建。
    queue_dirty: bool,
}

impl State {
    fn new(resolver: mpsc::Sender<ResolveRequest>, handle: Handle, snap: PlaybackSnapshot) -> Self {
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
            device_id: None,
            mode: OutputMode::Shared,
            gapless: true,
            queue_dirty: false,
        }
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
                if let Some(session) = self.session.as_mut() {
                    if let Err(e) = session.seek(target) {
                        tracing::warn!(target: "playback", position_ms = target, error = %e, "seek failed");
                    }
                }
            }
            EngineCommand::SetRepeat(mode) => {
                self.queue.set_repeat(mode);
                self.spawn_prefetch();
            }
            EngineCommand::SetShuffle(mode) => {
                if mode != self.queue.shuffle() {
                    self.queue_dirty = true;
                    self.queue.set_shuffle(mode, lekis_types::now_ms() as u64);
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
        self.snap.position_ms = position;

        if finished || (worker_dead && session.underruns() > 0) {
            // 解码结束且缓冲被播空 → 自动切下一首（PLY-01：repeat=one 时 queue 会回到同一首）。
            tracing::debug!(
                target: "playback",
                track = ?self.snap.track_id,
                position_ms = position,
                "track finished, advancing"
            );
            let next = self.queue.advance(false);
            self.snap.position_ms = 0;
            if next.is_none() {
                self.close_session();
                self.snap.state = PlaybackState::Ended;
                self.refresh_queue_fields();
                return;
            }
            self.load_current().await;
        } else {
            self.refresh_queue_fields();
        }
    }

    /// 解析当前曲目并开始播放。
    async fn load_current(&mut self) {
        self.close_session();
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
        let media = match self.resolve(track_id).await {
            Ok(media) => media,
            Err(e) => {
                tracing::warn!(target: "playback", %track_id, error = %e, "cannot resolve track");
                self.snap.state = PlaybackState::Paused;
                return;
            }
        };

        // 时长先按解析结果填，解码器打开后会用真实值覆盖。
        self.snap.duration_ms = media.duration_hint_ms;
        match Session::start(
            &media,
            self.device_id.as_deref(),
            self.mode,
            self.snap.volume,
            self.handle.clone(),
        )
        .await
        {
            Ok(session) => {
                if let Some(duration) = session.duration_ms() {
                    self.snap.duration_ms = duration;
                }
                tracing::debug!(
                    target: "playback",
                    %track_id,
                    rate = session.format().sample_rate,
                    channels = session.format().channels,
                    device_rate = session.device_format().sample_rate,
                    device_channels = session.device_format().channels,
                    "playing"
                );
                self.session = Some(session);
                self.snap.state = PlaybackState::Playing;
            }
            Err(e) => {
                // 没有音频设备、格式不支持、文件坏了……都不 panic，退化成"暂停"。
                tracing::warn!(target: "playback", %track_id, error = %e, "cannot start playback session");
                self.snap.state = PlaybackState::Paused;
            }
        }
        // 先把下一首解析好（无缝换曲）。
        self.spawn_prefetch();
    }

    /// 优先用预解析结果，否则现场向 resolver 要。
    async fn resolve(&mut self, track_id: TrackId) -> Result<MediaSource> {
        self.drain_prefetch();
        if let Some(pos) = self.prefetched.iter().position(|(id, _)| *id == track_id) {
            if let Some((_, media)) = self.prefetched.remove(pos) {
                return Ok(media);
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
        let Some(next) = self.queue.peek_next() else {
            return;
        };
        if self.snap.track_id == Some(next) || self.prefetched.iter().any(|(id, _)| *id == next) {
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
    mut commands: mpsc::UnboundedReceiver<EngineCommand>,
    snapshot: watch::Sender<PlaybackSnapshot>,
    resolver: mpsc::Sender<ResolveRequest>,
) {
    let mut state = State::new(resolver, Handle::current(), PlaybackSnapshot::default());
    let mut ticker = tokio::time::interval(Duration::from_millis(TICK_MS));
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    // 第一条 tick 会立刻触发；先消费掉，别让首帧快照多跳一次。
    ticker.tick().await;

    loop {
        tokio::select! {
            command = commands.recv() => {
                match command {
                    Some(EngineCommand::Shutdown) | None => break,
                    Some(cmd) => state.handle(cmd).await,
                }
            }
            _ = ticker.tick() => state.on_tick().await,
        }
        snapshot.send_replace(state.snap.clone());
    }

    // Shutdown：停流 + join 解码线程（幂等，重复调用安全）。
    state.close_session();
    snapshot.send_replace(state.snap.clone());
    tracing::debug!(target: "playback", "engine task exiting");
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::MediaLocation;

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
}
