//! 无锁 SPSC 环形缓冲：解码线程写、输出回调读（PLY-08 预读缓冲）。
//!
//! **实时线程规则**：回调里只做 `pop_slice` + 补零，不分配、不加锁、不做 IO、不打日志。
//! 环形缓冲区（[`ringbuf`]）的 SPSC 实现由原子索引达成，生产者和消费者各持一半。
//!
//! 除样本本身，[`RingProgress`] 还持有一组原子量用于跨线程观察进度：
//! 已推送/已播放样本数、欠载次数，以及"清空缓冲"的握手序号（seek / 切歌时用）。
//!
//! 用法：
//! ```ignore
//! let (mut writer, source, progress) = ring_source::ring_buffer(rate * channels, channels);
//! // 解码线程：writer.push_blocking(&samples, &stop_flag); progress.add_pushed(n);
//! // 输出后端：source.fill(buf)（在 cpal 回调里）
//! ```

use crate::output::SampleSource;
use ringbuf::traits::{Consumer, Observer, Producer, Split};
use ringbuf::{HeapCons, HeapProd, HeapRb};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// 解码侧：往环形缓冲区里写样本。
pub struct RingSourceWriter {
    prod: HeapProd<f32>,
}

impl RingSourceWriter {
    /// 写入尽可能多的样本，返回写入数量（缓冲区满时可能少于 `samples.len()`）。
    pub fn push(&mut self, samples: &[f32]) -> usize {
        self.prod.push_slice(samples)
    }

    /// 阻塞写入全部样本。缓冲区满时短暂让出 CPU 等消费者腾地方。
    ///
    /// `stop` 变 `true` 时立即返回已写入的数量，保证停止命令不会卡住解码线程。
    pub fn push_blocking(&mut self, samples: &[f32], stop: &AtomicBool) -> usize {
        let mut written = 0;
        while written < samples.len() {
            if stop.load(Ordering::Relaxed) {
                break;
            }
            written += self.prod.push_slice(&samples[written..]);
            if written < samples.len() {
                // 缓冲区满：等一小会儿，别忙等烧 CPU。
                std::thread::sleep(Duration::from_millis(3));
            }
        }
        written
    }

    /// 还能再写多少样本（缓冲区剩余空间）。
    pub fn vacant_len(&self) -> usize {
        self.prod.vacant_len()
    }

    /// 缓冲区里还有多少样本没被消费。
    pub fn occupied_len(&self) -> usize {
        self.prod.occupied_len()
    }
}

/// 跨线程进度与握手（原子量，不加锁）。
#[derive(Clone)]
pub struct RingProgress {
    played: Arc<AtomicU64>,
    pushed: Arc<AtomicU64>,
    flush: Arc<AtomicU64>,
    flush_ack: Arc<AtomicU64>,
    underruns: Arc<AtomicU64>,
}

impl RingProgress {
    /// 已被输出回调消费的样本数（干净地跟着播放进度走）。
    pub fn played_samples(&self) -> u64 {
        self.played.load(Ordering::Acquire)
    }

    /// 解码线程已推送的样本数。
    pub fn pushed_samples(&self) -> u64 {
        self.pushed.load(Ordering::Acquire)
    }

    /// 解码线程记录本次推送的样本数。
    pub fn add_pushed(&self, n: u64) {
        if n > 0 {
            self.pushed.fetch_add(n, Ordering::AcqRel);
        }
    }

    /// 欠载次数（缓冲没数据就轮到回调了 —— 说明解码跟不上或刚开始播）。
    pub fn underruns(&self) -> u64 {
        self.underruns.load(Ordering::Relaxed)
    }

    /// 缓冲是否已被播空（配合 `eof` 判断"这首放完了"）。
    pub fn drained(&self) -> bool {
        self.played_samples() >= self.pushed_samples()
    }

    /// 清零进度计数（seek / 换曲后调用）。
    pub fn reset_samples(&self) {
        self.played.store(0, Ordering::Release);
        self.pushed.store(0, Ordering::Release);
    }

    /// 请求消费者丢弃缓冲里的旧数据（seek / 换曲），返回握手序号。
    ///
    /// 调用方应随后 [`Self::wait_flush_ack`] 等消费者确认，避免新数据被这次清空带走。
    pub fn request_flush(&self) -> u64 {
        self.flush.fetch_add(1, Ordering::AcqRel) + 1
    }

    /// 等待消费者确认清空（最多 `timeout`）。返回是否收到确认。
    ///
    /// 超时意味着没有消费者在跑（设备没起来 / 流已停），调用方照常继续即可。
    pub fn wait_flush_ack(&self, seq: u64, stop: &AtomicBool, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        loop {
            if self.flush_ack.load(Ordering::Acquire) >= seq {
                return true;
            }
            if stop.load(Ordering::Relaxed) || Instant::now() >= deadline {
                return false;
            }
            std::thread::sleep(Duration::from_millis(1));
        }
    }

    fn on_flushed(&self, seq: u64) {
        self.flush_ack.store(seq, Ordering::Release);
    }

    fn add_played(&self, n: usize) {
        self.played.fetch_add(n as u64, Ordering::AcqRel);
    }

    fn note_underrun(&self) {
        self.underruns.fetch_add(1, Ordering::Relaxed);
    }
}

/// 输出侧：[`SampleSource`] 实现，在实时回调里被调用。
pub struct RingSource {
    cons: HeapCons<f32>,
    progress: RingProgress,
    /// 已观察到的最新清空序号。
    seen_flush: u64,
    /// 声道数，用于把欠载的尾部补成整帧静音。
    channels: u16,
}

impl RingSource {
    /// 欠载次数。
    pub fn underruns(&self) -> u64 {
        self.progress.underruns()
    }
}

impl SampleSource for RingSource {
    fn fill(&mut self, out: &mut [f32]) -> usize {
        // seek / 切歌后第一次回调：丢弃旧数据，并向上游确认。
        let current_flush = self.progress.flush.load(Ordering::Acquire);
        if current_flush != self.seen_flush {
            self.seen_flush = current_flush;
            self.cons.clear();
            self.progress.on_flushed(current_flush);
        }
        let n = self.cons.pop_slice(out);
        if n < out.len() {
            self.progress.note_underrun();
            // 不够就补静音；补齐到整帧，避免左右声道错位。
            let ch = usize::from(self.channels.max(1));
            let mut end = out.len();
            if end % ch != 0 {
                end -= end % ch;
            }
            for s in &mut out[n..end.max(n)] {
                *s = 0.0;
            }
        }
        self.progress.add_played(n);
        n
    }
}

/// 创建一对（写端, 读端）和一个进度句柄。`capacity` 是**样本数**（帧数 × 声道）。
pub fn ring_buffer(capacity: usize, channels: u16) -> (RingSourceWriter, RingSource, RingProgress) {
    let capacity = capacity.max(usize::from(channels.max(1)) * 1024);
    let rb = HeapRb::<f32>::new(capacity);
    let (prod, cons) = rb.split();
    let progress = RingProgress {
        played: Arc::new(AtomicU64::new(0)),
        pushed: Arc::new(AtomicU64::new(0)),
        flush: Arc::new(AtomicU64::new(0)),
        flush_ack: Arc::new(AtomicU64::new(0)),
        underruns: Arc::new(AtomicU64::new(0)),
    };
    (
        RingSourceWriter { prod },
        RingSource {
            cons,
            progress: progress.clone(),
            seen_flush: 0,
            channels,
        },
        progress,
    )
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    #[test]
    fn push_and_fill_roundtrip() {
        let (mut writer, mut source, progress) = ring_buffer(64 * 2, 2);
        assert_eq!(writer.push(&[0.1, -0.1, 0.2, -0.2]), 4);
        progress.add_pushed(4);

        let mut out = [0.0f32; 8];
        let n = source.fill(&mut out);
        assert_eq!(n, 4);
        assert_eq!(&out[..4], &[0.1, -0.1, 0.2, -0.2]);
        // 不够的部分必须补静音，且返回的是真实写入数。
        assert!(out[4..].iter().all(|s| *s == 0.0));
        assert!(source.underruns() >= 1);
        // 进度计数跟着走。
        assert_eq!(progress.played_samples(), 4);
        assert_eq!(progress.pushed_samples(), 4);
        assert!(progress.drained());
    }

    #[test]
    fn fill_is_bounded_by_capacity_and_drains_in_order() {
        // 请求容量会被抬到下限 channels * 1024，这里故意传 1 验证下限生效。
        let (mut writer, mut source, _progress) = ring_buffer(1, 1);
        let seq: Vec<f32> = (0..1500).map(|i| i as f32).collect();
        assert_eq!(writer.push(&seq), 1024, "容量下限是 channels * 1024");
        assert!(writer.vacant_len() == 0);
        let mut out = vec![0.0f32; 1024];
        assert_eq!(source.fill(&mut out), 1024);
        // 顺序必须严格保持先进先出。
        assert!(out.iter().enumerate().all(|(i, s)| *s == i as f32));
        // 腾出空间后能继续写剩下那部分。
        assert_eq!(writer.push(&seq[1024..]), 476);
        let mut tail = vec![0.0f32; 512];
        assert_eq!(source.fill(&mut tail), 476);
        assert!(tail[..476]
            .iter()
            .enumerate()
            .all(|(i, s)| *s == (1024 + i) as f32));
    }

    #[test]
    fn flush_discards_stale_samples_and_acks() {
        let (mut writer, mut source, progress) = ring_buffer(32, 1);
        writer.push(&[1.0, 2.0, 3.0, 4.0]);
        let mut out = [0.0f32; 4];
        assert_eq!(source.fill(&mut out), 4);
        assert_eq!(out, [1.0, 2.0, 3.0, 4.0]);

        // 重新灌一批"旧位置"的数据，然后请求清空（模拟 seek）。
        writer.push(&[5.0, 6.0, 7.0, 8.0]);
        let seq = progress.request_flush();
        assert_eq!(seq, 1);
        // 还没回调：确认不到。
        assert_eq!(progress.flush_ack.load(Ordering::Acquire), 0);

        // 回调看到 flush 标记后清空旧数据，这一次拿不到任何样本。
        let n = source.fill(&mut out);
        assert_eq!(n, 0, "seek 后的旧缓冲必须被丢弃");
        assert_eq!(out, [0.0f32; 4]);
        // 握手完成。
        assert_eq!(progress.flush_ack.load(Ordering::Acquire), 1);
        let stop = AtomicBool::new(false);
        assert!(progress.wait_flush_ack(1, &stop, Duration::from_millis(10)));

        // 清空确认之后写入的样本（seek 之后的新位置）必须正常播出。
        writer.push(&[9.0]);
        let n = source.fill(&mut out);
        assert_eq!(n, 1);
        assert_eq!(out[0], 9.0);
        assert_eq!(out[1], 0.0);
    }

    #[test]
    fn flush_wait_times_out_without_consumer() {
        let (_writer, _source, progress) = ring_buffer(32, 2);
        let seq = progress.request_flush();
        let stop = AtomicBool::new(false);
        let acked = progress.wait_flush_ack(seq, &stop, Duration::from_millis(20));
        assert!(!acked, "没有消费者时握手必须超时返回，不能卡死");
    }
}
