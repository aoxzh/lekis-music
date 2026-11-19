//! 结果本地缓存（ENR-09 的"结果本地缓存"）。
//!
//! 只做**进程内**的 TTL 缓存：同一首歌在一次扫描里会被"取封面 + 取歌词"分别问到，
//! 专辑里十几首歌也常常共享同一个专辑封面，命中一次就少一次网络请求，正好配合
//! [`crate::throttle::RateLimiter`] 把配额留给自己真正需要的查询。
//!
//! 设计上的三个克制：
//! - **只缓存成功结果**。失败（限流、网络错）不进缓存，否则一次抖动会把"没有数据"固化下来；
//! - **容量有上限**，超了先清过期、再丢最早的那条（LRU 太复杂，这里按插入时间淘汰足够）；
//! - **只按线索精确命中**。键里包含标题/艺人/专辑/时长/MBID 和提供方自己的地址，
//!   换一首歌、换一个自建实例都不会误命中。
//!
//! 跨进程、跨设备的缓存属于 ENR-10 的共享缓存，不在这一层。

use crate::TrackHint;
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// 默认存活时间：10 分钟。补全是一次性任务，跑完就不会再问同一首歌；
/// TTL 主要防"用户在一分钟内反复点刷新"。
pub const DEFAULT_TTL: Duration = Duration::from_secs(600);

/// 默认容量：256 条（一张专辑最多十几首，够覆盖几十张专辑的批量补全）。
pub const DEFAULT_CAPACITY: usize = 256;

/// 带 TTL 的进程内缓存。
#[derive(Debug)]
pub struct TtlCache<T> {
    ttl: Duration,
    capacity: usize,
    entries: Mutex<HashMap<String, Entry<T>>>,
}

#[derive(Debug)]
struct Entry<T> {
    /// 写入时刻，用来判过期和淘汰。
    stored_at: Instant,
    /// 值。
    value: T,
}

impl<T: Clone> TtlCache<T> {
    /// 用默认策略创建。
    pub fn new() -> Self {
        Self::with_policy(DEFAULT_TTL, DEFAULT_CAPACITY)
    }

    /// 指定 TTL 和容量。
    pub fn with_policy(ttl: Duration, capacity: usize) -> Self {
        Self {
            ttl,
            capacity: capacity.max(1),
            entries: Mutex::new(HashMap::new()),
        }
    }

    /// 取一条还在有效期内的结果。
    ///
    /// 锁 poisoning 时当作未命中：缓存不是正确性依赖，宁可多打一次网络请求。
    pub fn get(&self, key: &str) -> Option<T> {
        let entries = self.entries.lock().ok()?;
        let entry = entries.get(key)?;
        if entry.stored_at.elapsed() < self.ttl {
            Some(entry.value.clone())
        } else {
            None
        }
    }

    /// 写入一条结果（同时做过期清理和容量淘汰）。
    pub fn insert(&self, key: String, value: T) {
        let Ok(mut entries) = self.entries.lock() else {
            return;
        };
        let now = Instant::now();
        entries.retain(|_, e| now.duration_since(e.stored_at) < self.ttl);
        if entries.len() >= self.capacity {
            // 丢掉最早写入的那条：TTL 相同的前提下它就是最久没被更新的。
            if let Some(oldest) = entries
                .iter()
                .min_by_key(|(_, e)| e.stored_at)
                .map(|(k, _)| k.clone())
            {
                entries.remove(&oldest);
            }
        }
        entries.insert(
            key,
            Entry {
                stored_at: now,
                value,
            },
        );
    }

    /// 当前条数（含可能已过期但还没被清理的条目）。
    pub fn len(&self) -> usize {
        self.entries.lock().map(|e| e.len()).unwrap_or(0)
    }

    /// 是否为空。
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// 清空。
    pub fn clear(&self) {
        if let Ok(mut entries) = self.entries.lock() {
            entries.clear();
        }
    }
}

impl<T: Clone> Default for TtlCache<T> {
    fn default() -> Self {
        Self::new()
    }
}

/// 由线索生成缓存键：`提供方地址 + 标题 + 艺人 + 专辑 + 时长 + 两个 MBID`。
///
/// 分隔符用 `\u{1f}`（Unit Separator）：它不可能出现在任何真实标签里，
/// 因此不会出现 "AB|C" 和 "A|BC" 撞键。
pub fn cache_key(base_url: &str, hint: &TrackHint) -> String {
    let artists = hint
        .artists
        .iter()
        .map(|a| normalize_part(a))
        .filter(|a| !a.is_empty())
        .collect::<Vec<_>>()
        .join("\u{1f}");
    format!(
        "{base_url}\u{1f}{}\u{1f}{artists}\u{1f}{}\u{1f}{}\u{1f}{}\u{1f}{}",
        normalize_part(&hint.title),
        hint.album
            .as_deref()
            .map(normalize_part)
            .unwrap_or_default(),
        hint.duration_ms,
        hint.mbid_recording.as_deref().unwrap_or(""),
        hint.mbid_release.as_deref().unwrap_or(""),
    )
}

/// 键的单个部分：去空白、转小写（大小写不同的同一首歌要命中同一条缓存）。
fn normalize_part(value: &str) -> String {
    value.trim().to_lowercase()
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    fn hint(title: &str) -> TrackHint {
        TrackHint {
            title: title.into(),
            artists: vec!["周杰伦".into()],
            album: Some("叶惠美".into()),
            duration_ms: 269_000,
            ..Default::default()
        }
    }

    #[test]
    fn stores_and_reads_back() {
        let cache: TtlCache<u32> = TtlCache::new();
        assert!(cache.get("k").is_none());
        cache.insert("k".into(), 7);
        assert_eq!(cache.get("k"), Some(7));
        assert_eq!(cache.len(), 1);
        assert!(!cache.is_empty());
        cache.clear();
        assert!(cache.is_empty());
    }

    /// 过期之后必须当作未命中，不能再拿旧结果。
    #[test]
    fn expires_after_ttl() {
        let cache: TtlCache<u32> = TtlCache::with_policy(Duration::from_millis(30), 8);
        cache.insert("k".into(), 1);
        assert_eq!(cache.get("k"), Some(1));
        std::thread::sleep(Duration::from_millis(60));
        assert!(cache.get("k").is_none());
    }

    /// 容量满了要淘汰，不能无限涨。
    #[test]
    fn evicts_when_full() {
        let cache: TtlCache<u32> = TtlCache::with_policy(Duration::from_secs(60), 3);
        for i in 0..10 {
            cache.insert(format!("k{i}"), i);
        }
        assert!(cache.len() <= 3, "len = {}", cache.len());
        // 最新的那条一定还在。
        assert_eq!(cache.get("k9"), Some(9));
    }

    /// 键对标题/专辑/时长/MBID 敏感，不同实例的地址也要区分开。
    #[test]
    fn cache_key_distinguishes_inputs() {
        let a = hint("晴天");
        let mut b = hint("晴天");
        b.album = Some("七里香".into());
        assert_ne!(
            cache_key("https://lrclib.net", &a),
            cache_key("https://lrclib.net", &b)
        );
        assert_ne!(
            cache_key("https://lrclib.net", &a),
            cache_key("https://mirror.example", &a)
        );

        let mut c = hint("晴天");
        c.duration_ms = 270_000;
        assert_ne!(cache_key("x", &a), cache_key("x", &c));

        // 大小写和首尾空白不影响命中。
        let mut d = hint("  晴天 ");
        d.album = Some("叶惠美  ".into());
        assert_eq!(cache_key("x", &a), cache_key("x", &d));
    }

    /// 分隔符不会让 "AB" + "C" 和 "A" + "BC" 撞键。
    #[test]
    fn cache_key_is_not_ambiguous() {
        let mut a = hint("AB");
        a.artists = vec!["C".into()];
        let mut b = hint("A");
        b.artists = vec!["BC".into()];
        assert_ne!(cache_key("x", &a), cache_key("x", &b));
    }
}
