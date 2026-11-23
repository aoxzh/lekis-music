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
                    // mdns-sd 在 debug 级别每个包都打一行，会把 logcat 刷满。
                    .with_filter(
                        android_logger::FilterBuilder::new()
                            .parse("debug,mdns_sd=warn")
                            .build(),
                    )
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
        credentials: Arc::new(FileCredentials::open(std::path::Path::new(
            &config.data_dir,
        ))),
    };
    let inner = lekis_core::LekisCore::new(config.into(), platform)?;
    let _ = CORE.set(inner);
    // PLY-05：Android USB DAC 直出的平台层 + 恢复上次的开关。
    #[cfg(target_os = "android")]
    crate::usb_audio::init_after_core();
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

/// 同步界面语言到核心，让核心返回给界面的默认名称与提示跟随切换。
#[frb(sync)]
pub fn set_ui_language(english: bool) {
    lekis_types::i18n::set_english(english);
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

/// 列出服务器上的 SMB 共享 / NFS 导出，供「添加音源」时点选。
///
/// 只用 `source.addresses[0]` 的主机部分（`smb://nas`、`nfs://nas` 即可），
/// 用户名在 `options["username"]`，密码按 `credential_ref` 先存好（和 `test_source` 一样）。
pub async fn list_shares(source: SourceConfigDto) -> Result<Vec<ShareDto>, CoreError> {
    Ok(core()
        .list_shares(source.into())
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// 浏览一个未保存的网络音源配置里 `path` 下的子文件夹（`/` 分隔，相对配置的根，空串是根）。
pub async fn browse_source(
    source: SourceConfigDto,
    path: String,
) -> Result<SourceListingDto, CoreError> {
    Ok(core().browse_source(source.into(), path).await?.into())
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
    Ok(core().start_scan(lekis_types::SourceId(source_id)).await?)
}

// ---- 网络电台（SRC-11）----

/// 浏览 / 搜索 Radio Browser。`country_code` 用 ISO 3166-1（`CN`），
/// `language` / `tag` 用 Radio Browser 的原始值。结果会缓存到本地，返回带本机 ID。
#[allow(clippy::too_many_arguments)]
pub async fn radio_browse(
    search: String,
    country_code: Option<String>,
    language: Option<String>,
    tag: Option<String>,
    sort: RadioSortDto,
    offset: u32,
    limit: u32,
) -> Result<RadioPageDto, CoreError> {
    let page = core()
        .radio_browse(lekis_core::RadioQuery {
            search,
            country_code,
            language,
            tag,
            sort: sort.into(),
            offset,
            limit: limit.clamp(1, lekis_core::RADIO_PAGE_MAX),
        })
        .await?;
    Ok(RadioPageDto {
        stations: page.stations.into_iter().map(Into::into).collect(),
        has_more: page.has_more,
    })
}

/// 国家 / 语言 / 标签筛选选项。
pub async fn radio_filter_options() -> Result<RadioFilterOptionsDto, CoreError> {
    Ok(core().radio_filter_options().await?.into())
}

/// 收藏的电台。
pub async fn radio_favorites(limit: u32) -> Result<Vec<RadioStationDto>, CoreError> {
    Ok(core()
        .radio_favorites(limit)
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// 最近播放过的电台。
pub async fn radio_recent(limit: u32) -> Result<Vec<RadioStationDto>, CoreError> {
    Ok(core()
        .radio_recent(limit)
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// 用户自定义的电台。
pub async fn radio_custom(limit: u32) -> Result<Vec<RadioStationDto>, CoreError> {
    Ok(core()
        .radio_custom(limit)
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// 添加自定义电台。`address` 可以是流地址，也可以是粘贴的 M3U / PLS 文本。
pub async fn radio_add_custom(
    name: String,
    address: String,
    homepage: Option<String>,
) -> Result<RadioStationDto, CoreError> {
    Ok(core()
        .radio_add_custom(name, address, homepage)
        .await?
        .into())
}

/// 删除自定义电台。
pub async fn radio_delete_custom(station_id: i64) -> Result<(), CoreError> {
    Ok(core()
        .radio_delete_custom(lekis_types::RadioStationId(station_id))
        .await?)
}

/// 收藏 / 取消收藏电台。
pub async fn radio_set_favorite(station_id: i64, favorite: bool) -> Result<(), CoreError> {
    Ok(core()
        .radio_set_favorite(lekis_types::RadioStationId(station_id), favorite)
        .await?)
}

/// 用一组电台替换播放队列并从 `start` 开始播放。
pub async fn radio_play(station_ids: Vec<i64>, start: u32) -> Result<u32, CoreError> {
    Ok(core()
        .radio_play(
            station_ids
                .into_iter()
                .map(lekis_types::RadioStationId)
                .collect(),
            start,
        )
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

/// Search an enabled source plugin for playable tracks.
pub async fn search_plugin(
    plugin_id: String,
    query: String,
    limit: u32,
) -> Result<SearchResultsDto, CoreError> {
    Ok(core().search_plugin(plugin_id, query, limit).await?.into())
}

/// Browse an enabled source plugin's public pages and collections.
pub async fn browse_plugin(
    plugin_id: String,
    path: String,
    cursor: Option<String>,
) -> Result<PluginBrowsePageDto, CoreError> {
    Ok(core().browse_plugin(plugin_id, path, cursor).await?.into())
}

// ---- 重复检测与库健康（LIB-10 / LIB-11）----

/// 分页列出重复组；每组的保留版本由核心挑选。
pub async fn duplicate_groups(
    offset: u32,
    limit: u32,
) -> Result<Vec<DuplicateGroupDto>, CoreError> {
    Ok(core()
        .duplicate_groups(offset, limit)
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// 重复组总数。
pub async fn duplicate_group_count() -> Result<u64, CoreError> {
    Ok(core().duplicate_group_count().await?)
}

/// 库健康汇总。
pub async fn library_health_summary() -> Result<LibraryHealthSummaryDto, CoreError> {
    Ok(core().library_health_summary().await?.into())
}

/// 某一类健康问题的条目数。
pub async fn library_health_count(kind: HealthIssueKindDto) -> Result<u64, CoreError> {
    Ok(core().library_health_count(kind.into()).await?)
}

/// 某一类健康问题的一页条目。
pub async fn library_health_page(
    kind: HealthIssueKindDto,
    offset: u32,
    limit: u32,
) -> Result<Vec<LibraryHealthEntryDto>, CoreError> {
    Ok(core()
        .library_health_page(kind.into(), offset, limit)
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// 扫描所有文件系统音源的可读性；一次性返回扫描结果。
pub async fn scan_library_health() -> Result<LibraryHealthScanReportDto, CoreError> {
    Ok(core().scan_library_health().await?.into())
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

// ---- 均衡器（PLY-04） ----

/// 读取 10 段均衡器设置；缺省为关闭、平直曲线。
pub async fn equalizer() -> Result<EqualizerDto, CoreError> {
    Ok(core().equalizer().await?.into())
}

/// 保存并立即应用均衡器设置。输入会被钳制到合法范围。
pub async fn set_equalizer(settings: EqualizerDto) -> Result<(), CoreError> {
    Ok(core().set_equalizer(settings.into()).await?)
}

/// 内置的 AutoEQ 风格预设（近似曲线，不是官方测量数据）。
#[frb(sync)]
pub fn equalizer_presets() -> Vec<EqualizerPresetDto> {
    lekis_core::equalizer::presets()
        .iter()
        .map(EqualizerPresetDto::from)
        .collect()
}

// ---- 本地插件 ----

/// 已安装插件列表。清单损坏的插件也会返回，错误放在 `error` 字段。
pub async fn plugins() -> Result<Vec<PluginInfoDto>, CoreError> {
    Ok(core()
        .plugins()
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// 从本地文件夹或 `.zip` 安装插件。
pub async fn install_plugin_from_path(path: String) -> Result<PluginInfoDto, CoreError> {
    Ok(core().install_plugin_from_path(path).await?.into())
}

/// 启用 / 停用插件（状态持久化）。
pub async fn set_plugin_enabled(plugin_id: String, enabled: bool) -> Result<(), CoreError> {
    Ok(core().set_plugin_enabled(plugin_id, enabled).await?)
}

/// Grant or revoke Android native code execution independently of plugin settings.
pub async fn set_plugin_native_android_allowed(
    plugin_id: String,
    allowed: bool,
) -> Result<(), CoreError> {
    Ok(core()
        .set_plugin_native_android_allowed(plugin_id, allowed)
        .await?)
}

/// 移除插件及其数据目录和设置。
pub async fn remove_plugin(plugin_id: String) -> Result<(), CoreError> {
    Ok(core().remove_plugin(plugin_id).await?)
}

/// 插件的设置项及当前值（密码项不回传值）。
pub async fn plugin_settings(plugin_id: String) -> Result<Vec<PluginSettingDto>, CoreError> {
    Ok(core()
        .plugin_settings(plugin_id)
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// 保存一个插件设置项。
pub async fn set_plugin_setting(
    plugin_id: String,
    key: String,
    value: String,
) -> Result<(), CoreError> {
    Ok(core().set_plugin_setting(plugin_id, key, value).await?)
}

/// 本地插件目录（设置页可以复制路径）。
#[frb(sync)]
pub fn plugins_dir() -> String {
    core().plugins_dir()
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
    core().report_source_reachability(lekis_types::SourceId(source_id), reachable);
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

// ---- 离线下载（OFF-01/02/04）----

/// 把一首歌加入离线下载队列。立即返回，进度通过 `coreEvents` 推送。
pub async fn download_track(track_id: i64) -> Result<(), CoreError> {
    Ok(core()
        .download_track(lekis_types::TrackId(track_id))
        .await?)
}

/// 批量加入离线下载队列，返回成功入队 / 已在下载的条数。
pub async fn download_tracks(track_ids: Vec<i64>) -> Result<u32, CoreError> {
    let ids = track_ids.into_iter().map(lekis_types::TrackId).collect();
    Ok(core().download_tracks(ids).await?)
}

/// 全部离线记录（下载中 / 排队 / 已完成 / 失败）。
pub async fn offline_downloads() -> Result<Vec<OfflineDownloadDto>, CoreError> {
    Ok(core()
        .offline_downloads()
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// 已下载曲目数 + 缓存总字节数。
pub async fn offline_stats() -> Result<OfflineStatsDto, CoreError> {
    Ok(core().offline_stats().await?.into())
}

/// 某首歌的离线状态；没有记录时为 `null`。
pub async fn offline_status(track_id: i64) -> Result<Option<OfflineDownloadDto>, CoreError> {
    Ok(core()
        .offline_status(lekis_types::TrackId(track_id))
        .await?
        .map(Into::into))
}

/// 删除离线记录和缓存文件；正在下载时同时取消。
pub async fn remove_download(track_id: i64) -> Result<(), CoreError> {
    Ok(core()
        .remove_download(lekis_types::TrackId(track_id))
        .await?)
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

/// 系统音频焦点闪避（压低到 30% / 恢复），不改用户音量。
#[frb(sync)]
pub fn set_ducked(ducked: bool) -> Result<(), CoreError> {
    Ok(core().set_ducked(ducked)?)
}

#[frb(sync)]
pub fn playback_snapshot() -> PlaybackSnapshotDto {
    core().playback_snapshot().into()
}

// ---- 播放会话持久化（重启后接着听）----

/// 保存当前播放会话（队列、游标、进度、随机 / 循环模式、音量）。
///
/// 队列为空时清除旧记录。暂停、跳转、队列变化和退到后台时调用；
/// 播放中请节流（例如每 10 秒一次），不要每个进度 tick 都写库。
pub async fn save_playback_state() -> Result<(), CoreError> {
    Ok(core().save_playback_state().await?)
}

/// 上次保存的播放会话；没有可恢复的会话时为 `null`。
pub async fn playback_state() -> Result<Option<PlaybackSessionDto>, CoreError> {
    Ok(core().playback_state().await?.map(Into::into))
}

/// 清除已保存的播放会话。
pub async fn clear_playback_state() -> Result<(), CoreError> {
    Ok(core().clear_playback_state().await?)
}

/// 恢复上次的播放会话（暂停在保存的进度上，不自动播放）。返回是否恢复出队列。
pub async fn restore_playback_state() -> Result<bool, CoreError> {
    Ok(core().restore_playback_state().await?)
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
///
/// 返回引擎实际使用的模式：Android 上模式由 USB DAC 直出开关决定（见 `usb_output`），
/// 请求与之矛盾时会被忽略，界面应以返回值为准。
#[frb(sync)]
pub fn set_output_mode(mode: OutputModeDto) -> Result<OutputModeDto, CoreError> {
    let effective = crate::usb_audio::effective_output_mode(mode.into());
    core().set_output_mode(effective)?;
    Ok(effective.into())
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
pub async fn pending_candidates(limit: u32) -> Result<Vec<EnrichCandidateDto>, CoreError> {
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

/// 强制重试在线歌词查找，保留当前歌词版本。
pub async fn retry_lyrics(track_id: i64) -> Result<Option<LyricsDto>, CoreError> {
    Ok(core()
        .retry_lyrics(lekis_types::TrackId(track_id))
        .await?
        .map(Into::into))
}

/// 选择属于此曲目的已存储歌词版本。
pub async fn activate_lyrics(track_id: i64, lyrics_id: i64) -> Result<(), CoreError> {
    Ok(core()
        .activate_lyrics(lekis_types::TrackId(track_id), lyrics_id)
        .await?)
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
pub async fn set_track_artwork(track_id: i64, artwork_id: Option<i64>) -> Result<(), CoreError> {
    Ok(core()
        .set_track_artwork(
            lekis_types::TrackId(track_id),
            artwork_id.map(lekis_types::ArtworkId),
        )
        .await?)
}

/// 用用户选的图片（原始字节）当封面：给了 `album_id` 换专辑封面，
/// `track_ids` 里的曲目钉上这张图。返回换之前的状态（交给 [`restore_artwork`] 撤销）。
pub async fn set_artwork_from_image(
    image: Vec<u8>,
    track_ids: Vec<i64>,
    album_id: Option<i64>,
) -> Result<ArtworkChangeDto, CoreError> {
    let ids = track_ids.into_iter().map(lekis_types::TrackId).collect();
    Ok(core()
        .set_artwork_from_image(image, ids, album_id.map(lekis_types::AlbumId))
        .await?
        .into())
}

/// 把用户选的图片存进封面缓存，返回封面 ID（再交给 `set_playlist_artwork` 之类）。
pub async fn import_artwork(image: Vec<u8>) -> Result<i64, CoreError> {
    Ok(core().import_artwork(image).await?.0)
}

/// 撤销一次换封面。
pub async fn restore_artwork(change: ArtworkChangeDto) -> Result<(), CoreError> {
    Ok(core().restore_artwork(change.into()).await?)
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

pub async fn remove_from_playlist(playlist_id: i64, position_key: String) -> Result<(), CoreError> {
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

// ---- M3U / M3U8 导入导出（PL-03）----

/// 把普通歌单导出成 M3U8 文本（UTF-8）。智能歌单会返回参数错误。
pub async fn export_playlist_m3u(playlist_id: i64) -> Result<String, CoreError> {
    Ok(core()
        .export_playlist_m3u(lekis_types::PlaylistId(playlist_id))
        .await?)
}

/// 从 M3U / M3U8 文本新建歌单，返回匹配数、缺失路径和新歌单 ID。
pub async fn import_playlist_m3u(
    name: String,
    content: String,
) -> Result<PlaylistImportReportDto, CoreError> {
    Ok(core().import_playlist_m3u(name, content).await?.into())
}

/// 把普通歌单导出成 XSPF 1.0 文本；智能歌单返回参数错误。
pub async fn export_playlist_xspf(playlist_id: i64) -> Result<String, CoreError> {
    Ok(core()
        .export_playlist_xspf(lekis_types::PlaylistId(playlist_id))
        .await?)
}

/// 从 XSPF 文本新建歌单，返回匹配数和缺失路径。
pub async fn import_playlist_xspf(
    name: String,
    content: String,
) -> Result<PlaylistImportReportDto, CoreError> {
    Ok(core().import_playlist_xspf(name, content).await?.into())
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
pub async fn get_playlist_rules(playlist_id: i64) -> Result<Option<SmartRulesDto>, CoreError> {
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

// ---- 听歌记录上报（DIS-07）----

/// 当前上报设置（不含明文凭据）。
#[frb(sync)]
pub fn scrobble_settings() -> ScrobbleSettingsDto {
    core().scrobble_settings().into()
}

/// 保存上报设置。凭据字段传 `null` 表示保留已保存的值。
pub async fn set_scrobble_settings(
    settings: ScrobbleSettingsInputDto,
) -> Result<ScrobbleSettingsDto, CoreError> {
    Ok(core().set_scrobble_settings(settings.into()).await?.into())
}

/// 上报状态（队列条数、最近错误 / 成功时间）。
#[frb(sync)]
pub fn scrobble_status() -> ScrobbleStatusDto {
    core().scrobble_status().into()
}

/// 测试当前上报配置：只做只读校验，不会产生 scrobble / now-playing。
pub async fn test_scrobble() -> Result<(), CoreError> {
    Ok(core().test_scrobble().await?)
}

// ---- 统计 / 覆盖层（DIS-06、ENR-07）----

/// 喜欢的曲目。
pub async fn loved_tracks(offset: u32, limit: u32) -> Result<Vec<TrackRowDto>, CoreError> {
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

/// 有听歌记录的年份，新的在前（DIS-06）。
pub async fn listening_years() -> Result<Vec<i32>, CoreError> {
    Ok(core().listening_years().await?)
}

/// 某年/全部时间的听歌报告（DIS-06）。
pub async fn listening_summary(
    year: Option<i32>,
    top_limit: u32,
) -> Result<ListeningSummaryDto, CoreError> {
    Ok(core().listening_summary(year, top_limit).await?.into())
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

// ---- 标签编辑与写回（LIB-13 / ENR-08）----

/// 读手工标签覆盖层；没有时返回 `None`。
pub async fn track_tag_overrides(track_id: i64) -> Result<Option<TrackTagOverridesDto>, CoreError> {
    Ok(core()
        .track_tag_overrides(lekis_types::TrackId(track_id))
        .await?
        .map(Into::into))
}

/// 读本地音频文件里的实际标签（编辑对话框预填用）。
pub async fn read_track_file_tags(track_id: i64) -> Result<TrackTagOverridesDto, CoreError> {
    Ok(core()
        .read_track_file_tags(lekis_types::TrackId(track_id))
        .await?
        .into())
}

/// 保存标签覆盖层：只改资料库，不碰文件。
pub async fn set_track_tag_overrides(
    track_id: i64,
    fields: TrackTagOverridesDto,
) -> Result<(), CoreError> {
    Ok(core()
        .set_track_tag_overrides(lekis_types::TrackId(track_id), fields.into())
        .await?)
}

/// 清除标签覆盖层。
pub async fn clear_track_tag_overrides(track_id: i64) -> Result<(), CoreError> {
    Ok(core()
        .clear_track_tag_overrides(lekis_types::TrackId(track_id))
        .await?)
}

/// 把覆盖层写回文件；返回备份路径和实际写入的字段。
pub async fn write_track_tags(track_id: i64) -> Result<TagWriteResultDto, CoreError> {
    Ok(core()
        .write_track_tags(lekis_types::TrackId(track_id))
        .await?
        .into())
}

/// 从 `<文件>.lekis-tags-backup.json` 恢复上一份原标签。
pub async fn restore_track_tags(track_id: i64) -> Result<TagWriteResultDto, CoreError> {
    Ok(core()
        .restore_track_tags(lekis_types::TrackId(track_id))
        .await?
        .into())
}

/// 批量写回。返回逐项结果，一首失败不会中断其余曲目。
pub async fn batch_write_track_tags(
    track_ids: Vec<i64>,
) -> Result<Vec<BatchTagWriteItemDto>, CoreError> {
    let ids = track_ids.into_iter().map(lekis_types::TrackId).collect();
    Ok(core()
        .batch_write_track_tags(ids)
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
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

// ---- 统一资料库（SRC-13）----

/// 列出曲目关联的全部来源文件与当前选源状态。
pub async fn track_sources(track_id: i64) -> Result<Vec<TrackSourceInfoDto>, CoreError> {
    Ok(core()
        .track_sources(lekis_types::TrackId(track_id))
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// 把 `absorb_ids` 合并到 `keep_id` 下（保留所有音源文件与用户数据，不删磁盘文件）。
pub async fn merge_tracks(keep_id: i64, absorb_ids: Vec<i64>) -> Result<u64, CoreError> {
    let absorb = absorb_ids.into_iter().map(lekis_types::TrackId).collect();
    Ok(core()
        .merge_tracks(lekis_types::TrackId(keep_id), absorb)
        .await?)
}

/// 删除重复歌曲中的低音质版本（可选同时删除磁盘 / NAS 源文件）。
pub async fn delete_duplicate_file(
    source_id: i64,
    path: String,
    delete_source_file: bool,
) -> Result<bool, CoreError> {
    Ok(core()
        .delete_duplicate_file(lekis_types::SourceId(source_id), path, delete_source_file)
        .await?)
}

/// 把曲目下的某个来源拆分成一条独立曲目，返回新曲目 ID。
pub async fn split_track_source(
    track_id: i64,
    source_id: i64,
    file_id: Option<i64>,
    external_id: Option<String>,
) -> Result<i64, CoreError> {
    Ok(core()
        .split_track_source(
            lekis_types::TrackId(track_id),
            lekis_types::SourceId(source_id),
            file_id,
            external_id,
        )
        .await?
        .0)
}

/// 歌曲按标题排序时的首字母索引偏移（UIX-05）。
pub async fn track_index_offsets() -> Result<Vec<LetterOffsetDto>, CoreError> {
    Ok(core()
        .track_index_offsets()
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// 艺人列表的首字母索引偏移（UIX-05）。
pub async fn artist_index_offsets() -> Result<Vec<LetterOffsetDto>, CoreError> {
    Ok(core()
        .artist_index_offsets()
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

// ---- 诊断日志（SET-03）----

/// 最近的核心日志（最多 2000 行，已做简单脱敏）。
#[frb(sync)]
pub fn recent_logs(limit: u32) -> Vec<String> {
    lekis_core::logs::recent(limit as usize)
}

/// 清空诊断日志缓冲。
#[frb(sync)]
pub fn clear_logs() {
    lekis_core::logs::clear();
}

/// A transient Spotify catalogue album, shown with Spotify attribution.
pub struct SpotifyAlbumDto {
    pub id: String,
    pub title: String,
    pub artists: Vec<String>,
    pub release_date: Option<String>,
    pub image_url: Option<String>,
    pub spotify_url: String,
}

/// Search Spotify using the token in the platform credential store.
pub async fn search_spotify_albums(
    album: String,
    artist: String,
    market: String,
) -> Result<Vec<SpotifyAlbumDto>, CoreError> {
    Ok(core()
        .search_spotify_albums(album, artist, market)
        .await?
        .into_iter()
        .map(|a| SpotifyAlbumDto {
            id: a.id,
            title: a.title,
            artists: a.artists,
            release_date: a.release_date,
            image_url: a.image_url,
            spotify_url: a.spotify_url,
        })
        .collect())
}

/// Search with an ephemeral token, for platforms without encrypted credential storage.
pub async fn search_spotify_albums_session(
    album: String,
    artist: String,
    market: String,
    token: String,
) -> Result<Vec<SpotifyAlbumDto>, CoreError> {
    let rows = lekis_core::search_spotify_albums_with_token(token, album, artist, market).await?;
    Ok(rows
        .into_iter()
        .map(|a| SpotifyAlbumDto {
            id: a.id,
            title: a.title,
            artists: a.artists,
            release_date: a.release_date,
            image_url: a.image_url,
            spotify_url: a.spotify_url,
        })
        .collect())
}

/// Search Apple Music using a stored developer token.
pub async fn search_apple_albums(
    album: String,
    artist: String,
    market: String,
) -> Result<Vec<SpotifyAlbumDto>, CoreError> {
    Ok(core()
        .search_apple_albums(album, artist, market)
        .await?
        .into_iter()
        .map(|a| SpotifyAlbumDto {
            id: a.id,
            title: a.title,
            artists: vec![a.artist],
            release_date: a.release_date,
            image_url: a.image_url,
            spotify_url: a.external_url,
        })
        .collect())
}
/// Search Apple Music with a session-only developer token.
pub async fn search_apple_albums_session(
    album: String,
    artist: String,
    market: String,
    token: String,
) -> Result<Vec<SpotifyAlbumDto>, CoreError> {
    Ok(
        lekis_core::search_apple_albums_with_token(token, album, artist, market)
            .await?
            .into_iter()
            .map(|a| SpotifyAlbumDto {
                id: a.id,
                title: a.title,
                artists: vec![a.artist],
                release_date: a.release_date,
                image_url: a.image_url,
                spotify_url: a.external_url,
            })
            .collect(),
    )
}
