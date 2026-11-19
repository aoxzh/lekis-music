//! 核心门面：Flutter 调用的全部函数。
//!
//! 和 lekis-ffi 的 `LekisCore` 方法一一对应（ADR-0006），只是把对象方法换成了全局函数：
//! 进程里只有一个核心实例，先调用 [`init_core`]，再调用其他函数。

use std::sync::Arc;

use flutter_rust_bridge::frb;

use crate::api::dto::*;
use crate::api::error::CoreError;
use crate::frb_generated::StreamSink;

use crate::credentials::FileCredentials;
use crate::internal::{core, SinkListener, CORE};

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();

    #[cfg(target_os = "android")]
    {
        use std::sync::Once;
        static INIT: Once = Once::new();
        INIT.call_once(|| {
            android_logger::init_once(
                android_logger::Config::default()
                    .with_max_level(log::LevelFilter::Debug)
                    .with_tag("lekis"),
            );
            std::panic::set_hook(Box::new(|info| {
                log::error!("RUST PANIC: {info}");
            }));
        });
    }
}

/// 创建核心（打开数据库、启动后台运行时）。重复调用直接返回。
pub fn init_core(config: CoreConfigDto) -> Result<(), CoreError> {
    if CORE.get().is_some() {
        return Ok(());
    }
    // 凭据按引用存在数据目录的 credentials.json 里（Windows 用 DPAPI 加密，见 credentials.rs）。
    let platform = lekis_core::PlatformServices {
        credentials: Arc::new(FileCredentials::open(std::path::Path::new(&config.data_dir))),
    };
    let inner = lekis_core::LekisCore::new(config.into(), platform)?;
    let _ = CORE.set(inner);
    Ok(())
}

/// 核心事件流（播放状态、进度、扫描进度、资料库变化……）。
pub fn core_events(sink: StreamSink<CoreEventDto>) {
    core().add_listener(Arc::new(SinkListener(sink)));
}

#[frb(sync)]
pub fn device_id() -> String {
    core().device_id().0
}

#[frb(sync)]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

// ---- 音源 ----

pub async fn add_source(source: SourceConfigDto) -> Result<i64, CoreError> {
    Ok(core().add_source(source.into()).await?.0)
}

pub async fn list_sources() -> Result<Vec<SourceConfigDto>, CoreError> {
    Ok(core()
        .list_sources()
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// 修改音源（`source.id` 必须有值）。旧连接会被丢掉，下次按新配置重连。
pub async fn update_source(source: SourceConfigDto) -> Result<(), CoreError> {
    Ok(core().update_source(source.into()).await?)
}

/// 删除音源及其曲目 / 索引行（发 `LibraryChanged`）。不删钥匙串里的凭据。
pub async fn remove_source(source_id: i64) -> Result<(), CoreError> {
    Ok(core()
        .remove_source(lekis_types::SourceId(source_id))
        .await?)
}

/// 试连一个音源（不保存）：文件系统源列根目录，服务器源 ping + 取一首。
/// 密码先用 `set_credential` 按 `credential_ref` 存好再测。
pub async fn test_source(source: SourceConfigDto) -> Result<(), CoreError> {
    Ok(core().test_source(source.into()).await?)
}

/// 扫描局域网里的 SMB / WebDAV / DLNA 服务，`timeout_ms` 后返回。
///
/// 一次性扫描，不注册任何服务。各协议的错误只记日志，不会让整次扫描失败。
/// Android 上调用前需要持有 `WifiManager.MulticastLock`（由 Dart 侧平台通道
/// 包住这次调用），否则 mDNS / SSDP 的组播包收不到。
pub async fn discover_lan(timeout_ms: u32) -> Result<Vec<DiscoveredServiceDto>, CoreError> {
    let timeout = std::time::Duration::from_millis(u64::from(timeout_ms));
    Ok(lekis_core::discovery::discover(timeout)
        .await
        .into_iter()
        .map(Into::into)
        .collect())
}

/// 音源列表，带最近一次扫描的时间 / 失败信息。
pub async fn list_source_infos() -> Result<Vec<SourceInfoDto>, CoreError> {
    Ok(core()
        .list_source_infos()
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

// ---- 凭据（SRC-15）----

/// 按引用保存密码 / token（`SourceConfigDto.credential_ref`）。明文不会再读回 Dart。
pub async fn set_credential(credential_ref: String, secret: String) -> Result<(), CoreError> {
    Ok(core().set_credential(credential_ref, secret).await?)
}

/// 删除一个凭据。
pub async fn delete_credential(credential_ref: String) -> Result<(), CoreError> {
    Ok(core().delete_credential(credential_ref).await?)
}

/// 某个引用是否已经保存了凭据（不返回内容）。
#[frb(sync)]
pub fn has_credential(credential_ref: String) -> bool {
    core().has_credential(&credential_ref)
}

pub async fn start_scan(source_id: i64) -> Result<(), CoreError> {
    Ok(core()
        .start_scan(lekis_types::SourceId(source_id))
        .await?)
}

// ---- 资料库 ----

pub async fn list_tracks(
        sort: TrackSortDto,
    offset: u32,
    limit: u32,
) -> Result<Vec<TrackRowDto>, CoreError> {
    let q = lekis_types::TrackQuery {
        sort: sort.into(),
        offset,
        limit,
    };
    Ok(core()
        .list_tracks(q)
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// 曲目详情（含收藏 / 评分 / 播放次数）。
pub async fn get_track(track_id: i64) -> Result<TrackDto, CoreError> {
    Ok(core()
        .get_track_with_state(lekis_types::TrackId(track_id))
        .await?
        .into())
}

// ---- 计数（滚动条）----

pub async fn count_tracks() -> Result<u64, CoreError> {
    Ok(core().count_tracks().await?)
}

pub async fn count_albums() -> Result<u64, CoreError> {
    Ok(core().count_albums().await?)
}

pub async fn count_artists() -> Result<u64, CoreError> {
    Ok(core().count_artists().await?)
}

pub async fn count_genre_tracks(name: String) -> Result<u64, CoreError> {
    Ok(core().count_genre_tracks(name).await?)
}

pub async fn count_loved() -> Result<u64, CoreError> {
    Ok(core().count_loved().await?)
}

/// 最近播放过的曲目（首页"继续收听"）。
pub async fn recently_played(limit: u32) -> Result<Vec<TrackRowDto>, CoreError> {
    Ok(core()
        .recently_played(limit)
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

pub async fn search(text: String, limit: u32) -> Result<SearchResultsDto, CoreError> {
    Ok(core().search(text, limit).await?.into())
}

// ---- 浏览维度（LIB-06）----

pub async fn list_albums(
        sort: TrackSortDto,
    offset: u32,
    limit: u32,
) -> Result<Vec<AlbumDto>, CoreError> {
    Ok(core()
        .list_albums(sort.into(), offset, limit)
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

pub async fn get_album(album_id: i64) -> Result<AlbumDto, CoreError> {
    Ok(core()
        .get_album(lekis_types::AlbumId(album_id))
        .await?
        .into())
}

pub async fn album_tracks(
        album_id: i64,
    offset: u32,
    limit: u32,
) -> Result<Vec<TrackRowDto>, CoreError> {
    Ok(core()
        .album_tracks(lekis_types::AlbumId(album_id), offset, limit)
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// 专辑的生效封面（专辑没有时取第一首有封面的曲目）。
pub async fn album_artwork(album_id: i64) -> Result<Option<ArtworkDto>, CoreError> {
    Ok(core()
        .album_artwork(lekis_types::AlbumId(album_id))
        .await?
        .map(Into::into))
}

/// 按 ID 取封面元数据。
pub async fn get_artwork(artwork_id: i64) -> Result<ArtworkDto, CoreError> {
    Ok(core()
        .get_artwork(lekis_types::ArtworkId(artwork_id))
        .await?
        .into())
}

pub async fn album_artists(album_id: i64) -> Result<Vec<ArtistDto>, CoreError> {
    Ok(core()
        .album_artists(lekis_types::AlbumId(album_id))
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

pub async fn list_artists(offset: u32, limit: u32) -> Result<Vec<ArtistDto>, CoreError> {
    Ok(core()
        .list_artists(offset, limit)
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

pub async fn get_artist(artist_id: i64) -> Result<ArtistDto, CoreError> {
    Ok(core()
        .get_artist(lekis_types::ArtistId(artist_id))
        .await?
        .into())
}

pub async fn artist_tracks(
        artist_id: i64,
    offset: u32,
    limit: u32,
) -> Result<Vec<TrackRowDto>, CoreError> {
    Ok(core()
        .artist_tracks(lekis_types::ArtistId(artist_id), offset, limit)
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

pub async fn artist_albums(
        artist_id: i64,
    offset: u32,
    limit: u32,
) -> Result<Vec<AlbumDto>, CoreError> {
    Ok(core()
        .artist_albums(lekis_types::ArtistId(artist_id), offset, limit)
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

pub async fn list_genres(limit: u32) -> Result<Vec<GenreCountDto>, CoreError> {
    Ok(core()
        .list_genres(limit)
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

pub async fn genre_tracks(
        name: String,
    offset: u32,
    limit: u32,
) -> Result<Vec<TrackRowDto>, CoreError> {
    Ok(core()
        .genre_tracks(name, offset, limit)
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

pub async fn recently_added(limit: u32) -> Result<Vec<TrackRowDto>, CoreError> {
    Ok(core()
        .recently_added(limit)
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

pub async fn set_loved(track_id: i64, loved: bool) -> Result<(), CoreError> {
    Ok(core()
        .set_loved(lekis_types::TrackId(track_id), loved)
        .await?)
}

/// 给曲目打分（1~5；0 表示清除）。
pub async fn set_rating(track_id: i64, rating: i64) -> Result<(), CoreError> {
    Ok(core()
        .set_rating(lekis_types::TrackId(track_id), rating)
        .await?)
}

// ---- 设置 ----

/// 读一个设置项；不存在时返回 `None`。
pub async fn get_setting(key: String) -> Result<Option<String>, CoreError> {
    Ok(core().get_setting(key).await?)
}

/// 写一个设置项。`sync.` 前缀的设置项会跨设备同步。
pub async fn set_setting(key: String, value: String) -> Result<(), CoreError> {
    Ok(core().set_setting(key, value).await?)
}

// ---- 网络与同步 ----

/// 告诉核心当前的网络环境（`away = true` 表示离开了家庭网络）。
/// 平台层在 Wi-Fi 切换时调用（SRC-14）。
#[frb(sync)]
pub fn set_network_away(away: bool) {
    let net = if away {
        lekis_core::NetworkContext::Away
    } else {
        lekis_core::NetworkContext::Home
    };
    core().set_network_context(net);
}

/// 上报一次音源可达性探测结果，核心据此调整选源顺序（SRC-14）。
#[frb(sync)]
pub fn report_source_reachability(source_id: i64, reachable: bool) {
    core()
        .report_source_reachability(lekis_types::SourceId(source_id), reachable);
}

/// 用某个文件系统音源指向的共享目录跑一轮同步（SYN-01/02）。
///
/// 返回推上去 / 拉下来 / 应用的操作数。`source_id` 必须是可写的文件系统音源
/// （本地目录、SMB 共享、WebDAV 等），核心会在它下面建 `.lekis/sync/`。
pub async fn sync_now(source_id: i64) -> Result<SyncReportDto, CoreError> {
    Ok(core()
        .sync_source(lekis_types::SourceId(source_id))
        .await?
        .into())
}

// ---- 播放（非阻塞）----

#[frb(sync)]
pub fn play_tracks(track_ids: Vec<i64>, start: u32) -> Result<(), CoreError> {
    let ids = track_ids.into_iter().map(lekis_types::TrackId).collect();
    Ok(core().play_tracks(ids, start)?)
}

/// 把整个浏览上下文放进队列，从列表第 `start_index` 行开始播放。返回队列长度。
pub async fn play_context(context: PlayContextDto, start_index: u32) -> Result<u32, CoreError> {
    Ok(core().play_context(context.into(), start_index).await?)
}

/// 追加到队尾（队列为空时直接开始播放）。
#[frb(sync)]
pub fn add_to_queue(track_ids: Vec<i64>) -> Result<(), CoreError> {
    let ids = track_ids.into_iter().map(lekis_types::TrackId).collect();
    Ok(core().add_to_queue(ids)?)
}

/// 插到当前曲目之后（"下一首播放"）。
#[frb(sync)]
pub fn play_next(track_ids: Vec<i64>) -> Result<(), CoreError> {
    let ids = track_ids.into_iter().map(lekis_types::TrackId).collect();
    Ok(core().play_next(ids)?)
}

/// 删除队列里（播放顺序）第 `index` 首。
#[frb(sync)]
pub fn queue_remove(index: u32) -> Result<(), CoreError> {
    Ok(core().queue_remove(index)?)
}

/// 在队列里移动一首（播放顺序下标）。
#[frb(sync)]
pub fn queue_move(from: u32, to: u32) -> Result<(), CoreError> {
    Ok(core().queue_move(from, to)?)
}

/// 队列的一页（播放顺序）。`PlaybackSnapshotDto.queue_version` 变了就重新拉。
pub async fn queue_items(offset: u32, limit: u32) -> Result<Vec<TrackRowDto>, CoreError> {
    Ok(core()
        .queue_items(offset, limit)
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

#[frb(sync)]
pub fn play() -> Result<(), CoreError> {
    Ok(core().play()?)
}

#[frb(sync)]
pub fn pause() -> Result<(), CoreError> {
    Ok(core().pause()?)
}

#[frb(sync)]
pub fn next() -> Result<(), CoreError> {
    Ok(core().next()?)
}

#[frb(sync)]
pub fn previous() -> Result<(), CoreError> {
    Ok(core().previous()?)
}

#[frb(sync)]
pub fn seek(position_ms: u64) -> Result<(), CoreError> {
    Ok(core().seek(position_ms)?)
}

#[frb(sync)]
pub fn set_repeat(mode: RepeatModeDto) -> Result<(), CoreError> {
    Ok(core().set_repeat(mode.into())?)
}

#[frb(sync)]
pub fn set_shuffle(mode: ShuffleModeDto) -> Result<(), CoreError> {
    Ok(core().set_shuffle(mode.into())?)
}

#[frb(sync)]
pub fn set_volume(volume: f32) -> Result<(), CoreError> {
    Ok(core().set_volume(volume)?)
}

#[frb(sync)]
pub fn playback_snapshot() -> PlaybackSnapshotDto {
    core().playback_snapshot().into()
}

// ---- 输出设备（PLY-05/PLY-12）----

/// 列出所有可用的音频输出设备。
#[frb(sync)]
pub fn list_output_devices() -> Result<Vec<OutputDeviceDto>, CoreError> {
    Ok(core()
        .list_output_devices()?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// 切换输出设备；`None` 表示跟随系统默认。播放中切换会从当前位置续播。
#[frb(sync)]
pub fn set_output_device(device_id: Option<String>) -> Result<(), CoreError> {
    Ok(core().set_output_device(device_id)?)
}

/// 切换输出模式（共享 / 独占）。播放中切换会从当前位置续播。
#[frb(sync)]
pub fn set_output_mode(mode: OutputModeDto) -> Result<(), CoreError> {
    Ok(core().set_output_mode(mode.into())?)
}

// ---- 元数据补全（ENR-01/03/06/07）----

/// 给一首歌跑补全流水线（封面 + 歌词）。
pub async fn enrich_track(track_id: i64) -> Result<EnrichReportDto, CoreError> {
    Ok(core()
        .enrich_track(lekis_types::TrackId(track_id))
        .await?
        .into())
}

/// 批量补全。`track_ids` 为空时补全所有缺封面/歌词的曲目。
pub async fn enrich_tracks(track_ids: Vec<i64>) -> Result<EnrichReportDto, CoreError> {
    let ids = track_ids.into_iter().map(lekis_types::TrackId).collect();
    Ok(core().enrich_tracks(ids).await?.into())
}

/// 待确认队列里的候选（ENR-06）。
pub async fn pending_candidates(
        limit: u32,
) -> Result<Vec<EnrichCandidateDto>, CoreError> {
    Ok(core()
        .pending_candidates(limit)
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// 待确认队列长度。
pub async fn pending_candidate_count() -> Result<u64, CoreError> {
    Ok(core().pending_candidate_count().await?)
}

/// 接受一条候选并应用。
pub async fn accept_candidate(candidate_id: i64) -> Result<(), CoreError> {
    Ok(core().accept_candidate(candidate_id).await?)
}

/// 拒绝一条候选。
pub async fn reject_candidate(candidate_id: i64) -> Result<(), CoreError> {
    Ok(core().reject_candidate(candidate_id).await?)
}

/// 接受队列里的全部候选，返回应用条数。
pub async fn accept_all_candidates() -> Result<u64, CoreError> {
    Ok(core().accept_all_candidates().await?)
}

// ---- 歌词 / 封面 ----

/// 取当前生效的歌词。
pub async fn lyrics(track_id: i64) -> Result<Option<LyricsDto>, CoreError> {
    Ok(core()
        .lyrics(lekis_types::TrackId(track_id))
        .await?
        .map(Into::into))
}

/// 取一首歌的全部歌词版本（按来源优先级排序）。
pub async fn lyrics_versions(track_id: i64) -> Result<Vec<LyricsRowDto>, CoreError> {
    Ok(core()
        .lyrics_versions(lekis_types::TrackId(track_id))
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// 手工写一份歌词（ENR-07），返回这条歌词的 ID。
pub async fn set_lyrics(track_id: i64, lyrics: LyricsDto) -> Result<i64, CoreError> {
    Ok(core()
        .set_lyrics(lekis_types::TrackId(track_id), lyrics.into())
        .await?)
}

/// 调整歌词整体偏移（毫秒）。正数 = 歌词提前出现（与 LRC `[offset:]` 相同）。
pub async fn set_lyrics_offset(track_id: i64, offset_ms: i32) -> Result<(), CoreError> {
    Ok(core()
        .set_lyrics_offset(lekis_types::TrackId(track_id), offset_ms)
        .await?)
}

/// 取曲目封面（曲目没有时回落到专辑封面）。
pub async fn artwork(track_id: i64) -> Result<Option<ArtworkDto>, CoreError> {
    Ok(core()
        .artwork(lekis_types::TrackId(track_id))
        .await?
        .map(Into::into))
}

/// 封面图片的本机绝对路径：不小于 `width` 的最近一档（128 / 256 / 512 / 1024），
/// 缺这一档时从已有的最大一份就地生成。文件不存在时 UI 显示占位图。
#[frb(sync)]
pub fn artwork_path(hash: String, width: u32) -> String {
    core().artwork_path(hash, width)
}

/// 手动指定曲目封面。
pub async fn set_track_artwork(
        track_id: i64,
    artwork_id: Option<i64>,
) -> Result<(), CoreError> {
    Ok(core()
        .set_track_artwork(
            lekis_types::TrackId(track_id),
            artwork_id.map(lekis_types::ArtworkId),
        )
        .await?)
}

// ---- 歌单（PL-01/PL-05）----

/// 新建歌单，返回 ID。
pub async fn create_playlist(name: String) -> Result<i64, CoreError> {
    Ok(core().create_playlist(name).await?.0)
}

pub async fn rename_playlist(playlist_id: i64, name: String) -> Result<(), CoreError> {
    Ok(core()
        .rename_playlist(lekis_types::PlaylistId(playlist_id), name)
        .await?)
}

/// 删除歌单（墓碑，会同步到其它设备）。
pub async fn delete_playlist(playlist_id: i64) -> Result<(), CoreError> {
    Ok(core()
        .delete_playlist(lekis_types::PlaylistId(playlist_id))
        .await?)
}

pub async fn list_playlists() -> Result<Vec<PlaylistDto>, CoreError> {
    Ok(core()
        .list_playlists()
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

pub async fn get_playlist(playlist_id: i64) -> Result<PlaylistDto, CoreError> {
    Ok(core()
        .get_playlist(lekis_types::PlaylistId(playlist_id))
        .await?
        .into())
}

/// 歌单内容。`track` 为 `None` 的条目是占位（曲目暂时不可用，PL-05）。
pub async fn playlist_items(
        playlist_id: i64,
    offset: u32,
    limit: u32,
) -> Result<Vec<PlaylistEntryDto>, CoreError> {
    Ok(core()
        .playlist_items(lekis_types::PlaylistId(playlist_id), offset, limit)
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// 往歌单里插入一首，返回它的位置键。
pub async fn add_to_playlist(
        playlist_id: i64,
    track_uid: String,
    before_key: Option<String>,
    after_key: Option<String>,
) -> Result<String, CoreError> {
    Ok(core()
        .add_to_playlist(
            lekis_types::PlaylistId(playlist_id),
            track_uid,
            before_key,
            after_key,
        )
        .await?)
}

pub async fn remove_from_playlist(
        playlist_id: i64,
    position_key: String,
) -> Result<(), CoreError> {
    Ok(core()
        .remove_from_playlist(lekis_types::PlaylistId(playlist_id), position_key)
        .await?)
}

pub async fn move_playlist_item(
        playlist_id: i64,
    position_key: String,
    before_key: Option<String>,
    after_key: Option<String>,
) -> Result<(), CoreError> {
    Ok(core()
        .move_playlist_item(
            lekis_types::PlaylistId(playlist_id),
            position_key,
            before_key,
            after_key,
        )
        .await?)
}

pub async fn set_playlist_artwork(
        playlist_id: i64,
    artwork_id: Option<i64>,
) -> Result<(), CoreError> {
    Ok(core()
        .set_playlist_artwork(
            lekis_types::PlaylistId(playlist_id),
            artwork_id.map(lekis_types::ArtworkId),
        )
        .await?)
}

// ---- 智能歌单（DIS-01）----

/// 所有智能歌单。
pub async fn smart_playlists() -> Result<Vec<PlaylistDto>, CoreError> {
    Ok(core()
        .smart_playlists()
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// 求值一个智能歌单，返回一页曲目。
pub async fn smart_playlist_tracks(
    playlist_id: i64,
    offset: u32,
    limit: u32,
) -> Result<Vec<TrackRowDto>, CoreError> {
    Ok(core()
        .smart_playlist_tracks(lekis_types::PlaylistId(playlist_id), offset, limit)
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// 读歌单规则；普通歌单返回 `None`。
pub async fn get_playlist_rules(
    playlist_id: i64,
) -> Result<Option<SmartRulesDto>, CoreError> {
    Ok(core()
        .playlist_rules(lekis_types::PlaylistId(playlist_id))
        .await?
        .map(Into::into))
}

/// 设置 / 清除歌单规则；有规则时歌单自动变成智能歌单。
pub async fn set_playlist_rules(
    playlist_id: i64,
    rules: Option<SmartRulesDto>,
) -> Result<(), CoreError> {
    let rules = match rules {
        Some(rules) => Some(lekis_library::SmartRules::try_from(rules)?),
        None => None,
    };
    Ok(core()
        .set_playlist_rules(lekis_types::PlaylistId(playlist_id), rules)
        .await?)
}

/// 按规则预览曲目（不落库）。
pub async fn preview_smart_rules(
    rules: SmartRulesDto,
    offset: u32,
    limit: u32,
) -> Result<Vec<TrackRowDto>, CoreError> {
    let rules = lekis_library::SmartRules::try_from(rules)?;
    Ok(core()
        .evaluate_smart_rules(rules, offset, limit)
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// 按规则统计匹配曲目数（规则编辑器预览用）。
pub async fn count_smart_rules(rules: SmartRulesDto) -> Result<u64, CoreError> {
    let rules = lekis_library::SmartRules::try_from(rules)?;
    Ok(core().count_smart_rules(rules).await?)
}

// ---- 统计 / 覆盖层（DIS-06、ENR-07）----

/// 喜欢的曲目。
pub async fn loved_tracks(
        offset: u32,
    limit: u32,
) -> Result<Vec<TrackRowDto>, CoreError> {
    Ok(core()
        .loved_tracks(offset, limit)
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// 播放次数最多的曲目。
pub async fn most_played(limit: u32) -> Result<Vec<TrackRowDto>, CoreError> {
    Ok(core()
        .most_played(limit)
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// 记一次播放（写播放历史 + 累加播放次数）。
pub async fn record_play(track_id: i64, ms_played: u64) -> Result<(), CoreError> {
    Ok(core()
        .record_play(lekis_types::TrackId(track_id), ms_played)
        .await?)
}

/// 设置/清除曲目覆盖层（用户手工改的元数据，ENR-07）。
pub async fn set_track_overlay(
        track_id: i64,
    overlay: Option<TrackOverlayDto>,
) -> Result<(), CoreError> {
    Ok(core()
        .set_track_overlay(lekis_types::TrackId(track_id), overlay.map(Into::into))
        .await?)
}


// ---- 按文件夹浏览（LIB）----

/// 文件夹视图的第一层：一个有曲目的音源。
#[derive(Debug, Clone)]
pub struct FolderRootDto {
    pub source_id: i64,
    pub name: String,
    pub track_count: u32,
}

/// 一个子文件夹。`path` 相对音源根目录，用 `/` 分隔，传回 [`list_folder`] 继续往下走。
#[derive(Debug, Clone)]
pub struct FolderEntryDto {
    pub name: String,
    pub path: String,
    pub track_count: u32,
}

/// 一个目录的内容：子文件夹（自然排序）+ 直属曲目数（曲目本身用 [`folder_tracks`] 分页取）。
#[derive(Debug, Clone)]
pub struct FolderListingDto {
    pub folders: Vec<FolderEntryDto>,
    pub track_count: u32,
}

/// 有曲目的音源（文件夹视图的根）。
pub async fn folder_roots() -> Result<Vec<FolderRootDto>, CoreError> {
    Ok(core()
        .folder_roots()
        .await?
        .into_iter()
        .map(|r| FolderRootDto {
            source_id: r.source_id.0,
            name: r.name,
            track_count: r.track_count,
        })
        .collect())
}

/// 音源 `source_id` 下目录 `path`（`""` = 根目录）的子文件夹和直属曲目数。
pub async fn list_folder(source_id: i64, path: String) -> Result<FolderListingDto, CoreError> {
    let l = core()
        .list_folder(lekis_types::SourceId(source_id), path)
        .await?;
    Ok(FolderListingDto {
        folders: l
            .folders
            .into_iter()
            .map(|f| FolderEntryDto {
                name: f.name,
                path: f.path,
                track_count: f.track_count,
            })
            .collect(),
        track_count: l.track_count,
    })
}

/// 目录的直属曲目（按文件名），分页。整个目录播放用 `PlayContextDto::Folder`。
pub async fn folder_tracks(
    source_id: i64,
    path: String,
    offset: u32,
    limit: u32,
) -> Result<Vec<TrackRowDto>, CoreError> {
    Ok(core()
        .folder_tracks(lekis_types::SourceId(source_id), path, offset, limit)
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}
