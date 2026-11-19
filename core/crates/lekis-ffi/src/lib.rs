//! UniFFI 导出层（ADR-0005）。
//!
//! 规则：
//! - 这里**只做类型转换**，不写业务逻辑；
//! - FFI 类型（`*Dto`）和领域类型分开定义，通过 `From` 转换，领域 crate 不知道 UniFFI 的存在；
//! - 改了这里的任何公开项，都要运行 `tools/gen-bindings.sh` 重新生成绑定，并同步修改 Android / Windows 的桥接层。
//!
//! 生成的绑定：Kotlin 包名 `uniffi.lekis_ffi`，C# 命名空间 `uniffi.lekis_ffi`。

mod dto;
mod error;

pub use dto::*;
pub use error::CoreError;

use std::sync::Arc;

uniffi::setup_scaffolding!();

// ---------------------------------------------------------------------------
// 平台实现的回调接口
// ---------------------------------------------------------------------------

/// 核心事件监听者。回调在核心线程上触发，平台要自己切回 UI 线程。
#[uniffi::export(callback_interface)]
pub trait CoreEventListener: Send + Sync {
    fn on_event(&self, event: CoreEventDto);
}

/// 凭据存储（系统钥匙串），由平台实现。
#[uniffi::export(callback_interface)]
pub trait CredentialStore: Send + Sync {
    fn get(&self, key: String) -> Option<String>;
    fn set(&self, key: String, secret: String) -> bool;
    fn delete(&self, key: String) -> bool;
}

struct ListenerAdapter(Box<dyn CoreEventListener>);

impl lekis_core::EventListener for ListenerAdapter {
    fn on_event(&self, event: lekis_types::CoreEvent) {
        self.0.on_event(event.into());
    }
}

struct CredentialAdapter(Box<dyn CredentialStore>);

impl lekis_core::CredentialStore for CredentialAdapter {
    fn get(&self, key: &str) -> Option<String> {
        self.0.get(key.to_string())
    }

    fn set(&self, key: &str, secret: &str) -> lekis_types::Result<()> {
        if self.0.set(key.to_string(), secret.to_string()) {
            Ok(())
        } else {
            Err(lekis_types::LekisError::new(
                lekis_types::ErrorCode::PermissionDenied,
                "platform credential store rejected the write",
            ))
        }
    }

    fn delete(&self, key: &str) -> lekis_types::Result<()> {
        self.0.delete(key.to_string());
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// 核心对象
// ---------------------------------------------------------------------------

/// 核心句柄。平台层在启动时创建一个，整个进程共用。
#[derive(uniffi::Object)]
pub struct LekisCore {
    inner: lekis_core::LekisCore,
}

#[uniffi::export]
impl LekisCore {
    /// 创建核心。会打开数据库并启动后台运行时，耗时几十毫秒，不要在 UI 线程上调用。
    #[uniffi::constructor]
    pub fn new(
        config: CoreConfigDto,
        credentials: Box<dyn CredentialStore>,
    ) -> Result<Arc<Self>, CoreError> {
        let platform = lekis_core::PlatformServices {
            credentials: Arc::new(CredentialAdapter(credentials)),
        };
        let inner = lekis_core::LekisCore::new(config.into(), platform)?;
        Ok(Arc::new(Self { inner }))
    }

    /// 本机设备 ID。
    pub fn device_id(&self) -> String {
        self.inner.device_id().0
    }

    /// 注册事件监听者。
    pub fn add_listener(&self, listener: Box<dyn CoreEventListener>) {
        self.inner.add_listener(Arc::new(ListenerAdapter(listener)));
    }

    // ---- 音源 ----

    pub async fn add_source(&self, source: SourceConfigDto) -> Result<i64, CoreError> {
        Ok(self.inner.add_source(source.into()).await?.0)
    }

    pub async fn list_sources(&self) -> Result<Vec<SourceConfigDto>, CoreError> {
        Ok(self
            .inner
            .list_sources()
            .await?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub async fn start_scan(&self, source_id: i64) -> Result<(), CoreError> {
        Ok(self
            .inner
            .start_scan(lekis_types::SourceId(source_id))
            .await?)
    }

    // ---- 资料库 ----

    pub async fn list_tracks(
        &self,
        sort: TrackSortDto,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<TrackRowDto>, CoreError> {
        let q = lekis_types::TrackQuery {
            sort: sort.into(),
            offset,
            limit,
        };
        Ok(self
            .inner
            .list_tracks(q)
            .await?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub async fn get_track(&self, track_id: i64) -> Result<TrackDto, CoreError> {
        Ok(self
            .inner
            .get_track(lekis_types::TrackId(track_id))
            .await?
            .into())
    }

    pub async fn search(&self, text: String, limit: u32) -> Result<SearchResultsDto, CoreError> {
        Ok(self.inner.search(text, limit).await?.into())
    }

    // ---- 浏览维度（LIB-06）----

    pub async fn list_albums(
        &self,
        sort: TrackSortDto,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<AlbumDto>, CoreError> {
        Ok(self
            .inner
            .list_albums(sort.into(), offset, limit)
            .await?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub async fn get_album(&self, album_id: i64) -> Result<AlbumDto, CoreError> {
        Ok(self
            .inner
            .get_album(lekis_types::AlbumId(album_id))
            .await?
            .into())
    }

    pub async fn album_tracks(
        &self,
        album_id: i64,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<TrackRowDto>, CoreError> {
        Ok(self
            .inner
            .album_tracks(lekis_types::AlbumId(album_id), offset, limit)
            .await?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub async fn album_artists(&self, album_id: i64) -> Result<Vec<ArtistDto>, CoreError> {
        Ok(self
            .inner
            .album_artists(lekis_types::AlbumId(album_id))
            .await?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub async fn list_artists(&self, offset: u32, limit: u32) -> Result<Vec<ArtistDto>, CoreError> {
        Ok(self
            .inner
            .list_artists(offset, limit)
            .await?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub async fn get_artist(&self, artist_id: i64) -> Result<ArtistDto, CoreError> {
        Ok(self
            .inner
            .get_artist(lekis_types::ArtistId(artist_id))
            .await?
            .into())
    }

    pub async fn artist_tracks(
        &self,
        artist_id: i64,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<TrackRowDto>, CoreError> {
        Ok(self
            .inner
            .artist_tracks(lekis_types::ArtistId(artist_id), offset, limit)
            .await?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub async fn artist_albums(
        &self,
        artist_id: i64,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<AlbumDto>, CoreError> {
        Ok(self
            .inner
            .artist_albums(lekis_types::ArtistId(artist_id), offset, limit)
            .await?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub async fn list_genres(&self, limit: u32) -> Result<Vec<GenreCountDto>, CoreError> {
        Ok(self
            .inner
            .list_genres(limit)
            .await?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub async fn genre_tracks(
        &self,
        name: String,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<TrackRowDto>, CoreError> {
        Ok(self
            .inner
            .genre_tracks(name, offset, limit)
            .await?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub async fn recently_added(&self, limit: u32) -> Result<Vec<TrackRowDto>, CoreError> {
        Ok(self
            .inner
            .recently_added(limit)
            .await?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub async fn set_loved(&self, track_id: i64, loved: bool) -> Result<(), CoreError> {
        Ok(self
            .inner
            .set_loved(lekis_types::TrackId(track_id), loved)
            .await?)
    }

    /// 给曲目打分（1~5；0 表示清除）。
    pub async fn set_rating(&self, track_id: i64, rating: i64) -> Result<(), CoreError> {
        Ok(self
            .inner
            .set_rating(lekis_types::TrackId(track_id), rating)
            .await?)
    }

    // ---- 设置 ----

    /// 读一个设置项；不存在时返回 `None`。
    pub async fn get_setting(&self, key: String) -> Result<Option<String>, CoreError> {
        Ok(self.inner.get_setting(key).await?)
    }

    /// 写一个设置项。`sync.` 前缀的设置项会跨设备同步。
    pub async fn set_setting(&self, key: String, value: String) -> Result<(), CoreError> {
        Ok(self.inner.set_setting(key, value).await?)
    }

    // ---- 网络与同步 ----

    /// 告诉核心当前的网络环境（`away = true` 表示离开了家庭网络）。
    /// 平台层在 Wi-Fi 切换时调用（SRC-14）。
    pub fn set_network_away(&self, away: bool) {
        let net = if away {
            lekis_core::NetworkContext::Away
        } else {
            lekis_core::NetworkContext::Home
        };
        self.inner.set_network_context(net);
    }

    /// 上报一次音源可达性探测结果，核心据此调整选源顺序（SRC-14）。
    pub fn report_source_reachability(&self, source_id: i64, reachable: bool) {
        self.inner
            .report_source_reachability(lekis_types::SourceId(source_id), reachable);
    }

    /// 用某个文件系统音源指向的共享目录跑一轮同步（SYN-01/02）。
    ///
    /// 返回推上去 / 拉下来 / 应用的操作数。`source_id` 必须是可写的文件系统音源
    /// （本地目录、SMB 共享、WebDAV 等），核心会在它下面建 `.lekis/sync/`。
    pub async fn sync_now(&self, source_id: i64) -> Result<SyncReportDto, CoreError> {
        Ok(self
            .inner
            .sync_source(lekis_types::SourceId(source_id))
            .await?
            .into())
    }

    // ---- 播放（非阻塞）----

    pub fn play_tracks(&self, track_ids: Vec<i64>, start: u32) -> Result<(), CoreError> {
        let ids = track_ids.into_iter().map(lekis_types::TrackId).collect();
        Ok(self.inner.play_tracks(ids, start)?)
    }

    pub fn play(&self) -> Result<(), CoreError> {
        Ok(self.inner.play()?)
    }

    pub fn pause(&self) -> Result<(), CoreError> {
        Ok(self.inner.pause()?)
    }

    pub fn next(&self) -> Result<(), CoreError> {
        Ok(self.inner.next()?)
    }

    pub fn previous(&self) -> Result<(), CoreError> {
        Ok(self.inner.previous()?)
    }

    pub fn seek(&self, position_ms: u64) -> Result<(), CoreError> {
        Ok(self.inner.seek(position_ms)?)
    }

    pub fn set_repeat(&self, mode: RepeatModeDto) -> Result<(), CoreError> {
        Ok(self.inner.set_repeat(mode.into())?)
    }

    pub fn set_shuffle(&self, mode: ShuffleModeDto) -> Result<(), CoreError> {
        Ok(self.inner.set_shuffle(mode.into())?)
    }

    pub fn set_volume(&self, volume: f32) -> Result<(), CoreError> {
        Ok(self.inner.set_volume(volume)?)
    }

    pub fn playback_snapshot(&self) -> PlaybackSnapshotDto {
        self.inner.playback_snapshot().into()
    }

    // ---- 输出设备（PLY-05/PLY-12）----

    /// 列出所有可用的音频输出设备。
    pub fn list_output_devices(&self) -> Result<Vec<OutputDeviceDto>, CoreError> {
        Ok(self
            .inner
            .list_output_devices()?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// 切换输出设备；`None` 表示跟随系统默认。播放中切换会从当前位置续播。
    pub fn set_output_device(&self, device_id: Option<String>) -> Result<(), CoreError> {
        Ok(self.inner.set_output_device(device_id)?)
    }

    /// 切换输出模式（共享 / 独占）。播放中切换会从当前位置续播。
    pub fn set_output_mode(&self, mode: OutputModeDto) -> Result<(), CoreError> {
        Ok(self.inner.set_output_mode(mode.into())?)
    }

    // ---- 元数据补全（ENR-01/03/06/07）----

    /// 给一首歌跑补全流水线（封面 + 歌词）。
    pub async fn enrich_track(&self, track_id: i64) -> Result<EnrichReportDto, CoreError> {
        Ok(self
            .inner
            .enrich_track(lekis_types::TrackId(track_id))
            .await?
            .into())
    }

    /// 批量补全。`track_ids` 为空时补全所有缺封面/歌词的曲目。
    pub async fn enrich_tracks(&self, track_ids: Vec<i64>) -> Result<EnrichReportDto, CoreError> {
        let ids = track_ids.into_iter().map(lekis_types::TrackId).collect();
        Ok(self.inner.enrich_tracks(ids).await?.into())
    }

    /// 待确认队列里的候选（ENR-06）。
    pub async fn pending_candidates(
        &self,
        limit: u32,
    ) -> Result<Vec<EnrichCandidateDto>, CoreError> {
        Ok(self
            .inner
            .pending_candidates(limit)
            .await?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// 待确认队列长度。
    pub async fn pending_candidate_count(&self) -> Result<u64, CoreError> {
        Ok(self.inner.pending_candidate_count().await?)
    }

    /// 接受一条候选并应用。
    pub async fn accept_candidate(&self, candidate_id: i64) -> Result<(), CoreError> {
        Ok(self.inner.accept_candidate(candidate_id).await?)
    }

    /// 拒绝一条候选。
    pub async fn reject_candidate(&self, candidate_id: i64) -> Result<(), CoreError> {
        Ok(self.inner.reject_candidate(candidate_id).await?)
    }

    /// 接受队列里的全部候选，返回应用条数。
    pub async fn accept_all_candidates(&self) -> Result<u64, CoreError> {
        Ok(self.inner.accept_all_candidates().await?)
    }

    // ---- 歌词 / 封面 ----

    /// 取当前生效的歌词。
    pub async fn lyrics(&self, track_id: i64) -> Result<Option<LyricsDto>, CoreError> {
        Ok(self
            .inner
            .lyrics(lekis_types::TrackId(track_id))
            .await?
            .map(Into::into))
    }

    /// 取一首歌的全部歌词版本（按来源优先级排序）。
    pub async fn lyrics_versions(&self, track_id: i64) -> Result<Vec<LyricsRowDto>, CoreError> {
        Ok(self
            .inner
            .lyrics_versions(lekis_types::TrackId(track_id))
            .await?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// 手工写一份歌词（ENR-07），返回这条歌词的 ID。
    pub async fn set_lyrics(&self, track_id: i64, lyrics: LyricsDto) -> Result<i64, CoreError> {
        Ok(self
            .inner
            .set_lyrics(lekis_types::TrackId(track_id), lyrics.into())
            .await?)
    }

    /// 调整歌词整体偏移（毫秒）。
    pub async fn set_lyrics_offset(&self, track_id: i64, offset_ms: i32) -> Result<(), CoreError> {
        Ok(self
            .inner
            .set_lyrics_offset(lekis_types::TrackId(track_id), offset_ms)
            .await?)
    }

    /// 取曲目封面（曲目没有时回落到专辑封面）。
    pub async fn artwork(&self, track_id: i64) -> Result<Option<ArtworkDto>, CoreError> {
        Ok(self
            .inner
            .artwork(lekis_types::TrackId(track_id))
            .await?
            .map(Into::into))
    }

    /// 封面图片在缓存目录里的相对路径（平台层拼上 cacheDir 后读文件）。
    pub fn artwork_path(&self, hash: String, width: u32) -> String {
        self.inner.artwork_path(hash, width)
    }

    /// 手动指定曲目封面。
    pub async fn set_track_artwork(
        &self,
        track_id: i64,
        artwork_id: Option<i64>,
    ) -> Result<(), CoreError> {
        Ok(self
            .inner
            .set_track_artwork(
                lekis_types::TrackId(track_id),
                artwork_id.map(lekis_types::ArtworkId),
            )
            .await?)
    }

    // ---- 歌单（PL-01/PL-05）----

    /// 新建歌单，返回 ID。
    pub async fn create_playlist(&self, name: String) -> Result<i64, CoreError> {
        Ok(self.inner.create_playlist(name).await?.0)
    }

    pub async fn rename_playlist(&self, playlist_id: i64, name: String) -> Result<(), CoreError> {
        Ok(self
            .inner
            .rename_playlist(lekis_types::PlaylistId(playlist_id), name)
            .await?)
    }

    /// 删除歌单（墓碑，会同步到其它设备）。
    pub async fn delete_playlist(&self, playlist_id: i64) -> Result<(), CoreError> {
        Ok(self
            .inner
            .delete_playlist(lekis_types::PlaylistId(playlist_id))
            .await?)
    }

    pub async fn list_playlists(&self) -> Result<Vec<PlaylistDto>, CoreError> {
        Ok(self
            .inner
            .list_playlists()
            .await?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub async fn get_playlist(&self, playlist_id: i64) -> Result<PlaylistDto, CoreError> {
        Ok(self
            .inner
            .get_playlist(lekis_types::PlaylistId(playlist_id))
            .await?
            .into())
    }

    /// 歌单内容。`track` 为 `None` 的条目是占位（曲目暂时不可用，PL-05）。
    pub async fn playlist_items(
        &self,
        playlist_id: i64,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<PlaylistEntryDto>, CoreError> {
        Ok(self
            .inner
            .playlist_items(lekis_types::PlaylistId(playlist_id), offset, limit)
            .await?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// 往歌单里插入一首，返回它的位置键。
    pub async fn add_to_playlist(
        &self,
        playlist_id: i64,
        track_uid: String,
        before_key: Option<String>,
        after_key: Option<String>,
    ) -> Result<String, CoreError> {
        Ok(self
            .inner
            .add_to_playlist(
                lekis_types::PlaylistId(playlist_id),
                track_uid,
                before_key,
                after_key,
            )
            .await?)
    }

    pub async fn remove_from_playlist(
        &self,
        playlist_id: i64,
        position_key: String,
    ) -> Result<(), CoreError> {
        Ok(self
            .inner
            .remove_from_playlist(lekis_types::PlaylistId(playlist_id), position_key)
            .await?)
    }

    pub async fn move_playlist_item(
        &self,
        playlist_id: i64,
        position_key: String,
        before_key: Option<String>,
        after_key: Option<String>,
    ) -> Result<(), CoreError> {
        Ok(self
            .inner
            .move_playlist_item(
                lekis_types::PlaylistId(playlist_id),
                position_key,
                before_key,
                after_key,
            )
            .await?)
    }

    pub async fn set_playlist_artwork(
        &self,
        playlist_id: i64,
        artwork_id: Option<i64>,
    ) -> Result<(), CoreError> {
        Ok(self
            .inner
            .set_playlist_artwork(
                lekis_types::PlaylistId(playlist_id),
                artwork_id.map(lekis_types::ArtworkId),
            )
            .await?)
    }

    // ---- 统计 / 覆盖层（DIS-06、ENR-07）----

    /// 喜欢的曲目。
    pub async fn loved_tracks(
        &self,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<TrackRowDto>, CoreError> {
        Ok(self
            .inner
            .loved_tracks(offset, limit)
            .await?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// 播放次数最多的曲目。
    pub async fn most_played(&self, limit: u32) -> Result<Vec<TrackRowDto>, CoreError> {
        Ok(self
            .inner
            .most_played(limit)
            .await?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// 记一次播放（写播放历史 + 累加播放次数）。
    pub async fn record_play(&self, track_id: i64, ms_played: u64) -> Result<(), CoreError> {
        Ok(self
            .inner
            .record_play(lekis_types::TrackId(track_id), ms_played)
            .await?)
    }

    /// 设置/清除曲目覆盖层（用户手工改的元数据，ENR-07）。
    pub async fn set_track_overlay(
        &self,
        track_id: i64,
        overlay: Option<TrackOverlayDto>,
    ) -> Result<(), CoreError> {
        Ok(self
            .inner
            .set_track_overlay(lekis_types::TrackId(track_id), overlay.map(Into::into))
            .await?)
    }
}

/// 初始化日志（平台层在创建核心之前调用一次）。
///
/// TODO：Android 输出到 logcat（android_logger），Windows 输出到文件（滚动日志 + 脱敏）。
#[uniffi::export]
pub fn init_logging(level: String) {
    tracing::info!(target: "ffi", %level, "logging requested (not wired yet)");
}

/// 核心库版本，用于"关于"页面和诊断信息。
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}
