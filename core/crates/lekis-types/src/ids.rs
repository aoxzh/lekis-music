//! 强类型 ID。
//!
//! - 数据库自增 ID（`SourceId`、`TrackId`……）只在**本机**有意义，不能写进同步日志或共享索引。
//! - 跨设备、跨源稳定的 ID 用 [`TrackUid`]、[`DeviceId`] 这类字符串 ID。

use serde::{Deserialize, Serialize};
use std::fmt;

macro_rules! local_id {
    ($(#[$doc:meta] $name:ident),* $(,)?) => {$(
        #[$doc]
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
        #[serde(transparent)]
        pub struct $name(pub i64);

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                write!(f, "{}", self.0)
            }
        }
    )*};
}

local_id! {
    /// 音源（本地文件夹、SMB 共享、服务器……）。
    SourceId,
    /// 文件（某个源里的某个音频文件）。
    FileId,
    /// 曲目（统一资料库里的一首歌，可能对应多个文件）。
    TrackId,
    /// 专辑。
    AlbumId,
    /// 艺人。
    ArtistId,
    /// 歌单。
    PlaylistId,
    /// 封面 / 图片。
    ArtworkId,
    /// 网络电台（本地收藏 / 自定义）。
    RadioStationId,
    /// 播客节目（订阅 / 预览过的 RSS 源）。
    PodcastId,
    /// 播客单集。
    PodcastEpisodeId,
}

/// 播客单集合成 `TrackId` 的偏移量。
///
/// 电台占用 `-1 ..= -(2^40 - 1)`，单集占用 `-(2^40 + id)`，两段互不重叠，
/// 都避开资料库里永远为正的 `track.id`。
pub const PODCAST_EPISODE_TRACK_OFFSET: i64 = 1 << 40;

impl PodcastEpisodeId {
    /// 单集在播放队列里使用的合成曲目 ID。
    pub fn track_id(self) -> TrackId {
        TrackId(-(PODCAST_EPISODE_TRACK_OFFSET + self.0))
    }

    /// 从合成曲目 ID 还原单集 ID；其他曲目返回 `None`。
    pub fn from_track_id(track_id: TrackId) -> Option<Self> {
        (track_id.0 <= -PODCAST_EPISODE_TRACK_OFFSET)
            .then(|| Self(-track_id.0 - PODCAST_EPISODE_TRACK_OFFSET))
            .filter(|id| id.0 > 0)
    }
}

impl RadioStationId {
    /// 电台在播放队列里使用的合成曲目 ID。
    ///
    /// 用负数避开资料库自增的 `track.id`（永远为正），这样播放引擎、队列和
    /// 「正在播放」界面都不用为电台单独开一条路径。
    pub fn track_id(self) -> TrackId {
        TrackId(-self.0)
    }

    /// 从合成曲目 ID 还原电台 ID；普通曲目返回 `None`。
    pub fn from_track_id(track_id: TrackId) -> Option<Self> {
        (track_id.0 < 0 && track_id.0 > -PODCAST_EPISODE_TRACK_OFFSET).then_some(Self(-track_id.0))
    }
}

/// 跨设备、跨源稳定的曲目身份。
///
/// 生成优先级：`mb:<MusicBrainz 录音 ID>` > `ac:<AcoustID>` >
/// `h:<规范化的 艺人+标题+专辑+时长(取整到 2 秒) 的哈希>`。
/// 同步日志、歌单、播放历史里引用曲目时**必须**用它。
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct TrackUid(pub String);

impl TrackUid {
    /// 由 MusicBrainz 录音 ID 生成。
    pub fn from_mbid(mbid: &str) -> Self {
        Self(format!("mb:{}", mbid.to_ascii_lowercase()))
    }

    /// 由 AcoustID 生成。
    pub fn from_acoustid(id: &str) -> Self {
        Self(format!("ac:{}", id.to_ascii_lowercase()))
    }

    /// 由元数据哈希生成（哈希由调用方计算，这里只负责加前缀）。
    pub fn from_meta_hash(hex: &str) -> Self {
        Self(format!("h:{hex}"))
    }

    /// 没有 MBID / AcoustID 时，用元数据生成稳定 ID。
    ///
    /// 规范化：小写、折叠空白；时长取整到 2 秒，吸收不同编码之间的细微差异。
    /// 哈希用 FNV-1a 64 位——**算法和规范化规则一旦发布就不能改**，否则所有设备上的 ID 都会变。
    pub fn from_metadata(artist: &str, title: &str, album: &str, duration_ms: u64) -> Self {
        fn norm(s: &str) -> String {
            s.split_whitespace()
                .collect::<Vec<_>>()
                .join(" ")
                .to_lowercase()
        }
        let key = format!(
            "{}\u{1f}{}\u{1f}{}\u{1f}{}",
            norm(artist),
            norm(title),
            norm(album),
            (duration_ms + 1000) / 2000
        );
        let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
        for byte in key.as_bytes() {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x0100_0000_01b3);
        }
        Self::from_meta_hash(&format!("{hash:016x}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn podcast_episode_track_id_does_not_collide_with_radio() {
        let episode = PodcastEpisodeId(7);
        let track = episode.track_id();
        assert!(track.0 < 0);
        assert_eq!(PodcastEpisodeId::from_track_id(track), Some(episode));
        assert_eq!(RadioStationId::from_track_id(track), None);
        assert_eq!(PodcastEpisodeId::from_track_id(TrackId(-7)), None);
        assert_eq!(PodcastEpisodeId::from_track_id(TrackId(7)), None);
    }

    #[test]
    fn radio_track_id_is_negative_and_roundtrips() {
        let station = RadioStationId(7);
        assert_eq!(station.track_id(), TrackId(-7));
        assert_eq!(RadioStationId::from_track_id(TrackId(-7)), Some(station));
        assert_eq!(RadioStationId::from_track_id(TrackId(7)), None);
    }

    #[test]
    fn metadata_uid_is_stable_and_normalized() {
        let a = TrackUid::from_metadata("Jay  Chou", "晴天", "叶惠美", 269_400);
        let b = TrackUid::from_metadata("jay chou", "晴天", "叶惠美", 269_900);
        assert_eq!(a, b);
        assert!(a.0.starts_with("h:"));
        // 固定值：防止有人无意中改了算法。
        assert_eq!(
            a,
            TrackUid::from_metadata("JAY CHOU", "晴天", "叶惠美", 269_000)
        );
        // 字面量：TrackUid 会写进同步日志和共享索引，算法一旦改变，所有设备的数据都会对不上。
        // 如果这条断言失败，说明你改了算法——这需要一个 ADR 和迁移方案，而不是改这个值。
        assert_eq!(a.0, "h:47f8b2199bcdc0d5");
    }
}

/// 设备 ID（首次启动时生成，存在本机数据目录）。
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct DeviceId(pub String);

impl DeviceId {
    /// 生成一个新的设备 ID（UUIDv7，带时间顺序）。
    pub fn generate() -> Self {
        Self(uuid::Uuid::now_v7().to_string())
    }
}

/// 插件 ID（反向域名格式，例如 `com.example.lrclib`）。
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct PluginId(pub String);

impl fmt::Display for TrackUid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl fmt::Display for DeviceId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl fmt::Display for PluginId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}
