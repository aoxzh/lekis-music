//! 日期与时间的极小工具（只用标准库）。
//!
//! 服务器 API 里两种格式都有：Subsonic / Plex 用 ISO-8601 字符串，
//! Jellyfin 的过滤参数也要 ISO-8601。`chrono` / `time` 都没进 workspace 依赖，
//! 而这里只需要"Unix 毫秒 ↔ UTC 日历"这一件事，所以手写（算法见
//! Howard Hinnant 的 `days_from_civil` / `civil_from_days`）。

/// Unix 毫秒 → `(年, 月, 日, 时, 分, 秒)`（UTC）。
pub(crate) fn civil_from_ms(ms: i64) -> (i64, u32, u32, u32, u32, u32) {
    let secs = ms.div_euclid(1000);
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (y, m, d) = civil_from_days(days);
    (
        y,
        m,
        d,
        (rem / 3600) as u32,
        ((rem % 3600) / 60) as u32,
        (rem % 60) as u32,
    )
}

/// Unix 毫秒 → `YYYY-MM-DDTHH:MM:SSZ`（UTC，秒级精度）。
pub(crate) fn format_iso8601_ms(ms: i64) -> String {
    let (y, m, d, hh, mm, ss) = civil_from_ms(ms);
    format!("{y:04}-{m:02}-{d:02}T{hh:02}:{mm:02}:{ss:02}Z")
}

/// 解析 ISO-8601 的 UTC 时间（形如 `2024-05-01T12:34:56.789Z` 或 `2024-05-01T12:34:56Z`）。
///
/// 只接受 Subsonic / Jellyfin 实际会用到的形状：带 `T`、`Z` 结尾、可选小数秒。
/// 解析失败返回 `None`（调用方据此退化为"不过滤"，而不是让整次同步失败）。
pub(crate) fn parse_iso8601_ms(text: &str) -> Option<i64> {
    let text = text.trim();
    let (date, time) = text.split_once('T')?;
    let time = time.strip_suffix('Z').unwrap_or(time);

    let mut date_parts = date.splitn(3, '-');
    let year: i64 = date_parts.next()?.parse().ok()?;
    let month: u32 = date_parts.next()?.parse().ok()?;
    let day: u32 = date_parts.next()?.parse().ok()?;
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }

    // 时区偏移（`+08:00`）这里不支持：Subsonic 固定返回 UTC。
    let mut time_parts = time.splitn(3, ':');
    let hour: i64 = time_parts.next()?.parse().ok()?;
    let minute: i64 = time_parts.next()?.parse().ok()?;
    let second_part = time_parts.next()?;
    let (second, millis) = match second_part.split_once('.') {
        Some((sec, frac)) => {
            let sec: i64 = sec.parse().ok()?;
            // 小数部分按毫秒截断（"5" → 500ms，"567" → 567ms）。
            let frac: String = frac.chars().take(3).collect();
            let frac: u32 = frac.parse().ok()?;
            let scale = 10u32.pow(3 - frac.to_string().len() as u32);
            (sec, frac * scale)
        }
        None => (second_part.parse().ok()?, 0),
    };

    let days = days_from_civil(year, month, day);
    Some(days * 86_400_000 + hour * 3_600_000 + minute * 60_000 + second * 1000 + i64::from(millis))
}

/// 公历日期 → 距 1970-01-01 的天数（可为负）。
fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400; // [0, 399]
    let mp = (i64::from(month) + 9) % 12; // [0, 11]
    let doy = (153 * mp + 2) / 5 + i64::from(day) - 1; // [0, 365]
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    era * 146_097 + doe - 719_468
}

/// 距 1970-01-01 的天数 → 公历日期。
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 }; // [1, 12]
    (if m <= 2 { y + 1 } else { y }, m as u32, d as u32)
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    #[test]
    fn epoch_and_known_dates() {
        assert_eq!(days_from_civil(1970, 1, 1), 0);
        assert_eq!(days_from_civil(2000, 3, 1), 11_017);
        assert_eq!(parse_iso8601_ms("1970-01-01T00:00:00Z"), Some(0));
        // Navidrome 返回的就是这种带毫秒的格式。
        assert_eq!(
            parse_iso8601_ms("2024-05-01T12:34:56.789Z"),
            Some(1_714_566_896_789)
        );
        assert_eq!(
            parse_iso8601_ms("2024-05-01T12:34:56Z"),
            Some(1_714_566_896_000)
        );
    }

    #[test]
    fn roundtrip_through_format() {
        for ms in [0, 1_714_566_896_000, 1_600_000_000_000, 2_000_000_000_000] {
            let text = format_iso8601_ms(ms);
            assert_eq!(parse_iso8601_ms(&text), Some(ms), "ms = {ms}");
        }
    }

    #[test]
    fn rejects_garbage() {
        assert_eq!(parse_iso8601_ms(""), None);
        assert_eq!(parse_iso8601_ms("not-a-date"), None);
        assert_eq!(parse_iso8601_ms("2024-13-01T00:00:00Z"), None);
        assert_eq!(parse_iso8601_ms("2024-05-01 12:34:56"), None);
    }
}
