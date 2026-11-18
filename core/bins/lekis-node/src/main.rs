//! Lekis NAS 节点（REQUIREMENTS 3.13 节，NOD-01~09）。**可选组件**：不部署它，客户端也能使用全部核心功能。
//!
//! 配置（环境变量）：
//! - `LEKIS_DATA_DIR`：数据目录，默认 `/data`
//! - `LEKIS_CACHE_DIR`：缓存目录，默认 `/cache`
//! - `LEKIS_BIND`：监听地址，默认 `0.0.0.0:4533`（和 Navidrome 默认端口一致，方便替换）
//! - `RUST_LOG`：日志级别
//!
//! 路由：
//! - `/health`：健康检查
//! - `/rest/*`：OpenSubsonic API（NOD-03），让现有的 Subsonic 客户端直接可用
//! - `/api/v1/*`：Lekis 自有 API（NOD-04），给 Lekis 客户端用（同步、远程控制）

mod opensubsonic;

use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::{Json, Router};
use lekis_core::{CoreConfig, LekisCore, PlatformKind, PlatformServices};
use lekis_types::{LekisError, TrackQuery, TrackSort};
use serde::Deserialize;
use std::path::PathBuf;
use std::sync::Arc;

#[derive(Clone)]
struct AppState {
    core: Arc<LekisCore>,
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
    let state = AppState {
        core: Arc::new(core),
    };

    let app = Router::new()
        .route("/health", get(|| async { "ok" }))
        .nest("/rest", opensubsonic::router())
        .route("/api/v1/tracks", get(list_tracks))
        .route("/api/v1/search", get(search))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(&bind).await?;
    tracing::info!(%bind, "lekis-node listening");
    axum::serve(listener, app)
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await?;
    Ok(())
}

/// 把核心错误转成 HTTP 响应。
struct ApiError(LekisError);

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

// TODO(NOD-04)：鉴权（设备配对 token）。现在所有 /api/v1 接口都没有鉴权，不要暴露到公网。
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
