//! 鉴权（NOD-04 的 `/api/v1` 设备配对 token + Subsonic 自己的认证）。
//!
//! 两条独立的认证路径，互不影响：
//!
//! 1. **`/api/v1/*`**（Lekis 自有 API）：Bearer token / `X-Lekis-Token` 头。
//!    token 来自 `LEKIS_API_TOKEN`；没设置就随机生成一个并在启动日志里打出来，
//!    这样默认不会暴露一个"无鉴权"的端口。
//! 2. **`/rest/*`**（OpenSubsonic）：Subsonic 协议自己的认证，见
//!    [`AuthConfig::check_subsonic`]：`u` + `t`(md5(password + salt)) + `s`，
//!    或者 `apiKey` 参数，或者明文密码 `p`（仅当 `LEKIS_SUBSONIC_ALLOW_PLAINTEXT` 打开）。
//!
//! `/health` 两条都不走（健康检查不应该需要凭据）。
//!
//! 环境变量：
//! - `LEKIS_API_TOKEN`：`/api/v1` 的 token（默认随机生成并打印）
//! - `LEKIS_SUBSONIC_USER`：Subsonic 用户名（默认 `admin`）
//! - `LEKIS_SUBSONIC_PASSWORD`：Subsonic 密码（默认随机生成并打印）
//! - `LEKIS_SUBSONIC_ALLOW_PLAINTEXT`：设为 `1`/`true`/`yes` 允许 `p=` 明文密码

use crate::md5;
use crate::opensubsonic;
use crate::params::Params;
use crate::AppState;
use axum::extract::{Request, State};
use axum::http::{HeaderMap, StatusCode};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use axum::Json;
use lekis_types::{LekisError, Result};
use serde_json::json;

/// `/api/v1` 的 device-pairing token 头（和 Bearer 等价）。
pub(crate) const API_TOKEN_HEADER: &str = "x-lekis-token";

/// 认证配置。
#[derive(Debug, Clone)]
pub(crate) struct AuthConfig {
    /// `/api/v1` 的 token。
    api_token: String,
    /// Subsonic 用户名。
    subsonic_user: String,
    /// Subsonic 密码。
    subsonic_password: String,
    /// 是否允许 Subsonic 明文密码（`p` 参数）。
    allow_plaintext: bool,
}

impl AuthConfig {
    /// 从环境变量构造。缺的 token / 密码随机生成并**写进日志**（生产环境请显式设置）。
    pub(crate) fn from_env() -> Self {
        let api_token = env_or_generate("LEKIS_API_TOKEN", generate_token);
        let subsonic_user = std::env::var("LEKIS_SUBSONIC_USER")
            .ok()
            .filter(|user| !user.trim().is_empty())
            .unwrap_or_else(|| "admin".to_string());
        let subsonic_password = env_or_generate("LEKIS_SUBSONIC_PASSWORD", generate_token);
        let allow_plaintext = matches!(
            std::env::var("LEKIS_SUBSONIC_ALLOW_PLAINTEXT")
                .unwrap_or_default()
                .trim()
                .to_ascii_lowercase()
                .as_str(),
            "1" | "true" | "yes"
        );
        if allow_plaintext {
            tracing::warn!(
                target: "node",
                "LEKIS_SUBSONIC_ALLOW_PLAINTEXT 已打开：Subsonic 客户端可以用 `p=` 明文密码认证，\
                 请不要把 /rest 暴露到公网"
            );
        }
        tracing::info!(
            target: "node",
            user = %subsonic_user,
            "OpenSubsonic 认证：/rest/* 用 u + t/s 或 apiKey；/api/v1 用 Authorization: Bearer <LEKIS_API_TOKEN>"
        );
        Self {
            api_token,
            subsonic_user,
            subsonic_password,
            allow_plaintext,
        }
    }

    /// 测试用：直接给一组固定凭据。
    #[cfg(test)]
    pub(crate) fn for_tests(token: &str, user: &str, password: &str) -> Self {
        Self {
            api_token: token.to_string(),
            subsonic_user: user.to_string(),
            subsonic_password: password.to_string(),
            allow_plaintext: true,
        }
    }

    /// `/api/v1` 的 token（测试里用来拼期望值）。
    #[cfg(test)]
    pub(crate) fn api_token(&self) -> &str {
        &self.api_token
    }

    /// Subsonic 密码（测试里用来算 `t = md5(password + salt)`）。
    #[cfg(test)]
    pub(crate) fn subsonic_password(&self) -> &str {
        &self.subsonic_password
    }

    /// Subsonic 用户名（`getUser` 接口要回它）。
    pub(crate) fn subsonic_user(&self) -> &str {
        &self.subsonic_user
    }

    /// `/api/v1`：`Authorization: Bearer <token>` 或 `X-Lekis-Token: <token>`。
    pub(crate) fn check_api(&self, headers: &HeaderMap) -> bool {
        if let Some(token) = bearer_token(headers) {
            if secret_eq(token, &self.api_token) {
                return true;
            }
        }
        if let Some(token) = header_value(headers, API_TOKEN_HEADER) {
            if secret_eq(token, &self.api_token) {
                return true;
            }
        }
        false
    }

    /// Subsonic 认证。
    ///
    /// 优先级：
    /// 1. `X-Lekis-Token` 头或 `apiKey` 参数等于 [`AuthConfig::api_token`]
    ///    （OpenSubsonic 的 apiKey 认证，客户端不用保存密码）；
    /// 2. `u` + `t` + `s`：`t` 必须等于 `md5(password + s)`；
    /// 3. `u` + `p`：明文密码，仅当 `allow_plaintext`；支持 `enc:` 前缀的十六进制。
    pub(crate) fn check_subsonic(&self, params: &Params, headers: &HeaderMap) -> Result<()> {
        if let Some(token) = header_value(headers, API_TOKEN_HEADER) {
            if secret_eq(token, &self.api_token) {
                return Ok(());
            }
        }
        if let Some(api_key) = params.get("apiKey") {
            if secret_eq(api_key, &self.api_token) {
                return Ok(());
            }
            // apiKey 给错了就不要回退到密码认证：那多半是配置错误，直接报错更好排查。
            return Err(auth_error("invalid apiKey"));
        }

        let Some(user) = params.get("u") else {
            return Err(LekisError::invalid(
                "missing credentials: send u+t+s, apiKey, or X-Lekis-Token",
            ));
        };
        if !secret_eq(user, &self.subsonic_user) {
            return Err(auth_error("wrong username or password"));
        }

        if let Some(token) = params.get("t") {
            let salt = params.get("s").unwrap_or_default();
            if salt.is_empty() {
                return Err(LekisError::invalid(
                    "missing parameter: s (salt is required together with t)",
                ));
            }
            let expected = md5::hex_digest(format!("{}{salt}", self.subsonic_password).as_bytes());
            if secret_eq(&token.to_ascii_lowercase(), &expected) {
                return Ok(());
            }
            return Err(auth_error("wrong username or password"));
        }

        if let Some(password) = params.get("p") {
            if !self.allow_plaintext {
                return Err(LekisError::auth_not_allowed());
            }
            let password = decode_password(password)?;
            if secret_eq(&password, &self.subsonic_password) {
                return Ok(());
            }
            return Err(auth_error("wrong username or password"));
        }

        Err(LekisError::invalid(
            "missing credentials: send u+t+s, apiKey, or X-Lekis-Token",
        ))
    }
}

/// 认证失败的统一错误（Subsonic 错误码 40）。
fn auth_error(message: &str) -> LekisError {
    LekisError::new(lekis_types::ErrorCode::Auth, message)
}

/// 扩展：`p=` 明文认证被关掉时的错误。
trait AuthNotAllowed {
    fn auth_not_allowed() -> Self;
}

impl AuthNotAllowed for LekisError {
    fn auth_not_allowed() -> Self {
        LekisError::new(
            lekis_types::ErrorCode::Auth,
            "plaintext password authentication is disabled; use token auth (u+t+s) or apiKey",
        )
    }
}

/// 读环境变量，空值或缺失时用生成的值，并把生成的值打进日志。
fn env_or_generate(key: &str, generate: impl FnOnce() -> String) -> String {
    match std::env::var(key) {
        Ok(value) if !value.trim().is_empty() => value,
        _ => {
            let value = generate();
            tracing::warn!(
                target: "node",
                variable = key,
                value = %value,
                "环境变量未设置，已随机生成（重启后会变；长期使用请显式设置）"
            );
            value
        }
    }
}

/// 生成一个随机 token（UUIDv4 去掉横线，128 位熵）。
fn generate_token() -> String {
    format!("lekis-{}", uuid::Uuid::new_v4().simple())
}

/// 取 `HeaderMap` 里某个头（大小写不敏感，值必须是合法 UTF-8）。
fn header_value<'a>(headers: &'a HeaderMap, name: &str) -> Option<&'a str> {
    headers.get(name).and_then(|value| value.to_str().ok())
}

/// 取 `Authorization: Bearer <token>` 里的 token。
fn bearer_token(headers: &HeaderMap) -> Option<&str> {
    let value = header_value(headers, "authorization")?;
    let (scheme, token) = value.split_once(' ')?;
    if !scheme.eq_ignore_ascii_case("bearer") {
        return None;
    }
    let token = token.trim();
    if token.is_empty() {
        None
    } else {
        Some(token)
    }
}

/// 常量时间比较，避免 token 逐字节比较泄漏长度以外的信息（长度不同直接返回）。
fn secret_eq(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b) {
        diff |= x ^ y;
    }
    diff == 0
}

/// 解码 `enc:68656c6c6f`（Subsonic 的十六进制明文密码写法）。没有 `enc:` 前缀时原样返回。
fn decode_password(raw: &str) -> Result<String> {
    let Some(hex) = raw.strip_prefix("enc:") else {
        return Ok(raw.to_string());
    };
    let bytes = hex.trim().as_bytes();
    let invalid = || LekisError::invalid("parameter p: enc: prefix must be followed by hex digits");
    if bytes.len() % 2 != 0 {
        return Err(invalid());
    }
    let mut out = Vec::with_capacity(bytes.len() / 2);
    for pair in bytes.chunks_exact(2) {
        let hi = (pair[0] as char).to_digit(16).ok_or_else(invalid)?;
        let lo = (pair[1] as char).to_digit(16).ok_or_else(invalid)?;
        out.push((hi * 16 + lo) as u8);
    }
    String::from_utf8(out).map_err(|_| invalid())
}

/// `/api/v1/*` 中间件：校验 device token，失败返回 401。
pub(crate) async fn require_api_token(
    State(state): State<AppState>,
    request: Request,
    next: Next,
) -> Response {
    if state.auth.check_api(request.headers()) {
        return next.run(request).await;
    }
    (
        StatusCode::UNAUTHORIZED,
        Json(json!({
            "code": "auth",
            "message": "missing or invalid API token: send `Authorization: Bearer <LEKIS_API_TOKEN>`\
                        or `X-Lekis-Token: <LEKIS_API_TOKEN>`",
        })),
    )
        .into_response()
}

/// `/rest/*` 中间件：Subsonic 认证。失败时仍然是 HTTP 200 + `status: "failed"`，
/// 因为 Subsonic 客户端只看响应体（见 `opensubsonic` 模块头部的说明）。
pub(crate) async fn subsonic_auth(
    State(state): State<AppState>,
    request: Request,
    next: Next,
) -> Response {
    let params = Params::parse(request.uri().query().unwrap_or_default());
    match state.auth.check_subsonic(&params, request.headers()) {
        Ok(()) => next.run(request).await,
        Err(e) => opensubsonic::error_response(&e),
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use axum::http::HeaderValue;

    fn config() -> AuthConfig {
        AuthConfig::for_tests("token-123", "admin", "hunter2")
    }

    fn token_params(salt: &str) -> Params {
        let token = md5::hex_digest(format!("hunter2{salt}").as_bytes());
        Params::parse(&format!(
            "u=admin&t={token}&s={salt}&v=1.16.1&c=test&f=json"
        ))
    }

    #[test]
    fn api_token_accepts_bearer_and_header() {
        let cfg = config();
        let mut headers = HeaderMap::new();
        assert!(!cfg.check_api(&headers), "没有头就是没认证");
        headers.insert(
            "authorization",
            HeaderValue::from_static("Bearer token-123"),
        );
        assert!(cfg.check_api(&headers));

        let mut headers = HeaderMap::new();
        headers.insert("authorization", HeaderValue::from_static("Bearer wrong"));
        assert!(!cfg.check_api(&headers));
        headers.insert(API_TOKEN_HEADER, HeaderValue::from_static("token-123"));
        assert!(cfg.check_api(&headers));
    }

    #[test]
    fn subsonic_token_auth() {
        let cfg = config();
        let headers = HeaderMap::new();
        assert!(cfg
            .check_subsonic(&token_params("abc123"), &headers)
            .is_ok());

        let bad = Params::parse("u=admin&t=deadbeef&s=abc123");
        let err = cfg
            .check_subsonic(&bad, &headers)
            .expect_err("错 token 必须失败");
        assert_eq!(err.code, lekis_types::ErrorCode::Auth);

        let no_salt = Params::parse("u=admin&t=deadbeef");
        let err = cfg
            .check_subsonic(&no_salt, &headers)
            .expect_err("只有 t 没有 s");
        assert_eq!(err.code, lekis_types::ErrorCode::InvalidArgument);

        let wrong_user = Params::parse("u=root&t=deadbeef&s=abc");
        assert!(cfg.check_subsonic(&wrong_user, &headers).is_err());

        let nothing = Params::parse("v=1.16.1&c=test");
        let err = cfg
            .check_subsonic(&nothing, &headers)
            .expect_err("没有任何凭据");
        assert_eq!(err.code, lekis_types::ErrorCode::InvalidArgument);
    }

    #[test]
    fn subsonic_api_key_and_plaintext() {
        let cfg = config();
        let headers = HeaderMap::new();
        assert!(cfg
            .check_subsonic(&Params::parse("apiKey=token-123"), &headers)
            .is_ok());
        assert!(cfg
            .check_subsonic(&Params::parse("apiKey=nope"), &headers)
            .is_err());
        // 明文密码（测试配置允许）。
        assert!(cfg
            .check_subsonic(&Params::parse("u=admin&p=hunter2"), &headers)
            .is_ok());
        // `enc:` 十六进制等价于明文。
        let enc = format!(
            "u=admin&p=enc:{}",
            "hunter2"
                .bytes()
                .map(|b| format!("{b:02x}"))
                .collect::<String>()
        );
        assert!(cfg.check_subsonic(&Params::parse(&enc), &headers).is_ok());
        assert!(cfg
            .check_subsonic(&Params::parse("u=admin&p=wrong"), &headers)
            .is_err());
    }

    #[test]
    fn plaintext_can_be_disabled() {
        let mut cfg = config();
        cfg.allow_plaintext = false;
        let headers = HeaderMap::new();
        let err = cfg
            .check_subsonic(&Params::parse("u=admin&p=hunter2"), &headers)
            .expect_err("明文认证已关闭");
        assert_eq!(err.code, lekis_types::ErrorCode::Auth);
    }

    #[test]
    fn enc_password_rejects_garbage() {
        assert_eq!(decode_password("hunter2").unwrap(), "hunter2");
        assert_eq!(decode_password("enc:68").unwrap(), "h");
        // 奇数个十六进制位。
        assert_eq!(
            decode_password("enc:686").unwrap_err().code,
            lekis_types::ErrorCode::InvalidArgument
        );
        // 不是十六进制字符。
        assert!(decode_password("enc:zz").is_err());
        // 合法十六进制但不是合法 UTF-8。
        assert!(decode_password("enc:ff").is_err());
    }

    #[test]
    fn bearer_parsing_is_case_insensitive() {
        let mut headers = HeaderMap::new();
        headers.insert("authorization", HeaderValue::from_static("bearer abc"));
        assert_eq!(bearer_token(&headers), Some("abc"));
        headers.insert("authorization", HeaderValue::from_static("Basic abc"));
        assert_eq!(bearer_token(&headers), None);
        headers.insert("authorization", HeaderValue::from_static("Bearer "));
        assert_eq!(bearer_token(&headers), None);
    }
}
