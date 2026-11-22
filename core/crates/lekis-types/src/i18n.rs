//! 核心返回给界面的文字的语种（简体中文默认，English 对照）。
//!
//! 错误详情、状态原因、默认名称这类会被 App 原样显示的文字都通过 [`tr!`](crate::tr)
//! 生成：平台层在界面语言变化时调用 [`set_english`]，核心之后产生的文字就跟着切换。
//! 日志（`tracing`）不走这里。

use std::sync::atomic::{AtomicBool, Ordering};

static ENGLISH: AtomicBool = AtomicBool::new(false);

/// 界面语言切换时由平台层调用。
pub fn set_english(english: bool) {
    ENGLISH.store(english, Ordering::Relaxed);
}

/// 当前界面语言是否为英文。
pub fn is_english() -> bool {
    ENGLISH.load(Ordering::Relaxed)
}

/// 按界面语言选一句话：`tr!("中文", "English")`，
/// 带参数时和 `format!` 一样：`tr!("文件 {} 不存在", "File {} not found", path)`，
/// 也支持内联捕获：`tr!("读取失败：{e}", "Read failed: {e}")`。结果总是 `String`。
#[macro_export]
macro_rules! tr {
    ($zh:tt, $en:tt $(,)?) => {
        if $crate::i18n::is_english() {
            ::std::format!($en)
        } else {
            ::std::format!($zh)
        }
    };
    ($zh:tt, $en:tt, $($arg:tt)+) => {
        if $crate::i18n::is_english() {
            ::std::format!($en, $($arg)+)
        } else {
            ::std::format!($zh, $($arg)+)
        }
    };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn picks_language_and_formats() {
        let n = 3;
        let path = "a.flac";
        set_english(false);
        assert_eq!(crate::tr!("共 {n} 首", "{n} tracks"), "共 3 首");
        assert_eq!(
            crate::tr!("文件 {} 不存在", "File {} not found", path),
            "文件 a.flac 不存在"
        );
        set_english(true);
        assert_eq!(crate::tr!("共 {n} 首", "{n} tracks"), "3 tracks");
        assert_eq!(
            crate::tr!("文件 {} 不存在", "File {} not found", path),
            "File a.flac not found"
        );
        set_english(false);
    }
}
