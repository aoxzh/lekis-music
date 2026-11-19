//! 极小的日期时间工具（UTC ISO-8601 字符串）。
//!
//! Subsonic 的 `starred` / `created` 字段是 ISO-8601 字符串，而 workspace 里没有
//! `chrono` / `time`：这里只需要"Unix 毫秒 ↔ UTC 日历"这一件事，所以手写
//! （算法见 Howard Hinnant 的 `days_from_civil` / `civil_from_days`）。
//!
//! `core/crates/lekis-providers/src/datetime.rs` 里有同一套算法的另一份实现
//! （那边是 `pub(crate)`，lekis-node 用不了，也不该为了一个格式化函数去改别人的 crate）。
//! 如果以后多个 crate 都要用，应该把算法提到 `lekis-types`。

/// 当前 Unix 毫秒。
pub(crate) fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as i64)
        .unwrap_or(0)
}

/// Unix 毫秒 → `YYYY-MM-DDTHH:MM:SSZ`（UTC，秒级精度）。
pub(crate) fn iso8601_ms(ms: i64) -> String {
    let secs = ms.div_euclid(1000);
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
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
        assert_eq!(iso8601_ms(0), "1970-01-01T00:00:00Z");
        assert_eq!(iso8601_ms(1_714_566_896_000), "2024-05-01T12:34:56Z");
        // 闰日。
        assert_eq!(iso8601_ms(1_709_164_800_000), "2024-02-29T00:00:00Z");
        // 毫秒被截断，不进位。
        assert_eq!(iso8601_ms(1_714_566_896_999), "2024-05-01T12:34:56Z");
    }

    #[test]
    fn negative_epoch_is_handled() {
        // 1969-12-31T23:59:59Z：div_euclid 保证不会算错。
        assert_eq!(iso8601_ms(-1000), "1969-12-31T23:59:59Z");
    }

    #[test]
    fn now_is_plausible() {
        // 2020-01-01 之后、2100 年之前，避免把 ms / s 搞混。
        let ms = now_ms();
        assert!(ms > 1_577_836_800_000, "now_ms 看起来不是毫秒: {ms}");
        assert!(ms < 4_102_444_800_000, "now_ms 看起来不是毫秒: {ms}");
        assert_eq!(iso8601_ms(ms).len(), 20);
    }
}
