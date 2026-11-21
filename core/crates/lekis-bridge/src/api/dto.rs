//! 给 Flutter 的数据类型（从 lekis-ffi 移植，去掉了 UniFFI 标注）。字段含义见 lekis-types 里对应的领域类型。

use lekis_types as t;
use lekis_types::{
    LibraryScope, PlaybackState, RepeatMode, ScanPhase, ShuffleMode, SourceKind, SyncState,
    TrackSort,
};
use std::collections::HashMap;
use std::path::PathBuf;

// ---------------------------------------------------------------------------
// 配置
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlatformDto {
    Android,
    Windows,
    Linux,
}

#[derive(Debug, Clone)]
pub struct CoreConfigDto {
    pub data_dir: String,
    pub cache_dir: String,
    pub device_name: String,
    pub platform: PlatformDto,
}

impl From<CoreConfigDto> for lekis_core::CoreConfig {
    fn from(c: CoreConfigDto) -> Self {
        Self {
            data_dir: PathBuf::from(c.data_dir),
            cache_dir: PathBuf::from(c.cache_dir),
            device_name: c.device_name,
            platform: match c.platform {
                PlatformDto::Android => lekis_core::PlatformKind::Android,
                PlatformDto::Windows => lekis_core::PlatformKind::Windows,
                PlatformDto::Linux => lekis_core::PlatformKind::Linux,
            },
            worker_threads: None,
        }
    }
}

// ---------------------------------------------------------------------------
// 音源
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SourceKindDto {
    Local,
    Smb,
    WebDav,
    Nfs,
    Sftp,
    OpenSubsonic,
    Jellyfin,
    Emby,
    Plex,
    Radio,
    Plugin,
}

/// 为 FFI 枚举和领域枚举生成双向 `From`（两边的变体名必须完全一致）。
macro_rules! mirror_enum {
    ($dto:ident <=> $dom:path { $($v:ident),* $(,)? }) => {
        impl From<$dto> for $dom {
            fn from(v: $dto) -> Self {
                match v { $($dto::$v => <$dom>::$v),* }
            }
        }
        impl From<$dom> for $dto {
            fn from(v: $dom) -> Self {
                match v { $(<$dom>::$v => $dto::$v),* }
            }
        }
    };
}

mirror_enum!(SourceKindDto <=> SourceKind {
    Local, Smb, WebDav, Nfs, Sftp, OpenSubsonic, Jellyfin, Emby, Plex, Radio, Plugin
});

#[derive(Debug, Clone)]
pub struct SourceConfigDto {
    pub id: Option<i64>,
    pub kind: SourceKindDto,
    pub name: String,
    pub addresses: Vec<String>,
    pub root_path: String,
    pub credential_ref: Option<String>,
    pub options: HashMap<String, String>,
    pub enabled: bool,
}

impl From<SourceConfigDto> for t::SourceConfig {
    fn from(s: SourceConfigDto) -> Self {
        Self {
            id: s.id.map(t::SourceId),
            kind: s.kind.into(),
            name: s.name,
            addresses: s.addresses,
            root_path: s.root_path,
            credential_ref: s.credential_ref,
            options: s.options.into_iter().collect(),
            enabled: s.enabled,
        }
    }
}

impl From<t::SourceConfig> for SourceConfigDto {
    fn from(s: t::SourceConfig) -> Self {
        Self {
            id: s.id.map(|i| i.0),
            kind: s.kind.into(),
            name: s.name,
            addresses: s.addresses,
            root_path: s.root_path,
            credential_ref: s.credential_ref,
            options: s.options.into_iter().collect(),
            enabled: s.enabled,
        }
    }
}

/// 音源 + 最近一次扫描的状态（音源列表页用）。
#[derive(Debug, Clone)]
pub struct SourceInfoDto {
    pub config: SourceConfigDto,
    /// 最近一次扫描结束的时间（Unix 毫秒），不论成功失败；从没扫过为 `None`。
    pub last_scan_at: Option<i64>,
    /// 最近一次扫描失败的错误类别；成功或从没扫过为 `None`。
    pub last_scan_error_kind: Option<crate::api::error::ErrorKind>,
    /// 最近一次扫描失败的详情（给开发者看，不直接展示）；成功或从没扫过为 `None`。
    pub last_scan_error: Option<String>,
}

impl From<lekis_core::SourceInfo> for SourceInfoDto {
    fn from(i: lekis_core::SourceInfo) -> Self {
        Self {
            config: i.config.into(),
            last_scan_at: i.last_scan_at,
            last_scan_error_kind: i.last_scan_error_code.map(Into::into),
            last_scan_error: i.last_scan_error,
        }
    }
}

// ---------------------------------------------------------------------------
// 局域网发现（SRC-01~03）
// ---------------------------------------------------------------------------

/// 发现到的服务类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiscoveredKindDto {
    /// SMB 文件共享（mDNS `_smb._tcp` 或 WS-Discovery）。
    Smb,
    /// WebDAV（http）。
    WebDav,
    /// WebDAV（https）。
    WebDavs,
    /// UPnP / DLNA 媒体服务器。Lekis 不直接把它当音源，只提示"可能提供 SMB 共享"。
    MediaServer,
}

mirror_enum!(DiscoveredKindDto <=> lekis_core::discovery::DiscoveredKind {
    Smb, WebDav, WebDavs, MediaServer
});

/// 通过哪种协议发现的。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiscoveryProtocolDto {
    /// mDNS / DNS-SD。
    Mdns,
    /// WS-Discovery。
    WsDiscovery,
    /// SSDP（UPnP / DLNA）。
    Ssdp,
}

mirror_enum!(DiscoveryProtocolDto <=> lekis_core::discovery::DiscoveryProtocol {
    Mdns, WsDiscovery, Ssdp
});

/// 一条局域网发现结果。
#[derive(Debug, Clone)]
pub struct DiscoveredServiceDto {
    /// 服务类型。
    pub kind: DiscoveredKindDto,
    /// 显示名称（mDNS 实例名 / DLNA friendlyName；拿不到时是主机地址）。
    pub name: String,
    /// 连接用的主机（优先 IPv4 字面量）。
    pub host: String,
    /// mDNS 主机名（`nas.local`），没有时为 `None`。
    pub hostname: Option<String>,
    /// 端口。
    pub port: u16,
    /// WebDAV 的 TXT `path`（如 `/music`），其他类型为 `None`。
    pub path: Option<String>,
    /// 发现途径。
    pub via: DiscoveryProtocolDto,
}

impl From<lekis_core::discovery::DiscoveredService> for DiscoveredServiceDto {
    fn from(s: lekis_core::discovery::DiscoveredService) -> Self {
        Self {
            kind: s.kind.into(),
            name: s.name,
            host: s.host,
            hostname: s.hostname,
            port: s.port,
            path: s.path,
            via: s.via.into(),
        }
    }
}

// ---------------------------------------------------------------------------
// 添加音源时的共享列表 / 目录浏览
// ---------------------------------------------------------------------------

/// 服务器上的一个 SMB 共享或 NFS 导出。
#[derive(Debug, Clone)]
pub struct ShareDto {
    /// 共享名（SMB）或导出路径（NFS）。
    pub name: String,
    /// 服务器给的备注，没有时为空串。
    pub comment: String,
}

impl From<lekis_core::ShareInfo> for ShareDto {
    fn from(s: lekis_core::ShareInfo) -> Self {
        Self {
            name: s.name,
            comment: s.comment,
        }
    }
}

/// 远端一层目录的浏览结果。
#[derive(Debug, Clone)]
pub struct SourceListingDto {
    /// 子文件夹名（已去掉隐藏 / 系统目录，按名称排序）。
    pub folders: Vec<String>,
    /// 这一层直接包含的音频文件数。
    pub audio_files: u32,
}

impl From<lekis_core::SourceListing> for SourceListingDto {
    fn from(l: lekis_core::SourceListing) -> Self {
        Self {
            folders: l.folders,
            audio_files: l.audio_files,
        }
    }
}

// ---------------------------------------------------------------------------
// 网络电台（SRC-11）
// ---------------------------------------------------------------------------

/// 一个网络电台。
#[derive(Debug, Clone)]
pub struct RadioStationDto {
    /// 本机 ID。
    pub id: i64,
    /// Radio Browser 的稳定 UUID；自定义电台为 `None`。
    pub station_uuid: Option<String>,
    /// 显示名称。
    pub name: String,
    /// 流地址（仅 http/https）。
    pub url: String,
    /// 图标地址。
    pub favicon: Option<String>,
    /// 国家 / 地区。
    pub country: Option<String>,
    /// ISO 3166-1 国家代码。
    pub country_code: Option<String>,
    /// 语言。
    pub language: Option<String>,
    /// 标签 / 流派。
    pub tags: Vec<String>,
    /// 编码。
    pub codec: Option<String>,
    /// 码率（kbps）。
    pub bitrate: Option<u32>,
    /// 主页。
    pub homepage: Option<String>,
    /// 用户自定义。
    pub custom: bool,
    /// 已收藏。
    pub favorite: bool,
    /// 最近播放时间（Unix 毫秒）。
    pub last_played_at: Option<i64>,
}

impl From<t::RadioStation> for RadioStationDto {
    fn from(s: t::RadioStation) -> Self {
        Self {
            id: s.id.0,
            station_uuid: s.station_uuid,
            name: s.name,
            url: s.url,
            favicon: s.favicon,
            country: s.country,
            country_code: s.country_code,
            language: s.language,
            tags: s.tags,
            codec: s.codec,
            bitrate: s.bitrate,
            homepage: s.homepage,
            custom: s.is_custom,
            favorite: s.favorite,
            last_played_at: s.last_played_at,
        }
    }
}

/// 一页电台浏览结果。
#[derive(Debug, Clone)]
pub struct RadioPageDto {
    /// 电台。
    pub stations: Vec<RadioStationDto>,
    /// 后面可能还有更多。
    pub has_more: bool,
}

/// 浏览排序。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RadioSortDto {
    /// 热度。
    Popular,
    /// 名称。
    Name,
}

impl From<RadioSortDto> for lekis_core::RadioSort {
    fn from(value: RadioSortDto) -> Self {
        match value {
            RadioSortDto::Popular => Self::Popular,
            RadioSortDto::Name => Self::Name,
        }
    }
}

/// 一个筛选选项。
#[derive(Debug, Clone)]
pub struct RadioFilterOptionDto {
    /// 显示名。
    pub name: String,
    /// 传给 `radio_browse` 的值。
    pub value: String,
    /// 电台数。
    pub station_count: u32,
}

/// 国家 / 语言 / 标签筛选选项。
#[derive(Debug, Clone)]
pub struct RadioFilterOptionsDto {
    /// 国家 / 地区。
    pub countries: Vec<RadioFilterOptionDto>,
    /// 语言。
    pub languages: Vec<RadioFilterOptionDto>,
    /// 标签 / 流派。
    pub tags: Vec<RadioFilterOptionDto>,
}

impl From<lekis_core::RadioFilterOption> for RadioFilterOptionDto {
    fn from(value: lekis_core::RadioFilterOption) -> Self {
        Self {
            name: value.name,
            value: value.value,
            station_count: value.station_count,
        }
    }
}

impl From<lekis_core::RadioFilterOptions> for RadioFilterOptionsDto {
    fn from(value: lekis_core::RadioFilterOptions) -> Self {
        Self {
            countries: value.countries.into_iter().map(Into::into).collect(),
            languages: value.languages.into_iter().map(Into::into).collect(),
            tags: value.tags.into_iter().map(Into::into).collect(),
        }
    }
}

// ---------------------------------------------------------------------------
// 资料库
// ---------------------------------------------------------------------------

/// 可以整体播放的浏览上下文（`play_context`）。顺序和对应列表页一致。
#[derive(Debug, Clone)]
pub enum PlayContextDto {
    /// 全部曲目，按某个维度排序（和 `list_tracks` 一致）。
    Library { sort: TrackSortDto },
    /// 一张专辑。
    Album { album_id: i64 },
    /// 一位艺人参与的曲目（和 `artist_tracks` 一致）。
    Artist { artist_id: i64 },
    /// 一个流派（和 `genre_tracks` 一致）。
    Genre { name: String },
    /// 一个歌单（行号含占位条目，和 `playlist_items` 一致）。
    Playlist { playlist_id: i64 },
    /// 收藏列表（和 `loved_tracks` 一致）。
    Loved,
    /// 一个文件夹的直属曲目（和 `folder_tracks` 一致）。
    Folder { source_id: i64, path: String },
}

impl From<PlayContextDto> for lekis_core::TrackContext {
    fn from(c: PlayContextDto) -> Self {
        match c {
            PlayContextDto::Library { sort } => Self::Library(sort.into()),
            PlayContextDto::Album { album_id } => Self::Album(t::AlbumId(album_id)),
            PlayContextDto::Artist { artist_id } => Self::Artist(t::ArtistId(artist_id)),
            PlayContextDto::Genre { name } => Self::Genre(name),
            PlayContextDto::Playlist { playlist_id } => Self::Playlist(t::PlaylistId(playlist_id)),
            PlayContextDto::Loved => Self::Loved,
            PlayContextDto::Folder { source_id, path } => Self::Folder {
                source_id: t::SourceId(source_id),
                path,
            },
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrackSortDto {
    Title,
    Artist,
    Album,
    RecentlyAdded,
    MostPlayed,
}

mirror_enum!(TrackSortDto <=> TrackSort { Title, Artist, Album, RecentlyAdded, MostPlayed });

#[derive(Debug, Clone)]
pub struct TrackRowDto {
    pub id: i64,
    pub title: String,
    pub artist_line: String,
    pub album_title: Option<String>,
    pub duration_ms: u64,
    pub artwork_id: Option<i64>,
    pub quality_badge: Option<String>,
    pub loved: bool,
}

impl From<t::TrackRow> for TrackRowDto {
    fn from(r: t::TrackRow) -> Self {
        Self {
            id: r.id.0,
            title: r.title,
            artist_line: r.artist_line,
            album_title: r.album_title,
            duration_ms: r.duration_ms,
            artwork_id: r.artwork_id.map(|a| a.0),
            quality_badge: r.quality_badge,
            loved: r.loved,
        }
    }
}

/// 月度/小时听歌柱状图的一格（DIS-06）。
#[derive(Debug, Clone, Copy, Default)]
pub struct ListeningBucketDto {
    pub index: u32,
    pub plays: u64,
    pub played_ms: u64,
}

/// 按听歌时长排名的艺人。
#[derive(Debug, Clone, Default)]
pub struct ArtistListeningDto {
    pub artist: String,
    pub plays: u64,
    pub played_ms: u64,
}

/// 按听歌时长排名的专辑。
#[derive(Debug, Clone, Default)]
pub struct AlbumListeningDto {
    pub title: String,
    pub artist: String,
    pub plays: u64,
    pub played_ms: u64,
}

/// 按听歌时长排名的曲目。
#[derive(Debug, Clone)]
pub struct TrackListeningDto {
    pub track: TrackRowDto,
    pub plays: u64,
    pub played_ms: u64,
}

/// 年度/全部时间听歌报告（DIS-06）。
#[derive(Debug, Clone, Default)]
pub struct ListeningSummaryDto {
    pub total_plays: u64,
    pub total_played_ms: u64,
    pub unique_tracks: u64,
    pub unique_artists: u64,
    pub unique_albums: u64,
    pub first_played_at: Option<i64>,
    pub last_played_at: Option<i64>,
    pub available_years: Vec<i32>,
    pub months: Vec<ListeningBucketDto>,
    pub hours: Vec<ListeningBucketDto>,
    pub top_artists: Vec<ArtistListeningDto>,
    pub top_albums: Vec<AlbumListeningDto>,
    pub top_tracks: Vec<TrackListeningDto>,
}

impl From<lekis_core::ListeningSummary> for ListeningSummaryDto {
    fn from(s: lekis_core::ListeningSummary) -> Self {
        Self {
            total_plays: s.total_plays,
            total_played_ms: s.total_played_ms,
            unique_tracks: s.unique_tracks,
            unique_artists: s.unique_artists,
            unique_albums: s.unique_albums,
            first_played_at: s.first_played_at,
            last_played_at: s.last_played_at,
            available_years: s.available_years,
            months: s
                .months
                .into_iter()
                .map(|b| ListeningBucketDto {
                    index: b.index,
                    plays: b.plays,
                    played_ms: b.played_ms,
                })
                .collect(),
            hours: s
                .hours
                .into_iter()
                .map(|b| ListeningBucketDto {
                    index: b.index,
                    plays: b.plays,
                    played_ms: b.played_ms,
                })
                .collect(),
            top_artists: s
                .top_artists
                .into_iter()
                .map(|a| ArtistListeningDto {
                    artist: a.artist,
                    plays: a.plays,
                    played_ms: a.played_ms,
                })
                .collect(),
            top_albums: s
                .top_albums
                .into_iter()
                .map(|a| AlbumListeningDto {
                    title: a.title,
                    artist: a.artist,
                    plays: a.plays,
                    played_ms: a.played_ms,
                })
                .collect(),
            top_tracks: s
                .top_tracks
                .into_iter()
                .map(|t| TrackListeningDto {
                    track: t.track.into(),
                    plays: t.plays,
                    played_ms: t.played_ms,
                })
                .collect(),
        }
    }
}

/// 曲目覆盖层：用户手工改过的元数据（ENR-07）。空字段表示"用文件标签的原值"。
#[derive(Debug, Clone, Default)]
pub struct TrackOverlayDto {
    pub title: Option<String>,
    pub artists: Option<Vec<String>>,
    pub album_title: Option<String>,
    pub year: Option<i32>,
    pub track_no: Option<u32>,
    pub disc_no: Option<u32>,
    pub genres: Option<Vec<String>>,
    /// 覆盖层来源（`manual` / `enrich`）。
    pub source: Option<String>,
}

impl From<TrackOverlayDto> for t::TrackOverlay {
    fn from(o: TrackOverlayDto) -> Self {
        Self {
            title: o.title,
            artists: o.artists,
            album_title: o.album_title,
            year: o.year,
            track_no: o.track_no,
            disc_no: o.disc_no,
            genres: o.genres,
            source: o.source,
        }
    }
}

impl From<t::TrackOverlay> for TrackOverlayDto {
    fn from(o: t::TrackOverlay) -> Self {
        Self {
            title: o.title,
            artists: o.artists,
            album_title: o.album_title,
            year: o.year,
            track_no: o.track_no,
            disc_no: o.disc_no,
            genres: o.genres,
            source: o.source,
        }
    }
}

/// 手工编辑的标签字段（LIB-13）。空字段表示"不覆盖 / 不修改"。
#[derive(Debug, Clone, Default)]
pub struct TrackTagOverridesDto {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub track_no: Option<u32>,
    pub disc_no: Option<u32>,
    pub year: Option<i32>,
    pub genre: Option<String>,
    pub comment: Option<String>,
    pub composer: Option<String>,
    pub lyricist: Option<String>,
    pub musicbrainz_track_id: Option<String>,
    pub musicbrainz_album_id: Option<String>,
}

impl From<TrackTagOverridesDto> for t::TrackTagOverrides {
    fn from(o: TrackTagOverridesDto) -> Self {
        Self {
            title: o.title,
            artist: o.artist,
            album: o.album,
            album_artist: o.album_artist,
            track_no: o.track_no,
            disc_no: o.disc_no,
            year: o.year,
            genre: o.genre,
            comment: o.comment,
            composer: o.composer,
            lyricist: o.lyricist,
            musicbrainz_track_id: o.musicbrainz_track_id,
            musicbrainz_album_id: o.musicbrainz_album_id,
        }
    }
}

impl From<t::TrackTagOverrides> for TrackTagOverridesDto {
    fn from(o: t::TrackTagOverrides) -> Self {
        Self {
            title: o.title,
            artist: o.artist,
            album: o.album,
            album_artist: o.album_artist,
            track_no: o.track_no,
            disc_no: o.disc_no,
            year: o.year,
            genre: o.genre,
            comment: o.comment,
            composer: o.composer,
            lyricist: o.lyricist,
            musicbrainz_track_id: o.musicbrainz_track_id,
            musicbrainz_album_id: o.musicbrainz_album_id,
        }
    }
}

/// 一次标签写回 / 恢复的结果。
#[derive(Debug, Clone)]
pub struct TagWriteResultDto {
    pub track_id: i64,
    pub file_path: String,
    pub backup_path: String,
    pub fields: Vec<String>,
}

impl From<lekis_library::TagWriteResult> for TagWriteResultDto {
    fn from(r: lekis_library::TagWriteResult) -> Self {
        Self {
            track_id: r.track_id.0,
            file_path: r.file_path,
            backup_path: r.backup_path,
            fields: r.fields,
        }
    }
}

/// 批量写回的一项结果。
#[derive(Debug, Clone)]
pub struct BatchTagWriteItemDto {
    pub track_id: i64,
    pub result: Option<TagWriteResultDto>,
    pub error_kind: Option<crate::api::error::ErrorKind>,
    pub error: Option<String>,
}

impl From<lekis_library::BatchTagWriteItem> for BatchTagWriteItemDto {
    fn from(item: lekis_library::BatchTagWriteItem) -> Self {
        Self {
            track_id: item.track_id.0,
            result: item.result.map(Into::into),
            error_kind: item.error_code.map(Into::into),
            error: item.error,
        }
    }
}

#[derive(Debug, Clone)]
pub struct TrackDto {
    pub id: i64,
    pub uid: String,
    pub title: String,
    pub artists: Vec<String>,
    pub album_id: Option<i64>,
    pub album_title: Option<String>,
    pub track_no: Option<u32>,
    pub disc_no: Option<u32>,
    pub year: Option<i32>,
    pub duration_ms: u64,
    pub genres: Vec<String>,
    pub quality_badge: Option<String>,
    pub artwork_id: Option<i64>,
    /// 曲目上手工改过的元数据（没有就是 `None`）。
    pub overlay: Option<TrackOverlayDto>,
    /// 是否收藏。
    pub loved: bool,
    /// 评分 1~5（没评过为 `None`）。
    pub rating: Option<i64>,
    /// 播放次数。
    pub play_count: i64,
}

impl From<(t::Track, lekis_core::TrackUserState)> for TrackDto {
    fn from((tr, state): (t::Track, lekis_core::TrackUserState)) -> Self {
        let mut dto = Self::from(tr);
        dto.loved = state.loved;
        dto.rating = state.rating;
        dto.play_count = state.play_count;
        dto
    }
}

impl From<t::Track> for TrackDto {
    fn from(tr: t::Track) -> Self {
        Self {
            id: tr.id.0,
            uid: tr.uid.0,
            title: tr.title,
            artists: tr.artists.into_iter().map(|a| a.name).collect(),
            album_id: tr.album_id.map(|a| a.0),
            album_title: tr.album_title,
            track_no: tr.track_no,
            disc_no: tr.disc_no,
            year: tr.year,
            duration_ms: tr.duration_ms,
            genres: tr.genres,
            quality_badge: tr.audio.as_ref().map(t::AudioProps::quality_badge),
            artwork_id: tr.artwork_id.map(|a| a.0),
            overlay: tr.overlay.map(Into::into),
            loved: false,
            rating: None,
            play_count: 0,
        }
    }
}

/// 离线下载状态（OFF-01/02）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OfflineStateDto {
    Queued,
    Downloading,
    Ready,
    Failed,
}

mirror_enum!(OfflineStateDto <=> t::OfflineState { Queued, Downloading, Ready, Failed });

/// 一条离线下载记录。
#[derive(Debug, Clone)]
pub struct OfflineDownloadDto {
    /// 曲目。
    pub track_id: i64,
    /// 下载时使用的音源。
    pub source_id: i64,
    /// 缓存文件的本机绝对路径。
    pub cache_path: String,
    /// 已写字节数。
    pub bytes: u64,
    /// 源文件总字节数（未知时为 0）。
    pub total_bytes: u64,
    /// 状态。
    pub state: OfflineStateDto,
    /// 最近一次失败 / 取消原因（给开发者看）。
    pub error: Option<String>,
    /// 创建时间（Unix 毫秒）。
    pub created_at: i64,
    /// 最后更新时间（Unix 毫秒）。
    pub updated_at: i64,
}

impl From<lekis_library::OfflineDownload> for OfflineDownloadDto {
    fn from(d: lekis_library::OfflineDownload) -> Self {
        Self {
            track_id: d.track_id.0,
            source_id: d.source_id.0,
            cache_path: d.cache_path,
            bytes: d.bytes,
            total_bytes: d.total_bytes,
            state: d.state.into(),
            error: d.error,
            created_at: d.created_at,
            updated_at: d.updated_at,
        }
    }
}

/// 离线下载汇总。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct OfflineStatsDto {
    /// 已下载曲目数。
    pub count: u64,
    /// 缓存总字节数。
    pub bytes: u64,
}

impl From<lekis_library::OfflineStats> for OfflineStatsDto {
    fn from(s: lekis_library::OfflineStats) -> Self {
        Self {
            count: s.count,
            bytes: s.bytes,
        }
    }
}

/// 专辑（LIB-06）。
#[derive(Debug, Clone)]
pub struct AlbumDto {
    pub id: i64,
    pub title: String,
    pub artist_line: String,
    pub year: Option<i32>,
    pub track_count: u32,
    pub artwork_id: Option<i64>,
    pub mbid_release: Option<String>,
    /// 生效封面的哈希（专辑自己没有时取第一首有封面的曲目），直接传给 `artwork_path`。
    pub artwork_hash: Option<String>,
}

impl From<t::Album> for AlbumDto {
    fn from(a: t::Album) -> Self {
        Self {
            id: a.id.0,
            title: a.title,
            artist_line: a.artist_line,
            year: a.year,
            track_count: a.track_count,
            artwork_id: a.artwork_id.map(|x| x.0),
            mbid_release: a.mbid_release,
            artwork_hash: a.artwork_hash,
        }
    }
}

/// 艺人（LIB-06）。
#[derive(Debug, Clone)]
pub struct ArtistDto {
    pub id: i64,
    pub name: String,
    pub sort_name: Option<String>,
    pub aliases: Vec<String>,
    pub artwork_id: Option<i64>,
    pub mbid: Option<String>,
}

impl From<t::Artist> for ArtistDto {
    fn from(a: t::Artist) -> Self {
        Self {
            id: a.id.0,
            name: a.name,
            sort_name: a.sort_name,
            aliases: a.aliases,
            artwork_id: a.artwork_id.map(|x| x.0),
            mbid: a.mbid,
        }
    }
}

/// 流派及其曲目数（LIB-06）。
#[derive(Debug, Clone)]
pub struct GenreCountDto {
    pub name: String,
    pub track_count: u32,
}

impl From<t::GenreCount> for GenreCountDto {
    fn from(g: t::GenreCount) -> Self {
        Self {
            name: g.name,
            track_count: g.track_count,
        }
    }
}

#[derive(Debug, Clone)]
pub struct SearchResultsDto {
    pub tracks: Vec<TrackRowDto>,
    pub albums: Vec<AlbumDto>,
    pub artists: Vec<ArtistDto>,
}

impl From<t::SearchResults> for SearchResultsDto {
    fn from(r: t::SearchResults) -> Self {
        Self {
            tracks: r.tracks.into_iter().map(Into::into).collect(),
            albums: r.albums.into_iter().map(Into::into).collect(),
            artists: r.artists.into_iter().map(Into::into).collect(),
        }
    }
}

// ---------------------------------------------------------------------------
// 播放
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlaybackStateDto {
    Idle,
    Loading,
    Playing,
    Paused,
    Buffering,
    Ended,
}

mirror_enum!(PlaybackStateDto <=> PlaybackState { Idle, Loading, Playing, Paused, Buffering, Ended });

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RepeatModeDto {
    Off,
    All,
    One,
}

mirror_enum!(RepeatModeDto <=> RepeatMode { Off, All, One });

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShuffleModeDto {
    Off,
    Random,
    Smart,
}

mirror_enum!(ShuffleModeDto <=> ShuffleMode { Off, Random, Smart });

#[derive(Debug, Clone)]
pub struct PlaybackSnapshotDto {
    pub state: PlaybackStateDto,
    pub track_id: Option<i64>,
    pub position_ms: u64,
    pub duration_ms: u64,
    pub queue_len: u32,
    pub queue_index: Option<u32>,
    pub volume: f32,
    /// 当前输出设备（`None` = 跟随系统默认，PLY-05）。
    pub output_device: Option<String>,
    /// 当前输出模式（PLY-12）。
    pub output_mode: OutputModeDto,
    /// 循环模式。
    pub repeat: RepeatModeDto,
    /// 随机模式。
    pub shuffle: ShuffleModeDto,
    /// 是否预解析下一首（`playback.gapless`）。
    pub gapless: bool,
    /// 队列内容版本号：变了就重新调 `queue_items`。`queue_index` 是播放顺序里的下标。
    pub queue_version: u64,
}

impl From<lekis_core::PlaybackSnapshot> for PlaybackSnapshotDto {
    fn from(s: lekis_core::PlaybackSnapshot) -> Self {
        Self {
            state: s.state.into(),
            track_id: s.track_id.map(|t| t.0),
            position_ms: s.position_ms,
            duration_ms: s.duration_ms,
            queue_len: s.queue_len,
            queue_index: s.queue_index,
            volume: s.volume,
            output_device: s.output_device,
            output_mode: s.output_mode.into(),
            repeat: s.repeat.into(),
            shuffle: s.shuffle.into(),
            gapless: s.gapless,
            queue_version: s.queue_version,
        }
    }
}

/// 10 段均衡器设置（PLY-04）。
#[derive(Debug, Clone)]
pub struct EqualizerDto {
    /// 是否启用。
    pub enabled: bool,
    /// 前级增益（dB，-12..=+12）。
    pub preamp_db: f32,
    /// 10 段增益（dB），顺序为 31 Hz 到 16 kHz。
    pub bands_db: Vec<f32>,
    /// 当前预设 ID；`None` 表示自定义 / 平直。
    pub preset: Option<String>,
}

impl From<lekis_core::EqualizerSettings> for EqualizerDto {
    fn from(value: lekis_core::EqualizerSettings) -> Self {
        Self {
            enabled: value.enabled,
            preamp_db: value.preamp_db,
            bands_db: value.bands_db,
            preset: value.preset,
        }
    }
}

impl From<EqualizerDto> for lekis_core::EqualizerSettings {
    fn from(value: EqualizerDto) -> Self {
        Self {
            enabled: value.enabled,
            preamp_db: value.preamp_db,
            bands_db: value.bands_db,
            preset: value.preset,
        }
    }
}

/// 内置均衡器预设。
#[derive(Debug, Clone)]
pub struct EqualizerPresetDto {
    /// 稳定 ID。
    pub id: String,
    /// 显示名称。
    pub name: String,
    /// 来源 / 适用场景说明。
    pub description: String,
    /// 建议 preamp（dB）。
    pub preamp_db: f32,
    /// 10 段增益（dB）。
    pub bands_db: Vec<f32>,
}

impl From<&lekis_playback::EqPreset> for EqualizerPresetDto {
    fn from(value: &lekis_playback::EqPreset) -> Self {
        Self {
            id: value.id.to_string(),
            name: value.name.to_string(),
            description: value.description.to_string(),
            preamp_db: value.preamp_db,
            bands_db: value.bands_db.to_vec(),
        }
    }
}

/// 保存下来的播放会话（重启后恢复用）。
#[derive(Debug, Clone)]
pub struct PlaybackSessionDto {
    /// 按播放顺序排列的曲目 ID。
    pub queue: Vec<i64>,
    /// 当前曲目在队列里的下标。
    pub current_index: u32,
    /// 当前曲目进度（毫秒）。
    pub position_ms: u64,
    /// 随机模式。
    pub shuffle: ShuffleModeDto,
    /// 循环模式。
    pub repeat: RepeatModeDto,
    /// 音量（0..=1）。
    pub volume: f32,
    /// 最后一次保存时间（Unix 毫秒）。
    pub updated_at: i64,
}

impl From<lekis_core::PlaybackStateRow> for PlaybackSessionDto {
    fn from(s: lekis_core::PlaybackStateRow) -> Self {
        Self {
            queue: s.queue.into_iter().map(|id| id.0).collect(),
            current_index: s.current_index,
            position_ms: s.position_ms,
            shuffle: s.shuffle.into(),
            repeat: s.repeat.into(),
            volume: s.volume,
            updated_at: s.updated_at,
        }
    }
}

// ---------------------------------------------------------------------------
// 听歌记录上报（DIS-07）
// ---------------------------------------------------------------------------

/// 上报设置的安全视图：只有"凭据是否已保存"，没有明文。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScrobbleSettingsDto {
    /// 是否启用。
    pub enabled: bool,
    /// `lastfm` / `listenbrainz` / `librefm`。
    pub service: String,
    /// 用户名。
    pub username: Option<String>,
    /// 是否发送 now-playing。
    pub now_playing: bool,
    /// 是否已保存 API key。
    pub has_api_key: bool,
    /// 是否已保存 API secret。
    pub has_api_secret: bool,
    /// 是否已保存 session key。
    pub has_session_key: bool,
    /// 是否已保存 user token。
    pub has_user_token: bool,
}

impl From<lekis_core::ScrobbleSettings> for ScrobbleSettingsDto {
    fn from(s: lekis_core::ScrobbleSettings) -> Self {
        Self {
            enabled: s.enabled,
            service: s.service,
            username: s.username,
            now_playing: s.now_playing,
            has_api_key: s.has_api_key,
            has_api_secret: s.has_api_secret,
            has_session_key: s.has_session_key,
            has_user_token: s.has_user_token,
        }
    }
}

/// 修改上报设置。凭据是 `Option<String>`：`None` 保留，`Some("")` 清除。
#[derive(Debug, Clone, Default)]
pub struct ScrobbleSettingsInputDto {
    /// 是否启用。
    pub enabled: bool,
    /// `lastfm` / `listenbrainz` / `librefm`。
    pub service: String,
    /// 用户名（空字符串清除）。
    pub username: String,
    /// 是否发送 now-playing。
    pub now_playing: bool,
    /// 新 API key。
    pub api_key: Option<String>,
    /// 新 API secret。
    pub api_secret: Option<String>,
    /// 新 session key。
    pub session_key: Option<String>,
    /// 新 user token。
    pub user_token: Option<String>,
}

impl From<ScrobbleSettingsInputDto> for lekis_core::ScrobbleSettingsInput {
    fn from(s: ScrobbleSettingsInputDto) -> Self {
        Self {
            enabled: s.enabled,
            service: s.service,
            username: s.username,
            now_playing: s.now_playing,
            api_key: s.api_key,
            api_secret: s.api_secret,
            session_key: s.session_key,
            user_token: s.user_token,
        }
    }
}

/// 上报状态。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScrobbleStatusDto {
    /// 是否已配置完整。
    pub configured: bool,
    /// 用户是否打开开关。
    pub enabled: bool,
    /// 服务标识。
    pub service: String,
    /// 待补报条数。
    pub queued: u32,
    /// 最近错误（不含凭据）。
    pub last_error: Option<String>,
    /// 最近成功上报 / 测试的 Unix 毫秒。
    pub last_success_at_ms: Option<i64>,
}

impl From<lekis_core::ScrobbleStatus> for ScrobbleStatusDto {
    fn from(s: lekis_core::ScrobbleStatus) -> Self {
        Self {
            configured: s.configured,
            enabled: s.enabled,
            service: s.service,
            queued: s.queued,
            last_error: s.last_error,
            last_success_at_ms: s.last_success_at_ms,
        }
    }
}

/// 输出模式（PLY-05）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutputModeDto {
    /// 共享模式（系统混音）。
    Shared,
    /// 独占 / 比特完美。
    Exclusive,
}

mirror_enum!(OutputModeDto <=> lekis_playback::OutputMode { Shared, Exclusive });

/// 一个音频输出设备（PLY-12）。
#[derive(Debug, Clone)]
pub struct OutputDeviceDto {
    /// 稳定 ID。
    pub id: String,
    /// 显示名称。
    pub name: String,
    /// 是否是系统默认设备。
    pub is_default: bool,
    /// 是否支持独占 / 比特完美。
    pub supports_exclusive: bool,
}

impl From<lekis_playback::OutputDevice> for OutputDeviceDto {
    fn from(d: lekis_playback::OutputDevice) -> Self {
        Self {
            id: d.id,
            name: d.name,
            is_default: d.is_default,
            supports_exclusive: d.supports_exclusive,
        }
    }
}

/// 一轮同步的结果（SYN-01）。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct SyncReportDto {
    /// 推给对方的操作数。
    pub pushed: u64,
    /// 从对方拉下来的操作数。
    pub pulled: u64,
    /// 实际改变本地状态的操作数。
    pub applied: u64,
}

impl From<lekis_core::SyncReport> for SyncReportDto {
    fn from(r: lekis_core::SyncReport) -> Self {
        Self {
            pushed: r.pushed,
            pulled: r.pulled,
            applied: r.applied,
        }
    }
}

// ---------------------------------------------------------------------------
// 补全 / 歌词 / 封面（ENR-01/03/06/07）
// ---------------------------------------------------------------------------

/// 补全处理统计。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct EnrichReportDto {
    /// 自动应用的条数。
    pub auto_applied: u32,
    /// 进待确认队列的条数。
    pub queued: u32,
    /// 丢弃的条数。
    pub discarded: u32,
}

impl From<lekis_core::EnrichReport> for EnrichReportDto {
    fn from(r: lekis_core::EnrichReport) -> Self {
        Self {
            auto_applied: r.auto_applied,
            queued: r.queued,
            discarded: r.discarded,
        }
    }
}

/// 待确认队列里的一条候选（ENR-06）。
#[derive(Debug, Clone)]
pub struct EnrichCandidateDto {
    /// 候选 ID。
    pub id: i64,
    /// 关联曲目。
    pub track_id: Option<i64>,
    /// 关联专辑。
    pub album_id: Option<i64>,
    /// 类型：`artwork` / `lyrics` / `tags`。
    pub kind: String,
    /// 提供方返回的原始 JSON。
    pub payload_json: String,
    /// 提供方标识。
    pub source: String,
    /// 匹配分（0..=1）。
    pub score: f64,
    /// 入队时间（Unix 毫秒）。
    pub created_at: i64,
}

impl From<lekis_library::EnrichCandidateRow> for EnrichCandidateDto {
    fn from(r: lekis_library::EnrichCandidateRow) -> Self {
        Self {
            id: r.id,
            track_id: r.track_id.map(|t| t.0),
            album_id: r.album_id.map(|a| a.0),
            kind: r.kind,
            payload_json: r.payload_json,
            source: r.source,
            score: f64::from(r.score),
            created_at: r.created_at,
        }
    }
}

/// 歌词格式。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LyricsFormatDto {
    Plain,
    Lrc,
    EnhancedLrc,
    Ttml,
}

mirror_enum!(LyricsFormatDto <=> t::LyricsFormat { Plain, Lrc, EnhancedLrc, Ttml });

/// 歌词。
#[derive(Debug, Clone)]
pub struct LyricsDto {
    /// 格式。
    pub format: LyricsFormatDto,
    /// 原始内容。
    pub content: String,
    /// 来源（`embedded` / `sidecar` / `lrclib` / `manual`……）。
    pub source: String,
    /// 用户调整的整体偏移（毫秒）。
    pub offset_ms: i32,
    /// 匹配置信度（0..=1）。
    pub confidence: f64,
}

impl From<t::Lyrics> for LyricsDto {
    fn from(l: t::Lyrics) -> Self {
        Self {
            format: l.format.into(),
            content: l.content,
            source: l.source,
            offset_ms: l.offset_ms,
            confidence: f64::from(l.confidence),
        }
    }
}

impl From<LyricsDto> for t::Lyrics {
    fn from(l: LyricsDto) -> Self {
        Self {
            format: l.format.into(),
            content: l.content,
            source: l.source,
            offset_ms: l.offset_ms,
            confidence: l.confidence as f32,
        }
    }
}

/// 一首歌的一份歌词（可能有多份，按来源优先级排序）。
#[derive(Debug, Clone)]
pub struct LyricsRowDto {
    /// 这一份的 ID。
    pub id: i64,
    /// 曲目。
    pub track_id: i64,
    /// 内容。
    pub lyrics: LyricsDto,
    /// 是否是当前生效的那份。
    pub is_active: bool,
}

impl From<lekis_library::LyricsRow> for LyricsRowDto {
    fn from(r: lekis_library::LyricsRow) -> Self {
        Self {
            id: r.id,
            track_id: r.track_id.0,
            lyrics: r.lyrics.into(),
            is_active: r.is_active,
        }
    }
}

/// 封面调色板（ENR-12）。颜色是 `0xRRGGBB`。
#[derive(Debug, Clone)]
pub struct PaletteDto {
    /// 主色。
    pub primary: u32,
    /// 辅色。
    pub secondary: u32,
    /// 适合放在主色上的文字颜色。
    pub on_primary: u32,
    /// 背景渐变用的颜色。
    pub gradient: Vec<u32>,
}

impl From<t::Palette> for PaletteDto {
    fn from(p: t::Palette) -> Self {
        Self {
            primary: p.primary,
            secondary: p.secondary,
            on_primary: p.on_primary,
            gradient: p.gradient,
        }
    }
}

/// 封面元数据（图片字节按路径从缓存目录取）。
#[derive(Debug, Clone)]
pub struct ArtworkDto {
    /// 封面 ID。
    pub id: i64,
    /// 内容哈希（也是缓存文件名的前缀）。
    pub hash: String,
    /// 来源（`embedded` / `coverartarchive` / `itunes` / `manual`……）。
    pub source: String,
    /// 宽。
    pub width: Option<u32>,
    /// 高。
    pub height: Option<u32>,
    /// 主色调。
    pub palette: Option<PaletteDto>,
}

impl From<lekis_library::ArtworkRow> for ArtworkDto {
    fn from(a: lekis_library::ArtworkRow) -> Self {
        Self {
            id: a.id.0,
            hash: a.hash,
            source: a.source,
            width: a.width,
            height: a.height,
            palette: a.palette.map(Into::into),
        }
    }
}

// ---------------------------------------------------------------------------
// 歌单（PL-01/PL-05）
// ---------------------------------------------------------------------------/// 歌单类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlaylistKindDto {
    /// 普通歌单。
    Static,
    /// 智能歌单（规则驱动）。
    Smart,
}

mirror_enum!(PlaylistKindDto <=> lekis_library::PlaylistKind { Static, Smart });

/// 一个歌单。
#[derive(Debug, Clone)]
pub struct PlaylistDto {
    /// 本机 ID。
    pub id: i64,
    /// 跨设备稳定 ID。
    pub uid: String,
    /// 名称。
    pub name: String,
    /// 类型。
    pub kind: PlaylistKindDto,
    /// 所在文件夹。
    pub folder_uid: Option<String>,
    /// 封面。
    pub artwork_id: Option<i64>,
    /// 曲目数。
    pub track_count: u32,
    /// 创建时间（Unix 毫秒）。
    pub created_at: i64,
    /// 最后修改时间（Unix 毫秒）。
    pub updated_at: i64,
}

impl From<lekis_library::Playlist> for PlaylistDto {
    fn from(p: lekis_library::Playlist) -> Self {
        Self {
            id: p.id.0,
            uid: p.uid,
            name: p.name,
            kind: p.kind.into(),
            folder_uid: p.folder_uid,
            artwork_id: p.artwork_id.map(|a| a.0),
            track_count: p.track_count,
            created_at: p.created_at,
            updated_at: p.updated_at,
        }
    }
}

/// 歌单里的一条（`track` 为 `None` 表示占位，PL-05）。
#[derive(Debug, Clone)]
pub struct PlaylistEntryDto {
    /// 曲目 uid。
    pub track_uid: String,
    /// 位置键（CRDT 排序用）。
    pub position_key: String,
    /// 加入时间（Unix 毫秒）。
    pub added_at: i64,
    /// 曲目信息；`None` 表示这首暂时不可用（占位）。
    pub track: Option<TrackRowDto>,
}

impl From<lekis_library::PlaylistEntry> for PlaylistEntryDto {
    fn from(e: lekis_library::PlaylistEntry) -> Self {
        Self {
            track_uid: e.item.track_uid,
            position_key: e.item.position_key,
            added_at: e.item.added_at,
            track: e.track.map(Into::into),
        }
    }
}

/// M3U / M3U8 导入结果。
#[derive(Debug, Clone)]
pub struct PlaylistImportReportDto {
    /// 新建歌单的 ID。
    pub playlist_id: i64,
    /// 成功匹配的条目数。
    pub matched: u32,
    /// 解析到的条目总数（含未匹配）。
    pub total: u32,
    /// 没匹配到本地曲目的原始路径（按 M3U 顺序）。
    pub missing: Vec<String>,
}

impl From<lekis_library::PlaylistImportReport> for PlaylistImportReportDto {
    fn from(r: lekis_library::PlaylistImportReport) -> Self {
        Self {
            playlist_id: r.playlist_id.0,
            matched: r.matched,
            total: r.total,
            missing: r.missing,
        }
    }
}

// ---------------------------------------------------------------------------
// 智能歌单规则（DIS-01）
//
// DTO 和 `lekis_library::SmartRules` 一一对应；JSON 的唯一格式仍然由
// `SmartRules::to_json` / `parse` 决定，桥接层只做树形结构转换。
// ---------------------------------------------------------------------------

/// 规则字段。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RuleFieldDto {
    Title,
    Artist,
    Album,
    Genre,
    Year,
    DurationMs,
    BitrateKbps,
    SampleRate,
    BitDepth,
    Codec,
    Loved,
    Rating,
    PlayCount,
    AddedAt,
    LastPlayed,
    QualityScore,
}

mirror_enum!(RuleFieldDto <=> lekis_library::RuleField {
    Title, Artist, Album, Genre, Year, DurationMs, BitrateKbps, SampleRate, BitDepth,
    Codec, Loved, Rating, PlayCount, AddedAt, LastPlayed, QualityScore
});

/// 比较操作符。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RuleOpDto {
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
    Contains,
    NotContains,
    In,
    NotIn,
    Between,
}

mirror_enum!(RuleOpDto <=> lekis_library::RuleOp {
    Eq, Ne, Lt, Le, Gt, Ge, Contains, NotContains, In, NotIn, Between
});

/// 规则值。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RuleValueDto {
    Text(String),
    Number(i64),
    Bool(bool),
    TextList(Vec<String>),
    Codec(String),
}

impl From<lekis_library::RuleValue> for RuleValueDto {
    fn from(v: lekis_library::RuleValue) -> Self {
        match v {
            lekis_library::RuleValue::Text(s) => Self::Text(s),
            lekis_library::RuleValue::Number(n) => Self::Number(n),
            lekis_library::RuleValue::Bool(b) => Self::Bool(b),
            lekis_library::RuleValue::TextList(items) => Self::TextList(items),
            lekis_library::RuleValue::Codec(s) => Self::Codec(s),
        }
    }
}

impl From<RuleValueDto> for lekis_library::RuleValue {
    fn from(v: RuleValueDto) -> Self {
        match v {
            RuleValueDto::Text(s) => Self::Text(s),
            RuleValueDto::Number(n) => Self::Number(n),
            RuleValueDto::Bool(b) => Self::Bool(b),
            RuleValueDto::TextList(items) => Self::TextList(items),
            RuleValueDto::Codec(s) => Self::Codec(s),
        }
    }
}

/// 一条规则（字段 + 操作符 + 值）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuleDto {
    pub field: RuleFieldDto,
    pub op: RuleOpDto,
    pub value: RuleValueDto,
}

impl From<lekis_library::Rule> for RuleDto {
    fn from(r: lekis_library::Rule) -> Self {
        Self {
            field: r.field.into(),
            op: r.op.into(),
            value: r.value.into(),
        }
    }
}

impl From<RuleDto> for lekis_library::Rule {
    fn from(r: RuleDto) -> Self {
        Self {
            field: r.field.into(),
            op: r.op.into(),
            value: r.value.into(),
        }
    }
}

/// 规则组类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RuleGroupKindDto {
    /// AND。
    All,
    /// OR。
    Any,
    /// NOT（`rules` 里恰好一个子组）。
    Not,
    /// 单条规则（`rule` 有值）。
    Rule,
}

/// 规则组。
///
/// 这里用"kind + 子组列表 + 可选单条规则"的扁平结构，而不是递归 enum：
/// FRB 对递归 enum 的支持不稳定，扁平结构在 Dart 侧也更容易编辑。
/// 语义和 [`lekis_library::RuleGroup`] 完全一致。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuleGroupDto {
    pub kind: RuleGroupKindDto,
    pub rules: Vec<RuleGroupDto>,
    pub rule: Option<RuleDto>,
}

impl From<lekis_library::RuleGroup> for RuleGroupDto {
    fn from(g: lekis_library::RuleGroup) -> Self {
        match g {
            lekis_library::RuleGroup::All(rules) => Self {
                kind: RuleGroupKindDto::All,
                rules: rules.into_iter().map(Into::into).collect(),
                rule: None,
            },
            lekis_library::RuleGroup::Any(rules) => Self {
                kind: RuleGroupKindDto::Any,
                rules: rules.into_iter().map(Into::into).collect(),
                rule: None,
            },
            lekis_library::RuleGroup::Not(inner) => Self {
                kind: RuleGroupKindDto::Not,
                rules: vec![(*inner).into()],
                rule: None,
            },
            lekis_library::RuleGroup::Rule(rule) => Self {
                kind: RuleGroupKindDto::Rule,
                rules: Vec::new(),
                rule: Some(rule.into()),
            },
        }
    }
}

impl RuleGroupDto {
    /// 转回核心规则树，并检查结构是否自洽（NOT 恰好一个子组、Rule 带规则）。
    pub(crate) fn into_rule_group(
        self,
    ) -> Result<lekis_library::RuleGroup, lekis_types::LekisError> {
        use lekis_library::RuleGroup;
        use lekis_types::LekisError;

        match self.kind {
            RuleGroupKindDto::All | RuleGroupKindDto::Any => {
                if self.rule.is_some() {
                    return Err(LekisError::invalid(
                        "AND/OR smart playlist group must not carry a single rule",
                    ));
                }
                let children = self
                    .rules
                    .into_iter()
                    .map(RuleGroupDto::into_rule_group)
                    .collect::<Result<Vec<_>, _>>()?;
                Ok(match self.kind {
                    RuleGroupKindDto::All => RuleGroup::All(children),
                    _ => RuleGroup::Any(children),
                })
            }
            RuleGroupKindDto::Not => {
                if self.rule.is_some() || self.rules.len() != 1 {
                    return Err(LekisError::invalid(
                        "NOT smart playlist group needs exactly one nested group",
                    ));
                }
                let inner = match self.rules.into_iter().next() {
                    Some(inner) => inner.into_rule_group()?,
                    None => {
                        return Err(LekisError::invalid(
                            "NOT smart playlist group needs exactly one nested group",
                        ))
                    }
                };
                Ok(RuleGroup::Not(Box::new(inner)))
            }
            RuleGroupKindDto::Rule => {
                if !self.rules.is_empty() {
                    return Err(LekisError::invalid(
                        "smart playlist rule must not contain nested groups",
                    ));
                }
                let rule = self
                    .rule
                    .ok_or_else(|| LekisError::invalid("smart playlist rule group needs a rule"))?;
                Ok(RuleGroup::Rule(rule.into()))
            }
        }
    }
}

/// 一个智能歌单的完整规则。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SmartRulesDto {
    pub root: RuleGroupDto,
    pub limit: Option<u32>,
    pub sort: Option<TrackSortDto>,
    pub sort_desc: bool,
}

impl From<lekis_library::SmartRules> for SmartRulesDto {
    fn from(rules: lekis_library::SmartRules) -> Self {
        Self {
            root: rules.root.into(),
            limit: rules.limit,
            sort: rules.sort.map(Into::into),
            sort_desc: rules.sort_desc,
        }
    }
}

impl TryFrom<SmartRulesDto> for lekis_library::SmartRules {
    type Error = lekis_types::LekisError;

    fn try_from(dto: SmartRulesDto) -> Result<Self, Self::Error> {
        let rules = Self {
            root: dto.root.into_rule_group()?,
            limit: dto.limit,
            sort: dto.sort.map(Into::into),
            sort_desc: dto.sort_desc,
        };
        rules.validate()?;
        Ok(rules)
    }
}

// ---------------------------------------------------------------------------
// 重复检测与库健康（LIB-10 / LIB-11）
// ---------------------------------------------------------------------------

/// 重复组里的一个文件版本。
#[derive(Debug, Clone)]
pub struct DuplicateTrackDto {
    /// 曲目 ID（同一组的多个文件可能属于同一首曲目）。
    pub track_id: i64,
    /// 音源。
    pub source_id: Option<i64>,
    /// 标题。
    pub title: String,
    /// 艺人署名。
    pub artist_line: String,
    /// 专辑。
    pub album_title: Option<String>,
    /// 专辑 ID。
    pub album_id: Option<i64>,
    /// 文件路径。
    pub path: String,
    /// 时长（毫秒）。
    pub duration_ms: u64,
    /// 文件大小（字节）。
    pub size_bytes: u64,
    /// 音质标签（如 `FLAC 24/96`）。
    pub format: Option<String>,
    /// 编码名。
    pub codec: Option<String>,
    /// 平均码率（kbps）。
    pub bitrate_kbps: Option<u32>,
    /// 位深。
    pub bit_depth: Option<u8>,
    /// 采样率（Hz）。
    pub sample_rate: Option<u32>,
    /// 资料库音质分。
    pub quality_score: i64,
    /// 是否建议保留。每组恰好一个。
    pub suggested_keep: bool,
}

impl From<lekis_library::DuplicateTrack> for DuplicateTrackDto {
    fn from(t: lekis_library::DuplicateTrack) -> Self {
        Self {
            track_id: t.track_id.0,
            source_id: t.source_id.map(|s| s.0),
            title: t.title,
            artist_line: t.artist_line,
            album_title: t.album_title,
            album_id: t.album_id.map(|a| a.0),
            path: t.path,
            duration_ms: t.duration_ms,
            size_bytes: t.size_bytes,
            format: t.format,
            codec: t.codec,
            bitrate_kbps: t.bitrate_kbps,
            bit_depth: t.bit_depth,
            sample_rate: t.sample_rate,
            quality_score: t.quality_score,
            suggested_keep: t.suggested_keep,
        }
    }
}

/// 一组重复曲目。
#[derive(Debug, Clone)]
pub struct DuplicateGroupDto {
    /// 分组用的规范化键（不展示）。
    pub key: String,
    /// 代表标题。
    pub title: String,
    /// 代表艺人。
    pub artist_line: String,
    /// 代表专辑。
    pub album_title: Option<String>,
    /// 代表专辑 ID。
    pub album_id: Option<i64>,
    /// 组内一致的 MusicBrainz Recording ID。
    pub mbid_recording: Option<String>,
    /// 建议保留的曲目。
    pub keep_track_id: i64,
    /// 所有版本，按推荐顺序排列。
    pub tracks: Vec<DuplicateTrackDto>,
}

impl From<lekis_library::DuplicateGroup> for DuplicateGroupDto {
    fn from(g: lekis_library::DuplicateGroup) -> Self {
        Self {
            key: g.key,
            title: g.title,
            artist_line: g.artist_line,
            album_title: g.album_title,
            album_id: g.album_id.map(|a| a.0),
            mbid_recording: g.mbid_recording,
            keep_track_id: g.keep_track_id.0,
            tracks: g.tracks.into_iter().map(Into::into).collect(),
        }
    }
}

/// 健康问题类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HealthIssueKindDto {
    /// 缺封面。
    MissingCover,
    /// 缺歌词。
    MissingLyrics,
    /// 缺标题 / 艺人。
    MissingTags,
    /// 疑似假无损。
    FakeLossless,
    /// 损坏 / 不可读文件。
    Unreadable,
}

mirror_enum!(HealthIssueKindDto <=> lekis_core::HealthIssueKind {
    MissingCover, MissingLyrics, MissingTags, FakeLossless, Unreadable
});

/// 库健康汇总。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct LibraryHealthSummaryDto {
    /// 曲目总数。
    pub total_tracks: u64,
    /// 重复组数量。
    pub duplicate_groups: u64,
    /// 缺封面。
    pub missing_cover: u64,
    /// 缺歌词。
    pub missing_lyrics: u64,
    /// 缺标题 / 艺人。
    pub missing_tags: u64,
    /// 疑似假无损。
    pub fake_lossless: u64,
    /// 损坏 / 不可读文件。
    pub unreadable_files: u64,
}

impl From<lekis_core::LibraryHealthSummary> for LibraryHealthSummaryDto {
    fn from(s: lekis_core::LibraryHealthSummary) -> Self {
        Self {
            total_tracks: s.total_tracks,
            duplicate_groups: s.duplicate_groups,
            missing_cover: s.missing_cover,
            missing_lyrics: s.missing_lyrics,
            missing_tags: s.missing_tags,
            fake_lossless: s.fake_lossless,
            unreadable_files: s.unreadable_files,
        }
    }
}

/// 健康报告的一条。
#[derive(Debug, Clone)]
pub struct LibraryHealthEntryDto {
    /// 问题类型。
    pub kind: HealthIssueKindDto,
    /// 曲目。
    pub track_id: i64,
    /// 标题。
    pub title: String,
    /// 艺人。
    pub artist_line: String,
    /// 专辑。
    pub album_title: Option<String>,
    /// 专辑 ID。
    pub album_id: Option<i64>,
    /// 音源。
    pub source_id: Option<i64>,
    /// 文件路径。
    pub path: String,
    /// 音质标签。
    pub format: Option<String>,
    /// 编码名。
    pub codec: Option<String>,
    /// 平均码率（kbps）。
    pub bitrate_kbps: Option<u32>,
    /// 位深。
    pub bit_depth: Option<u8>,
    /// 采样率（Hz）。
    pub sample_rate: Option<u32>,
    /// 文件大小（字节）。
    pub size_bytes: u64,
    /// 时长（毫秒）。
    pub duration_ms: u64,
    /// 额外说明（不可读文件的原因）。
    pub detail: Option<String>,
}

impl From<lekis_library::LibraryHealthEntry> for LibraryHealthEntryDto {
    fn from(e: lekis_library::LibraryHealthEntry) -> Self {
        Self {
            kind: e.kind.into(),
            track_id: e.track_id.0,
            title: e.title,
            artist_line: e.artist_line,
            album_title: e.album_title,
            album_id: e.album_id.map(|a| a.0),
            source_id: e.source_id.map(|s| s.0),
            path: e.path,
            format: e.format,
            codec: e.codec,
            bitrate_kbps: e.bitrate_kbps,
            bit_depth: e.bit_depth,
            sample_rate: e.sample_rate,
            size_bytes: e.size_bytes,
            duration_ms: e.duration_ms,
            detail: e.detail,
        }
    }
}

/// 一次健康扫描的结果。
#[derive(Debug, Clone, Default)]
pub struct LibraryHealthScanReportDto {
    /// 扫描的音源数。
    pub sources: u32,
    /// 检查的文件数。
    pub files_checked: u64,
    /// 不可读文件数（包括之前已标记的）。
    pub unreadable: u64,
    /// 恢复正常的文件数。
    pub cleared: u64,
    /// 打不开的音源数。
    pub failed_sources: u32,
    /// 音源级错误。
    pub errors: Vec<String>,
}

impl From<lekis_core::HealthScanReport> for LibraryHealthScanReportDto {
    fn from(r: lekis_core::HealthScanReport) -> Self {
        Self {
            sources: r.sources,
            files_checked: r.files_checked,
            unreadable: r.unreadable,
            cleared: r.cleared,
            failed_sources: r.failed_sources,
            errors: r.errors,
        }
    }
}

// ---------------------------------------------------------------------------
// 事件
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScanPhaseDto {
    Walking,
    ReadingTags,
    Artwork,
    WritingSharedIndex,
}

mirror_enum!(ScanPhaseDto <=> ScanPhase { Walking, ReadingTags, Artwork, WritingSharedIndex });

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LibraryScopeDto {
    Catalog,
    Playlists,
    UserState,
    Sources,
}

mirror_enum!(LibraryScopeDto <=> LibraryScope { Catalog, Playlists, UserState, Sources });

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncStateDto {
    Idle,
    Syncing,
    Unavailable,
}

mirror_enum!(SyncStateDto <=> SyncState { Idle, Syncing, Unavailable });

#[derive(Debug, Clone)]
pub enum CoreEventDto {
    PlaybackChanged {
        state: PlaybackStateDto,
        track_id: Option<i64>,
        position_ms: u64,
        duration_ms: u64,
    },
    PositionTick {
        position_ms: u64,
        buffered_ms: u64,
    },
    QueueChanged {
        length: u32,
        current_index: Option<u32>,
    },
    ScanProgress {
        source_id: i64,
        phase: ScanPhaseDto,
        done: u64,
        total: Option<u64>,
    },
    ScanFinished {
        source_id: i64,
        added: u64,
        updated: u64,
        removed: u64,
    },
    LibraryChanged {
        scope: LibraryScopeDto,
    },
    EnrichQueueChanged {
        pending: u32,
    },
    SyncStatus {
        state: SyncStateDto,
    },
    SourceReachability {
        source_id: i64,
        reachable: bool,
    },
    /// 后台扫描 / 服务器同步失败（`start_scan` 已返回成功，失败只能靠这个事件通知）。
    ScanFailed {
        source_id: i64,
        /// 错误类别（UI 据此显示本地化提示）。
        kind: crate::api::error::ErrorKind,
        /// 给开发者看的详情（不直接展示给用户）。
        detail: String,
    },
    /// 循环 / 随机 / 音量 / 预解析下一首 变了。
    PlaybackOptionsChanged {
        repeat: RepeatModeDto,
        shuffle: ShuffleModeDto,
        volume: f32,
        gapless: bool,
    },
    /// 离线下载进度。
    OfflineProgress {
        track_id: i64,
        downloaded: u64,
        total: Option<u64>,
    },
    /// 离线下载状态变了。
    OfflineChanged {
        track_id: i64,
        state: OfflineStateDto,
        error: Option<String>,
    },
    /// 离线下载记录被删除。
    OfflineRemoved {
        track_id: i64,
    },
}

impl From<t::CoreEvent> for CoreEventDto {
    fn from(e: t::CoreEvent) -> Self {
        use t::CoreEvent as E;
        match e {
            E::PlaybackChanged {
                state,
                track_id,
                position_ms,
                duration_ms,
            } => Self::PlaybackChanged {
                state: state.into(),
                track_id: track_id.map(|t| t.0),
                position_ms,
                duration_ms,
            },
            E::PositionTick {
                position_ms,
                buffered_ms,
            } => Self::PositionTick {
                position_ms,
                buffered_ms,
            },
            E::QueueChanged {
                length,
                current_index,
            } => Self::QueueChanged {
                length,
                current_index,
            },
            E::ScanProgress {
                source_id,
                phase,
                done,
                total,
            } => Self::ScanProgress {
                source_id: source_id.0,
                phase: phase.into(),
                done,
                total,
            },
            E::ScanFinished {
                source_id,
                added,
                updated,
                removed,
            } => Self::ScanFinished {
                source_id: source_id.0,
                added,
                updated,
                removed,
            },
            E::LibraryChanged { scope } => Self::LibraryChanged {
                scope: scope.into(),
            },
            E::EnrichQueueChanged { pending } => Self::EnrichQueueChanged { pending },
            E::SyncStatus { state } => Self::SyncStatus {
                state: state.into(),
            },
            E::SourceReachability {
                source_id,
                reachable,
            } => Self::SourceReachability {
                source_id: source_id.0,
                reachable,
            },
            E::ScanFailed {
                source_id,
                code,
                detail,
            } => Self::ScanFailed {
                source_id: source_id.0,
                kind: code.into(),
                detail,
            },
            E::PlaybackOptionsChanged {
                repeat,
                shuffle,
                volume,
                gapless,
            } => Self::PlaybackOptionsChanged {
                repeat: repeat.into(),
                shuffle: shuffle.into(),
                volume,
                gapless,
            },
            E::OfflineProgress {
                track_id,
                downloaded,
                total,
            } => Self::OfflineProgress {
                track_id: track_id.0,
                downloaded,
                total,
            },
            E::OfflineChanged {
                track_id,
                state,
                error,
            } => Self::OfflineChanged {
                track_id: track_id.0,
                state: state.into(),
                error,
            },
            E::OfflineRemoved { track_id } => Self::OfflineRemoved {
                track_id: track_id.0,
            },
        }
    }
}

// ---------------------------------------------------------------------------
// 在其他设备上播放 / 遥控其他设备（Lekis Connect，CST-01~06）
// ---------------------------------------------------------------------------

/// 「在其他设备上播放」的设置。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectSettingsDto {
    /// 本机在其他设备上显示的名字。
    pub device_name: String,
    /// 允许其他设备控制本机（默认允许，仍需配对）。
    pub allow_control: bool,
}

impl From<lekis_core::connect::ConnectSettings> for ConnectSettingsDto {
    fn from(s: lekis_core::connect::ConnectSettings) -> Self {
        Self {
            device_name: s.device_name,
            allow_control: s.allow_control,
        }
    }
}

impl From<ConnectSettingsDto> for lekis_core::connect::ConnectSettings {
    fn from(s: ConnectSettingsDto) -> Self {
        Self {
            device_name: s.device_name,
            allow_control: s.allow_control,
        }
    }
}

/// 局域网里的一台 Lekis（mDNS 看到的或手动添加的）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectDeviceDto {
    /// 设备 ID。
    pub device_id: String,
    /// 名称。
    pub name: String,
    /// 平台（`android` / `windows` / ...）。
    pub platform: String,
    /// 地址。
    pub host: String,
    /// 端口。
    pub port: u16,
    /// 已经配对过。
    pub paired: bool,
    /// 当前有控制连接。
    pub connected: bool,
}

impl From<lekis_core::connect::ConnectDevice> for ConnectDeviceDto {
    fn from(d: lekis_core::connect::ConnectDevice) -> Self {
        Self {
            device_id: d.device_id,
            name: d.name,
            platform: d.platform,
            host: d.host,
            port: d.port,
            paired: d.paired,
            connected: d.connected,
        }
    }
}

/// 一台已配对的设备（长期密钥在凭据库里，不经过桥接层）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairedPeerDto {
    /// 设备 ID。
    pub device_id: String,
    /// 配对时的设备名。
    pub name: String,
    /// 平台。
    pub platform: String,
    /// 配对时间（Unix 毫秒）。
    pub paired_at_ms: i64,
}

impl From<lekis_core::connect::PairedPeer> for PairedPeerDto {
    fn from(p: lekis_core::connect::PairedPeer) -> Self {
        Self {
            device_id: p.device_id,
            name: p.name,
            platform: p.platform,
            paired_at_ms: p.paired_at_ms,
        }
    }
}

/// 一首歌在被控端是怎么播的。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaViaDto {
    /// 被控端自己的资料库里有同一首歌。
    Library,
    /// 两边接了同一个音源，被控端直接从音源读。
    SameSource,
    /// 控制端通过局域网把文件流给被控端。
    Stream,
}

mirror_enum!(MediaViaDto <=> lekis_core::connect::MediaVia { Library, SameSource, Stream });

/// 被控端上的一首歌（显示用）。
#[derive(Debug, Clone, PartialEq)]
pub struct RemoteTrackDto {
    /// 被控端本机的曲目 ID（取封面时用）。
    pub id: i64,
    /// 跨设备 ID（被控端没有封面时，按它在本地找同一首歌）。
    pub uid: Option<String>,
    /// 标题。
    pub title: String,
    /// 艺人。
    pub artist: String,
    /// 专辑名。
    pub album: Option<String>,
    /// 时长（毫秒）。
    pub duration_ms: u64,
    /// 这首歌是怎么解析的。
    pub via: Option<MediaViaDto>,
}

impl From<lekis_core::connect::RemoteTrack> for RemoteTrackDto {
    fn from(t: lekis_core::connect::RemoteTrack) -> Self {
        Self {
            id: t.id,
            uid: t.uid,
            title: t.title,
            artist: t.artist,
            album: t.album,
            duration_ms: t.duration_ms,
            via: t.via.map(Into::into),
        }
    }
}

/// 被控端的播放状态。
#[derive(Debug, Clone, PartialEq)]
pub struct RemoteStateDto {
    /// 播放 / 暂停 / 缓冲……
    pub state: PlaybackStateDto,
    /// 当前曲目（空队列时为 `None`）。
    pub track: Option<RemoteTrackDto>,
    /// 当前位置（毫秒）。
    pub position_ms: u64,
    /// 当前曲目时长（毫秒）。
    pub duration_ms: u64,
    /// 音量（0..=1）。
    pub volume: f32,
    /// 队列长度。
    pub queue_len: u32,
    /// 当前曲目在队列里的下标。
    pub queue_index: Option<u32>,
    /// 循环模式。
    pub repeat: RepeatModeDto,
    /// 随机模式。
    pub shuffle: ShuffleModeDto,
    /// 队列版本（变了就说明队列内容变了）。
    pub queue_version: u64,
}

impl From<lekis_core::connect::RemoteState> for RemoteStateDto {
    fn from(s: lekis_core::connect::RemoteState) -> Self {
        Self {
            state: s.state.into(),
            track: s.track.map(Into::into),
            position_ms: s.position_ms,
            duration_ms: s.duration_ms,
            volume: s.volume,
            queue_len: s.queue_len,
            queue_index: s.queue_index,
            repeat: s.repeat.into(),
            shuffle: s.shuffle.into(),
            queue_version: s.queue_version,
        }
    }
}

/// 遥控动作（和 `connect::Control` 一一对应）。
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ControlActionDto {
    /// 播放 / 继续。
    Play,
    /// 暂停。
    Pause,
    /// 播放中就暂停，否则开始播放。
    Toggle,
    /// 下一首。
    Next,
    /// 上一首（播了几秒时回到本曲开头）。
    Previous,
    /// 跳转。
    Seek {
        /// 目标位置（毫秒）。
        position_ms: u64,
    },
    /// 音量。
    Volume {
        /// 0..=1。
        volume: f32,
    },
    /// 循环模式。
    Repeat {
        /// 新的循环模式。
        mode: RepeatModeDto,
    },
    /// 随机模式。
    Shuffle {
        /// 新的随机模式。
        mode: ShuffleModeDto,
    },
    /// 播放队列里的第 N 首。
    PlayIndex {
        /// 队列下标（越界时取最后一首）。
        index: u32,
    },
}

impl From<ControlActionDto> for lekis_core::connect::Control {
    fn from(a: ControlActionDto) -> Self {
        match a {
            ControlActionDto::Play => Self::Play,
            ControlActionDto::Pause => Self::Pause,
            ControlActionDto::Toggle => Self::Toggle,
            ControlActionDto::Next => Self::Next,
            ControlActionDto::Previous => Self::Previous,
            ControlActionDto::Seek { position_ms } => Self::Seek { position_ms },
            ControlActionDto::Volume { volume } => Self::Volume { volume },
            ControlActionDto::Repeat { mode } => Self::Repeat { mode: mode.into() },
            ControlActionDto::Shuffle { mode } => Self::Shuffle { mode: mode.into() },
            ControlActionDto::PlayIndex { index } => Self::PlayIndex { index },
        }
    }
}

/// 把队列交给另一台设备的结果：每种方式各解析了几首。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct QueueReportDto {
    /// 一共几首。
    pub total: u32,
    /// 从被控端自己的资料库里找到的。
    pub library: u32,
    /// 同一个音源上直接读的。
    pub same_source: u32,
    /// 走控制端局域网流的。
    pub stream: u32,
    /// 解析不了、被跳过的。
    pub skipped: u32,
}

impl From<lekis_core::connect::QueueReport> for QueueReportDto {
    fn from(r: lekis_core::connect::QueueReport) -> Self {
        Self {
            total: r.total,
            library: r.library,
            same_source: r.same_source,
            stream: r.stream,
            skipped: r.skipped,
        }
    }
}

/// Connect 事件（和 `CoreEventDto` 分开，界面单独订阅）。
#[derive(Debug, Clone, PartialEq)]
pub enum ConnectEventDto {
    /// 设备列表变了。
    DevicesChanged {
        /// 当前局域网里（含手动添加的）所有设备。
        devices: Vec<ConnectDeviceDto>,
    },
    /// 本机作为被控端：有设备请求配对，请把配对码显示出来。
    PairingCode {
        /// 请求配对的设备 ID。
        peer_id: String,
        /// 请求配对的设备名。
        peer_name: String,
        /// 6 位配对码，用户需要把它输进那台设备。
        code: String,
    },
    /// 本机作为被控端：配对结束（成功或失败），可以收起配对码。
    PairingFinished {
        /// 请求配对的设备 ID。
        peer_id: String,
        /// 请求配对的设备名。
        peer_name: String,
        /// 是否成功。
        success: bool,
    },
    /// 本机作为控制端：远端设备的状态变了。
    RemoteState {
        /// 哪台设备。
        device_id: String,
        /// 它的最新状态。
        state: RemoteStateDto,
    },
    /// 本机作为控制端：和远端设备的连接断了。
    SessionClosed {
        /// 哪台设备。
        device_id: String,
        /// 断开的原因（给日志 / 提示用）。
        reason: String,
    },
    /// 本机作为被控端：有设备连上 / 断开了。
    ControllersChanged {
        /// 当前连着本机的控制端名字。
        names: Vec<String>,
    },
}

impl From<lekis_core::connect::ConnectEvent> for ConnectEventDto {
    fn from(e: lekis_core::connect::ConnectEvent) -> Self {
        use lekis_core::connect::ConnectEvent as E;
        match e {
            E::DevicesChanged { devices } => Self::DevicesChanged {
                devices: devices.into_iter().map(Into::into).collect(),
            },
            E::PairingCode {
                peer_id,
                peer_name,
                code,
            } => Self::PairingCode {
                peer_id,
                peer_name,
                code,
            },
            E::PairingFinished {
                peer_id,
                peer_name,
                success,
            } => Self::PairingFinished {
                peer_id,
                peer_name,
                success,
            },
            E::RemoteState { device_id, state } => Self::RemoteState {
                device_id,
                state: state.into(),
            },
            E::SessionClosed { device_id, reason } => Self::SessionClosed { device_id, reason },
            E::ControllersChanged { names } => Self::ControllersChanged { names },
        }
    }
}

// ---------------------------------------------------------------------------
// 本地插件（PLG-01~07）
// ---------------------------------------------------------------------------

/// 插件声明的权限摘要。
#[derive(Debug, Clone)]
pub struct PluginPermissionsDto {
    /// 允许访问的域名。
    pub network: Vec<String>,
    /// 允许启动的外部程序。
    pub process: Vec<String>,
    /// 需要附加请求头的域名（不包含头的值）。
    pub request_header_hosts: Vec<String>,
    /// 是否需要网页登录。
    pub web_sign_in: bool,
    /// 存储配额（KB）。
    pub storage_kb: u32,
}

impl From<lekis_core::PluginPermissions> for PluginPermissionsDto {
    fn from(p: lekis_core::PluginPermissions) -> Self {
        Self {
            network: p.network,
            process: p.process,
            request_header_hosts: p.request_header_hosts,
            web_sign_in: p.web_sign_in,
            storage_kb: p.storage_kb,
        }
    }
}

/// 一个插件设置项及当前值。
#[derive(Debug, Clone)]
pub struct PluginSettingDto {
    /// 设置 key。
    pub key: String,
    /// 展示标签（可能是 locales 里的键）。
    pub label: String,
    /// 帮助文字（可能是 locales 里的键）。
    pub help: Option<String>,
    /// `string` / `password` / `boolean` / `select`。
    pub kind: String,
    /// 下拉选项。
    pub options: Vec<String>,
    /// 默认值（密码为空）。
    pub default_value: Option<String>,
    /// 当前值（密码永远为 `None`）。
    pub value: Option<String>,
    /// 是否已经保存过值。
    pub has_value: bool,
    /// 是否是密码项。
    pub secret: bool,
}

impl From<lekis_core::PluginSettingView> for PluginSettingDto {
    fn from(s: lekis_core::PluginSettingView) -> Self {
        Self {
            key: s.key,
            label: s.label,
            help: s.help,
            kind: s.kind,
            options: s.options,
            default_value: s.default,
            value: s.value,
            has_value: s.has_value,
            secret: s.secret,
        }
    }
}

/// 已安装的本地插件。
#[derive(Debug, Clone)]
pub struct PluginInfoDto {
    /// 插件 id；清单损坏时是目录名。
    pub id: String,
    /// 名称；清单损坏时是目录名。
    pub name: String,
    /// 版本。
    pub version: String,
    /// 插件 API 版本。
    pub api_version: String,
    /// `js` / `wasm` / `none`。
    pub runtime: String,
    /// 插件类型。
    pub kinds: Vec<String>,
    /// 入口文件。
    pub entry: Option<String>,
    /// 是否启用。
    pub enabled: bool,
    /// 清单错误（正常为 `None`）。
    pub error: Option<String>,
    /// 插件目录名。
    pub directory: String,
    /// 作者。
    pub author: Option<String>,
    /// 主页。
    pub homepage: Option<String>,
    /// 权限摘要。
    pub permissions: PluginPermissionsDto,
    /// 设置项。
    pub settings: Vec<PluginSettingDto>,
}

impl From<lekis_core::PluginInfo> for PluginInfoDto {
    fn from(p: lekis_core::PluginInfo) -> Self {
        Self {
            id: p.id,
            name: p.name,
            version: p.version,
            api_version: p.api_version,
            runtime: p.runtime,
            kinds: p.kinds,
            entry: p.entry,
            enabled: p.enabled,
            error: p.error,
            directory: p.directory,
            author: p.author,
            homepage: p.homepage,
            permissions: p.permissions.into(),
            settings: p.settings.into_iter().map(Into::into).collect(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lekis_library::{Rule, RuleGroup, RuleValue, SmartRules};

    fn rule(field: RuleFieldDto, op: RuleOpDto, value: RuleValueDto) -> RuleGroupDto {
        RuleGroupDto {
            kind: RuleGroupKindDto::Rule,
            rules: Vec::new(),
            rule: Some(RuleDto { field, op, value }),
        }
    }

    /// 桥接 DTO → 核心规则 → 规范 JSON → 核心规则 → DTO，应当逐字段一致。
    #[test]
    fn smart_rules_dto_round_trips_through_canonical_json() {
        let dto = SmartRulesDto {
            root: RuleGroupDto {
                kind: RuleGroupKindDto::All,
                rules: vec![
                    rule(RuleFieldDto::Loved, RuleOpDto::Eq, RuleValueDto::Bool(true)),
                    rule(RuleFieldDto::Rating, RuleOpDto::Ge, RuleValueDto::Number(4)),
                    RuleGroupDto {
                        kind: RuleGroupKindDto::Any,
                        rules: vec![
                            rule(
                                RuleFieldDto::Genre,
                                RuleOpDto::In,
                                RuleValueDto::TextList(vec!["Rock".into(), "Jazz".into()]),
                            ),
                            rule(
                                RuleFieldDto::Codec,
                                RuleOpDto::Eq,
                                RuleValueDto::Codec("lossless".into()),
                            ),
                        ],
                        rule: None,
                    },
                    RuleGroupDto {
                        kind: RuleGroupKindDto::Not,
                        rules: vec![rule(
                            RuleFieldDto::Year,
                            RuleOpDto::Between,
                            RuleValueDto::TextList(vec!["1990".into(), "1999".into()]),
                        )],
                        rule: None,
                    },
                ],
                rule: None,
            },
            limit: Some(500),
            sort: Some(TrackSortDto::RecentlyAdded),
            sort_desc: true,
        };

        let rules = SmartRules::try_from(dto.clone()).expect("DTO should convert");
        let json = rules.to_json().expect("rules should serialize");
        let parsed = SmartRules::parse(&json).expect("canonical JSON should parse");
        let back = SmartRulesDto::from(parsed);
        assert_eq!(back, dto);
    }

    /// NOT 组必须恰好有一个子组，避免 UI 传入模棱两可的结构。
    #[test]
    fn not_group_rejects_ambiguous_shapes() {
        let bad = RuleGroupDto {
            kind: RuleGroupKindDto::Not,
            rules: Vec::new(),
            rule: None,
        };
        assert!(bad.into_rule_group().is_err());

        let bad = RuleGroupDto {
            kind: RuleGroupKindDto::All,
            rules: Vec::new(),
            rule: Some(RuleDto {
                field: RuleFieldDto::Loved,
                op: RuleOpDto::Eq,
                value: RuleValueDto::Bool(true),
            }),
        };
        assert!(bad.into_rule_group().is_err());
    }

    /// 值和字段 / 操作符不匹配时，核心校验应当在桥接层就拒绝。
    #[test]
    fn smart_rules_dto_validates_value_kinds() {
        let dto = SmartRulesDto {
            root: RuleGroupDto {
                kind: RuleGroupKindDto::All,
                rules: vec![rule(
                    RuleFieldDto::Loved,
                    RuleOpDto::Ge,
                    RuleValueDto::Number(1),
                )],
                rule: None,
            },
            limit: None,
            sort: None,
            sort_desc: false,
        };
        assert!(SmartRules::try_from(dto).is_err());
    }

    /// 确认直接构造的规则树和规范 JSON 的语义一致（兜底，防止 DTO 转义丢失 NOT）。
    #[test]
    fn canonical_rule_tree_keeps_not_and_nested_groups() {
        let group = RuleGroup::Not(Box::new(RuleGroup::Any(vec![
            RuleGroup::Rule(Rule {
                field: lekis_library::RuleField::Loved,
                op: lekis_library::RuleOp::Eq,
                value: RuleValue::Bool(true),
            }),
            RuleGroup::Rule(Rule {
                field: lekis_library::RuleField::Rating,
                op: lekis_library::RuleOp::Gt,
                value: RuleValue::Number(3),
            }),
        ])));
        let rules = SmartRules {
            root: group.clone(),
            limit: None,
            sort: None,
            sort_desc: false,
        };
        let json = rules.to_json().expect("serialize");
        let parsed = SmartRules::parse(&json).expect("parse");
        assert_eq!(parsed.root, group);
    }
}

/// 一次换封面的结果（撤销用）。
#[derive(Debug, Clone)]
pub struct ArtworkChangeDto {
    /// 新封面 ID。
    pub artwork_id: i64,
    /// 换了封面的曲目。
    pub track_ids: Vec<i64>,
    /// 这些曲目原来自己钉的封面（和 `track_ids` 一一对应）。
    pub previous_track_artwork: Vec<Option<i64>>,
    /// 换了封面的专辑。
    pub album_id: Option<i64>,
    /// 专辑原来的封面。
    pub previous_album_artwork: Option<i64>,
}

impl From<lekis_core::ArtworkChange> for ArtworkChangeDto {
    fn from(c: lekis_core::ArtworkChange) -> Self {
        let (track_ids, previous_track_artwork) = c
            .previous_tracks
            .into_iter()
            .map(|(t, a)| (t.0, a.map(|a| a.0)))
            .unzip();
        Self {
            artwork_id: c.artwork_id.0,
            track_ids,
            previous_track_artwork,
            album_id: c.previous_album.map(|(a, _)| a.0),
            previous_album_artwork: c.previous_album.and_then(|(_, p)| p.map(|p| p.0)),
        }
    }
}

impl From<ArtworkChangeDto> for lekis_core::ArtworkChange {
    fn from(d: ArtworkChangeDto) -> Self {
        use lekis_types::{AlbumId, ArtworkId, TrackId};
        Self {
            artwork_id: ArtworkId(d.artwork_id),
            previous_tracks: d
                .track_ids
                .into_iter()
                .zip(d.previous_track_artwork)
                .map(|(t, a)| (TrackId(t), a.map(ArtworkId)))
                .collect(),
            previous_album: d
                .album_id
                .map(|a| (AlbumId(a), d.previous_album_artwork.map(ArtworkId))),
        }
    }
}

/// 统一资料库里一首歌的某个来源（SRC-13）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrackSourceInfoDto {
    pub source_id: i64,
    pub source_name: String,
    pub source_kind: SourceKindDto,
    pub file_id: Option<i64>,
    pub path: String,
    pub external_id: Option<String>,
    pub size_bytes: u64,
    pub format: Option<String>,
    pub quality_score: i64,
    pub reachable: Option<bool>,
    pub preferred: bool,
}

impl From<lekis_core::TrackSourceInfo> for TrackSourceInfoDto {
    fn from(s: lekis_core::TrackSourceInfo) -> Self {
        Self {
            source_id: s.source_id.0,
            source_name: s.source_name,
            source_kind: s.source_kind.into(),
            file_id: s.file_id,
            path: s.path,
            external_id: s.external_id,
            size_bytes: s.size_bytes,
            format: s.format,
            quality_score: s.quality_score,
            reachable: s.reachable,
            preferred: s.preferred,
        }
    }
}
