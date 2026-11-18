//! OpenSubsonic API（NOD-03）。规范：https://opensubsonic.netlify.app/
//!
//! 每个接口同时注册 `/xxx` 和 `/xxx.view` 两种路径（老客户端会带 `.view`）。
//! 响应格式由 `f` 参数决定：`json` 或 `xml`（默认 xml）。这里先只实现 json。
//!
//! TODO：
//! - 鉴权：`u` + `t`（md5(password + salt)）+ `s`，或者 OpenSubsonic 的 `apiKey`；
//! - 接口：getLicense、getMusicFolders、getArtists、getAlbumList2、getAlbum、search3、stream、getCoverArt、
//!   getLyricsBySongId、scrobble、star / unstar、getPlaylists ……

use axum::routing::get;
use axum::{Json, Router};
use serde_json::{json, Value};

/// 我们实现的 Subsonic API 版本。
const API_VERSION: &str = "1.16.1";

fn ok(extra: Value) -> Json<Value> {
    let mut body = json!({
        "status": "ok",
        "version": API_VERSION,
        "type": "lekis",
        "serverVersion": env!("CARGO_PKG_VERSION"),
        "openSubsonic": true,
    });
    if let (Some(obj), Some(extra)) = (body.as_object_mut(), extra.as_object()) {
        obj.extend(extra.clone());
    }
    Json(json!({ "subsonic-response": body }))
}

async fn ping() -> Json<Value> {
    ok(json!({}))
}

async fn extensions() -> Json<Value> {
    ok(json!({ "openSubsonicExtensions": [] }))
}

/// `/rest` 下的路由。
pub fn router<S: Clone + Send + Sync + 'static>() -> Router<S> {
    Router::new()
        .route("/ping", get(ping))
        .route("/ping.view", get(ping))
        .route("/getOpenSubsonicExtensions", get(extensions))
        .route("/getOpenSubsonicExtensions.view", get(extensions))
}
