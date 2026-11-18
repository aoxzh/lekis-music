//! 混合逻辑时钟（Hybrid Logical Clock）。
//!
//! 在设备时钟不准的情况下也能给出因果一致的全序：先比物理时间，再比计数器，最后比设备 ID。

use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::fmt;

/// 一个 HLC 时间戳。
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Hlc {
    /// 物理时间（Unix 毫秒）。
    pub wall_ms: i64,
    /// 同一毫秒内的逻辑计数器。
    pub counter: u32,
    /// 产生这个时间戳的设备（用于打破平局）。
    pub device: String,
}

impl Ord for Hlc {
    fn cmp(&self, other: &Self) -> Ordering {
        (self.wall_ms, self.counter, &self.device).cmp(&(
            other.wall_ms,
            other.counter,
            &other.device,
        ))
    }
}

impl PartialOrd for Hlc {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl fmt::Display for Hlc {
    /// 字符串形式可以直接按字典序比较（数据库里存这个）：`0000001732000000000-00000001-<device>`。
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{:019}-{:08x}-{}",
            self.wall_ms.max(0),
            self.counter,
            self.device
        )
    }
}

/// 本机的时钟。
#[derive(Debug, Clone)]
pub struct HlcClock {
    last: Hlc,
}

impl HlcClock {
    /// 创建本机时钟。
    pub fn new(device: impl Into<String>) -> Self {
        Self {
            last: Hlc {
                wall_ms: 0,
                counter: 0,
                device: device.into(),
            },
        }
    }

    /// 为本机产生的新事件生成时间戳。`now_ms` 由调用方传入，方便测试。
    pub fn tick(&mut self, now_ms: i64) -> Hlc {
        if now_ms > self.last.wall_ms {
            self.last.wall_ms = now_ms;
            self.last.counter = 0;
        } else {
            self.last.counter = self.last.counter.saturating_add(1);
        }
        self.last.clone()
    }

    /// 收到远端时间戳后推进本机时钟，保证之后的本机事件一定排在它后面。
    pub fn observe(&mut self, remote: &Hlc, now_ms: i64) {
        let wall = now_ms.max(self.last.wall_ms).max(remote.wall_ms);
        let counter = if wall == self.last.wall_ms && wall == remote.wall_ms {
            self.last.counter.max(remote.counter).saturating_add(1)
        } else if wall == self.last.wall_ms {
            self.last.counter.saturating_add(1)
        } else if wall == remote.wall_ms {
            remote.counter.saturating_add(1)
        } else {
            0
        };
        self.last.wall_ms = wall;
        self.last.counter = counter;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn monotonic_even_if_wall_clock_goes_back() {
        let mut c = HlcClock::new("a");
        let t1 = c.tick(1000);
        let t2 = c.tick(900); // 时钟回拨
        assert!(t2 > t1);
    }

    #[test]
    fn observe_remote_future_event() {
        let mut c = HlcClock::new("a");
        c.tick(1000);
        let remote = Hlc {
            wall_ms: 5000,
            counter: 3,
            device: "b".into(),
        };
        c.observe(&remote, 1001);
        assert!(c.tick(1002) > remote);
    }

    #[test]
    fn string_form_sorts_like_struct() {
        let a = Hlc {
            wall_ms: 99,
            counter: 10,
            device: "x".into(),
        };
        let b = Hlc {
            wall_ms: 100,
            counter: 0,
            device: "a".into(),
        };
        assert!(a < b);
        assert!(a.to_string() < b.to_string());
    }
}
