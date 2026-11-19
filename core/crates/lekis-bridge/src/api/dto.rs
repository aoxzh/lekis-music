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
