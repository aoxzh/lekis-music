//! 节流与退避（ENR-09）。
//!
//! 两类状态分开管：
//! - [`RateLimiter`]：**主动**限速，保证两次请求之间至少间隔 `min_interval`。
//!   各提供方的限额（写在 [`crate::providers`] 的构造函数里）：
//!   LRCLIB 保守 1 次/秒、Cover Art Archive 1 次/秒（跑在 Internet Archive 上，
//!   官方建议温和使用）、iTunes Search 约 20 次/分钟、MusicBrainz 1 次/秒（以后接指纹时用）。
//! - [`Backoff`]：**被动**退避，请求失败（`RateLimited` / `Network`）后依次拉长间隔，
//!   成功一次就归零。纯计算、无 IO，方便单测。
//!
//! 实现是同进程内的最小间隔互斥，够用：一个 App 同时只会有一两个补全任务在跑，
//! 跨进程/跨设备共享配额要靠 ENR-10 的共享缓存，不在这一层。

use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Duration;
use tokio::sync::Mutex;
use tokio::time::Instant;

/// 两次请求之间的最小间隔。
#[derive(Debug)]
pub struct RateLimiter {
    /// 最小间隔。
    min_interval: Duration,
    /// 下一次允许发起请求的时刻；`None` 表示还没请求过。
    next_allowed: Mutex<Option<Instant>>,
}

impl RateLimiter {
    /// 以最小间隔创建。
    pub const fn new(min_interval: Duration) -> Self {
        Self {
            min_interval,
            next_allowed: Mutex::const_new(None),
        }
    }

    /// 最小间隔。
    pub const fn min_interval(&self) -> Duration {
        self.min_interval
    }

    /// 等到允许发请求为止。
    ///
    /// 持有锁等睡眠，等于把并发的调用排成队；对"每 N 秒一次"的配额来说这是对的语义。
    pub async fn acquire(&self) {
        let mut guard = self.next_allowed.lock().await;
        let now = Instant::now();
        if let Some(next) = *guard {
            if next > now {
                tokio::time::sleep(next - now).await;
            }
        }
        // 以"醒来后的时刻"为基准，避免累积漂移。
        *guard = Some(Instant::now() + self.min_interval);
    }
}

/// 失败后的指数退避。
#[derive(Debug)]
pub struct Backoff {
    /// 第一次失败后的等待。
    base: Duration,
    /// 上限，避免无限拉长。
    max: Duration,
    /// 连续失败次数。
    failures: AtomicU32,
}

impl Backoff {
    /// 创建：`base` 起步，最长 `max`。
    pub const fn new(base: Duration, max: Duration) -> Self {
        Self {
            base,
            max,
            failures: AtomicU32::new(0),
        }
    }

    /// 记一次失败，返回这一次应该等多久。
    ///
    /// 第 n 次失败等 `base * 2^(n-1)`，封顶 `max`。
    pub fn record_failure(&self) -> Duration {
        let failures = self
            .failures
            .fetch_add(1, Ordering::Relaxed)
            .saturating_add(1);
        self.delay_for(failures)
    }

    /// 成功之后清零。
    pub fn reset(&self) {
        self.failures.store(0, Ordering::Relaxed);
    }

    /// 当前连续失败次数。
    pub fn failures(&self) -> u32 {
        self.failures.load(Ordering::Relaxed)
    }

    /// 第 `failures` 次失败对应的等待时间（纯函数，便于测试）。
    fn delay_for(&self, failures: u32) -> Duration {
        if failures == 0 {
            return Duration::ZERO;
        }
        // 2^(n-1)，n 很大时直接封顶，避免移位溢出。
        let shift = failures.saturating_sub(1).min(16);
        let scaled = self.base.saturating_mul(1u32 << shift);
        scaled.min(self.max)
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    #[test]
    fn backoff_doubles_and_caps() {
        let backoff = Backoff::new(Duration::from_millis(100), Duration::from_millis(1000));
        assert_eq!(backoff.record_failure(), Duration::from_millis(100));
        assert_eq!(backoff.record_failure(), Duration::from_millis(200));
        assert_eq!(backoff.record_failure(), Duration::from_millis(400));
        assert_eq!(backoff.record_failure(), Duration::from_millis(800));
        // 封顶。
        assert_eq!(backoff.record_failure(), Duration::from_millis(1000));
        assert_eq!(backoff.failures(), 5);
        // 成功后归零。
        backoff.reset();
        assert_eq!(backoff.failures(), 0);
        assert_eq!(backoff.record_failure(), Duration::from_millis(100));
    }

    #[test]
    fn backoff_does_not_overflow_on_many_failures() {
        let backoff = Backoff::new(Duration::from_millis(1), Duration::from_secs(60));
        for _ in 0..200 {
            let delay = backoff.record_failure();
            assert!(delay <= Duration::from_secs(60));
        }
    }

    /// 真的会把连续调用拉开间隔（用很短的间隔跑，别让测试变慢）。
    #[tokio::test]
    async fn rate_limiter_spaces_calls() {
        let limiter = RateLimiter::new(Duration::from_millis(40));
        let start = std::time::Instant::now();
        limiter.acquire().await;
        limiter.acquire().await;
        limiter.acquire().await;
        let elapsed = start.elapsed();
        // 第一次不等，后两次各等 ~40ms。
        assert!(
            elapsed >= Duration::from_millis(70),
            "三次调用至少应花 70ms，实际 {elapsed:?}"
        );
        assert_eq!(limiter.min_interval(), Duration::from_millis(40));
    }

    /// 并发的 acquire 必须串行（否则配额会被瞬间打满）。
    #[tokio::test]
    async fn rate_limiter_serializes_concurrent_callers() {
        let limiter = std::sync::Arc::new(RateLimiter::new(Duration::from_millis(20)));
        let start = std::time::Instant::now();
        let mut handles = Vec::new();
        for _ in 0..4 {
            let limiter = std::sync::Arc::clone(&limiter);
            handles.push(tokio::spawn(async move {
                limiter.acquire().await;
            }));
        }
        for handle in handles {
            handle.await.unwrap();
        }
        // 4 次调用：第一次立即，其余 3 次各等 ~20ms。
        assert!(start.elapsed() >= Duration::from_millis(45));
    }
}
