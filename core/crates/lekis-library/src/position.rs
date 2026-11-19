//! 歌单条目的位置键（分数索引）。
//!
//! 每个条目有一个字符串键，按字典序排序就是歌单顺序。插入两个条目之间时，生成一个夹在中间的新键，
//! 不需要修改其他条目，所以多台设备同时插入、拖动排序也不会冲突（最多出现相邻顺序的差异）。
//!
//! 算法参照 rocicorp/fractional-indexing 的 `midpoint`。键只用 `0-9a-z` 这 36 个字符，
//! 并且**键永远不以 `0` 结尾**（否则它前面就没有空间可以插入了）。
//!
//! **这是一份拷贝**：权威实现在 `lekis-sync/src/position.rs`（同步日志的序列 CRDT 用它），
//! 但 `lekis-library` 不能依赖 `lekis-sync`（依赖方向只允许 sync → library），所以这里复制一份。
//! 两边的实现和测试必须保持一致——改算法时两边一起改。

const DIGITS: &[u8] = b"0123456789abcdefghijklmnopqrstuvwxyz";

fn digit_value(c: u8) -> usize {
    DIGITS.iter().position(|&d| d == c).unwrap_or(0)
}

/// 生成一个排在 `before` 和 `after` 之间的键。
/// `before = None` 表示插到最前面，`after = None` 表示插到最后面。
///
/// 调用方保证 `before < after`（字典序），并且两者都是本函数生成的键。
pub(crate) fn key_between(before: Option<&str>, after: Option<&str>) -> String {
    let a = before.unwrap_or("").as_bytes();
    let b = after.map(str::as_bytes);
    String::from_utf8(midpoint(a, b)).unwrap_or_default()
}

fn midpoint(a: &[u8], b: Option<&[u8]>) -> Vec<u8> {
    if let Some(b) = b {
        // 去掉公共前缀（a 不够长时按 '0' 补齐）。
        let mut n = 0;
        while n < b.len() && a.get(n).copied().unwrap_or(b'0') == b[n] {
            n += 1;
        }
        if n > 0 {
            let mut out = b[..n].to_vec();
            out.extend(midpoint(a.get(n..).unwrap_or(&[]), Some(&b[n..])));
            return out;
        }
    }
    // 第一位不同（或者某一方没有这一位）。
    let digit_a = a.first().map(|&c| digit_value(c)).unwrap_or(0);
    let digit_b = match b {
        Some(b) => b.first().map(|&c| digit_value(c)).unwrap_or(DIGITS.len()),
        None => DIGITS.len(),
    };
    if digit_b.saturating_sub(digit_a) > 1 {
        return vec![DIGITS[(digit_a + digit_b).div_ceil(2)]];
    }
    // 第一位相邻。
    match b {
        Some(b) if b.len() > 1 => vec![b[0]],
        _ => {
            let mut out = vec![DIGITS[digit_a]];
            out.extend(midpoint(a.get(1..).unwrap_or(&[]), None));
            out
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_are_ordered() {
        let first = key_between(None, None);
        let end = key_between(Some(&first), None);
        let start = key_between(None, Some(&first));
        let mid = key_between(Some(&first), Some(&end));
        assert!(
            start < first && first < mid && mid < end,
            "{start} {first} {mid} {end}"
        );
    }

    #[test]
    fn many_inserts_between_adjacent_keys() {
        let lo = key_between(None, None);
        let mut hi = key_between(Some(&lo), None);
        for _ in 0..50 {
            let k = key_between(Some(&lo), Some(&hi));
            assert!(lo < k && k < hi, "{lo} < {k} < {hi}");
            assert!(!k.ends_with('0'));
            hi = k;
        }
    }

    #[test]
    fn many_appends_and_prepends() {
        let mut last = key_between(None, None);
        let mut first = last.clone();
        for _ in 0..100 {
            let next = key_between(Some(&last), None);
            assert!(next > last);
            last = next;
            let prev = key_between(None, Some(&first));
            assert!(prev < first, "{prev} < {first}");
            first = prev;
        }
    }
}
