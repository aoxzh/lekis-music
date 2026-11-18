//! FFI 数据类型。字段含义见 lekis-types 里对应的领域类型。

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

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PlatformDto {
    Android,
    Windows,
    Linux,
}

#[derive(Debug, Clone, uniffi::Record)]
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
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
    ($dto:ident <=> $dom:ident { $($v:ident),* $(,)? }) => {
        impl From<$dto> for $dom {
            fn from(v: $dto) -> Self {
                match v { $($dto::$v => $dom::$v),* }
            }
        }
        impl From<$dom> for $dto {
            fn from(v: $dom) -> Self {
                match v { $($dom::$v => $dto::$v),* }
            }
        }
    };
}

mirror_enum!(SourceKindDto <=> SourceKind {
    Local, Smb, WebDav, Nfs, Sftp, OpenSubsonic, Jellyfin, Emby, Plex, Radio, Plugin
});

#[derive(Debug, Clone, uniffi::Record)]
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

// ---------------------------------------------------------------------------
// 资料库
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TrackSortDto {
    Title,
    Artist,
    Album,
    RecentlyAdded,
    MostPlayed,
}

mirror_enum!(TrackSortDto <=> TrackSort { Title, Artist, Album, RecentlyAdded, MostPlayed });

#[derive(Debug, Clone, uniffi::Record)]
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

#[derive(Debug, Clone, uniffi::Record)]
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
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SearchResultsDto {
    pub tracks: Vec<TrackRowDto>,
    // TODO：albums、artists 分组（和 lekis-types::SearchResults 一起补）。
}

impl From<t::SearchResults> for SearchResultsDto {
    fn from(r: t::SearchResults) -> Self {
        Self {
            tracks: r.tracks.into_iter().map(Into::into).collect(),
        }
    }
}

// ---------------------------------------------------------------------------
// 播放
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PlaybackStateDto {
    Idle,
    Loading,
    Playing,
    Paused,
    Buffering,
    Ended,
}

mirror_enum!(PlaybackStateDto <=> PlaybackState { Idle, Loading, Playing, Paused, Buffering, Ended });

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RepeatModeDto {
    Off,
    All,
    One,
}

mirror_enum!(RepeatModeDto <=> RepeatMode { Off, All, One });

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ShuffleModeDto {
    Off,
    Random,
    Smart,
}

mirror_enum!(ShuffleModeDto <=> ShuffleMode { Off, Random, Smart });

#[derive(Debug, Clone, uniffi::Record)]
pub struct PlaybackSnapshotDto {
    pub state: PlaybackStateDto,
    pub track_id: Option<i64>,
    pub position_ms: u64,
    pub duration_ms: u64,
    pub queue_len: u32,
    pub queue_index: Option<u32>,
    pub volume: f32,
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
        }
    }
}

// ---------------------------------------------------------------------------
// 事件
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ScanPhaseDto {
    Walking,
    ReadingTags,
    Artwork,
    WritingSharedIndex,
}

mirror_enum!(ScanPhaseDto <=> ScanPhase { Walking, ReadingTags, Artwork, WritingSharedIndex });

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LibraryScopeDto {
    Catalog,
    Playlists,
    UserState,
    Sources,
}

mirror_enum!(LibraryScopeDto <=> LibraryScope { Catalog, Playlists, UserState, Sources });

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SyncStateDto {
    Idle,
    Syncing,
    Unavailable,
}

mirror_enum!(SyncStateDto <=> SyncState { Idle, Syncing, Unavailable });

#[derive(Debug, Clone, uniffi::Enum)]
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
        }
    }
}
