//! 播放器状态：播放条、正在播放页、迷你播放器、桌面歌词共用的一份数据。
//!
//! 这里只做两件事：
//! 1. 把界面操作翻译成 `lekis-core` 的播放控制调用（真正的播放逻辑全在核心里）；
//! 2. 把核心推过来的 [`CoreEvent`] 合并成界面能直接读的快照。
//!
//! **进度完全由 `PositionTick` 事件驱动，没有任何轮询**（REQUIREMENTS 的 PLY 约束）。
//! 数据和通知机制分开：数据用 `Mutex`（这样 `Arc<Player>` 可以跨线程送进事件桥），
//! 界面回调用 thread-local 的 `Rc<dyn Fn()>` 只在 GTK 主线程上跑。

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::{Arc, Mutex, MutexGuard};

use gtk4::glib;
use lekis_core::PlaybackSnapshot;
use lekis_types::{CoreEvent, PlaybackState, RepeatMode, ShuffleMode, TrackId};

use crate::core_service::CoreHandle;
use crate::i18n;

/// 正在播放曲目的展示信息（从 `get_track` 拉到的字段，够界面用就好）。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NowPlaying {
    /// 标题。
    pub title: String,
    /// 副标题（`艺人 / 艺人 · 专辑`，和 Windows 版一致）。
    pub subtitle: String,
    /// 音质徽章，例如 `FLAC 24/96`。
    pub quality: Option<String>,
}

/// 播放器共享数据（`Send + Sync`，可以跨线程）。
struct PlayerData {
    /// 核心快照。
    snapshot: Mutex<PlaybackSnapshot>,
    /// 当前曲目的展示信息。
    now_playing: Mutex<Option<NowPlaying>>,
    /// 展示信息对应的曲目，切歌时用来判断是否要重新拉。
    now_playing_id: Mutex<Option<TrackId>>,
    /// 循环模式（核心快照里没有，界面自己记）。
    repeat: Mutex<RepeatMode>,
    /// 随机模式。
    shuffle: Mutex<ShuffleMode>,
}

/// 播放器句柄。
///
/// 克隆只是 `Arc` 加一；所有播放控制方法都是同步发命令给核心（不阻塞）。
#[derive(Clone)]
pub struct Player {
    /// 核心句柄。
    core: CoreHandle,
    /// 共享数据。
    data: Arc<PlayerData>,
}

impl Player {
    /// 创建一个播放器（还没开始播放）。
    pub fn new(core: CoreHandle) -> Self {
        let snapshot = core.arc().playback_snapshot();
        Self {
            core,
            data: Arc::new(PlayerData {
                snapshot: Mutex::new(snapshot),
                now_playing: Mutex::new(None),
                now_playing_id: Mutex::new(None),
                repeat: Mutex::new(RepeatMode::default()),
                shuffle: Mutex::new(ShuffleMode::default()),
            }),
        }
    }

    // -----------------------------------------------------------------------
    // 读状态
    // -----------------------------------------------------------------------

    /// 当前播放快照。
    ///
    /// 界面一般用下面几个更具体的读取方法；需要同时看多个字段（比如"状态 + 位置"）
    /// 时用这个，避免多次加锁不一致。
    pub fn snapshot(&self) -> PlaybackSnapshot {
        lock(&self.data.snapshot).clone()
    }

    /// 当前曲目的展示信息。
    pub fn now_playing(&self) -> Option<NowPlaying> {
        lock(&self.data.now_playing).clone()
    }

    /// 是否正在播放。
    pub fn is_playing(&self) -> bool {
        matches!(lock(&self.data.snapshot).state, PlaybackState::Playing)
    }

    /// 是否有曲目（队列非空）。
    pub fn has_track(&self) -> bool {
        lock(&self.data.snapshot).track_id.is_some()
    }

    /// 当前位置（毫秒）。
    pub fn position_ms(&self) -> u64 {
        lock(&self.data.snapshot).position_ms
    }

    /// 总时长（毫秒）。
    pub fn duration_ms(&self) -> u64 {
        lock(&self.data.snapshot).duration_ms
    }

    /// 音量（0.0 ~ 1.0）。
    pub fn volume(&self) -> f32 {
        lock(&self.data.snapshot).volume
    }

    /// 循环模式。
    pub fn repeat(&self) -> RepeatMode {
        *lock(&self.data.repeat)
    }

    /// 随机模式。
    pub fn shuffle(&self) -> ShuffleMode {
        *lock(&self.data.shuffle)
    }

    // -----------------------------------------------------------------------
    // 播放控制（同步发命令给核心，失败由调用方提示）
    // -----------------------------------------------------------------------

    /// 播放 / 暂停。
    pub fn toggle_play_pause(&self) {
        if self.is_playing() {
            report(self.core.arc().pause());
        } else {
            report(self.core.arc().play());
        }
    }

    /// 播放指定的曲目列表。
    pub fn play_tracks(&self, ids: Vec<TrackId>, start: u32) {
        report(self.core.arc().play_tracks(ids, start));
    }

    /// 下一首。
    pub fn next(&self) {
        report(self.core.arc().next());
    }

    /// 上一首。
    pub fn previous(&self) {
        report(self.core.arc().previous());
    }

    /// 跳转到指定位置（毫秒）。
    pub fn seek(&self, position_ms: u64) {
        report(self.core.arc().seek(position_ms));
    }

    /// 相对当前位置跳转（快捷键 ←/→ 用，负数表示后退）。
    pub fn seek_by(&self, delta_ms: i64) {
        let current = self.position_ms() as i64;
        let duration = self.duration_ms() as i64;
        let mut target = current.saturating_add(delta_ms);
        if target < 0 {
            target = 0;
        }
        if duration > 0 && target > duration {
            target = duration;
        }
        self.seek(target as u64);
    }

    /// 设置音量（0.0 ~ 1.0）。
    pub fn set_volume(&self, volume: f32) {
        let clamped = volume.clamp(0.0, 1.0);
        if self.core.arc().set_volume(clamped).is_ok() {
            lock(&self.data.snapshot).volume = clamped;
            notify();
        }
    }

    /// 轮换循环模式：关闭 → 列表 → 单曲 → 关闭。
    pub fn cycle_repeat(&self) {
        let next = i18n::next_repeat(self.repeat());
        if self.core.arc().set_repeat(next).is_ok() {
            *lock(&self.data.repeat) = next;
            notify();
        }
    }

    /// 轮换随机模式：关闭 → 真随机 → 智能随机 → 关闭。
    pub fn cycle_shuffle(&self) {
        let next = i18n::next_shuffle(self.shuffle());
        if self.core.arc().set_shuffle(next).is_ok() {
            *lock(&self.data.shuffle) = next;
            notify();
        }
    }

    // -----------------------------------------------------------------------
    // 事件合并（只在 GTK 主线程调用）
    // -----------------------------------------------------------------------

    /// 把核心事件合并进播放器状态，然后通知界面。
    ///
    /// 这个方法只应该跑在 GTK 主线程上（[`crate::bridge`] 保证这一点）。
    pub fn apply_event(&self, event: &CoreEvent) {
        match event {
            CoreEvent::PlaybackChanged {
                state,
                track_id,
                position_ms,
                duration_ms,
            } => {
                let previous_track = {
                    let mut snapshot = lock(&self.data.snapshot);
                    snapshot.state = *state;
                    snapshot.track_id = *track_id;
                    snapshot.position_ms = *position_ms;
                    snapshot.duration_ms = *duration_ms;
                    snapshot.track_id
                };
                let showing = *lock(&self.data.now_playing_id);
                if previous_track != showing {
                    match previous_track {
                        Some(id) => self.fetch_track(id),
                        None => {
                            *lock(&self.data.now_playing) = None;
                            *lock(&self.data.now_playing_id) = None;
                        }
                    }
                }
                notify();
            }
            CoreEvent::PositionTick { position_ms, .. } => {
                lock(&self.data.snapshot).position_ms = *position_ms;
                notify();
            }
            CoreEvent::QueueChanged {
                length,
                current_index,
            } => {
                let mut snapshot = lock(&self.data.snapshot);
                snapshot.queue_len = *length;
                snapshot.queue_index = *current_index;
                drop(snapshot);
                notify();
            }
            _ => {}
        }
    }

    /// 重新把核心快照读一遍（核心刚启动、或界面从后台回来时用）。
    pub fn refresh(&self) {
        let snapshot = self.core.arc().playback_snapshot();
        let previous_track = lock(&self.data.snapshot).track_id;
        *lock(&self.data.snapshot) = snapshot.clone();
        if snapshot.track_id != previous_track {
            match snapshot.track_id {
                Some(id) => self.fetch_track(id),
                None => {
                    *lock(&self.data.now_playing) = None;
                    *lock(&self.data.now_playing_id) = None;
                }
            }
        }
        notify();
    }

    /// 异步拉曲目详情，回来后只在“还是这首”时才写回界面。
    fn fetch_track(&self, id: TrackId) {
        let core = self.core.arc();
        let data = Arc::clone(&self.data);
        glib::spawn_future_local(async move {
            let result = core.get_track(id).await;
            // 用户可能已经切歌了，过期的结果直接丢掉。
            if lock(&data.snapshot).track_id != Some(id) {
                return;
            }
            match result {
                Ok(track) => {
                    let artists: Vec<&str> =
                        track.artists.iter().map(|a| a.name.as_str()).collect();
                    let mut subtitle = artists.join(" / ");
                    if let Some(album) = track.album_title.as_deref() {
                        if !album.is_empty() {
                            if !subtitle.is_empty() {
                                subtitle.push_str(" · ");
                            }
                            subtitle.push_str(album);
                        }
                    }
                    let quality = track.audio.as_ref().map(|a| a.quality_badge());
                    *lock(&data.now_playing) = Some(NowPlaying {
                        title: track.title,
                        subtitle,
                        quality,
                    });
                    *lock(&data.now_playing_id) = Some(id);
                }
                Err(err) => {
                    tracing::warn!(track = %id, error = %err, "拉取曲目详情失败");
                    *lock(&data.now_playing) = Some(NowPlaying {
                        title: format!("#{id}"),
                        subtitle: i18n::error_text(&err),
                        quality: None,
                    });
                    *lock(&data.now_playing_id) = Some(id);
                }
            }
            notify();
        });
    }
}

/// 取锁；即使别的线程 panic 过也继续用（界面不能因为一个锁中毒就罢工）。
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

/// 播放控制失败只记日志：这些命令都是“发出去就行”，失败了界面也做不了什么。
fn report(result: lekis_types::Result<()>) {
    if let Err(err) = result {
        tracing::warn!(error = %err, "{}", i18n::PLAY_FAILED);
    }
}

// ---------------------------------------------------------------------------
// 界面订阅（只在 GTK 主线程使用）
// ---------------------------------------------------------------------------

thread_local! {
    /// 播放器状态的界面回调。
    static SINKS: RefCell<Vec<Rc<dyn Fn()>>> = const { RefCell::new(Vec::new()) };
}

/// 订阅播放器状态变化；回调在 GTK 主线程上执行。
///
/// 回调里可以随便碰控件（`Rc<dyn Fn()>` 不要求 `Send`），但**不要太重**：
/// 播放中每 250ms 会来一次 `PositionTick`。
pub fn subscribe(sink: Rc<dyn Fn()>) {
    SINKS.with(|sinks| sinks.borrow_mut().push(sink));
}

/// 通知所有订阅者（内部用；只在主线程调用）。
pub fn notify() {
    // 先复制一份，避免回调里再次 subscribe 时借用冲突。
    let sinks: Vec<Rc<dyn Fn()>> = SINKS.with(|sinks| sinks.borrow().clone());
    for sink in sinks {
        sink();
    }
}
