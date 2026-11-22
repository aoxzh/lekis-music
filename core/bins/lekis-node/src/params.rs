//! Subsonic 查询参数的**宽容**解析（NOD-03）。
//!
//! Subsonic 客户端会传一堆我们不需要的参数（`c`、`v`、`f`、`callback`、`format`……），
//! 而且**同一个键可以出现多次**（`star?id=1&id=2`）。所以这里既不反序列化成 struct
//! （未知字段会让整个请求失败），也不直接塞进 `HashMap`（重复键会丢），
//! 而是保留原始键值对序列：
//!
//! - 未知参数：直接忽略；
//! - 重复参数：用 [`Params::get_all`] 取全部；
//! - 缺少必需参数：用 [`Params::require`]，它会变成 `invalid_argument`，
//!   再被映射成 Subsonic 的错误码 10；
//! - 数字 / 布尔参数：解析失败就退化成默认值（客户端偶尔会传 `?`、`-1`、空串）。

use lekis_types::{LekisError, Result};

/// 一次请求的查询参数（保持原始顺序，允许重复键）。
#[derive(Debug, Clone, Default)]
pub(crate) struct Params(Vec<(String, String)>);

impl Params {
    /// 从 `a=1&b=2` 这样的原始查询串解析（百分号解码，`+` 当作空格）。
    pub(crate) fn parse(query: &str) -> Self {
        Self(
            url::form_urlencoded::parse(query.as_bytes())
                .into_owned()
                .collect(),
        )
    }

    /// 从 axum 的 `RawQuery` 提取器的值构造。
    ///
    /// 参数是 `Option<String>` 而不是 `RawQuery`：handler 里解构写成
    /// `RawQuery(raw): RawQuery` 后 `raw` 就是 `Option<String>`，这样能直接借过去。
    pub(crate) fn from_raw(raw: &Option<String>) -> Self {
        Self::parse(raw.as_deref().unwrap_or_default())
    }

    /// 取第一个值。
    pub(crate) fn get(&self, key: &str) -> Option<&str> {
        self.0
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
    }

    /// 取所有值（`star?id=1&id=2` 这种用法）。
    pub(crate) fn get_all(&self, key: &str) -> Vec<&str> {
        self.0
            .iter()
            .filter(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
            .collect()
    }

    /// 取一个必需的参数。空值和缺失都算缺失。
    pub(crate) fn require(&self, key: &str) -> Result<&str> {
        match self.get(key) {
            Some(value) if !value.is_empty() => Ok(value),
            _ => Err(LekisError::invalid(format!("missing parameter: {key}"))),
        }
    }

    /// 取一个 `u32`，缺失或解析失败时用默认值。
    pub(crate) fn u32_or(&self, key: &str, default: u32) -> u32 {
        self.get(key)
            .and_then(|value| value.trim().parse::<u32>().ok())
            .unwrap_or(default)
    }

    /// 取一个布尔值，缺失或无法识别时用默认值。`true`/`1`/`yes` 视为真。
    pub(crate) fn bool_or(&self, key: &str, default: bool) -> bool {
        match self.get(key).map(str::trim) {
            Some(value) if value.eq_ignore_ascii_case("true") || value == "1" => true,
            Some(value) if value.eq_ignore_ascii_case("false") || value == "0" => false,
            Some(value) if value.eq_ignore_ascii_case("yes") => true,
            Some(value) if value.eq_ignore_ascii_case("no") => false,
            _ => default,
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    #[test]
    fn unknown_and_repeated_keys_are_tolerated() {
        let p = Params::parse("id=1&id=2&c=test&v=1.16.1&f=json&weird=%E4%B8%AD");
        assert_eq!(p.get("id"), Some("1"));
        assert_eq!(p.get_all("id"), vec!["1", "2"]);
        assert_eq!(p.get("weird"), Some("中"));
        assert_eq!(p.get("missing"), None);
        assert!(p.require("c").is_ok());
    }

    #[test]
    fn numeric_and_boolean_defaults_are_graceful() {
        let p = Params::parse("size=-1&offset=abc&flag=yes&off=false");
        assert_eq!(p.u32_or("size", 10), 10);
        assert_eq!(p.u32_or("offset", 3), 3);
        assert!(p.bool_or("flag", false));
        assert!(!p.bool_or("off", true));
        assert!(p.bool_or("absent", true));
    }

    #[test]
    fn missing_or_empty_required_key_is_invalid_argument() {
        let p = Params::parse("u=admin&id=");
        let err = p.require("id").expect_err("空值算缺失");
        assert_eq!(err.code, lekis_types::ErrorCode::InvalidArgument);
        assert!(p.require("nope").is_err());
    }

    #[test]
    fn plus_and_percent_encoding() {
        // `+` 是空格，`%2B` 才是加号（老客户端会用后者传密码里的 +）。
        let p = Params::parse("q=jay+chou&p=a%2Bb");
        assert_eq!(p.get("q"), Some("jay chou"));
        assert_eq!(p.get("p"), Some("a+b"));
    }
}
