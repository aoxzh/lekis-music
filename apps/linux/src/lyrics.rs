//! 桌面歌词（UIX-07）用的 LRC 解析。
//!
//! 核心目前还没有歌词 API（`TODO(ENR-04)`），所以这里先把“拿到 LRC 文本之后”的
//! 逻辑做完并单测覆盖：解析时间轴、按播放位置找当前行、算上下文的透明度。
//! 等 `lekis-core` 提供 `lyrics(track_id)` 之后，[`crate::lyrics_window`] 只要把
//! 文本喂进来即可，不需要改这里的逻辑。

/// 一行歌词。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LyricLine {
    /// 起始时间（毫秒）。
    pub start_ms: u64,
    /// 歌词文本（已去掉时间标签）。
    pub text: String,
}

/// 解析 LRC 文本。
///
/// 支持：
/// - 一行多个时间标签：`[00:12.00][01:20.00]歌词`；
/// - `[mm:ss]`、`[mm:ss.SS]`、`[mm:ss.SSS]`；
/// - 元信息行（`[ar:...]`、`[ti:...]`）被忽略；
/// - 空行忽略。
///
/// 返回结果按 `start_ms` 升序排列，方便二分查找。
pub fn parse_lrc(text: &str) -> Vec<LyricLine> {
    let mut lines = Vec::new();
    for raw in text.lines() {
        let mut rest = raw.trim();
        let mut stamps = Vec::new();
        // 反复剥掉行首的时间标签。
        while let Some(stripped) = rest.strip_prefix('[') {
            let Some(end) = stripped.find(']') else { break };
            let Some(ms) = parse_stamp(&stripped[..end]) else {
                // 不是时间标签（例如 [ar:艺人]），整行跳过。
                stamps.clear();
                break;
            };
            stamps.push(ms);
            rest = stripped[end + 1..].trim_start();
        }
        if stamps.is_empty() {
            continue;
        }
        let text = rest.trim();
        if text.is_empty() {
            continue;
        }
        for start_ms in stamps {
            lines.push(LyricLine {
                start_ms,
                text: text.to_string(),
            });
        }
    }
    lines.sort_by_key(|line| line.start_ms);
    lines
}

/// `mm:ss` / `mm:ss.SS` / `mm:ss.SSS` → 毫秒。
fn parse_stamp(stamp: &str) -> Option<u64> {
    let (mm, rest) = stamp.split_once(':')?;
    let minutes: u64 = mm.trim().parse().ok()?;
    let (ss, frac) = match rest.split_once('.') {
        Some((ss, frac)) => (ss, Some(frac)),
        None => (rest, None),
    };
    let seconds: u64 = ss.trim().parse().ok()?;
    if seconds >= 60 {
        return None;
    }
    let millis = match frac {
        None => 0,
        Some(frac) => {
            let frac = frac.trim();
            if frac.is_empty() || !frac.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            // 两位按 1/100 秒算，三位按 1/1000 秒算。
            let value: u64 = frac.parse().ok()?;
            match frac.len() {
                1 => value * 100,
                2 => value * 10,
                3 => value,
                _ => value / 10_u64.pow(frac.len() as u32 - 3),
            }
        }
    };
    Some(minutes * 60_000 + seconds * 1000 + millis)
}

/// 按播放位置找当前行下标；没有匹配返回 `None`。
pub fn current_line(lines: &[LyricLine], position_ms: u64) -> Option<usize> {
    if lines.is_empty() {
        return None;
    }
    // 找最后一个 `start_ms <= position_ms` 的行。
    match lines.partition_point(|line| line.start_ms <= position_ms) {
        0 => None,
        index => Some(index - 1),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 常见 LRC：元信息 + 多时间标签 + 毫秒精度。
    #[test]
    fn parses_typical_lrc() {
        let text = "[ar:测试艺人]\n[ti:测试曲目]\n\
                    [00:01.50]第一行\n\
                    [00:12.00][00:42.00]副歌\n\
                    \n\
                    [00:20.123]第三行\n";
        let lines = parse_lrc(text);
        assert_eq!(lines.len(), 4);
        assert_eq!(lines[0].start_ms, 1_500);
        assert_eq!(lines[0].text, "第一行");
        assert_eq!(lines[1].start_ms, 12_000);
        assert_eq!(lines[2].start_ms, 20_123);
        assert_eq!(lines[3].start_ms, 42_000);
        assert_eq!(lines[3].text, "副歌");
    }

    /// 当前行随位置前进，位置超过最后一行时停在最后一行。
    #[test]
    fn picks_current_line() {
        let lines = parse_lrc("[00:01.00]a\n[00:05.00]b\n[00:09.00]c\n");
        assert_eq!(current_line(&lines, 0), None);
        assert_eq!(current_line(&lines, 1_000), Some(0));
        assert_eq!(current_line(&lines, 4_999), Some(0));
        assert_eq!(current_line(&lines, 5_000), Some(1));
        assert_eq!(current_line(&lines, 60_000), Some(2));
    }

    /// 空文本不算歌词。
    #[test]
    fn empty_input_yields_nothing() {
        assert!(parse_lrc("").is_empty());
        assert!(parse_lrc("[ar:只有元信息]\n").is_empty());
    }
}
