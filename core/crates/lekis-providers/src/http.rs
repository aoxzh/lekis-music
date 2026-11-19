//! HTTP 公共部分：客户端构造、错误映射、URL 拼接。
//!
//! 所有媒体服务器客户端都走这里，保证：
//! - 统一超时（`TIMEOUT`）和 `User-Agent`；
//! - HTTP 状态码统一映射到 [`ErrorCode`]（429 → `RateLimited`、5xx → `Network`、404 → `NotFound`……）；
//! - **错误信息里不出现 URL**：URL 上有 `X-Plex-Token`、Subsonic 的 `t`/`s`，日志和错误里一旦带上就等于泄露凭据。
//!   所以这里一律用 `reqwest::Error::without_url()` 去掉 URL 再取信息。

use lekis_types::{ErrorCode, LekisError, Result};
use reqwest::Url;
use std::time::Duration;

/// 发给服务器的 `User-Agent`（Plex 和 Cover Art Archive 都要求可识别的 UA）。
pub(crate) const USER_AGENT: &str = concat!(
    "LekisMusic/",
    env!("CARGO_PKG_VERSION"),
    " (+https://github.com/lekis-music/lekis)"
);

/// 单次请求的总超时。
pub(crate) const TIMEOUT: Duration = Duration::from_secs(15);

/// 连接超时（服务器不可达时不要卡满 15 秒）。
pub(crate) const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

/// 构造共享的 HTTP 客户端。
///
/// 单独建客户端而不是用 `reqwest::get`：连接池可以复用 TLS 会话，局域网里连续拉几百首时差别明显。
pub(crate) fn client() -> Result<reqwest::Client> {
    reqwest::Client::builder()
        .user_agent(USER_AGENT)
        .timeout(TIMEOUT)
        .connect_timeout(CONNECT_TIMEOUT)
        .build()
        .map_err(|e| LekisError::new(ErrorCode::Internal, format!("构建 HTTP 客户端失败：{e}")))
}

/// 把 `reqwest` 的错误映射成 [`LekisError`]，并且**去掉 URL**（里面可能有 token）。
pub(crate) fn network(e: reqwest::Error) -> LekisError {
    let code = if e.is_builder() {
        ErrorCode::Internal
    } else {
        // 超时、连接被拒、DNS 失败、响应体截断、TLS 失败……对调用方都是"网络不通"。
        ErrorCode::Network
    };
    LekisError::new(code, format!("网络请求失败：{}", e.without_url()))
}

/// HTTP 状态码 → 错误。
///
/// `what` 是给日志用的动作名（例如 `"opensubsonic ping"`），不包含地址和凭据。
pub(crate) fn status(code: u16, what: &str) -> LekisError {
    let error_code = match code {
        401 => ErrorCode::Auth,
        403 => ErrorCode::PermissionDenied,
        404 => ErrorCode::NotFound,
        429 => ErrorCode::RateLimited,
        500..=599 => ErrorCode::Network,
        _ => ErrorCode::Internal,
    };
    LekisError::new(error_code, format!("{what}：HTTP {code}"))
}

/// 检查响应状态码；非 2xx 转成 [`LekisError`]。
pub(crate) fn ensure_status(resp: &reqwest::Response, what: &str) -> Result<()> {
    let code = resp.status();
    if code.is_success() {
        return Ok(());
    }
    // 429 和 503 有时候带 `Retry-After`，以后做指数退避时用得上，先记在 tracing 里。
    if code.as_u16() == 429 || code.as_u16() == 503 {
        tracing::warn!(
            target: "lekis_providers::http",
            status = code.as_u16(),
            retry_after = resp
                .headers()
                .get(reqwest::header::RETRY_AFTER)
                .and_then(|v| v.to_str().ok())
                .unwrap_or(""),
            "{what} 被限流"
        );
    }
    Err(status(code.as_u16(), what))
}

/// 拼出完整地址：`base` 去掉尾部 `/`，再接上以 `/` 开头的 `path`。
///
/// 不用 [`Url::join`]：它会把 base 里的路径前缀（例如 Navidrome 的 `/music`）当成可替换部分丢掉。
pub(crate) fn join(base: &str, path: &str) -> Result<Url> {
    let base = base.trim_end_matches('/');
    if base.is_empty() {
        return Err(LekisError::invalid("服务器地址为空"));
    }
    Url::parse(&format!("{base}{path}"))
        .map_err(|e| LekisError::invalid(format!("服务器地址无法解析：{e}")))
}

/// 把字节编码成小写十六进制（历史 Subsonic 服务器的 `p=enc:<hex>` 用）。
pub(crate) fn hex_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        // `from_digit` 对 0..16 一定成功；失败时用 '0' 兜底而不是 unwrap。
        out.push(char::from_digit(u32::from(byte >> 4), 16).unwrap_or('0'));
        out.push(char::from_digit(u32::from(byte & 0x0f), 16).unwrap_or('0'));
    }
    out
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    #[test]
    fn join_keeps_base_path_prefix() {
        let url = join("https://nas.local:4533/music/", "/rest/ping.view").unwrap();
        assert_eq!(url.as_str(), "https://nas.local:4533/music/rest/ping.view");
    }

    #[test]
    fn status_mapping() {
        assert_eq!(status(401, "x").code, ErrorCode::Auth);
        assert_eq!(status(403, "x").code, ErrorCode::PermissionDenied);
        assert_eq!(status(404, "x").code, ErrorCode::NotFound);
        assert_eq!(status(429, "x").code, ErrorCode::RateLimited);
        assert_eq!(status(502, "x").code, ErrorCode::Network);
        assert_eq!(status(418, "x").code, ErrorCode::Internal);
    }

    #[test]
    fn empty_base_is_invalid() {
        assert_eq!(
            join("", "/rest/ping.view").unwrap_err().code,
            ErrorCode::InvalidArgument
        );
    }

    #[test]
    fn hex_encoding() {
        assert_eq!(hex_encode(b"abc"), "616263");
        assert_eq!(hex_encode(&[0x00, 0xff]), "00ff");
    }
}
