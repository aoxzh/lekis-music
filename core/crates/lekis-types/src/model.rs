//! 领域模型。和数据库表一一对应的部分见 `lekis-library/migrations/0001_init.sql`。

use crate::ids::*;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

// ---------------------------------------------------------------------------
// 音源
// ---------------------------------------------------------------------------

/// 音源类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceKind {
    /// 本机文件夹（包括移动硬盘）。
    Local,
    /// SMB 2/3 共享。
    Smb,
    /// WebDAV（含 Alist/OpenList、Nextcloud）。
    WebDav,
    /// NFS。
    Nfs,
    /// SFTP。
    Sftp,
    /// OpenSubsonic / Subsonic 服务器（Navidrome、gonic……）。
    OpenSubsonic,
    /// Jellyfin。
    Jellyfin,
    /// Emby。
    Emby,
    /// Plex。
    Plex,
    /// 网络电台。
    Radio,
    /// 插件提供的音源。
    Plugin,
}

impl SourceKind {
    /// 是不是"文件系统类"的源（需要我们自己扫描和解析标签）。
    pub fn is_filesystem(self) -> bool {
        matches!(
            self,
            Self::Local | Self::Smb | Self::WebDav | Self::Nfs | Self::Sftp
        )
    }
}

/// 音源配置。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SourceConfig {
    /// 本机 ID；新建时为 `None`。
    pub id: Option<SourceId>,
    /// 类型。
    pub kind: SourceKind,
    /// 显示名称。
    pub name: String,
    /// 访问地址，按优先级排列（SRC-14：在家用局域网地址，在外用 Tailscale 地址……）。
    /// 本地源是绝对路径；SMB 是 `smb://host/share`；服务器是 `https://host:port`。
    pub addresses: Vec<String>,
    /// 源内的根目录（文件系统类源）。
    pub root_path: String,
    /// 凭据在系统钥匙串里的引用 ID（不是密码本身）。
    pub credential_ref: Option<String>,
    /// 各类型特有的选项。
    pub options: BTreeMap<String, String>,
    /// 是否启用。
    pub enabled: bool,
}

// ---------------------------------------------------------------------------
// 网络电台（SRC-11）
// ---------------------------------------------------------------------------

/// 一个网络电台。
///
/// Radio Browser 返回的电台会在浏览时缓存到本地；用户收藏和自定义电台永久保存。
/// 播放时用 [`RadioStationId::track_id`] 映射成合成 `TrackId`，不要求完整的曲目扫描。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RadioStation {
    /// 本机 ID。
    pub id: RadioStationId,
    /// Radio Browser 的稳定 UUID；自定义电台为 `None`。
    pub station_uuid: Option<String>,
    /// 显示名称。
    pub name: String,
    /// 可直接播放的流地址（已解析 `url_resolved`，仅 http/https）。
    pub url: String,
    /// 图标地址。
    pub favicon: Option<String>,
    /// 国家 / 地区显示名。
    pub country: Option<String>,
    /// ISO 3166-1 国家代码（筛选用）。
    pub country_code: Option<String>,
    /// 语言。
    pub language: Option<String>,
    /// 标签 / 流派。
    pub tags: Vec<String>,
    /// 编码（MP3 / AAC / OGG……）。
    pub codec: Option<String>,
    /// 码率（kbps）。
    pub bitrate: Option<u32>,
    /// 主页。
    pub homepage: Option<String>,
    /// 用户手动添加的电台。
    pub is_custom: bool,
    /// 是否收藏。
    pub favorite: bool,
    /// 最近播放时间（Unix 毫秒）。
    pub last_played_at: Option<i64>,
}

// ---------------------------------------------------------------------------
// 播客（SRC-12）
// ---------------------------------------------------------------------------

/// 一档播客节目（RSS 源）。
///
/// 打开过的节目都会缓存到本地；`subscribed` 为真才出现在「我的订阅」里。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Podcast {
    /// 本机 ID。
    pub id: PodcastId,
    /// RSS 地址（仅 http/https）。
    pub feed_url: String,
    /// Apple Podcasts 目录 ID（从目录添加时才有）。
    pub itunes_id: Option<i64>,
    /// 标题。
    pub title: String,
    /// 作者 / 出品方。
    pub author: Option<String>,
    /// 简介（纯文本）。
    pub description: Option<String>,
    /// 封面地址。
    pub artwork_url: Option<String>,
    /// 节目主页。
    pub link: Option<String>,
    /// 语言。
    pub language: Option<String>,
    /// 分类。
    pub categories: Vec<String>,
    /// 是否已订阅。
    pub subscribed: bool,
    /// 订阅时间（Unix 毫秒）。
    pub subscribed_at: Option<i64>,
    /// 最近一次成功刷新（Unix 毫秒）。
    pub last_refreshed_at: Option<i64>,
    /// 最近一次刷新失败的原因。
    pub last_error: Option<String>,
    /// 单集数。
    pub episode_count: u32,
    /// 未播放的单集数。
    pub unplayed_count: u32,
    /// 最新一集的发布时间（Unix 毫秒）。
    pub latest_published_at: Option<i64>,
}

/// 播客单集。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PodcastEpisode {
    /// 本机 ID。
    pub id: PodcastEpisodeId,
    /// 所属节目。
    pub podcast_id: PodcastId,
    /// 节目标题（冗余，方便列表显示）。
    pub podcast_title: String,
    /// RSS `guid`（没有时用音频地址）。
    pub guid: String,
    /// 标题。
    pub title: String,
    /// 简介（纯文本）。
    pub description: Option<String>,
    /// 音频地址（enclosure）。
    pub audio_url: String,
    /// MIME 类型。
    pub mime_type: Option<String>,
    /// 文件大小（字节）。
    pub size_bytes: Option<u64>,
    /// 时长（毫秒，0 表示未知）。
    pub duration_ms: u64,
    /// 发布时间（Unix 毫秒）。
    pub published_at: Option<i64>,
    /// 单集封面；没有时 UI 用节目封面。
    pub artwork_url: Option<String>,
    /// 集数。
    pub episode_no: Option<u32>,
    /// 季。
    pub season_no: Option<u32>,
    /// 单集网页。
    pub link: Option<String>,
    /// 上次听到的位置（毫秒）。
    pub position_ms: u64,
    /// 已播放完。
    pub played: bool,
    /// 最近播放时间（Unix 毫秒）。
    pub last_played_at: Option<i64>,
}

// ---------------------------------------------------------------------------
// 音频属性
// ---------------------------------------------------------------------------

/// 编码格式。
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Codec {
    /// MP3。
    Mp3,
    /// AAC。
    Aac,
    /// ALAC。
    Alac,
    /// FLAC。
    Flac,
    /// WAV（PCM）。
    Wav,
    /// AIFF。
    Aiff,
    /// Ogg Vorbis。
    Vorbis,
    /// Opus。
    Opus,
    /// Monkey's Audio。
    Ape,
    /// WavPack。
    WavPack,
    /// TTA。
    Tta,
    /// DSD（DSF / DFF）。
    Dsd,
    /// 其他。
    Other(String),
}

impl Codec {
    /// 是否无损。
    pub fn is_lossless(&self) -> bool {
        matches!(
            self,
            Self::Alac
                | Self::Flac
                | Self::Wav
                | Self::Aiff
                | Self::Ape
                | Self::WavPack
                | Self::Tta
                | Self::Dsd
        )
    }
}

/// 音频流属性。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AudioProps {
    /// 编码。
    pub codec: Codec,
    /// 采样率（Hz）。
    pub sample_rate: u32,
    /// 位深（有损格式为 `None`）。
    pub bit_depth: Option<u8>,
    /// 声道数。
    pub channels: u8,
    /// 平均码率（kbps）。
    pub bitrate_kbps: Option<u32>,
}

impl AudioProps {
    /// 界面上显示的音质标签，例如 `FLAC 24/96`、`MP3 320`。
    pub fn quality_badge(&self) -> String {
        let name = match &self.codec {
            Codec::Mp3 => "MP3",
            Codec::Aac => "AAC",
            Codec::Alac => "ALAC",
            Codec::Flac => "FLAC",
            Codec::Wav => "WAV",
            Codec::Aiff => "AIFF",
            Codec::Vorbis => "OGG",
            Codec::Opus => "OPUS",
            Codec::Ape => "APE",
            Codec::WavPack => "WV",
            Codec::Tta => "TTA",
            Codec::Dsd => "DSD",
            Codec::Other(s) => s.as_str(),
        };
        match (self.codec.is_lossless(), self.bit_depth, self.bitrate_kbps) {
            (true, Some(bits), _) => {
                let khz = self.sample_rate as f32 / 1000.0;
                if khz.fract().abs() < 0.05 {
                    format!("{name} {bits}/{}", khz.round() as u32)
                } else {
                    format!("{name} {bits}/{khz:.1}")
                }
            }
            (false, _, Some(kbps)) => format!("{name} {kbps}"),
            _ => name.to_string(),
        }
    }
}

/// ReplayGain 信息。
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
pub struct ReplayGain {
    /// 曲目增益（dB）。
    pub track_gain_db: Option<f32>,
    /// 曲目峰值（线性，0..=1+）。
    pub track_peak: Option<f32>,
    /// 专辑增益（dB）。
    pub album_gain_db: Option<f32>,
    /// 专辑峰值。
    pub album_peak: Option<f32>,
}

// ---------------------------------------------------------------------------
// 资料库实体
// ---------------------------------------------------------------------------

/// 艺人在曲目或专辑里的角色。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ArtistRole {
    /// 主艺人。
    Main,
    /// 合作 / feat.。
    Featured,
    /// 作曲。
    Composer,
    /// 作词。
    Lyricist,
    /// 指挥（古典）。
    Conductor,
    /// 演奏者（古典）。
    Performer,
    /// 混音。
    Remixer,
}

impl ArtistRole {
    /// 数据库里存的字符串（snake_case），和 `#[serde(rename_all = "snake_case")]` 一致。
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Main => "main",
            Self::Featured => "featured",
            Self::Composer => "composer",
            Self::Lyricist => "lyricist",
            Self::Conductor => "conductor",
            Self::Performer => "performer",
            Self::Remixer => "remixer",
        }
    }

    /// 从数据库字符串还原；未知值按主艺人处理（向前兼容：以后加新角色时旧版本不会报错）。
    pub fn from_db(value: &str) -> Self {
        match value {
            "featured" => Self::Featured,
            "composer" => Self::Composer,
            "lyricist" => Self::Lyricist,
            "conductor" => Self::Conductor,
            "performer" => Self::Performer,
            "remixer" => Self::Remixer,
            _ => Self::Main,
        }
    }
}

/// 曲目里的一个艺人署名。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ArtistCredit {
    /// 已经入库的艺人 ID。
    pub artist_id: Option<ArtistId>,
    /// 显示名称。
    pub name: String,
    /// 角色。
    pub role: ArtistRole,
}

/// 用户手工编辑的标签字段（LIB-13）。
///
/// 这是资料库里的**覆盖层**，只影响扫描 / 展示，不直接改文件；字段为 `None`
/// 表示"沿用文件标签"。用户确认"写入文件"后，核心再把这里的字段写回本地音频。
///
/// 和 [`TrackOverlay`] 分开存：补全结果（ENR）可以整体替换，而手工标签编辑需要
/// 保留评论、作曲、MusicBrainz ID 等补全不关心的字段。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TrackTagOverrides {
    /// 标题。
    pub title: Option<String>,
    /// 艺人（多个艺人用 ` / ` 连接）。
    pub artist: Option<String>,
    /// 专辑名。
    pub album: Option<String>,
    /// 专辑艺人。
    pub album_artist: Option<String>,
    /// 曲目号。
    pub track_no: Option<u32>,
    /// 碟片号。
    pub disc_no: Option<u32>,
    /// 年份。
    pub year: Option<i32>,
    /// 流派（多个流派用 `;` 连接）。
    pub genre: Option<String>,
    /// 评论。
    pub comment: Option<String>,
    /// 作曲。
    pub composer: Option<String>,
    /// 作词。
    pub lyricist: Option<String>,
    /// MusicBrainz 录音 ID。
    pub musicbrainz_track_id: Option<String>,
    /// MusicBrainz 专辑（release）ID。
    pub musicbrainz_album_id: Option<String>,
}

impl TrackTagOverrides {
    /// 是否一个字段都没覆盖。
    pub fn is_empty(&self) -> bool {
        self.title.is_none()
            && self.artist.is_none()
            && self.album.is_none()
            && self.album_artist.is_none()
            && self.track_no.is_none()
            && self.disc_no.is_none()
            && self.year.is_none()
            && self.genre.is_none()
            && self.comment.is_none()
            && self.composer.is_none()
            && self.lyricist.is_none()
            && self.musicbrainz_track_id.is_none()
            && self.musicbrainz_album_id.is_none()
    }
}

/// 用户或补全结果对曲目元数据的覆盖层（LIB-13 / ENR）。
///
/// 覆盖层**不改原始文件**，只改库里的显示与排序；字段为 `None` 表示"沿用文件标签"。
/// 同步（SYN-01）把它当作可同步的实体，因此每个字段都要能独立合并。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct TrackOverlay {
    /// 覆盖后的标题。
    pub title: Option<String>,
    /// 覆盖后的艺人显示名（按顺序）。
    pub artists: Option<Vec<String>>,
    /// 覆盖后的专辑名。
    pub album_title: Option<String>,
    /// 覆盖后的年份。
    pub year: Option<i32>,
    /// 覆盖后的曲目号。
    pub track_no: Option<u32>,
    /// 覆盖后的碟片号。
    pub disc_no: Option<u32>,
    /// 覆盖后的流派。
    pub genres: Option<Vec<String>>,
    /// 覆盖层来源（`manual` / `musicbrainz` / `plugin:<id>`……）。
    pub source: Option<String>,
}

impl TrackOverlay {
    /// 一份什么都没覆盖的覆盖层等价于没有覆盖层。
    pub fn is_empty(&self) -> bool {
        self.title.is_none()
            && self.artists.is_none()
            && self.album_title.is_none()
            && self.year.is_none()
            && self.track_no.is_none()
            && self.disc_no.is_none()
            && self.genres.is_none()
    }
}

/// 曲目（完整信息，详情页用）。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Track {
    /// 本机 ID。
    pub id: TrackId,
    /// 跨设备稳定 ID。
    pub uid: TrackUid,
    /// 标题。
    pub title: String,
    /// 排序用标题。
    pub sort_title: Option<String>,
    /// 艺人署名（按顺序）。
    pub artists: Vec<ArtistCredit>,
    /// 所属专辑。
    pub album_id: Option<AlbumId>,
    /// 专辑名（冗余，方便显示）。
    pub album_title: Option<String>,
    /// 曲目号。
    pub track_no: Option<u32>,
    /// 碟片号。
    pub disc_no: Option<u32>,
    /// 年份。
    pub year: Option<i32>,
    /// 时长（毫秒）。
    pub duration_ms: u64,
    /// 流派。
    pub genres: Vec<String>,
    /// MusicBrainz 录音 ID。
    pub mbid_recording: Option<String>,
    /// 最佳文件的音频属性。
    pub audio: Option<AudioProps>,
    /// ReplayGain。
    pub replaygain: ReplayGain,
    /// 封面。
    pub artwork_id: Option<ArtworkId>,
    /// 用户 / 补全结果的覆盖层（`None` 字段沿用文件标签）。
    pub overlay: Option<TrackOverlay>,
    /// 是否已存在本地文件副本（来自 `SourceKind::Local`）；本地曲目无需离线下载。
    #[serde(default)]
    pub is_local: bool,
}

/// 曲目（列表用的精简版）。大列表只返回这个，详情页再取 [`Track`]。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TrackRow {
    /// 本机 ID。
    pub id: TrackId,
    /// 标题。
    pub title: String,
    /// 艺人显示文字（已经拼好，例如 `周杰伦 / 费玉清`）。
    pub artist_line: String,
    /// 专辑名。
    pub album_title: Option<String>,
    /// 时长（毫秒）。
    pub duration_ms: u64,
    /// 封面。
    pub artwork_id: Option<ArtworkId>,
    /// 音质标签。
    pub quality_badge: Option<String>,
    /// 是否已收藏。
    pub loved: bool,
    /// 是否已存在本地文件副本（来自 `SourceKind::Local`）；本地曲目无需离线下载。
    #[serde(default)]
    pub is_local: bool,
}

/// 专辑。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Album {
    /// 本机 ID。
    pub id: AlbumId,
    /// 标题。
    pub title: String,
    /// 专辑艺人显示文字。
    pub artist_line: String,
    /// 年份。
    pub year: Option<i32>,
    /// 曲目数。
    pub track_count: u32,
    /// 封面。
    pub artwork_id: Option<ArtworkId>,
    /// MusicBrainz Release ID。
    pub mbid_release: Option<String>,
    /// 生效封面的内容哈希（专辑自己没有封面时取它第一首有封面的曲目），
    /// UI 直接拿它调 `artwork_path`，不用再逐张查。
    #[serde(default)]
    pub artwork_hash: Option<String>,
}

/// 艺人。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Artist {
    /// 本机 ID。
    pub id: ArtistId,
    /// 名称。
    pub name: String,
    /// 排序名。
    pub sort_name: Option<String>,
    /// 别名（例如 `周杰伦` ↔ `Jay Chou`）。
    pub aliases: Vec<String>,
    /// 头像 / 头图。
    pub artwork_id: Option<ArtworkId>,
    /// MusicBrainz 艺人 ID。
    pub mbid: Option<String>,
}

// ---------------------------------------------------------------------------
// 歌词与封面
// ---------------------------------------------------------------------------

/// 歌词格式（ENR-04）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LyricsFormat {
    /// 纯文本。
    Plain,
    /// 逐行 LRC。
    Lrc,
    /// 逐字增强 LRC。
    EnhancedLrc,
    /// TTML（支持逐字、对唱、背景人声）。
    Ttml,
}

/// 一份歌词。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Lyrics {
    /// 格式。
    pub format: LyricsFormat,
    /// 原始内容。
    pub content: String,
    /// 来源（`embedded`、`sidecar`、`lrclib`、`plugin:<id>`……）。
    pub source: String,
    /// 用户调整过的整体偏移（毫秒）。
    ///
    /// 约定与 LRC 的 `[offset:]` 标签一致：**正数表示歌词提前出现**（显示时间 = 时间戳 − offset），
    /// 负数表示延后。核心只存储这个值，不改写时间戳；渲染时由 UI 套用。
    pub offset_ms: i32,
    /// 匹配置信度（0..=1）。
    pub confidence: f32,
}

/// 图片尺寸档位。缩略图按这些尺寸预先生成，UI 只取需要的档位。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ArtworkSize {
    /// 列表缩略图（96px）。
    Thumb,
    /// 网格（320px）。
    Medium,
    /// 正在播放页（1024px）。
    Large,
    /// 原图。
    Original,
}

impl ArtworkSize {
    /// 边长（像素）；原图返回 `None`。
    pub fn pixels(self) -> Option<u32> {
        match self {
            Self::Thumb => Some(96),
            Self::Medium => Some(320),
            Self::Large => Some(1024),
            Self::Original => None,
        }
    }
}

/// 从封面提取的调色板（正在播放页的动态背景用）。颜色是 `0xRRGGBB`。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Palette {
    /// 主色。
    pub primary: u32,
    /// 辅色。
    pub secondary: u32,
    /// 适合放在主色上的文字颜色。
    pub on_primary: u32,
    /// 背景渐变用的颜色（3~5 个）。
    pub gradient: Vec<u32>,
}

// ---------------------------------------------------------------------------
// 播放
// ---------------------------------------------------------------------------

/// 播放状态。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlaybackState {
    /// 空闲（队列为空）。
    Idle,
    /// 正在打开 / 首次缓冲。
    Loading,
    /// 播放中。
    Playing,
    /// 已暂停。
    Paused,
    /// 播放中但缓冲不足（网络卡顿）。
    Buffering,
    /// 队列播完了。
    Ended,
}

/// 循环模式。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RepeatMode {
    /// 不循环。
    #[default]
    Off,
    /// 列表循环。
    All,
    /// 单曲循环。
    One,
}

/// 随机模式（PLY-09）。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ShuffleMode {
    /// 顺序。
    #[default]
    Off,
    /// 真随机。
    Random,
    /// 智能随机（避免同一艺人连续出现）。
    Smart,
}

/// 离线下载状态（OFF-01/02）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OfflineState {
    /// 已入队，等待用户重试或开始。
    Queued,
    /// 正在写缓存文件。
    Downloading,
    /// 缓存文件可用。
    Ready,
    /// 下载失败 / 被取消。
    Failed,
}

impl OfflineState {
    /// 数据库里的字符串表示。
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Queued => "queued",
            Self::Downloading => "downloading",
            Self::Ready => "ready",
            Self::Failed => "failed",
        }
    }

    /// 解析数据库里的字符串；未知值返回 `None`（不让一行坏数据拖垮整个列表）。
    pub fn from_db(raw: &str) -> Option<Self> {
        match raw {
            "queued" => Some(Self::Queued),
            "downloading" => Some(Self::Downloading),
            "ready" => Some(Self::Ready),
            "failed" => Some(Self::Failed),
            _ => None,
        }
    }
}

/// 资料库排序方式。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TrackSort {
    /// 按标题（拼音 / 字母）。
    #[default]
    Title,
    /// 按艺人。
    Artist,
    /// 按专辑。
    Album,
    /// 最近添加。
    RecentlyAdded,
    /// 最常播放。
    MostPlayed,
}

/// Source copies to include in a paginated track listing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TrackSourceScope {
    /// Files in local folders.
    Local,
    /// Network file shares and media servers.
    Nas,
    /// Tracks imported by the plugin with this manifest ID.
    Plugin(String),
}

/// Category metadata for a persisted track in a source scope.
#[derive(Debug, PartialEq)]
pub struct ScopedTrackMetadata {
    /// Library track ID.
    pub track_id: TrackId,
    /// Shared album identity, also for compilations.
    pub album_id: Option<AlbumId>,
    /// Credited album artists as displayed on the album.
    pub album_artist: Option<String>,
    /// Ordered individual credits from the catalog.
    pub artists: Vec<ArtistCredit>,
    /// Display genres including user overrides.
    pub genres: Vec<String>,
}

/// 分页查询曲目。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct TrackQuery {
    /// 排序。
    pub sort: TrackSort,
    /// 偏移。
    pub offset: u32,
    /// 每页数量（上限 500）。
    pub limit: u32,
}

impl TrackQuery {
    /// 每页最大数量。
    pub const MAX_LIMIT: u32 = 500;
}

/// 搜索结果（按类型分组）。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct SearchResults {
    /// 曲目。
    pub tracks: Vec<TrackRow>,
    /// 专辑。
    pub albums: Vec<Album>,
    /// 艺人。
    pub artists: Vec<Artist>,
}

/// 流派及其曲目数（LIB-06 按流派浏览时用）。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct GenreCount {
    /// 流派名。
    pub name: String,
    /// 这个流派下的曲目数。
    pub track_count: u32,
}
