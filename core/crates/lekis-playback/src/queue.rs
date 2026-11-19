//! 播放队列（PLY-09）。纯数据结构，不涉及音频。

use lekis_types::{RepeatMode, ShuffleMode, TrackId};

/// 播放队列。
///
/// 随机播放时不打乱 `items` 本身，而是维护一个播放顺序 `order`，
/// 这样关闭随机后能回到原来的顺序，UI 显示的"接下来播放"也从 `order` 取。
#[derive(Debug, Clone, Default)]
pub struct Queue {
    items: Vec<TrackId>,
    order: Vec<usize>,
    /// 当前在 `order` 里的位置。
    cursor: Option<usize>,
    repeat: RepeatMode,
    shuffle: ShuffleMode,
    seed: u64,
}

impl Queue {
    /// 用一组曲目替换队列，从 `start` 开始播放。
    pub fn set(&mut self, items: Vec<TrackId>, start: usize) {
        self.items = items;
        self.rebuild_order(Some(start));
    }

    /// 当前曲目。
    pub fn current(&self) -> Option<TrackId> {
        let pos = *self.order.get(self.cursor?)?;
        self.items.get(pos).copied()
    }

    /// 当前曲目在 `items` 里的下标。
    pub fn current_index(&self) -> Option<usize> {
        self.order.get(self.cursor?).copied()
    }

    /// 队列长度。
    pub fn len(&self) -> usize {
        self.items.len()
    }

    /// 是否为空。
    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    /// 下一首会是什么（不移动游标）。无缝播放用它提前预加载。
    pub fn peek_next(&self) -> Option<TrackId> {
        let next = self.next_cursor(false)?;
        self.items.get(*self.order.get(next)?).copied()
    }

    /// 前进到下一首。`user_initiated` 为 `true` 时（用户点了"下一首"），单曲循环也会切歌。
    pub fn advance(&mut self, user_initiated: bool) -> Option<TrackId> {
        self.cursor = self.next_cursor(user_initiated);
        self.current()
    }

    /// 回到上一首。
    pub fn previous(&mut self) -> Option<TrackId> {
        let cur = self.cursor?;
        self.cursor = Some(if cur == 0 {
            if self.repeat == RepeatMode::All {
                self.order.len().saturating_sub(1)
            } else {
                0
            }
        } else {
            cur - 1
        });
        self.current()
    }

    /// 在当前曲目之后插入（"下一首播放"）。
    pub fn play_next(&mut self, track: TrackId) {
        self.insert_after_current(vec![track]);
    }

    /// 在当前曲目之后按顺序插入多首（"下一首播放"）。随机模式下它们也紧跟当前曲目，
    /// 其余曲目的播放顺序不变。
    pub fn insert_after_current(&mut self, tracks: Vec<TrackId>) {
        if tracks.is_empty() {
            return;
        }
        let k = tracks.len();
        let at_item = self
            .current_index()
            .map(|i| i + 1)
            .unwrap_or(self.items.len());
        for o in &mut self.order {
            if *o >= at_item {
                *o += k;
            }
        }
        self.items.splice(at_item..at_item, tracks);
        let at_pos = self.cursor.map(|c| c + 1).unwrap_or(self.order.len());
        self.order.splice(at_pos..at_pos, at_item..at_item + k);
    }

    /// 追加到队尾（随机模式下也排在最后，已有的播放顺序不变）。
    pub fn append(&mut self, tracks: impl IntoIterator<Item = TrackId>) {
        let start = self.items.len();
        self.items.extend(tracks);
        self.order.extend(start..self.items.len());
    }

    /// 按**播放顺序**列出队列（UI 的"播放队列"页按这个显示）。
    pub fn ordered(&self) -> Vec<TrackId> {
        self.order
            .iter()
            .filter_map(|&i| self.items.get(i).copied())
            .collect()
    }

    /// 当前曲目在播放顺序里的位置。
    pub fn position(&self) -> Option<usize> {
        self.cursor
    }

    /// 删除播放顺序里第 `pos` 首，返回被删的曲目。
    ///
    /// 删的是当前曲目时，游标落到原来的下一首（没有下一首就落到新的最后一首）。
    pub fn remove_at(&mut self, pos: usize) -> Option<TrackId> {
        if pos >= self.order.len() {
            return None;
        }
        let idx = self.order.remove(pos);
        let removed = self.items.remove(idx);
        for o in &mut self.order {
            if *o > idx {
                *o -= 1;
            }
        }
        if let Some(c) = self.cursor {
            self.cursor = if self.order.is_empty() {
                None
            } else if pos < c {
                Some(c - 1)
            } else if pos == c {
                Some(c.min(self.order.len() - 1))
            } else {
                Some(c)
            };
        }
        Some(removed)
    }

    /// 把播放顺序里第 `from` 首挪到 `to`。当前曲目不变。越界时返回 `false`。
    pub fn move_item(&mut self, from: usize, to: usize) -> bool {
        let n = self.order.len();
        if from >= n || to >= n {
            return false;
        }
        if from == to {
            return true;
        }
        if self.shuffle == ShuffleMode::Off {
            // 顺序播放时 order 恒为 0..n：直接挪 items，关掉随机后也保持用户排好的顺序。
            let t = self.items.remove(from);
            self.items.insert(to, t);
        } else {
            let v = self.order.remove(from);
            self.order.insert(to, v);
        }
        if let Some(c) = self.cursor {
            self.cursor = Some(if c == from {
                to
            } else if from < c && c <= to {
                c - 1
            } else if to <= c && c < from {
                c + 1
            } else {
                c
            });
        }
        true
    }

    /// 循环模式。
    pub fn repeat(&self) -> RepeatMode {
        self.repeat
    }

    /// 随机模式。
    pub fn shuffle(&self) -> ShuffleMode {
        self.shuffle
    }

    /// 设置循环模式。
    pub fn set_repeat(&mut self, mode: RepeatMode) {
        self.repeat = mode;
    }

    /// 设置随机模式。当前曲目保持不变。
    ///
    /// TODO(PLY-09)：智能随机——避免同一艺人连续出现（需要 core 传入艺人信息）。
    pub fn set_shuffle(&mut self, mode: ShuffleMode, seed: u64) {
        self.shuffle = mode;
        self.seed = seed;
        let current = self.current_index();
        self.rebuild_order(current);
    }

    fn next_cursor(&self, user_initiated: bool) -> Option<usize> {
        let cur = self.cursor?;
        if self.repeat == RepeatMode::One && !user_initiated {
            return Some(cur);
        }
        if cur + 1 < self.order.len() {
            Some(cur + 1)
        } else if self.repeat != RepeatMode::Off && !self.order.is_empty() {
            Some(0)
        } else {
            None
        }
    }

    /// 重建播放顺序，并把游标放到 `current`（`items` 下标）对应的位置。
    fn rebuild_order(&mut self, current: Option<usize>) {
        self.order = (0..self.items.len()).collect();
        if self.shuffle != ShuffleMode::Off {
            // Fisher–Yates + xorshift，结果由 seed 决定，便于测试和多设备接力时复现。
            let mut state = self.seed | 1;
            for i in (1..self.order.len()).rev() {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                let j = (state % (i as u64 + 1)) as usize;
                self.order.swap(i, j);
            }
            // 当前曲目放到最前面，随机的是"之后的"顺序。
            if let Some(cur) = current {
                if let Some(pos) = self.order.iter().position(|&x| x == cur) {
                    self.order.remove(pos);
                    self.order.insert(0, cur);
                }
            }
        }
        self.cursor = match current {
            Some(cur) if cur < self.items.len() => self.order.iter().position(|&x| x == cur),
            _ if self.items.is_empty() => None,
            _ => Some(0),
        };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids(n: i64) -> Vec<TrackId> {
        (1..=n).map(TrackId).collect()
    }

    #[test]
    fn sequential_and_repeat() {
        let mut q = Queue::default();
        q.set(ids(3), 1);
        assert_eq!(q.current(), Some(TrackId(2)));
        assert_eq!(q.peek_next(), Some(TrackId(3)));
        assert_eq!(q.advance(false), Some(TrackId(3)));
        assert_eq!(q.advance(false), None);

        q.set(ids(3), 2);
        q.set_repeat(RepeatMode::All);
        assert_eq!(q.advance(false), Some(TrackId(1)));

        q.set_repeat(RepeatMode::One);
        assert_eq!(q.advance(false), Some(TrackId(1)));
        assert_eq!(q.advance(true), Some(TrackId(2)));
    }

    #[test]
    fn shuffle_keeps_current_and_all_items() {
        let mut q = Queue::default();
        q.set(ids(20), 5);
        q.set_shuffle(ShuffleMode::Random, 42);
        assert_eq!(q.current(), Some(TrackId(6)));
        let mut seen = vec![q.current()];
        while let Some(t) = q.advance(false) {
            seen.push(Some(t));
        }
        assert_eq!(seen.len(), 20);
    }

    #[test]
    fn play_next_inserts_after_current() {
        let mut q = Queue::default();
        q.set(ids(3), 0);
        q.play_next(TrackId(99));
        assert_eq!(q.peek_next(), Some(TrackId(99)));
    }

    #[test]
    fn insert_after_current_keeps_shuffled_order() {
        let mut q = Queue::default();
        q.set(ids(10), 3);
        q.set_shuffle(ShuffleMode::Random, 7);
        let before = q.ordered();
        q.insert_after_current(vec![TrackId(100), TrackId(101)]);
        let after = q.ordered();
        assert_eq!(q.current(), Some(TrackId(4)));
        assert_eq!(after[0], TrackId(4));
        assert_eq!(&after[1..3], &[TrackId(100), TrackId(101)]);
        assert_eq!(&after[3..], &before[1..]);
        q.append(vec![TrackId(200)]);
        assert_eq!(q.ordered().last(), Some(&TrackId(200)));
        assert_eq!(q.len(), 13);
    }

    #[test]
    fn remove_and_move_track_the_cursor() {
        let mut q = Queue::default();
        q.set(ids(5), 2); // current = 3
        assert_eq!(q.remove_at(0), Some(TrackId(1)));
        assert_eq!(q.current(), Some(TrackId(3)));
        assert_eq!(q.ordered(), vec![TrackId(2), TrackId(3), TrackId(4), TrackId(5)]);
        // 删当前：落到下一首。
        assert_eq!(q.remove_at(1), Some(TrackId(3)));
        assert_eq!(q.current(), Some(TrackId(4)));
        assert!(q.remove_at(9).is_none());

        // [2, 4, 5]，当前 4：把 5 挪到最前。
        assert!(q.move_item(2, 0));
        assert_eq!(q.ordered(), vec![TrackId(5), TrackId(2), TrackId(4)]);
        assert_eq!(q.current(), Some(TrackId(4)));
        // 挪当前曲目本身。
        assert!(q.move_item(2, 0));
        assert_eq!(q.current(), Some(TrackId(4)));
        assert_eq!(q.position(), Some(0));
        assert!(!q.move_item(0, 3));

        // 删到空。
        q.remove_at(0);
        q.remove_at(0);
        q.remove_at(0);
        assert!(q.is_empty());
        assert_eq!(q.current(), None);
    }

    #[test]
    fn move_in_shuffle_mode_only_changes_play_order() {
        let mut q = Queue::default();
        q.set(ids(6), 0);
        q.set_shuffle(ShuffleMode::Random, 3);
        let before = q.ordered();
        assert!(q.move_item(5, 1));
        let after = q.ordered();
        assert_eq!(after[1], before[5]);
        assert_eq!(q.current(), Some(before[0]));
        assert_eq!(after.len(), 6);
    }
}
