//! 在线补全用的 HTTP 基础件。
//!
//! 只服务三个免 Key 的公开 API（LRCLIB、Cover Art Archive、iTunes Search），所以：
//! - 统一 `User-Agent`（LRCLIB 和 Cover Art Archive 都要求可识别的 UA，MusicBrainz 系更是硬性要求）；
//! - 统一 10 秒超时（ENR-09），超时按 `Network` 上报；
//! - 404 不算错误，返回 `Ok(None)` 让流水线继续问下一个提供方；
//! - 429 → `RateLimited`，403 → `RateLimited`（这三个提供方都是免 Key 的，403 只可能是限流或封 UA），
//!   5xx / 连接失败 → `Network`。
//!
//! 错误信息里只带动作名和状态码，不带 URL（URL 上是用户的搜索词，属于隐私）。

use lekis_types::{ErrorCode, LekisError, Result};
use std::time::Duration;

/// 发给提供方的 `User-Agent`。LRCLIB 明确要求带上客户端标识和站点地址。
pub(crate) const USER_AGENT: &str = concat!(
    "LekisMusic/",
    env!("CARGO_PKG_VERSION"),
    " (https://github.com/lekis-music/lekis)"
);

/// 单次请求超时（ENR-09）。
pub(crate) const TIMEOUT: Duration = Duration::from_secs(10);

/// 连接超时：DNS 或 TCP 卡住时不要白等满 10 秒。
pub(crate) const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

/// 构造共享的 HTTP 客户端（连接池复用 TLS 会话，连续给一张专辑抓封面时差别明显）。
pub(crate) fn client() -> Result<reqwest::Client> {
    reqwest::Client::builder()
        .user_agent(USER_AGENT)
        .timeout(TIMEOUT)
        .connect_timeout(CONNECT_TIMEOUT)
        .build()
        .map_err(|e| LekisError::new(ErrorCode::Internal, format!("构建 HTTP 客户端失败：{e}")))
}

/// `reqwest` 的错误 → [`LekisError`]（去掉 URL，避免把搜索词带进日志）。
pub(crate) fn network(e: reqwest::Error) -> LekisError {
    let code = if e.is_builder() {
        ErrorCode::Internal
    } else {
        ErrorCode::Network
    };
    LekisError::new(code, format!("网络请求失败：{}", e.without_url()))
}

/// HTTP 状态码 → 错误码。
pub(crate) fn map_status(code: u16) -> ErrorCode {
    match code {
        401 => ErrorCode::Auth,
        // 免 Key 的公开 API 返回 403 基本只有一种原因：被限流或者 UA 被封。
        403 => ErrorCode::RateLimited,
        404 => ErrorCode::NotFound,
        // Apple 在被限流时有时给 503（同时带 Retry-After）。
        429 | 503 => ErrorCode::RateLimited,
        500..=599 => ErrorCode::Network,
        _ => ErrorCode::Internal,
    }
}

/// 状态码 → [`LekisError`]。
pub(crate) fn status(code: u16, what: &str) -> LekisError {
    LekisError::new(map_status(code), format!("{what}：HTTP {code}"))
}

/// 带 `User-Agent` 的 GET，返回响应体文本。
///
/// 404 返回 `Ok(None)`（"这个提供方没料"，不是错误）；其余非 2xx 转成错误。
pub(crate) async fn get_text(
    client: &reqwest::Client,
    url: reqwest::Url,
    what: &str,
) -> Result<Option<String>> {
    let response = client.get(url).send().await.map_err(network)?;
    let code = response.status();
    if code.is_success() {
        return response.text().await.map(Some).map_err(network);
    }
    if code.as_u16() == 404 {
        tracing::debug!(target: "lekis_enrich::http", "{what}：未找到（404）");
        return Ok(None);
    }
    if code.as_u16() == 503 || code.as_u16() == 429 {
        tracing::warn!(
            target: "lekis_enrich::http",
            status = code.as_u16(),
            retry_after = response
                .headers()
                .get(reqwest::header::RETRY_AFTER)
                .and_then(|v| v.to_str().ok())
                .unwrap_or(""),
            "{what} 被限流"
        );
    }
    Err(status(code.as_u16(), what))
}

/// 拼地址：`base` 去掉尾部 `/`，再接以 `/` 开头的 `path`。
pub(crate) fn join(base: &str, path: &str) -> Result<reqwest::Url> {
    let base = base.trim_end_matches('/');
    if base.is_empty() {
        return Err(LekisError::invalid("提供方地址为空"));
    }
    reqwest::Url::parse(&format!("{base}{path}"))
        .map_err(|e| LekisError::invalid(format!("提供方地址无法解析：{e}")))
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    #[test]
    fn joins_base_without_dropping_prefix() {
        let url = join("https://lrclib.net/", "/api/get?track_name=a").unwrap();
        assert_eq!(url.as_str(), "https://lrclib.net/api/get?track_name=a");
        assert!(join("", "/api/get").is_err());
    }

    #[test]
    fn status_mapping_matches_policy() {
        assert_eq!(map_status(404), ErrorCode::NotFound);
        assert_eq!(map_status(429), ErrorCode::RateLimited);
        assert_eq!(map_status(403), ErrorCode::RateLimited);
        assert_eq!(map_status(503), ErrorCode::RateLimited);
        assert_eq!(map_status(500), ErrorCode::Network);
        assert_eq!(map_status(502), ErrorCode::Network);
        assert_eq!(map_status(400), ErrorCode::Internal);
    }

    /// UA 里必须有版本号，MusicBrainz / LRCLIB 靠它区分客户端。
    #[test]
    fn user_agent_is_identifiable() {
        assert!(USER_AGENT.starts_with("LekisMusic/"));
        assert!(USER_AGENT.contains("https://"));
    }
}
