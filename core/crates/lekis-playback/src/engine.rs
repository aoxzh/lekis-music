//! 播放引擎：命令进、状态出。
//!
//! 引擎运行在自己的控制任务里，外部通过 [`EngineCommand`] 控制，通过 `watch` 通道读取 [`PlaybackSnapshot`]。
//! lekis-core 订阅快照并转成 `CoreEvent::PlaybackChanged` / `PositionTick` 推给 UI。
//!
//! 现在只实现了队列和状态机，解码和输出还没接上（见各模块 TODO）。

use crate::queue::Queue;
use crate::MediaSource;
use lekis_types::{LekisError, PlaybackState, RepeatMode, Result, ShuffleMode, TrackId};
use tokio::sync::{mpsc, oneshot, watch};

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

async fn run(
    mut commands: mpsc::UnboundedReceiver<EngineCommand>,
    snapshot: watch::Sender<PlaybackSnapshot>,
    resolver: mpsc::Sender<ResolveRequest>,
) {
    let mut queue = Queue::default();
    let mut snap = PlaybackSnapshot::default();

    while let Some(cmd) = commands.recv().await {
        match cmd {
            EngineCommand::SetQueue { tracks, start } => {
                queue.set(tracks, start);
                snap.state = PlaybackState::Loading;
                snap.position_ms = 0;
                load_current(&queue, &resolver, &mut snap).await;
            }
            EngineCommand::Play if snap.track_id.is_some() => snap.state = PlaybackState::Playing,
            EngineCommand::Play => {}
            EngineCommand::Pause => {
                if snap.state == PlaybackState::Playing {
                    snap.state = PlaybackState::Paused;
                }
            }
            EngineCommand::Next => {
                queue.advance(true);
                snap.position_ms = 0;
                load_current(&queue, &resolver, &mut snap).await;
            }
            EngineCommand::Previous => {
                if snap.position_ms <= 3_000 {
                    queue.previous();
                }
                snap.position_ms = 0;
                load_current(&queue, &resolver, &mut snap).await;
            }
            EngineCommand::Seek(ms) => snap.position_ms = ms.min(snap.duration_ms),
            EngineCommand::SetRepeat(mode) => queue.set_repeat(mode),
            EngineCommand::SetShuffle(mode) => {
                queue.set_shuffle(mode, lekis_types::now_ms() as u64)
            }
            EngineCommand::SetVolume(v) => snap.volume = v.clamp(0.0, 1.0),
            EngineCommand::Shutdown => break,
        }
        snap.queue_len = queue.len() as u32;
        snap.queue_index = queue.current_index().map(|i| i as u32);
        snapshot.send_replace(snap.clone());
    }
    tracing::debug!(target: "playback", "engine task exiting");
}

/// 解析当前曲目并（将来）交给解码器。
async fn load_current(
    queue: &Queue,
    resolver: &mpsc::Sender<ResolveRequest>,
    snap: &mut PlaybackSnapshot,
) {
    snap.track_id = queue.current();
    let Some(track_id) = snap.track_id else {
        snap.state = PlaybackState::Ended;
        return;
    };
    let (tx, rx) = oneshot::channel();
    if resolver.send((track_id, tx)).await.is_err() {
        tracing::warn!(target: "playback", "resolver channel closed");
        return;
    }
    match rx.await {
        Ok(Ok(media)) => {
            snap.duration_ms = media.duration_hint_ms;
            // TODO(PLY-01/PLY-08)：打开解码槽位、预加载下一首、启动输出后端。
            snap.state = PlaybackState::Playing;
        }
        Ok(Err(e)) => {
            tracing::warn!(target: "playback", %track_id, error = %e, "cannot resolve track");
            snap.state = PlaybackState::Paused;
        }
        Err(_) => snap.state = PlaybackState::Paused,
    }
}
