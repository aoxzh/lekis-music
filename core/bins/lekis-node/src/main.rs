//! Lekis NAS 节点（NOD-01~09）。**可选组件**：不部署它，客户端也能使用全部核心功能。
//!
//! 配置（环境变量）：
//! - `LEKIS_DATA_DIR`：数据目录，默认 `/data`
//! - `LEKIS_CACHE_DIR`：缓存目录，默认 `/cache`
//! - `LEKIS_BIND`：监听地址，默认 `0.0.0.0:4533`（和 Navidrome 默认端口一致，方便替换）
//! - `LEKIS_DEVICE_NAME`：设备名，默认 `lekis-node`
//! - `RUST_LOG`：日志级别
//!
//! 鉴权（NOD-04，详见 `auth` 模块）：
//! - `/api/v1/*`：`Authorization: Bearer <LEKIS_API_TOKEN>` 或 `X-Lekis-Token: <token>`；
//!   `LEKIS_API_TOKEN` 没有设置时启动时随机生成并打日志。
//! - `/rest/*`：Subsonic 自己的认证（`u` + `t`/`s`，或 `apiKey`），用户名/密码来自
//!   `LEKIS_SUBSONIC_USER`（默认 `admin`）/ `LEKIS_SUBSONIC_PASSWORD`（默认随机生成并打日志）。
//! - `/health`：两条都不走（健康检查不需要凭据）。
//!
//! 路由：
//! - `/health`：健康检查
//! - `/rest/*`：OpenSubsonic API（NOD-03），让现有的 Subsonic 客户端直接可用
//! - `/api/v1/*`：Lekis 自有 API（NOD-04），给 Lekis 客户端用（同步、远程控制）

mod auth;
mod datetime;
mod md5;
mod opensubsonic;
mod params;
mod scan;

use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::middleware;
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::{Json, Router};
use lekis_core::{CoreConfig, LekisCore, PlatformKind, PlatformServices};
use lekis_types::{LekisError, TrackQuery, TrackSort};
use serde::Deserialize;
use std::path::PathBuf;
use std::sync::Arc;

/// 所有 handler 共享的状态。
#[derive(Clone)]
pub(crate) struct AppState {
    /// 核心门面。
    pub(crate) core: Arc<LekisCore>,
    /// 认证配置（`/api/v1` 的 token、Subsonic 的用户名 / 密码）。
    pub(crate) auth: Arc<auth::AuthConfig>,
    /// 扫描状态（`getScanStatus` / `startScan` 用）。
    pub(crate) scan: Arc<scan::ScanTracker>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    let env = |k: &str, d: &str| std::env::var(k).unwrap_or_else(|_| d.to_string());
    let config = CoreConfig {
        data_dir: PathBuf::from(env("LEKIS_DATA_DIR", "/data")),
        cache_dir: PathBuf::from(env("LEKIS_CACHE_DIR", "/cache")),
        device_name: env("LEKIS_DEVICE_NAME", "lekis-node"),
        platform: PlatformKind::Node,
        worker_threads: None,
    };
    let bind = env("LEKIS_BIND", "0.0.0.0:4533");

    // TODO(NOD-01)：凭据存储改成加密的本地文件。
    let core = LekisCore::with_runtime(
        config,
        PlatformServices::in_memory(),
        tokio::runtime::Handle::current(),
    )?;

    // 扫描进度靠事件推送（`LekisCore::start_scan` 立即返回），这里注册跟踪器。
    let scan = Arc::new(scan::ScanTracker::default());
    core.add_listener(scan.clone());

    let state = AppState {
        core: Arc::new(core),
        auth: Arc::new(auth::AuthConfig::from_env()),
        scan,
    };

    let app = app(state);

    let listener = tokio::net::TcpListener::bind(&bind).await?;
    tracing::info!(%bind, "lekis-node listening");
    axum::serve(listener, app)
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await?;
    Ok(())
}

/// 组装路由。单独抽出来是为了让测试能直接用 `Router` 打（不起真服务）。
fn app(state: AppState) -> Router {
    // `/api/v1` 走设备配对 token（NOD-04）。
    let api = Router::new()
        .route("/tracks", get(list_tracks))
        .route("/search", get(search))
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            auth::require_api_token,
        ));

    // `/rest` 走 Subsonic 自己的认证（u + t/s 或 apiKey）。
    let rest = opensubsonic::router().route_layer(middleware::from_fn_with_state(
        state.clone(),
        auth::subsonic_auth,
    ));

    Router::new()
        .route("/health", get(health))
        .nest("/rest", rest)
        .nest("/api/v1", api)
        .with_state(state)
}

/// 健康检查：不鉴权（负载均衡器和容器探针要用）。
async fn health() -> &'static str {
    "ok"
}

/// 把核心错误转成 HTTP 响应。
pub(crate) struct ApiError(LekisError);

impl From<LekisError> for ApiError {
    fn from(e: LekisError) -> Self {
        Self(e)
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        use lekis_types::ErrorCode as C;
        let status = match self.0.code {
            C::NotFound => StatusCode::NOT_FOUND,
            C::InvalidArgument => StatusCode::BAD_REQUEST,
            C::Auth => StatusCode::UNAUTHORIZED,
            C::PermissionDenied => StatusCode::FORBIDDEN,
            C::NotImplemented | C::Unsupported => StatusCode::NOT_IMPLEMENTED,
            C::RateLimited => StatusCode::TOO_MANY_REQUESTS,
            _ => StatusCode::INTERNAL_SERVER_ERROR,
        };
        let body =
            Json(serde_json::json!({ "code": self.0.code.as_str(), "message": self.0.message }));
        (status, body).into_response()
    }
}

#[derive(Deserialize)]
struct Page {
    #[serde(default)]
    offset: u32,
    #[serde(default = "default_limit")]
    limit: u32,
}

fn default_limit() -> u32 {
    100
}

async fn list_tracks(
    State(s): State<AppState>,
    Query(p): Query<Page>,
) -> Result<impl IntoResponse, ApiError> {
    let rows = s
        .core
        .list_tracks(TrackQuery {
            sort: TrackSort::Title,
            offset: p.offset,
            limit: p.limit,
        })
        .await?;
    Ok(Json(rows))
}

#[derive(Deserialize)]
struct SearchQuery {
    q: String,
}

async fn search(
    State(s): State<AppState>,
    Query(q): Query<SearchQuery>,
) -> Result<impl IntoResponse, ApiError> {
    Ok(Json(s.core.search(q.q, 50).await?))
}

/// 测试辅助：用临时目录搭一个完整的 `Router`（**不监听端口**）。
#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
pub(crate) mod test_support {
    use super::*;

    /// 一个临时数据目录 + 指向它的 `Router`。
    pub(crate) struct TestApp {
        /// 组装好的路由（`/health`、`/rest`、`/api/v1`）。
        pub(crate) router: Router,
        /// 认证配置（测试要知道 token 和密码来拼请求）。
        pub(crate) auth: Arc<auth::AuthConfig>,
        /// 临时数据目录，drop 时删掉。
        root: PathBuf,
    }

    impl TestApp {
        /// 拼一个带有效凭据的 `/rest/<endpoint>` URI。
        ///
        /// `endpoint` 里可以自带查询串（`getAlbumList2?type=newest`），`extra` 会接在后面。
        /// 用明文密码（`p=`）而不是 `t=`/`s=` 摘要：测试只关心「认证通过之后」的行为，
        /// 摘要算法的正确性由 `auth` / `opensubsonic` 模块自己的测试覆盖。
        pub(crate) fn rest_uri(&self, endpoint: &str, extra: &str) -> String {
            let (path, inline_query) = match endpoint.split_once('?') {
                Some((path, query)) => (path, query.to_string()),
                None => (endpoint, String::new()),
            };
            let mut query = String::new();
            for part in [
                inline_query.as_str(),
                &format!(
                    "u=admin&p={}&v=1.16.1&c=lekis-node-test&f=json",
                    self.auth.subsonic_password()
                ),
                extra,
            ] {
                if part.is_empty() {
                    continue;
                }
                if !query.is_empty() {
                    query.push('&');
                }
                query.push_str(part);
            }
            format!("/rest/{path}?{query}")
        }
    }

    impl Drop for TestApp {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    /// 建一个测试 app。必须在 tokio 运行时里调用（`LekisCore` 要借用当前 runtime）。
    pub(crate) fn test_app(name: &str) -> TestApp {
        let root = std::env::temp_dir().join(format!(
            "lekis-node-test-{name}-{}-{}",
            std::process::id(),
            datetime::now_ms()
        ));
        let _ = std::fs::remove_dir_all(&root);
        let config = CoreConfig {
            data_dir: root.join("data"),
            cache_dir: root.join("cache"),
            device_name: "test-node".into(),
            platform: PlatformKind::Node,
            worker_threads: Some(2),
        };
        let core = LekisCore::with_runtime(
            config,
            PlatformServices::in_memory(),
            tokio::runtime::Handle::current(),
        );
        let core = match core {
            Ok(core) => core,
            Err(e) => {
                let _ = std::fs::remove_dir_all(&root);
                panic!("无法创建测试核心: {e}");
            }
        };
        let scan = Arc::new(scan::ScanTracker::default());
        core.add_listener(scan.clone());
        let auth = Arc::new(auth::AuthConfig::for_tests(
            "test-token",
            "admin",
            "hunter2",
        ));
        let state = AppState {
            core: Arc::new(core),
            auth: auth.clone(),
            scan,
        };
        TestApp {
            router: app(state),
            auth,
            root,
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::test_support::test_app;
    use super::*;
    use axum::body::{to_bytes, Body};
    use axum::http::{Request, StatusCode};
    use tower::ServiceExt;

    async fn get_json(
        app: &Router,
        uri: &str,
        token: Option<&str>,
    ) -> (StatusCode, serde_json::Value) {
        let mut builder = Request::builder().uri(uri);
        if let Some(token) = token {
            builder = builder.header("authorization", format!("Bearer {token}"));
        }
        let response = app
            .clone()
            .oneshot(builder.body(Body::empty()).unwrap())
            .await
            .unwrap();
        let status = response.status();
        let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
        let body = serde_json::from_slice(&bytes).unwrap_or(serde_json::Value::Null);
        (status, body)
    }

    #[tokio::test]
    async fn api_v1_requires_token() {
        let app = test_app("api-token");
        let token = app.auth.api_token().to_string();

        let (status, body) = get_json(&app.router, "/api/v1/tracks", None).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        assert_eq!(body["code"], "auth");

        let (status, body) = get_json(&app.router, "/api/v1/tracks", Some("wrong")).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        assert_eq!(body["code"], "auth");

        let (status, _) = get_json(&app.router, "/api/v1/tracks", Some(&token)).await;
        assert_eq!(status, StatusCode::OK);
    }

    #[tokio::test]
    async fn api_v1_accepts_x_lekis_token_header() {
        let app = test_app("api-header");
        let response = app
            .router
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/v1/search?q=jay")
                    .header("x-lekis-token", "test-token")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn health_is_public() {
        let app = test_app("health");
        let response = app
            .router
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/health")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn api_v1_search_requires_query() {
        let app = test_app("api-search");
        // 缺 `q`：`Query<SearchQuery>` 拒绝，400。
        let (status, _) = get_json(&app.router, "/api/v1/search", Some("test-token")).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }
}
