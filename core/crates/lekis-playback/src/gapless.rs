//! 无缝播放（PLY-01）：曲目边界时间轴。
//!
//! 真正的样本拼接发生在解码线程里（见 `session.rs`）：下一首的样本直接写进同一条
//! 环形缓冲，输出流和会话都不重建。本模块只负责一件事——记录「环形缓冲里的第几个
//! 样本开始属于下一首」，让引擎能在**真正听得见**的切换点更新队列和 UI。
//!
//! 为什么不能在解码线程切换解码器时立刻更新队列：解码线程领先输出 300 ms（见
//! `session.rs` 的 `BUFFER_MS`）。如果那时就推进队列游标，UI 会提前 300 ms 显示下一首，
//! 用户点「上一首」也会落到错误的曲目。这里把「已推送」的边界先挂在时间轴上，
//! 等 `played_samples` 追上边界样本号时才算可听，引擎再推进队列。
//!
//! 线程模型：解码线程只在曲目切换时 `push_boundary`（一把小锁，不在实时回调里）；
//! 引擎每 200 ms `audible(played_samples)` 读一次。实时输出回调完全不知道时间轴的存在。

use crate::decode::PcmFormat;
use lekis_types::TrackId;
use std::collections::VecDeque;
use std::sync::{Arc, Mutex, MutexGuard};

/// 一条曲目边界：从环形缓冲的第 `start_sample` 个**设备格式样本**开始。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AudibleTrack {
    /// 曲目。
    pub track_id: TrackId,
    /// 解码器给出的时长（毫秒）。
    pub duration_ms: Option<u64>,
    /// 内容格式（诊断用；缓冲里已经是设备格式）。
    pub format: PcmFormat,
    /// 这一首的第一个样本在环形缓冲时间轴上的位置（设备格式样本数）。
    pub start_sample: u64,
    /// 单调递增的边界序号（seek 重建边界也会 +1）。
    pub generation: u64,
    /// 到这条边界为止，**已经拼接**过多少次下一首（seek 不会增加）。
    ///
    /// 引擎按 `splice_count` 的增量调用 `Queue::advance(false)`，这样重复一首、
    /// 随机、列表循环的语义完全复用队列自己的实现。
    pub splice_count: u64,
}

#[derive(Debug)]
struct Inner {
    /// 最近一次「已经听得见」的曲目。
    current: Option<AudibleTrack>,
    /// 解码线程已经写进缓冲、但还没播到的曲目边界。
    pending: VecDeque<AudibleTrack>,
    /// 下一条边界的 generation。
    next_generation: u64,
}

/// 共享的曲目时间轴（解码线程写、引擎读）。
#[derive(Debug, Clone)]
pub struct TrackTimeline {
    inner: Arc<Mutex<Inner>>,
}

impl TrackTimeline {
    /// 建立只含当前曲目的时间轴。
    pub fn new(track_id: TrackId, duration_ms: Option<u64>, format: PcmFormat) -> Self {
        let inner = Inner {
            current: Some(AudibleTrack {
                track_id,
                duration_ms,
                format,
                start_sample: 0,
                generation: 0,
                splice_count: 0,
            }),
            pending: VecDeque::new(),
            next_generation: 1,
        };
        Self {
            inner: Arc::new(Mutex::new(inner)),
        }
    }

    /// 解码线程拼接下一首时登记边界。返回新边界的 generation。
    ///
    /// `start_sample` 必须是下一首第一个样本在环形缓冲里的设备样本序号；
    /// `splice_count` 是累计拼接次数（包含这一次）。
    pub fn push_boundary(
        &self,
        start_sample: u64,
        track_id: TrackId,
        duration_ms: Option<u64>,
        format: PcmFormat,
        splice_count: u64,
    ) -> u64 {
        let mut inner = self.lock();
        let generation = inner.next_generation;
        inner.next_generation = inner.next_generation.wrapping_add(1);
        inner.pending.push_back(AudibleTrack {
            track_id,
            duration_ms,
            format,
            start_sample,
            generation,
            splice_count,
        });
        generation
    }

    /// seek 之后重建时间轴：缓冲被清空，当前位置就是 `position` 对应样本。
    ///
    /// `splice_count` 传解码线程当前累计值：如果 seek 前已经拼接了下一首，
    /// seek 后实际播放的就是那一首，队列也应该补上这一次自然切换。
    pub fn rebase(
        &self,
        track_id: TrackId,
        duration_ms: Option<u64>,
        format: PcmFormat,
        splice_count: u64,
    ) -> u64 {
        let mut inner = self.lock();
        let generation = inner.next_generation;
        inner.next_generation = inner.next_generation.wrapping_add(1);
        inner.pending.clear();
        inner.current = Some(AudibleTrack {
            track_id,
            duration_ms,
            format,
            start_sample: 0,
            generation,
            splice_count,
        });
        generation
    }

    /// 按「已播放设备样本数」取出当前可听的曲目。
    ///
    /// 会把已经到达的待播边界提升为当前曲目。`played_samples` 是环形缓冲消费者
    /// 真正取走的样本数，所以边界只有到这一刻才「可听」。
    pub fn audible(&self, played_samples: u64) -> Option<AudibleTrack> {
        let mut inner = self.lock();
        while let Some(front) = inner.pending.front() {
            if front.start_sample > played_samples {
                break;
            }
            inner.current = inner.pending.pop_front();
        }
        inner.current.clone()
    }

    /// 解码线程**正在解**的曲目（可能已经拼进缓冲、还没播到）。
    ///
    /// 和 [`Self::audible`] 不同：它反映解码器的位置。seek 前用它判断用户看到的
    /// 曲目和实际解码器是不是同一首。
    pub fn active(&self) -> Option<AudibleTrack> {
        let inner = self.lock();
        inner
            .pending
            .back()
            .cloned()
            .or_else(|| inner.current.clone())
    }

    /// 还有多少条已解码、未播到的曲目边界（诊断 / 测试用）。
    pub fn pending_len(&self) -> usize {
        self.lock().pending.len()
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        // 时间轴只记录数字，锁中毒也不会破坏一致性；不能因为一次 panic 让播放卡死。
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    fn fmt() -> PcmFormat {
        PcmFormat {
            sample_rate: 48_000,
            channels: 2,
        }
    }

    fn track(n: i64) -> TrackId {
        TrackId(n)
    }

    /// 边界在播放位置追上之前不能变成「当前曲目」。
    #[test]
    fn boundary_becomes_audible_at_the_splice_sample() {
        let timeline = TrackTimeline::new(track(1), Some(1_000), fmt());
        assert_eq!(timeline.audible(0).unwrap().track_id, track(1));

        let generation = timeline.push_boundary(96_000, track(2), Some(2_000), fmt(), 1);
        // 解码线程已经拼接了，但设备还差一个样本才播到。
        assert_eq!(timeline.audible(95_999).unwrap().track_id, track(1));
        assert_eq!(timeline.pending_len(), 1);

        let audible = timeline.audible(96_000).unwrap();
        assert_eq!(audible.track_id, track(2));
        assert_eq!(audible.start_sample, 96_000);
        assert_eq!(audible.generation, generation);
        assert_eq!(audible.splice_count, 1);
        assert_eq!(audible.duration_ms, Some(2_000));
    }

    /// seek 重建不能增加拼接次数（引擎据此判断要不要推进队列）。
    #[test]
    fn rebase_does_not_add_a_natural_splice() {
        let timeline = TrackTimeline::new(track(1), Some(1_000), fmt());
        timeline.push_boundary(10, track(2), Some(2_000), fmt(), 1);
        let generation = timeline.rebase(track(1), Some(1_000), fmt(), 0);
        let audible = timeline.audible(0).unwrap();
        assert_eq!(audible.track_id, track(1));
        assert_eq!(audible.generation, generation);
        assert_eq!(audible.splice_count, 0);
        assert_eq!(timeline.pending_len(), 0, "seek 必须清掉还没播到的旧边界");
    }

    /// seek 落在已经拼接的下一首里：会话报的拼接次数要保留。
    #[test]
    fn rebase_after_splicing_keeps_the_splice_count() {
        let timeline = TrackTimeline::new(track(1), Some(1_000), fmt());
        timeline.push_boundary(10, track(2), Some(2_000), fmt(), 1);
        timeline.rebase(track(2), Some(2_000), fmt(), 1);
        let audible = timeline.audible(0).unwrap();
        assert_eq!(audible.track_id, track(2));
        assert_eq!(audible.splice_count, 1);
    }

    /// `active` 反映解码器位置：边界还没播到时它已经是下一首。
    #[test]
    fn active_track_leads_the_audible_track() {
        let timeline = TrackTimeline::new(track(1), Some(10), fmt());
        timeline.push_boundary(100, track(2), Some(10), fmt(), 1);
        assert_eq!(timeline.active().unwrap().track_id, track(2));
        assert_eq!(timeline.audible(50).unwrap().track_id, track(1));
        let audible = timeline.audible(150).unwrap();
        assert_eq!(audible.track_id, track(2));
        assert_eq!(timeline.active().unwrap().track_id, track(2));
    }

    /// 连续多个边界按播放位置依次提升，不能跳过。
    #[test]
    fn multiple_boundaries_are_promoted_in_order() {
        let timeline = TrackTimeline::new(track(1), Some(10), fmt());
        timeline.push_boundary(100, track(2), Some(10), fmt(), 1);
        timeline.push_boundary(200, track(3), Some(10), fmt(), 2);
        assert_eq!(timeline.audible(150).unwrap().track_id, track(2));
        assert_eq!(timeline.audible(250).unwrap().track_id, track(3));
        assert_eq!(timeline.audible(250).unwrap().splice_count, 2);
    }
}
