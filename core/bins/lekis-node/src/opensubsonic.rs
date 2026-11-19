//! OpenSubsonic API（NOD-03）。规范：<https://opensubsonic.netlify.app/>
//!
//! 目标：现有的 Subsonic / OpenSubsonic 客户端（Symfonium、Feishin、Supersonic、play:Sub……）
//! 把 `http://<nas>:4533/rest` 填进服务器地址就能直接用。
//!
//! # 约定
//!
//! - 每个接口同时注册 `/xxx` 和 `/xxx.view` 两种路径（老客户端会带 `.view` 后缀）。
//! - 所有响应都是 `{"subsonic-response": {...}}` 外壳（见 [`envelope`]）。
//! - **错误也返回 HTTP 200**，用外壳里的 `status: "failed"` + `error.code` 表达，
//!   这是 Subsonic 协议的要求（客户端只看响应体，不看状态码）。
//!   唯二例外见下面「图片 / 音频流」。
//! - id 一律用本机自增 id 的十进制字符串（`TrackId(pub i64)` 的 `.0`），稳定、无需编码。
//! - 查询参数用 [`Params`] 宽容解析：未知参数（`c`、`v`、`f`、`callback`……）全部忽略，
//!   重复键保留（`star?id=1&id=2`），坏数字退化成默认值而不是报错。
//!
//! # 尚未实现（原因写在这里，不要在客户端上表现为 500）
//!
//! - `stream` / `download`：**需要 `LekisCore` 暴露「曲目 → 可播文件」的解析结果**
//!   （`Library::track_files`，现在只有 `resolver.rs` 内部能用）。要 302 到上游、要按
//!   Range 读本地文件都拿不到路径，返回 HTTP 501 + `status: "failed"`；曲目不存在时
//!   先回 70，免得客户端对着 501 反复重试。
//!   TODO(NOD-06)：核心暴露 `track_files` 后改成 302 / 带 Range 的流式响应。
//! - `getCoverArt`：id 是**曲目 id**（不是 artwork id），因为 `LekisCore` 只暴露了
//!   `artwork(TrackId)` + `artwork_path(hash, width)`，没有「按 artwork id 反查」的接口。
//!   `song` 的 `coverArt` 因此也统一填曲目 id（客户端只会原样回传，语义由我们定）。
//!   图片是缓存目录里的 WebP 缩略图；文件不存在时返回**真正的 HTTP 404**（而不是
//!   Subsonic 的 200 + `status: "failed"`）：图片请求浏览器/客户端会直接渲染响应体，
//!   200 + JSON 会被当成一张坏图反复重试。`size` 参数映射到 96 / 320 / 1024 三个档位
//!   （和 `ArtworkSize` 对齐，库里只生成这三档）。
//! - `getPlaylists` / `getPlaylist`：已接 `LekisCore::list_playlists` / `get_playlist` /
//!   `playlist_items`。条目里 `track` 为 `None` 的占位条会被跳过（Subsonic 没有占位概念）。
//! - `scrobble`：`submission=true`（或省略）时用 `LekisCore::record_play` 落库，
//!   `submission=false`（正在播放）只校验曲目存在，不写播放历史。
//! - `getStarred2`：曲目收藏走 `LekisCore::loved_tracks`；专辑 / 艺人收藏还没有对应查询，
//!   那两个数组恒为空。
//! - `getAlbumList2` 的 `starred` / `highest` / `byYear` / `byGenre`：library 的
//!   `list_albums` 只支持 Title/Artist/RecentlyAdded/MostPlayed 四种排序，没有按收藏 /
//!   年份 / 流派过滤的专辑查询，返回空列表 + `note` 字段说明原因（不报错）。
//! - `startScan`/`getScanStatus` 的进度来自 [`crate::scan::ScanTracker`]（事件监听），
//!   不是去查数据库。
//! - 只支持 GET。Subsonic 规范允许 POST + 表单体，但那需要先在中间件里缓冲请求体，
//!   目前没做（客户端默认都用 GET）。

use crate::datetime::{iso8601_ms, now_ms};
use crate::params::Params;
use crate::scan;
use crate::AppState;
use axum::extract::{RawQuery, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::{Json, Router};
use lekis_types::{
    Album, Artist, Codec, ErrorCode, LekisError, Result, Track, TrackRow, TrackSort,
};
use serde_json::{json, Value};
use std::collections::BTreeMap;

/// 我们实现的 Subsonic API 版本。
const API_VERSION: &str = "1.16.1";

/// 排序时忽略的前缀冠词（Subsonic 的 `ignoredArticles`）。
const IGNORED_ARTICLES: &str = "The El La Los Las Le Les";

/// 单页最大条数。`lekis-library` 的浏览接口要求 1..=500，超了会 `invalid_argument`。
const MAX_PAGE: u32 = 500;

/// 封面缓存的最大边长档位。`lekis-core` 的补全管线按长边 1024 落盘，
/// 元数据里没写宽度时用它兜底（`cache_relative_path` 自己会夹到 96..=4096）。
const MAX_ARTWORK_PX: u32 = 1024;

// ---------------------------------------------------------------------------
// 响应外壳
// ---------------------------------------------------------------------------

/// 组装 `{"subsonic-response": {status: "ok", ...payload}}`。
fn envelope(payload: Value) -> Value {
    let mut body = json!({
        "status": "ok",
        "version": API_VERSION,
        "type": "lekis",
        "serverVersion": env!("CARGO_PKG_VERSION"),
        "openSubsonic": true,
    });
    if let (Some(obj), Some(payload)) = (body.as_object_mut(), payload.as_object()) {
        obj.extend(payload.clone());
    }
    json!({ "subsonic-response": body })
}

/// 组装失败外壳（Subsonic 的错误永远是 HTTP 200 + `status: "failed"`）。
fn failed_body(code: u32, message: &str) -> Value {
    json!({
        "subsonic-response": {
            "status": "failed",
            "version": API_VERSION,
            "type": "lekis",
            "serverVersion": env!("CARGO_PKG_VERSION"),
            "openSubsonic": true,
            "error": { "code": code, "message": message },
        }
    })
}

/// 成功响应（handler 里直接 `Ok(ok(json!({...})))`）。
fn ok(payload: Value) -> Json<Value> {
    Json(envelope(payload))
}

/// 把核心错误映射成 Subsonic 错误码。
///
/// 见 <https://opensubsonic.netlify.app/docs/errorcodes/>：
/// 0 通用、10 缺参数/参数错、20 客户端版本太老、30 服务器版本太老、
/// 40 认证失败、50 无权限、60 不支持该接口、70 资源不存在。
fn subsonic_code(code: ErrorCode) -> u32 {
    match code {
        ErrorCode::InvalidArgument => 10,
        ErrorCode::Auth => 40,
        ErrorCode::PermissionDenied => 50,
        ErrorCode::NotFound => 70,
        ErrorCode::NotImplemented | ErrorCode::Unsupported => 60,
        _ => 0,
    }
}

/// 核心错误 → HTTP 200 + `status: "failed"`。
///
/// `crate::auth::subsonic_auth` 也用它（认证失败要按 Subsonic 的错误格式回）。
pub(crate) fn error_response(error: &LekisError) -> Response {
    (
        StatusCode::OK,
        Json(failed_body(subsonic_code(error.code), &error.message)),
    )
        .into_response()
}

/// `?` 友好的错误包装：`Result<_, SubsonicError>` 的 handler 直接 `?` 核心错误。
pub(crate) struct SubsonicError(LekisError);

impl From<LekisError> for SubsonicError {
    fn from(error: LekisError) -> Self {
        Self(error)
    }
}

impl IntoResponse for SubsonicError {
    fn into_response(self) -> Response {
        error_response(&self.0)
    }
}

/// 未实现的接口：真 HTTP 状态码 + Subsonic 失败体（见模块头部「图片 / 音频流」）。
fn not_implemented(status: StatusCode, message: &str) -> Response {
    failed_response(status, 60, message)
}

/// 指定 HTTP 状态码 + Subsonic 错误码的响应。
///
/// 只给 `/rest` 里那两个「必须用真状态码」的接口用（`stream` / `getCoverArt`），
/// 其余接口的错误一律走 [`error_response`]（HTTP 200）。
fn failed_response(status: StatusCode, code: u32, message: &str) -> Response {
    (status, Json(failed_body(code, message))).into_response()
}

// ---------------------------------------------------------------------------
// 参数与分页
// ---------------------------------------------------------------------------

/// 取一个必需的 id 参数（十进制 i64）。
fn required_id(params: &Params, key: &str) -> Result<i64> {
    let raw = params.require(key)?;
    raw.trim().parse::<i64>().map_err(|_| {
        LekisError::invalid(format!(
            "parameter {key}: expected a numeric id, got {raw:?}"
        ))
    })
}

/// Subsonic 的分页参数（`size` / `offset`）。
#[derive(Debug, Clone, Copy)]
struct Paging {
    offset: u32,
    size: u32,
}

impl Paging {
    /// 读 `size`（默认 `default_size`）+ `offset`，并把 size 夹到 1..=`MAX_PAGE`。
    ///
    /// 夹取是必须的：客户端会传 `size=0` 或 `size=-1`，而 `lekis-library` 对 0 / >500
    /// 会直接 `invalid_argument`。
    fn new(params: &Params, default_size: u32) -> Self {
        let requested = params.u32_or("size", default_size);
        let size = if requested == 0 {
            default_size
        } else {
            requested
        };
        Self {
            offset: params.u32_or("offset", 0),
            size: size.clamp(1, MAX_PAGE),
        }
    }
}

// ---------------------------------------------------------------------------
// JSON 构造
// ---------------------------------------------------------------------------

/// 毫秒 → 秒（Subsonic 的 `duration` 是整数秒）。
fn seconds(ms: u64) -> u64 {
    ms / 1000
}

/// 只在 `value` 是 `Some` 时写入字段（Subsonic 客户端对 `null` 比缺字段更敏感）。
fn set_opt(obj: &mut Value, key: &str, value: Option<Value>) {
    if let Some(value) = value {
        obj[key] = value;
    }
}

/// 编码格式 → 文件后缀。
fn codec_suffix(codec: &Codec) -> &str {
    match codec {
        Codec::Mp3 => "mp3",
        Codec::Aac => "m4a",
        Codec::Alac => "m4a",
        Codec::Flac => "flac",
        Codec::Wav => "wav",
        Codec::Aiff => "aiff",
        Codec::Vorbis => "ogg",
        Codec::Opus => "opus",
        Codec::Ape => "ape",
        Codec::WavPack => "wv",
        Codec::Tta => "tta",
        Codec::Dsd => "dsf",
        Codec::Other(other) => other.as_str(),
    }
}

/// 编码格式 → MIME。
fn codec_content_type(codec: &Codec) -> &str {
    match codec {
        Codec::Mp3 => "audio/mpeg",
        Codec::Aac | Codec::Alac => "audio/mp4",
        Codec::Flac => "audio/flac",
        Codec::Wav => "audio/wav",
        Codec::Aiff => "audio/aiff",
        Codec::Vorbis => "audio/ogg",
        Codec::Opus => "audio/opus",
        Codec::Ape => "audio/x-ape",
        Codec::WavPack => "audio/x-wavpack",
        Codec::Tta => "audio/x-tta",
        Codec::Dsd => "audio/x-dsf",
        Codec::Other(_) => "application/octet-stream",
    }
}

/// 曲目的封面 id：`t<曲目 id>`。
///
/// Subsonic 的 id 是不透明字符串，客户端只会原样传回 `getCoverArt`，所以加个单字母
/// 前缀就能区分命名空间 —— 曲目和专辑各自自增，光靠数字会重号（`t1` 是第 1 首歌，
/// `a1` 是第 1 张专辑）。
fn cover_art_track(id: lekis_types::TrackId) -> String {
    format!("t{}", id.0)
}

/// 专辑的封面 id：`a<专辑 id>`。
fn cover_art_album(id: lekis_types::AlbumId) -> String {
    format!("a{}", id.0)
}

/// `getCoverArt` 里解的 id 指向哪种实体。
#[derive(Debug, Clone, Copy)]
enum CoverArtRef {
    /// 曲目（`t12`，或没有前缀的裸数字，兼容手填的客户端）。
    Track(lekis_types::TrackId),
    /// 专辑（`a3`）。
    Album(lekis_types::AlbumId),
}

/// 解析 `getCoverArt?id=`。
fn parse_cover_art_id(raw: &str) -> Result<CoverArtRef> {
    let raw = raw.trim();
    let invalid = || {
        LekisError::invalid(format!(
            "parameter id: expected a cover art id like t12 / a3, got {raw:?}"
        ))
    };
    if let Some(rest) = raw.strip_prefix('a') {
        let id = rest.parse::<i64>().map_err(|_| invalid())?;
        return Ok(CoverArtRef::Album(lekis_types::AlbumId(id)));
    }
    let digits = raw.strip_prefix('t').unwrap_or(raw);
    let id = digits.parse::<i64>().map_err(|_| invalid())?;
    Ok(CoverArtRef::Track(lekis_types::TrackId(id)))
}

/// 构造一个 `song` 对象。
///
/// `row` 是列表查询必定拿得到的那部分；`full` 是 `core.get_track()` 的完整信息，
/// 有就补上曲号、碟号、年份、码率、MusicBrainz ID 等可选字段。
fn song(row: &TrackRow, full: Option<&Track>) -> Value {
    let mut obj = json!({
        "id": row.id.0.to_string(),
        "title": row.title,
        "isDir": false,
        "mediaType": "song",
        "duration": seconds(row.duration_ms),
    });
    if !row.artist_line.is_empty() {
        obj["artist"] = json!(row.artist_line);
    }
    set_opt(
        &mut obj,
        "album",
        row.album_title.as_ref().map(|v| json!(v)),
    );
    // 只有真有封面才给 coverArt：没有的话给出一个必然 404 的 id，客户端会反复重试。
    set_opt(
        &mut obj,
        "coverArt",
        row.artwork_id.map(|_| json!(cover_art_track(row.id))),
    );
    if row.loved {
        // Subsonic 里只要 `starred` 存在就算收藏，值只是时间戳。
        obj["starred"] = json!(iso8601_ms(now_ms()));
    }

    let Some(track) = full else {
        return obj;
    };
    set_opt(
        &mut obj,
        "parent",
        track.album_id.map(|id| json!(id.0.to_string())),
    );
    set_opt(
        &mut obj,
        "albumId",
        track.album_id.map(|id| json!(id.0.to_string())),
    );
    set_opt(
        &mut obj,
        "sortName",
        track.sort_title.as_ref().map(|v| json!(v)),
    );
    set_opt(&mut obj, "track", track.track_no.map(|v| json!(v)));
    set_opt(&mut obj, "discNumber", track.disc_no.map(|v| json!(v)));
    set_opt(&mut obj, "year", track.year.map(|v| json!(v)));
    set_opt(
        &mut obj,
        "musicBrainzId",
        track.mbid_recording.as_ref().map(|v| json!(v)),
    );
    if !track.genres.is_empty() {
        obj["genre"] = json!(track.genres.join(", "));
        obj["genres"] = json!(track
            .genres
            .iter()
            .map(|name| json!({ "name": name }))
            .collect::<Vec<_>>());
    }
    if !track.artists.is_empty() {
        obj["artists"] = json!(track
            .artists
            .iter()
            .map(|credit| {
                let mut entry = json!({ "name": credit.name });
                if let Some(id) = credit.artist_id {
                    entry["id"] = json!(id.0.to_string());
                }
                entry
            })
            .collect::<Vec<_>>());
    }
    if let Some(audio) = &track.audio {
        obj["suffix"] = json!(codec_suffix(&audio.codec));
        obj["contentType"] = json!(codec_content_type(&audio.codec));
        obj["samplingRate"] = json!(audio.sample_rate);
        obj["channelCount"] = json!(audio.channels);
        set_opt(&mut obj, "bitDepth", audio.bit_depth.map(|v| json!(v)));
        set_opt(&mut obj, "bitRate", audio.bitrate_kbps.map(|v| json!(v)));
    }
    let gain = &track.replaygain;
    if gain.track_gain_db.is_some() || gain.album_gain_db.is_some() {
        // OpenSubsonic 的 replayGain 扩展。
        obj["replayGain"] = json!({
            "trackGain": gain.track_gain_db,
            "trackPeak": gain.track_peak,
            "albumGain": gain.album_gain_db,
            "albumPeak": gain.album_peak,
        });
    }
    obj
}

/// 构造一个 `album` 对象。
fn album(album: &Album) -> Value {
    let mut obj = json!({
        "id": album.id.0.to_string(),
        "name": album.title,
        "isDir": true,
        "songCount": album.track_count,
    });
    if !album.artist_line.is_empty() {
        obj["artist"] = json!(album.artist_line);
    }
    set_opt(&mut obj, "year", album.year.map(|v| json!(v)));
    // 只有真有封面才给 coverArt（见 `song` 里的说明）。
    set_opt(
        &mut obj,
        "coverArt",
        album.artwork_id.map(|_| json!(cover_art_album(album.id))),
    );
    set_opt(
        &mut obj,
        "musicBrainzId",
        album.mbid_release.as_ref().map(|v| json!(v)),
    );
    obj
}

/// 构造一个 `artist` 对象。
fn artist(artist: &Artist) -> Value {
    let mut obj = json!({
        "id": artist.id.0.to_string(),
        "name": artist.name,
    });
    set_opt(
        &mut obj,
        "sortName",
        artist.sort_name.as_ref().map(|v| json!(v)),
    );
    // 艺人封面故意不给：`LekisCore::artwork()` 只按 TrackId 取（曲目 → 专辑回落），
    // 没有「艺人 → 封面」的查询。给一个解不出来的 id 只会让客户端 404 重试。
    // TODO(NOD-07)：核心暴露 `artwork(ArtistId)` 后补上。
    set_opt(
        &mut obj,
        "musicBrainzId",
        artist.mbid.as_ref().map(|v| json!(v)),
    );
    if !artist.aliases.is_empty() {
        obj["aliases"] = json!(artist.aliases);
    }
    obj
}

/// 艺术家首字母分组的 key：`A`..`Z`，其余（数字、标点、CJK）归到 `#`。
fn index_letter(name: &str) -> String {
    // TODO(LIB-06)：按冠词（`The Beatles` → `Beatles` → `B`）和火鸡语做规范化，
    // 等 library 暴露「索引键」后改成用它（现在用的是 sort_name ∪ name 的首字符）。
    match name.trim().chars().next() {
        Some(first) if first.is_ascii_alphabetic() => first.to_ascii_uppercase().to_string(),
        _ => "#".to_string(),
    }
}

/// 把艺人列表按首字母分成 Subsonic 的 `index` 数组。
fn artist_indexes(artists: &[Artist]) -> Value {
    let mut groups: BTreeMap<String, Vec<Value>> = BTreeMap::new();
    for entry in artists {
        let key = index_letter(entry.sort_name.as_deref().unwrap_or(&entry.name));
        groups.entry(key).or_default().push(artist(entry));
    }
    json!(groups
        .into_iter()
        .map(|(name, artist)| json!({ "name": name, "artist": artist }))
        .collect::<Vec<_>>())
}

/// 把一批 `TrackRow` 变成 `song` 数组。
///
/// `enrich` 为真时逐条 `get_track()` 补全曲号等字段——专辑详情页需要曲号排序，
/// 但那是 N 次查询，所以只对列表很小（专辑）的场景打开。
async fn songs(state: &AppState, rows: &[TrackRow], enrich: bool) -> Vec<Value> {
    // 超过这个条数就不做补全了（一次专辑很少超过 200 首，列表接口则可能到 500）。
    const ENRICH_LIMIT: usize = 200;
    let enrich = enrich && rows.len() <= ENRICH_LIMIT;
    let mut songs = Vec::with_capacity(rows.len());
    for row in rows {
        if enrich {
            // 补全失败（比如查询期间曲目被删）就退回 row 里已有的字段，不影响整页。
            let full = state.core.get_track(row.id).await.ok();
            songs.push(song(row, full.as_ref()));
        } else {
            songs.push(song(row, None));
        }
    }
    songs
}

// ---------------------------------------------------------------------------
// 基础接口
// ---------------------------------------------------------------------------

/// `ping`：客户端用来验证地址 + 凭据。
async fn ping() -> Json<Value> {
    ok(json!({}))
}

/// `getLicense`：我们没有授权概念，永远有效。
async fn get_license() -> Json<Value> {
    ok(json!({ "license": { "valid": true } }))
}

/// `getOpenSubsonicExtensions`：声明支持的 OpenSubsonic 扩展。暂时一个都没有。
async fn extensions() -> Json<Value> {
    ok(json!({ "openSubsonicExtensions": [] }))
}

/// `getUser`：客户端登录后会拉一次（判断角色 / 能做什么）。
async fn get_user(State(state): State<AppState>) -> Json<Value> {
    ok(json!({
        "user": {
            "username": state.auth.subsonic_user(),
            "email": "",
            "scrobblingEnabled": false,
            "adminRole": true,
            "settingsRole": true,
            "downloadRole": false,
            "uploadRole": false,
            "playlistRole": false,
            "coverArtRole": false,
            "commentRole": false,
            "podcastRole": false,
            "streamRole": true,
            "jukeboxRole": false,
            "shareRole": false,
            "videoConversionRole": false,
        }
    }))
}

/// `getMusicFolders`：Subsonic 的「音乐文件夹」对应我们的音源。
async fn get_music_folders(
    State(state): State<AppState>,
) -> std::result::Result<Json<Value>, SubsonicError> {
    let sources = state.core.list_sources().await?;
    let folders = sources
        .iter()
        .filter(|source| source.enabled)
        .filter_map(|source| {
            source
                .id
                .map(|id| json!({ "id": id.0, "name": source.name }))
        })
        .collect::<Vec<_>>();
    Ok(ok(json!({ "musicFolders": { "musicFolder": folders } })))
}

// ---------------------------------------------------------------------------
// 艺人
// ---------------------------------------------------------------------------

/// `getArtists`：按首字母分组的艺人列表（ID3 版本）。
async fn get_artists(
    State(state): State<AppState>,
) -> std::result::Result<Json<Value>, SubsonicError> {
    let artists = state.core.list_artists(0, MAX_PAGE).await?;
    Ok(ok(json!({
        "artists": {
            "ignoredArticles": IGNORED_ARTICLES,
            "index": artist_indexes(&artists),
        }
    })))
}

/// `getIndexes`：和 `getArtists` 同一份数据，外壳不同（给老客户端）。
async fn get_indexes(
    State(state): State<AppState>,
) -> std::result::Result<Json<Value>, SubsonicError> {
    let artists = state.core.list_artists(0, MAX_PAGE).await?;
    Ok(ok(json!({
        "indexes": {
            // TODO(LIB-06)：library 没暴露「资料库最后修改时间」，先给 0（客户端会每次刷新索引）。
            "lastModified": 0,
            "ignoredArticles": IGNORED_ARTICLES,
            "index": artist_indexes(&artists),
        }
    })))
}

/// `getArtist?id=`：艺人详情 + 其专辑列表。
async fn get_artist(
    State(state): State<AppState>,
    RawQuery(raw): RawQuery,
) -> std::result::Result<Json<Value>, SubsonicError> {
    let params = Params::from_raw(&raw);
    let id = required_id(&params, "id")?;
    let id = lekis_types::ArtistId(id);
    let artist_detail = state.core.get_artist(id).await?;
    let albums = state.core.artist_albums(id, 0, MAX_PAGE).await?;

    let mut payload = artist(&artist_detail);
    payload["albumCount"] = json!(albums.len());
    payload["album"] = json!(albums.iter().map(album).collect::<Vec<_>>());
    Ok(ok(json!({ "artist": payload })))
}

/// `getArtistInfo2?id=`：艺人简介。我们还没有资料增强管线，返回空简介（不报错）。
async fn get_artist_info2(
    State(state): State<AppState>,
    RawQuery(raw): RawQuery,
) -> std::result::Result<Json<Value>, SubsonicError> {
    let params = Params::from_raw(&raw);
    let id = required_id(&params, "id")?;
    let artist_detail = state.core.get_artist(lekis_types::ArtistId(id)).await?;
    Ok(ok(json!({
        "artistInfo2": {
            // TODO(ENR-02)：等资料增强（MusicBrainz / Last.fm）落地后填简介、头像、相似艺人。
            "biography": "",
            "musicBrainzId": artist_detail.mbid.clone().unwrap_or_default(),
            "smallImageUrl": "",
            "mediumImageUrl": "",
            "largeImageUrl": "",
        }
    })))
}

// ---------------------------------------------------------------------------
// 专辑
// ---------------------------------------------------------------------------

/// `getAlbum?id=`：专辑详情 + 歌曲列表。
async fn get_album(
    State(state): State<AppState>,
    RawQuery(raw): RawQuery,
) -> std::result::Result<Json<Value>, SubsonicError> {
    let params = Params::from_raw(&raw);
    let id = required_id(&params, "id")?;
    let album_id = lekis_types::AlbumId(id);
    let album_detail = state.core.get_album(album_id).await?;
    let rows = state.core.album_tracks(album_id, 0, MAX_PAGE).await?;

    let duration: u64 = rows.iter().map(|row| seconds(row.duration_ms)).sum();
    let mut payload = album(&album_detail);
    payload["duration"] = json!(duration);
    payload["songCount"] = json!(rows.len());
    payload["song"] = json!(songs(&state, &rows, true).await);
    Ok(ok(json!({ "album": payload })))
}

/// `getAlbumInfo2?id=`：专辑简介。同样先返回空。
async fn get_album_info2(
    State(state): State<AppState>,
    RawQuery(raw): RawQuery,
) -> std::result::Result<Json<Value>, SubsonicError> {
    let params = Params::from_raw(&raw);
    let id = required_id(&params, "id")?;
    let album_detail = state.core.get_album(lekis_types::AlbumId(id)).await?;
    Ok(ok(json!({
        "albumInfo": {
            "notes": "",
            "musicBrainzId": album_detail.mbid_release.clone().unwrap_or_default(),
        }
    })))
}

/// `getAlbumList2?type=&size=&offset=`：按不同维度列专辑（ID3 版本）。
async fn get_album_list2(
    State(state): State<AppState>,
    RawQuery(raw): RawQuery,
) -> std::result::Result<Json<Value>, SubsonicError> {
    let params = Params::from_raw(&raw);
    let kind = params.get("type").unwrap_or("newest");
    let paging = Paging::new(&params, 10);

    // 我们只有四种排序维度（Title / Artist / RecentlyAdded / MostPlayed），
    // 其余 Subsonic 列表类型要么语义重复，要么需要播放统计 / 收藏查询，先按最接近的映射，
    // 实在不支持的显式返回空列表而不是乱给数据。
    let sort = match kind {
        "newest" | "recent" | "random" => TrackSort::RecentlyAdded,
        "frequent" => TrackSort::MostPlayed,
        "alphabeticalByName" => TrackSort::Title,
        "alphabeticalByArtist" => TrackSort::Artist,
        "starred" | "highest" | "byYear" | "byGenre" => {
            // TODO(LIB-07)：`starred` 需要「列出收藏」查询，`byYear`/`byGenre` 需要 library 支持过滤。
            let mut payload = json!({ "albumList2": { "album": [] } });
            payload["note"] = json!(format!(
                "album list type {kind:?} is not supported yet; returning an empty list"
            ));
            return Ok(ok(payload));
        }
        other => {
            return Err(LekisError::invalid(format!(
                "parameter type: unknown album list type {other:?}"
            ))
            .into())
        }
    };

    let albums = state
        .core
        .list_albums(sort, paging.offset, paging.size)
        .await?;
    Ok(ok(
        json!({ "albumList2": { "album": albums.iter().map(album).collect::<Vec<_>>() } }),
    ))
}

// ---------------------------------------------------------------------------
// 曲目
// ---------------------------------------------------------------------------

/// `getSong?id=`：单曲详情。
async fn get_song(
    State(state): State<AppState>,
    RawQuery(raw): RawQuery,
) -> std::result::Result<Json<Value>, SubsonicError> {
    let params = Params::from_raw(&raw);
    let id = required_id(&params, "id")?;
    let track = state.core.get_track(lekis_types::TrackId(id)).await?;
    let row = TrackRow {
        id: track.id,
        title: track.title.clone(),
        artist_line: track
            .artists
            .iter()
            .map(|credit| credit.name.clone())
            .collect::<Vec<_>>()
            .join(", "),
        album_title: track.album_title.clone(),
        duration_ms: track.duration_ms,
        artwork_id: track.artwork_id,
        quality_badge: track
            .audio
            .as_ref()
            .map(lekis_types::AudioProps::quality_badge),
        loved: false,
    };
    Ok(ok(json!({ "song": song(&row, Some(&track)) })))
}

/// `getRandomSongs?size=`：随机曲目。没有随机查询，用「最近添加」代替并标注。
async fn get_random_songs(
    State(state): State<AppState>,
    RawQuery(raw): RawQuery,
) -> std::result::Result<Json<Value>, SubsonicError> {
    let params = Params::from_raw(&raw);
    let paging = Paging::new(&params, 10);
    // TODO(LIB-07)：library 没有 `ORDER BY RANDOM()` 的入口，先用最近添加顶上（客户端一般只用它填"随便听听"）。
    let rows = state.core.recently_added(paging.size).await?;
    Ok(ok(
        json!({ "randomSongs": { "song": songs(&state, &rows, false).await } }),
    ))
}

/// `getGenres`：流派列表。
async fn get_genres(
    State(state): State<AppState>,
) -> std::result::Result<Json<Value>, SubsonicError> {
    let genres = state.core.list_genres(MAX_PAGE).await?;
    let list = genres
        .iter()
        .map(|genre| {
            json!({
                "value": genre.name,
                "songCount": genre.track_count,
                // 我们没有「流派下的专辑数」统计。
                "albumCount": 0,
            })
        })
        .collect::<Vec<_>>();
    Ok(ok(json!({ "genres": { "genre": list } })))
}

/// `getSongsByGenre?genre=&count=&offset=`：某个流派的曲目。
async fn get_songs_by_genre(
    State(state): State<AppState>,
    RawQuery(raw): RawQuery,
) -> std::result::Result<Json<Value>, SubsonicError> {
    let params = Params::from_raw(&raw);
    let genre = params.require("genre")?.to_string();
    let size = params.u32_or("count", 10);
    let size = if size == 0 { 10 } else { size }.clamp(1, MAX_PAGE);
    let offset = params.u32_or("offset", 0);
    let rows = state.core.genre_tracks(genre, offset, size).await?;
    Ok(ok(json!({
        "songsByGenre": { "song": songs(&state, &rows, false).await }
    })))
}

// ---------------------------------------------------------------------------
// 搜索
// ---------------------------------------------------------------------------

/// `search3?query=&...`：同时搜艺人 / 专辑 / 曲目（ID3 版本）。
async fn search3(
    State(state): State<AppState>,
    RawQuery(raw): RawQuery,
) -> std::result::Result<Json<Value>, SubsonicError> {
    let params = Params::from_raw(&raw);
    let query = params.get("query").unwrap_or_default().to_string();
    let song_count = params.u32_or("songCount", 20);
    let song_offset = params.u32_or("songOffset", 0);
    let album_count = params.u32_or("albumCount", 20);
    let album_offset = params.u32_or("albumOffset", 0);
    let artist_count = params.u32_or("artistCount", 20);
    let artist_offset = params.u32_or("artistOffset", 0);

    if query.trim().is_empty() {
        // 空查询是合法的（客户端偶尔用它探活），直接给空结果，不要拿空串去全表 LIKE。
        return Ok(ok(json!({
            "searchResult3": { "artist": [], "album": [], "song": [] }
        })));
    }

    // `core.search` 内部把 limit 夹到 100，所以先取一大页再在内存里做子分页。
    let results = state.core.search(query, 100).await?;
    let slice = |len: usize, offset: u32, count: u32| -> (usize, usize) {
        let start = (offset as usize).min(len);
        let end = (start + count as usize).min(len);
        (start, end)
    };

    let (start, end) = slice(
        results.tracks.len(),
        song_offset,
        if song_count == 0 { 20 } else { song_count },
    );
    let song_rows = &results.tracks[start..end];
    let (start, end) = slice(
        results.albums.len(),
        album_offset,
        if album_count == 0 { 20 } else { album_count },
    );
    let albums = &results.albums[start..end];
    let (start, end) = slice(
        results.artists.len(),
        artist_offset,
        if artist_count == 0 { 20 } else { artist_count },
    );
    let artists = &results.artists[start..end];

    Ok(ok(json!({
        "searchResult3": {
            "artist": artists.iter().map(artist).collect::<Vec<_>>(),
            "album": albums.iter().map(album).collect::<Vec<_>>(),
            "song": songs(&state, song_rows, false).await,
        }
    })))
}

// ---------------------------------------------------------------------------
// 收藏 / 评分 / 播放上报
// ---------------------------------------------------------------------------

/// `setRating?id=&rating=`：`rating` 0..=5，0 表示清除。
async fn set_rating(
    State(state): State<AppState>,
    RawQuery(raw): RawQuery,
) -> std::result::Result<Json<Value>, SubsonicError> {
    let params = Params::from_raw(&raw);
    let id = required_id(&params, "id")?;
    let rating = params.u32_or("rating", 0);
    if rating > 5 {
        return Err(
            LekisError::invalid(format!("parameter rating: must be 0..=5, got {rating}")).into(),
        );
    }
    state
        .core
        .set_rating(lekis_types::TrackId(id), i64::from(rating))
        .await?;
    Ok(ok(json!({})))
}

/// `star` / `unstar`：曲目收藏（映射到 `set_loved`）。
///
/// `id` 可以重复出现（`star?id=1&id=2`）。`albumId` / `artistId` 这两个维度
/// `LekisCore` 还没有对应接口，先忽略（不报错，免得客户端整批失败）。
async fn star_impl(
    state: &AppState,
    params: &Params,
    loved: bool,
) -> std::result::Result<Json<Value>, SubsonicError> {
    let ids = params.get_all("id");
    if ids.is_empty() {
        // 允许只 star 专辑 / 艺人（此时我们无操作），但至少要有一个参数。
        if params.get("albumId").is_none() && params.get("artistId").is_none() {
            return Err(LekisError::invalid("missing parameter: id").into());
        }
    }
    for raw in ids {
        let id = raw.trim().parse::<i64>().map_err(|_| {
            LekisError::invalid(format!("parameter id: expected a numeric id, got {raw:?}"))
        })?;
        state
            .core
            .set_loved(lekis_types::TrackId(id), loved)
            .await?;
    }
    // TODO(LIB-07)：收藏专辑 / 艺人（`albumId` / `artistId`）需要 library 的实体收藏表。
    Ok(ok(json!({})))
}

/// `star`。
async fn star(
    State(state): State<AppState>,
    RawQuery(raw): RawQuery,
) -> std::result::Result<Json<Value>, SubsonicError> {
    let params = Params::from_raw(&raw);
    star_impl(&state, &params, true).await
}

/// `unstar`。
async fn unstar(
    State(state): State<AppState>,
    RawQuery(raw): RawQuery,
) -> std::result::Result<Json<Value>, SubsonicError> {
    let params = Params::from_raw(&raw);
    star_impl(&state, &params, false).await
}

/// `getStarred2`：收藏列表。
///
/// 曲目收藏走 `LekisCore::loved_tracks`（`track.loved`），专辑 / 艺人收藏还没有对应
/// 的查询（library 没有实体收藏表），那两个数组恒为空。
/// TODO(LIB-07)：等 library 支持收藏专辑 / 艺人后补上。
async fn get_starred2(
    State(state): State<AppState>,
    RawQuery(raw): RawQuery,
) -> std::result::Result<Json<Value>, SubsonicError> {
    let params = Params::from_raw(&raw);
    let paging = Paging::new(&params, MAX_PAGE);
    // `list_loved` 要求 limit 在 1..=500，`Paging` 已经夹过了。
    let rows = state.core.loved_tracks(paging.offset, paging.size).await?;
    Ok(ok(json!({
        "starred2": {
            "artist": [],
            "album": [],
            "song": songs(&state, &rows, true).await,
        }
    })))
}

/// `scrobble?id=&submission=&time=`：播放上报。
///
/// - `submission=true`（默认）：播放完成，落一条播放记录（`LekisCore::record_play`）。
/// - `submission=false`：刚开始播放。Subsonic 的 "now playing" 我们没有单独的表，
///   写播放历史反而会污染统计，所以只校验曲目存在。
async fn scrobble(
    State(state): State<AppState>,
    RawQuery(raw): RawQuery,
) -> std::result::Result<Json<Value>, SubsonicError> {
    let params = Params::from_raw(&raw);
    // 校验一下参数形态，这样客户端配置错的时候能立刻看到错误码。
    let ids = params.get_all("id");
    if ids.is_empty() {
        return Err(LekisError::invalid("missing parameter: id").into());
    }
    let submission = params.bool_or("submission", true);
    for raw in ids {
        let id = raw.trim().parse::<i64>().map_err(|_| {
            LekisError::invalid(format!("parameter id: expected a numeric id, got {raw:?}"))
        })?;
        let track_id = lekis_types::TrackId(id);
        if submission {
            // 客户端不告诉我们听了多久（`time` 是上报时刻，不是时长），
            // 用曲目时长当播放时长：能走到这里的本来就是"听完了"。
            let track = state.core.get_track(track_id).await?;
            state.core.record_play(track_id, track.duration_ms).await?;
        } else {
            let _ = state.core.get_track(track_id).await?;
        }
    }
    Ok(ok(json!({})))
}

// ---------------------------------------------------------------------------
// 歌单
// ---------------------------------------------------------------------------

/// 构造一个 `playlist` 对象（`getPlaylists` / `getPlaylist` 共用）。
fn playlist_object(playlist: &lekis_library::Playlist) -> Value {
    let mut obj = json!({
        "id": playlist.id.0.to_string(),
        "name": playlist.name,
        "owner": "",
        "public": false,
        "songCount": playlist.track_count,
        "duration": 0,
        "created": iso8601_ms(playlist.created_at),
        "changed": iso8601_ms(playlist.updated_at),
    });
    set_opt(
        &mut obj,
        "coverArt",
        playlist.artwork_id.map(|id| json!(id.0.to_string())),
    );
    obj
}

/// `getPlaylists`：歌单列表。
async fn get_playlists(
    State(state): State<AppState>,
) -> std::result::Result<Json<Value>, SubsonicError> {
    let playlists = state.core.list_playlists().await?;
    Ok(ok(json!({
        "playlists": {
            "playlist": playlists.iter().map(playlist_object).collect::<Vec<_>>(),
        }
    })))
}

/// `getPlaylist?id=`：歌单详情 + 条目。
async fn get_playlist(
    State(state): State<AppState>,
    RawQuery(raw): RawQuery,
) -> std::result::Result<Json<Value>, SubsonicError> {
    let params = Params::from_raw(&raw);
    let id = required_id(&params, "id")?;
    let playlist_id = lekis_types::PlaylistId(id);
    let playlist = state.core.get_playlist(playlist_id).await?;
    let entries = state.core.playlist_items(playlist_id, 0, MAX_PAGE).await?;

    // `track: None` 是「曲目已不在库里」的占位条目，Subsonic 没有这个概念，跳过。
    let rows = entries
        .iter()
        .filter_map(|entry| entry.track.clone())
        .collect::<Vec<_>>();
    let duration: u64 = rows.iter().map(|row| seconds(row.duration_ms)).sum();

    let mut payload = playlist_object(&playlist);
    payload["duration"] = json!(duration);
    payload["songCount"] = json!(rows.len());
    payload["entry"] = json!(songs(&state, &rows, true).await);
    Ok(ok(json!({ "playlist": payload })))
}

// ---------------------------------------------------------------------------
// 歌词
// ---------------------------------------------------------------------------

/// 解析一个 LRC 时间标签（`mm:ss`、`mm:ss.xx`、`mm:ss:xx`）成毫秒。
fn parse_lrc_timestamp(tag: &str) -> Option<u64> {
    let (minutes, rest) = tag.split_once(':')?;
    let minutes = minutes.trim().parse::<u64>().ok()?;
    // 秒的小数部分可能用 `.` 或 `:` 分隔（两种写法都有实现）。
    let (seconds, fraction) = match rest.split_once(['.', ':']) {
        Some((seconds, fraction)) => (seconds, Some(fraction)),
        None => (rest, None),
    };
    let seconds = seconds.trim().parse::<u64>().ok()?;
    if seconds >= 60 {
        return None;
    }
    let millis = match fraction {
        None => 0,
        Some(fraction) => {
            let fraction = fraction.trim();
            if fraction.is_empty() || !fraction.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            let value = fraction.parse::<u64>().ok()?;
            // `.5` = 500ms，`.50` = 500ms，`.500` = 500ms。
            match fraction.len() {
                1 => value * 100,
                2 => value * 10,
                3 => value,
                _ => return None,
            }
        }
    };
    Some(minutes * 60_000 + seconds * 1000 + millis)
}

/// 把一份歌词转成 OpenSubsonic 的 `structuredLyrics` 对象。
///
/// - `Plain`：逐行输出，`synced: false`。
/// - `Lrc` / `EnhancedLrc`：按行首的 `[mm:ss.xx]` 标签取时间轴，`synced: true`；
///   一行可以有多个标签（`[00:01.00][00:05.00]副歌`）。没有标签的正文行没有 `start`。
/// - `Ttml`：解析 XML 超出本模块范围（会被当成标签行跳过），只输出纯文本行。
fn structured_lyrics(lyrics: &lekis_types::Lyrics) -> Value {
    use lekis_types::LyricsFormat;
    let offset = i64::from(lyrics.offset_ms);
    let mut lines = Vec::new();

    if matches!(lyrics.format, LyricsFormat::Lrc | LyricsFormat::EnhancedLrc) {
        for raw in lyrics.content.lines() {
            let text = raw.trim();
            if text.is_empty() {
                continue;
            }
            let mut rest = text;
            let mut starts = Vec::new();
            while let Some(stripped) = rest.strip_prefix('[') {
                let Some((tag, tail)) = stripped.split_once(']') else {
                    break;
                };
                match parse_lrc_timestamp(tag) {
                    Some(ms) => {
                        starts.push(ms);
                        rest = tail;
                    }
                    // 不是时间标签（`[ar:...]` / `[ti:...]` 之类的元信息）：跳过整行。
                    None => {
                        starts.clear();
                        break;
                    }
                }
            }
            let value = rest.trim();
            if value.is_empty() {
                continue;
            }
            if starts.is_empty() {
                // 元信息行（`[ar:xxx]`）没有正文，`rest` 还是原串；丢弃。
                if text.starts_with('[') {
                    continue;
                }
                lines.push(json!({ "value": value }));
                continue;
            }
            for start in starts {
                let start = (start as i64 + offset).max(0) as u64;
                lines.push(json!({ "start": start, "value": value }));
            }
        }
    } else {
        for raw in lyrics.content.lines() {
            let value = raw.trim();
            if value.is_empty() {
                continue;
            }
            lines.push(json!({ "value": value }));
        }
    }

    let synced = lines.iter().any(|line| line.get("start").is_some());
    json!({
        "displayArtist": "",
        "displayTitle": "",
        "lang": "und",
        "synced": synced,
        "line": lines,
    })
}

/// `getLyricsBySongId?id=`：结构化歌词。
///
/// 没有歌词时返回空 `structuredLyrics`（合法响应，客户端会显示"无歌词"）；
/// 曲目不存在时回错误码 70（让客户端能区分"歌没了"和"没歌词"）。
async fn get_lyrics_by_song_id(
    State(state): State<AppState>,
    RawQuery(raw): RawQuery,
) -> std::result::Result<Json<Value>, SubsonicError> {
    let params = Params::from_raw(&raw);
    let id = required_id(&params, "id")?;
    let track_id = lekis_types::TrackId(id);
    let _ = state.core.get_track(track_id).await?;
    let structured = match state.core.lyrics(track_id).await? {
        Some(lyrics) => vec![structured_lyrics(&lyrics)],
        None => Vec::new(),
    };
    Ok(ok(
        json!({ "lyricsList": { "structuredLyrics": structured } }),
    ))
}

// ---------------------------------------------------------------------------
// 扫描
// ---------------------------------------------------------------------------

/// `getScanStatus`：扫描进度。
async fn get_scan_status(State(state): State<AppState>) -> Json<Value> {
    let (done, _total) = state.scan.progress();
    ok(json!({
        "scanStatus": {
            "scanning": state.scan.scanning(),
            "count": done,
        }
    }))
}

/// `startScan`：触发所有启用音源的扫描，返回当前状态。
async fn start_scan(
    State(state): State<AppState>,
) -> std::result::Result<Json<Value>, SubsonicError> {
    let started = scan::start_all(&state).await?;
    if started == 0 {
        tracing::info!(target: "node", "startScan: 没有启用的音源，未发起扫描");
    }
    let (done, _total) = state.scan.progress();
    Ok(ok(json!({
        "scanStatus": {
            "scanning": state.scan.scanning(),
            "count": done,
        }
    })))
}

// ---------------------------------------------------------------------------
// 图片 / 音频流
// ---------------------------------------------------------------------------

/// Subsonic 的 `size` 参数（像素边长）。`0` / 非数字 / 缺失都当作"没指定"。
///
/// 我们只回缓存里已有的那一档（见 [`get_cover_art`]），这个值只用于日志。
fn requested_width(params: &Params) -> Option<u32> {
    let raw = params.get("size")?;
    let value = raw.trim().parse::<u32>().ok()?;
    if value == 0 {
        None
    } else {
        Some(value)
    }
}

/// 解析封面 id 到「artwork 元数据」。
///
/// 曲目走 `LekisCore::artwork(TrackId)`（曲目级 → 专辑级回落）；
/// 专辑走「专辑的第一首曲目的生效封面」——核心没有 `artwork(AlbumId)`，
/// 而同专辑曲目的 `effective_artwork` 本来就回落到专辑封面，所以结果一致。
async fn resolve_cover_art(
    state: &AppState,
    reference: CoverArtRef,
) -> std::result::Result<Option<lekis_library::ArtworkRow>, LekisError> {
    match reference {
        CoverArtRef::Track(track_id) => {
            // 先确认曲目存在：不存在要给 70，而不是「没有封面」。
            state.core.get_track(track_id).await?;
            state.core.artwork(track_id).await
        }
        CoverArtRef::Album(album_id) => {
            state.core.get_album(album_id).await?;
            let rows = state.core.album_tracks(album_id, 0, 1).await?;
            let Some(row) = rows.first() else {
                return Ok(None);
            };
            state.core.artwork(row.id).await
        }
    }
}

/// `getCoverArt?id=&size=`：封面（缓存目录里的 WebP 缩略图）。
///
/// - 没有封面 / 缓存文件还没生成：**真 HTTP 404**（见模块头部对「为什么这里不用 200」）。
/// - `size` 参数被忽略：缓存里只有一档（`lekis-core` 补全管线按长边 1024 落盘，小图不放大），
///   运行时缩放需要图像处理依赖，`lekis-node` 不引。客户端拿到大图自己会缩。
async fn get_cover_art(State(state): State<AppState>, RawQuery(raw): RawQuery) -> Response {
    let params = Params::from_raw(&raw);
    let requested = requested_width(&params);
    let id = match params.require("id") {
        Ok(id) => id.to_string(),
        Err(error) => return error_response(&error),
    };
    let reference = match parse_cover_art_id(&id) {
        Ok(reference) => reference,
        Err(error) => return error_response(&error),
    };
    let artwork = match resolve_cover_art(&state, reference).await {
        Ok(Some(artwork)) => artwork,
        Ok(None) => {
            return failed_response(
                StatusCode::NOT_FOUND,
                70,
                "getCoverArt: no artwork for this item",
            )
        }
        Err(error) if error.code == ErrorCode::NotFound => {
            return failed_response(StatusCode::NOT_FOUND, 70, &error.message)
        }
        Err(error) => return error_response(&error),
    };

    // 文件名里的宽度是「写盘时的实际宽度」(`process_image` 不放大，可能小于 1024)，
    // 所以必须用元数据里的 width 反推路径，不能直接用 `size` 参数。
    let width = artwork.width.unwrap_or(MAX_ARTWORK_PX);
    if let Some(requested) = requested.filter(|requested| *requested != width) {
        tracing::debug!(
            target: "node",
            requested,
            available = width,
            "getCoverArt: 只有一档缩放缓存，忽略 size 参数",
        );
    }
    let path = state.core.artwork_path(artwork.hash.clone(), width);
    match tokio::fs::read(&path).await {
        Ok(bytes) => (
            StatusCode::OK,
            [
                (axum::http::header::CONTENT_TYPE, "image/webp"),
                (axum::http::header::CACHE_CONTROL, "public, max-age=86400"),
            ],
            bytes,
        )
            .into_response(),
        Err(error) => {
            tracing::debug!(
                target: "node",
                path = %path,
                error = %error,
                "getCoverArt: 封面缓存文件不存在，先回 404（等补全管线生成缩略图）",
            );
            failed_response(
                StatusCode::NOT_FOUND,
                70,
                "getCoverArt: the artwork file is not in the cache directory yet",
            )
        }
    }
}

/// `stream` / `download`：音频流（未实现，见模块头部 TODO(NOD-06)）。
async fn stream(State(state): State<AppState>, RawQuery(raw): RawQuery) -> Response {
    let params = Params::from_raw(&raw);
    let id = match required_id(&params, "id") {
        Ok(id) => id,
        Err(error) => return error_response(&error),
    };
    // 曲目不存在就直接回 70，让客户端把这条记录标坏，而不是对 501 做无限重试。
    match state.core.get_track(lekis_types::TrackId(id)).await {
        Ok(_) => not_implemented(
            StatusCode::NOT_IMPLEMENTED,
            "stream is not implemented yet: LekisCore must expose Library::track_files so the node \
             can resolve a track to a local path (Range streaming) or an upstream URL (302) \
             (see TODO(NOD-06) in core/bins/lekis-node/src/opensubsonic.rs)",
        ),
        Err(error) => error_response(&error),
    }
}

// ---------------------------------------------------------------------------
// 路由
// ---------------------------------------------------------------------------

/// 注册一个接口的两个路径变体：`/xxx` 和 `/xxx.view`。
macro_rules! route_pair {
    ($router:expr, $path:literal, $handler:expr) => {
        $router
            .route($path, get($handler))
            .route(concat!($path, ".view"), get($handler))
    };
}

/// `/rest` 下的全部路由（外层会挂 Subsonic 认证中间件）。
pub fn router() -> Router<AppState> {
    let router = Router::new();
    let router = route_pair!(router, "/ping", ping);
    let router = route_pair!(router, "/getLicense", get_license);
    let router = route_pair!(router, "/getOpenSubsonicExtensions", extensions);
    let router = route_pair!(router, "/getUser", get_user);
    let router = route_pair!(router, "/getMusicFolders", get_music_folders);

    let router = route_pair!(router, "/getArtists", get_artists);
    let router = route_pair!(router, "/getIndexes", get_indexes);
    let router = route_pair!(router, "/getArtist", get_artist);
    let router = route_pair!(router, "/getArtistInfo2", get_artist_info2);

    let router = route_pair!(router, "/getAlbum", get_album);
    let router = route_pair!(router, "/getAlbumInfo2", get_album_info2);
    let router = route_pair!(router, "/getAlbumList2", get_album_list2);

    let router = route_pair!(router, "/getSong", get_song);
    let router = route_pair!(router, "/getRandomSongs", get_random_songs);
    let router = route_pair!(router, "/getGenres", get_genres);
    let router = route_pair!(router, "/getSongsByGenre", get_songs_by_genre);
    let router = route_pair!(router, "/search3", search3);

    let router = route_pair!(router, "/setRating", set_rating);
    let router = route_pair!(router, "/star", star);
    let router = route_pair!(router, "/unstar", unstar);
    let router = route_pair!(router, "/getStarred2", get_starred2);
    let router = route_pair!(router, "/scrobble", scrobble);

    let router = route_pair!(router, "/getPlaylists", get_playlists);
    let router = route_pair!(router, "/getPlaylist", get_playlist);
    let router = route_pair!(router, "/getLyricsBySongId", get_lyrics_by_song_id);

    let router = route_pair!(router, "/getScanStatus", get_scan_status);
    let router = route_pair!(router, "/startScan", start_scan);

    let router = route_pair!(router, "/getCoverArt", get_cover_art);
    route_pair!(router, "/stream", stream)
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::md5;
    use crate::test_support::TestApp;
    use axum::body::{to_bytes, Body};
    use axum::http::Request;
    use serde_json::Value as JsonValue;
    use tower::ServiceExt;

    /// 起一个 `Router` 并打一次 GET，返回 (HTTP 状态, 解析后的 body)。
    async fn call(app: &TestApp, uri: &str) -> (StatusCode, JsonValue) {
        let response = app
            .router
            .clone()
            .oneshot(Request::builder().uri(uri).body(Body::empty()).unwrap())
            .await
            .unwrap();
        let status = response.status();
        let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
        let body = serde_json::from_slice(&bytes).unwrap_or(JsonValue::Null);
        (status, body)
    }

    /// 打一个 `/rest` 接口（带上通过明文密码认证的参数；`for_tests` 打开了明文认证）。
    async fn rest(app: &TestApp, endpoint: &str) -> (StatusCode, JsonValue) {
        call(app, &app.rest_uri(endpoint, "")).await
    }

    /// 取 `subsonic-response` 外壳。
    fn payload(body: &JsonValue) -> &JsonValue {
        &body["subsonic-response"]
    }

    #[tokio::test]
    async fn ping_succeeds_with_valid_credentials() {
        let app = crate::test_support::test_app("os-ping");
        let (status, body) = rest(&app, "ping").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(payload(&body)["status"], "ok");
        assert_eq!(payload(&body)["version"], API_VERSION);
        assert_eq!(payload(&body)["type"], "lekis");
        assert_eq!(payload(&body)["openSubsonic"], true);
    }

    #[tokio::test]
    async fn view_suffix_is_registered_for_every_endpoint() {
        let app = crate::test_support::test_app("os-view");
        let (status, body) = rest(&app, "ping.view").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(payload(&body)["status"], "ok");

        // 抽查两个真正干活的接口。
        let (status, _) = rest(&app, "getLicense.view").await;
        assert_eq!(status, StatusCode::OK);
        let (status, _) = rest(&app, "getScanStatus.view").await;
        assert_eq!(status, StatusCode::OK);
    }

    #[tokio::test]
    async fn missing_credentials_fail_with_http_200_and_code_10() {
        let app = crate::test_support::test_app("os-noauth");
        let (status, body) = call(&app, "/rest/ping?c=test&v=1.16.1&f=json").await;
        // Subsonic 协议：错误也是 HTTP 200。
        assert_eq!(status, StatusCode::OK);
        assert_eq!(payload(&body)["status"], "failed");
        assert_eq!(payload(&body)["error"]["code"], 10);
    }

    #[tokio::test]
    async fn wrong_token_fails_with_code_40() {
        let app = crate::test_support::test_app("os-badtoken");
        let uri =
            "/rest/ping?u=admin&t=deadbeefdeadbeefdeadbeefdeadbeef&s=abc&v=1.16.1&c=test&f=json";
        let (status, body) = call(&app, uri).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(payload(&body)["status"], "failed");
        assert_eq!(payload(&body)["error"]["code"], 40);
    }

    #[tokio::test]
    async fn token_authentication_works() {
        let app = crate::test_support::test_app("os-token");
        let salt = "s4lt";
        let password = app.auth.subsonic_password();
        let hash = md5::hex_digest(format!("{password}{salt}").as_bytes());
        let uri = format!("/rest/ping?u=admin&t={hash}&s={salt}&v=1.16.1&c=test&f=json");
        let (status, body) = call(&app, &uri).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(payload(&body)["status"], "ok");
    }

    #[tokio::test]
    async fn api_key_authentication_works() {
        let app = crate::test_support::test_app("os-apikey");
        let token = app.auth.api_token().to_string();
        let uri = format!("/rest/ping?apiKey={token}&v=1.16.1&c=test&f=json");
        let (_, body) = call(&app, &uri).await;
        assert_eq!(payload(&body)["status"], "ok");
    }

    #[tokio::test]
    async fn unknown_endpoint_is_404_without_requiring_auth() {
        // 认证是 `route_layer`，只包已注册的路由；未注册的路径应当干净地 404，
        // 而不是先被认证中间件拦成 200 + failed。
        let app = crate::test_support::test_app("os-404");
        let (status, _) = call(&app, "/rest/thisEndpointDoesNotExist").await;
        assert_eq!(status, StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn get_license_is_always_valid() {
        let app = crate::test_support::test_app("os-license");
        let (_, body) = rest(&app, "getLicense").await;
        assert_eq!(payload(&body)["license"]["valid"], true);
    }

    #[tokio::test]
    async fn get_user_reports_the_configured_username() {
        let app = crate::test_support::test_app("os-user");
        let (_, body) = rest(&app, "getUser").await;
        assert_eq!(payload(&body)["user"]["username"], "admin");
        assert_eq!(payload(&body)["user"]["streamRole"], true);
    }

    #[tokio::test]
    async fn empty_library_still_returns_well_formed_payloads() {
        let app = crate::test_support::test_app("os-empty");

        let (_, body_json) = rest(&app, "getMusicFolders").await;
        assert_eq!(
            payload(&body_json)["musicFolders"]["musicFolder"],
            json!([])
        );

        let (_, body_json) = rest(&app, "getArtists").await;
        assert_eq!(payload(&body_json)["artists"]["index"], json!([]));

        let (_, body_json) = rest(&app, "getAlbumList2?type=newest").await;
        assert_eq!(payload(&body_json)["albumList2"]["album"], json!([]));

        let (_, body_json) = rest(&app, "search3?query=jay").await;
        assert_eq!(payload(&body_json)["searchResult3"]["song"], json!([]));

        let (_, body_json) = rest(&app, "getGenres").await;
        assert_eq!(payload(&body_json)["genres"]["genre"], json!([]));

        let (_, body_json) = rest(&app, "getPlaylists").await;
        assert_eq!(payload(&body_json)["playlists"]["playlist"], json!([]));

        let (_, body_json) = rest(&app, "getStarred2").await;
        assert_eq!(payload(&body_json)["starred2"]["song"], json!([]));
    }

    #[tokio::test]
    async fn empty_search_query_short_circuits() {
        let app = crate::test_support::test_app("os-emptysearch");
        let (status, body) = rest(&app, "search3?query=").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(payload(&body)["status"], "ok");
        assert_eq!(payload(&body)["searchResult3"]["artist"], json!([]));
    }

    #[tokio::test]
    async fn scan_status_reports_idle() {
        let app = crate::test_support::test_app("os-scan");
        let (_, body) = rest(&app, "getScanStatus").await;
        assert_eq!(payload(&body)["scanStatus"]["scanning"], false);
        assert_eq!(payload(&body)["scanStatus"]["count"], 0);

        // 没有配置音源时 `startScan` 也是成功的（只是没扫任何东西）。
        let (status, body) = rest(&app, "startScan").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(payload(&body)["status"], "ok");
        assert_eq!(payload(&body)["scanStatus"]["scanning"], false);
    }

    #[tokio::test]
    async fn missing_required_parameter_is_code_10() {
        let app = crate::test_support::test_app("os-noparam");
        for endpoint in ["getAlbum", "getArtist", "getSong", "getCoverArt"] {
            let (status, body) = rest(&app, endpoint).await;
            assert_eq!(status, StatusCode::OK, "{endpoint} 的错误也是 HTTP 200");
            assert_eq!(payload(&body)["status"], "failed", "{endpoint}");
            assert_eq!(payload(&body)["error"]["code"], 10, "{endpoint} 缺少 id");
        }
    }
    #[tokio::test]
    async fn nonexistent_entities_are_code_70() {
        let app = crate::test_support::test_app("os-notfound");
        for endpoint in ["getAlbum?id=9999", "getArtist?id=9999", "getSong?id=9999"] {
            let (status, body) = rest(&app, endpoint).await;
            assert_eq!(status, StatusCode::OK);
            assert_eq!(payload(&body)["status"], "failed", "{endpoint}");
            assert_eq!(payload(&body)["error"]["code"], 70, "{endpoint}");
        }
    }

    #[tokio::test]
    async fn star_requires_at_least_one_id() {
        let app = crate::test_support::test_app("os-star");
        let (_, body) = rest(&app, "star").await;
        assert_eq!(payload(&body)["error"]["code"], 10);
        // 给了 id 但曲目不存在 → 70（不是 500）。
        let (_, body) = rest(&app, "star?id=9999").await;
        assert_eq!(payload(&body)["error"]["code"], 70);
        // 只有 albumId 时不报错（我们暂时无操作）。
        let (_, body) = rest(&app, "star?albumId=1").await;
        assert_eq!(payload(&body)["status"], "ok");
    }

    #[tokio::test]
    async fn set_rating_validates_range() {
        let app = crate::test_support::test_app("os-rating");
        let (_, body) = rest(&app, "setRating?id=9999&rating=9").await;
        assert_eq!(payload(&body)["error"]["code"], 10);
        let (_, body) = rest(&app, "setRating?id=9999&rating=3").await;
        assert_eq!(payload(&body)["error"]["code"], 70);
    }

    #[tokio::test]
    async fn scrobble_validates_id() {
        let app = crate::test_support::test_app("os-scrobble");
        let (_, body) = rest(&app, "scrobble").await;
        assert_eq!(payload(&body)["error"]["code"], 10);
        // 现在 scrobble 会真的落一条播放记录，所以曲目不存在就必须报 70，
        // 而不是假装成功（否则客户端以为上报成功，统计里却没有这条）。
        let (_, body) = rest(&app, "scrobble?id=1&submission=true").await;
        assert_eq!(payload(&body)["status"], "failed");
        assert_eq!(payload(&body)["error"]["code"], 70);
        let (_, body) = rest(&app, "scrobble?id=1&submission=false").await;
        assert_eq!(payload(&body)["error"]["code"], 70);
    }

    #[tokio::test]
    async fn unsupported_album_list_type_is_rejected() {
        let app = crate::test_support::test_app("os-badtype");
        let (_, body) = rest(&app, "getAlbumList2?type=nonsense").await;
        assert_eq!(payload(&body)["error"]["code"], 10);
        // 知道但不支持的维度给空列表 + note，不报错。
        let (_, body) = rest(&app, "getAlbumList2?type=starred").await;
        assert_eq!(payload(&body)["status"], "ok");
        assert_eq!(payload(&body)["albumList2"]["album"], json!([]));
    }

    #[tokio::test]
    async fn get_playlist_and_get_playlists_hit_the_core() {
        let app = crate::test_support::test_app("os-playlist");
        // 空库里没有歌单：列表是空的，详情是不存在（70），都不是 500 / 60。
        let (status, body) = rest(&app, "getPlaylists").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(payload(&body)["status"], "ok");
        assert_eq!(payload(&body)["playlists"]["playlist"], json!([]));

        let (status, body) = rest(&app, "getPlaylist?id=1").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(payload(&body)["status"], "failed");
        assert_eq!(payload(&body)["error"]["code"], 70);
    }

    #[tokio::test]
    async fn lyrics_are_empty_for_existing_songs_only() {
        let app = crate::test_support::test_app("os-lyrics");
        // 曲目不存在 → 70（客户端能把这条记录标坏）。
        let (_, body) = rest(&app, "getLyricsBySongId?id=9999").await;
        assert_eq!(payload(&body)["error"]["code"], 70);
        // 缺少 id → 10。
        let (_, body) = rest(&app, "getLyricsBySongId").await;
        assert_eq!(payload(&body)["error"]["code"], 10);
    }

    #[test]
    fn lrc_timestamps_parse_the_common_variants() {
        assert_eq!(parse_lrc_timestamp("00:01"), Some(1_000));
        assert_eq!(parse_lrc_timestamp("01:02.5"), Some(62_500));
        assert_eq!(parse_lrc_timestamp("01:02.50"), Some(62_500));
        assert_eq!(parse_lrc_timestamp("01:02.500"), Some(62_500));
        // 有的实现用 `:` 分隔小数。
        assert_eq!(parse_lrc_timestamp("00:03:25"), Some(3_250));
        assert_eq!(parse_lrc_timestamp("10:00"), Some(600_000));
        // 秒必须 < 60，小数最多 3 位。
        assert_eq!(parse_lrc_timestamp("00:60"), None);
        assert_eq!(parse_lrc_timestamp("00:01.5000"), None);
        // 元信息标签不是时间。
        assert_eq!(parse_lrc_timestamp("ar:周杰伦"), None);
        assert_eq!(parse_lrc_timestamp(""), None);
    }

    #[test]
    fn structured_lyrics_parses_lrc_timelines() {
        let lyrics = lekis_types::Lyrics {
            format: lekis_types::LyricsFormat::Lrc,
            content: "[ar:周杰伦]\n[00:01.00]第一行\n[00:05.50][00:10.00]副歌\n\n".into(),
            source: "test".into(),
            offset_ms: 0,
            confidence: 1.0,
        };
        let value = structured_lyrics(&lyrics);
        assert_eq!(value["synced"], true);
        let lines = value["line"].as_array().unwrap();
        // `[ar:...]` 是元信息，丢掉；多标签的一行展开成多行。
        assert_eq!(lines.len(), 3);
        assert_eq!(lines[0]["start"], 1_000);
        assert_eq!(lines[0]["value"], "第一行");
        assert_eq!(lines[1]["start"], 5_500);
        assert_eq!(lines[2]["start"], 10_000);
        assert_eq!(lines[2]["value"], "副歌");
    }

    #[test]
    fn structured_lyrics_offsets_and_plain_text() {
        let shifted = lekis_types::Lyrics {
            format: lekis_types::LyricsFormat::Lrc,
            content: "[00:00.20]早".into(),
            source: "test".into(),
            offset_ms: -500,
            confidence: 1.0,
        };
        // 负偏移被夹到 0（Subsonic 的 `start` 不能是负数）。
        assert_eq!(structured_lyrics(&shifted)["line"][0]["start"], 0);

        let plain = lekis_types::Lyrics {
            format: lekis_types::LyricsFormat::Plain,
            content: "第一行\n\n第二行\n".into(),
            source: "test".into(),
            offset_ms: 0,
            confidence: 1.0,
        };
        let value = structured_lyrics(&plain);
        assert_eq!(value["synced"], false);
        let lines = value["line"].as_array().unwrap();
        assert_eq!(lines.len(), 2, "空行要丢掉");
        assert!(lines[0].get("start").is_none(), "纯文本没有时间轴");
    }

    #[test]
    fn cover_art_ids_are_namespaced() {
        assert!(matches!(
            parse_cover_art_id("t12"),
            Ok(CoverArtRef::Track(lekis_types::TrackId(12)))
        ));
        // 裸数字当成曲目（兼容手填的客户端）。
        assert!(matches!(
            parse_cover_art_id("7"),
            Ok(CoverArtRef::Track(lekis_types::TrackId(7)))
        ));
        assert!(matches!(
            parse_cover_art_id("a3"),
            Ok(CoverArtRef::Album(lekis_types::AlbumId(3)))
        ));
        assert!(parse_cover_art_id("t").is_err());
        assert!(parse_cover_art_id("a").is_err());
        assert!(parse_cover_art_id("t12x").is_err());
        // 曲目和专辑用不同前缀，所以 id 不会撞车。
        assert_eq!(cover_art_track(lekis_types::TrackId(1)), "t1");
        assert_eq!(cover_art_album(lekis_types::AlbumId(1)), "a1");
    }

    #[tokio::test]
    async fn cover_art_and_stream_are_not_500() {
        let app = crate::test_support::test_app("os-media");
        // 封面：曲目不存在 → 真 404 + 70（浏览器会把响应体当图片渲染，
        // 200 + JSON 会被当成坏图反复重试）。
        let (status, body) = rest(&app, "getCoverArt?id=t1").await;
        assert_eq!(status, StatusCode::NOT_FOUND);
        assert_eq!(payload(&body)["error"]["code"], 70);

        // 非法的封面 id → 200 + 10（参数错误，不是资源不存在）。
        let (status, body) = rest(&app, "getCoverArt?id=t12x").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(payload(&body)["error"]["code"], 10);

        // 音频流：不存在的曲目先回 70，存在的才会是 501。
        let (status, body) = rest(&app, "stream?id=9999").await;
        assert_eq!(status, StatusCode::OK, "不存在的曲目先回 70");
        assert_eq!(payload(&body)["error"]["code"], 70);
    }

    #[test]
    fn requested_width_is_tolerant() {
        assert_eq!(requested_width(&Params::parse("size=0")), None);
        assert_eq!(requested_width(&Params::parse("size=320")), Some(320));
        assert_eq!(requested_width(&Params::parse("size=abc")), None);
        assert_eq!(requested_width(&Params::parse("")), None);
    }
    #[tokio::test]
    async fn tolerant_to_unknown_parameters() {
        let app = crate::test_support::test_app("os-tolerant");
        // 客户端会塞一大堆我们不看的东西。
        let uri = app.rest_uri(
            "ping",
            "c=jellyfin-subsonic&v=1.16.1&f=json&callback=cb&_=1700000000000&format=raw",
        );
        let (status, body) = call(&app, &uri).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(payload(&body)["status"], "ok");
    }

    #[test]
    fn index_letters_group_non_ascii_and_symbols() {
        assert_eq!(index_letter("Beatles"), "B");
        assert_eq!(index_letter("  abbey road"), "A");
        // CJK 和其它非 ASCII 首字符归到 `#`（Subsonic 客户端能接受）。
        assert_eq!(index_letter("《无与伦比》"), "#");
        assert_eq!(index_letter("周杰伦"), "#");
        assert_eq!(index_letter(""), "#");
        assert_eq!(index_letter("123"), "#");
    }

    #[test]
    fn error_codes_follow_the_subsonic_table() {
        assert_eq!(subsonic_code(ErrorCode::InvalidArgument), 10);
        assert_eq!(subsonic_code(ErrorCode::Auth), 40);
        assert_eq!(subsonic_code(ErrorCode::PermissionDenied), 50);
        assert_eq!(subsonic_code(ErrorCode::NotImplemented), 60);
        assert_eq!(subsonic_code(ErrorCode::Unsupported), 60);
        assert_eq!(subsonic_code(ErrorCode::NotFound), 70);
        assert_eq!(subsonic_code(ErrorCode::Internal), 0);
    }

    #[test]
    fn paging_is_clamped_to_the_library_limits() {
        let params = Params::parse("size=0");
        assert_eq!(Paging::new(&params, 10).size, 10);
        let params = Params::parse("size=-5");
        assert_eq!(Paging::new(&params, 10).size, 10);
        let params = Params::parse("size=99999");
        assert_eq!(Paging::new(&params, 10).size, MAX_PAGE);
        let params = Params::parse("size=25&offset=50");
        let paging = Paging::new(&params, 10);
        assert_eq!((paging.size, paging.offset), (25, 50));
    }

    #[test]
    fn songs_omit_absent_fields_instead_of_emitting_null() {
        let row = TrackRow {
            id: lekis_types::TrackId(7),
            title: "夜曲".into(),
            artist_line: "周杰伦".into(),
            album_title: None,
            duration_ms: 226_000,
            artwork_id: None,
            quality_badge: None,
            loved: false,
        };
        let value = song(&row, None);
        assert_eq!(value["id"], "7");
        assert_eq!(value["duration"], 226);
        assert_eq!(value["artist"], "周杰伦");
        assert!(value.get("album").is_none(), "没有专辑就不要写 null");
        assert!(value.get("coverArt").is_none());
        assert!(value.get("starred").is_none());
    }
}
