//! 播客（SRC-12）：Apple 目录搜索 / 排行榜、RSS 订阅、单集播放与进度、OPML。
//!
//! 默认数据源都不需要密钥：Apple Podcasts 目录（`itunes.apple.com/search`、
//! `/lookup`、`/{cc}/rss/toppodcasts`）+ 节目自己的 RSS。

use lekis_types as t;

use crate::api::error::CoreError;
use crate::internal::core;

// ---------------------------------------------------------------------------
// DTO
// ---------------------------------------------------------------------------

/// 目录（搜索 / 排行榜）里的一档节目。
#[derive(Debug, Clone)]
pub struct DirectoryPodcastDto {
    /// Apple 目录 ID。
    pub itunes_id: Option<i64>,
    /// 标题。
    pub title: String,
    /// 作者。
    pub author: Option<String>,
    /// 封面。
    pub artwork_url: Option<String>,
    /// RSS 地址（排行榜不带）。
    pub feed_url: Option<String>,
    /// 主分类。
    pub genre: Option<String>,
    /// 集数。
    pub episode_count: Option<u32>,
    /// 已在本地库里时的本机 ID。
    pub local_id: Option<i64>,
    /// 已订阅。
    pub subscribed: bool,
}

impl From<lekis_core::DirectoryPodcast> for DirectoryPodcastDto {
    fn from(p: lekis_core::DirectoryPodcast) -> Self {
        Self {
            itunes_id: p.itunes_id,
            title: p.title,
            author: p.author,
            artwork_url: p.artwork_url,
            feed_url: p.feed_url,
            genre: p.genre,
            episode_count: p.episode_count,
            local_id: p.local_id.map(|id| id.0),
            subscribed: p.subscribed,
        }
    }
}

/// 一档节目（本地缓存）。
#[derive(Debug, Clone)]
pub struct PodcastDto {
    /// 本机 ID。
    pub id: i64,
    /// RSS 地址。
    pub feed_url: String,
    /// Apple 目录 ID。
    pub itunes_id: Option<i64>,
    /// 标题。
    pub title: String,
    /// 作者。
    pub author: Option<String>,
    /// 简介（纯文本）。
    pub description: Option<String>,
    /// 封面。
    pub artwork_url: Option<String>,
    /// 主页。
    pub link: Option<String>,
    /// 分类。
    pub categories: Vec<String>,
    /// 已订阅。
    pub subscribed: bool,
    /// 最近一次成功刷新（Unix 毫秒）。
    pub last_refreshed_at: Option<i64>,
    /// 最近一次刷新失败的原因。
    pub last_error: Option<String>,
    /// 单集数。
    pub episode_count: u32,
    /// 未播放单集数。
    pub unplayed_count: u32,
    /// 最新一集的发布时间（Unix 毫秒）。
    pub latest_published_at: Option<i64>,
}

impl From<t::Podcast> for PodcastDto {
    fn from(p: t::Podcast) -> Self {
        Self {
            id: p.id.0,
            feed_url: p.feed_url,
            itunes_id: p.itunes_id,
            title: p.title,
            author: p.author,
            description: p.description,
            artwork_url: p.artwork_url,
            link: p.link,
            categories: p.categories,
            subscribed: p.subscribed,
            last_refreshed_at: p.last_refreshed_at,
            last_error: p.last_error,
            episode_count: p.episode_count,
            unplayed_count: p.unplayed_count,
            latest_published_at: p.latest_published_at,
        }
    }
}

/// 播客单集。
#[derive(Debug, Clone)]
pub struct PodcastEpisodeDto {
    /// 本机 ID。
    pub id: i64,
    /// 播放队列里使用的合成曲目 ID（负数）。
    pub track_id: i64,
    /// 所属节目。
    pub podcast_id: i64,
    /// 节目标题。
    pub podcast_title: String,
    /// 标题。
    pub title: String,
    /// 简介（纯文本）。
    pub description: Option<String>,
    /// 音频地址。
    pub audio_url: String,
    /// 文件大小（字节）。
    pub size_bytes: Option<u64>,
    /// 时长（毫秒，0 表示未知）。
    pub duration_ms: u64,
    /// 发布时间（Unix 毫秒）。
    pub published_at: Option<i64>,
    /// 封面（没有单集封面时是节目封面）。
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

impl From<t::PodcastEpisode> for PodcastEpisodeDto {
    fn from(e: t::PodcastEpisode) -> Self {
        Self {
            id: e.id.0,
            track_id: e.id.track_id().0,
            podcast_id: e.podcast_id.0,
            podcast_title: e.podcast_title,
            title: e.title,
            description: e.description,
            audio_url: e.audio_url,
            size_bytes: e.size_bytes,
            duration_ms: e.duration_ms,
            published_at: e.published_at,
            artwork_url: e.artwork_url,
            episode_no: e.episode_no,
            season_no: e.season_no,
            link: e.link,
            position_ms: e.position_ms,
            played: e.played,
            last_played_at: e.last_played_at,
        }
    }
}

/// OPML 导入结果。
#[derive(Debug, Clone)]
pub struct OpmlImportReportDto {
    /// 有效条目数。
    pub total: u32,
    /// 新订阅。
    pub added: u32,
    /// 原本就订阅了。
    pub already_subscribed: u32,
    /// RSS 抓取失败（仍然订阅）。
    pub failed: u32,
}

/// 刷新全部订阅的结果。
#[derive(Debug, Clone)]
pub struct PodcastRefreshReportDto {
    /// 成功。
    pub refreshed: u32,
    /// 失败。
    pub failed: u32,
    /// 新增单集数。
    pub new_episodes: u32,
}

fn episodes(list: Vec<t::PodcastEpisode>) -> Vec<PodcastEpisodeDto> {
    list.into_iter().map(Into::into).collect()
}

// ---------------------------------------------------------------------------
// 函数
// ---------------------------------------------------------------------------

/// 搜索 Apple 播客目录。`country` 是 ISO 3166-1 二位代码（`CN`、`US`）。
/// 也可以直接传 Apple Podcasts 网页链接。
pub async fn podcast_search(
    term: String,
    country: String,
    limit: u32,
) -> Result<Vec<DirectoryPodcastDto>, CoreError> {
    Ok(core()
        .podcast_search(
            term,
            country,
            limit.clamp(1, lekis_core::PODCAST_DIRECTORY_MAX),
        )
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// 分地区排行榜；`genre_id` 是 Apple 播客分类 ID（`None` 表示全部）。
pub async fn podcast_top(
    country: String,
    genre_id: Option<u32>,
    limit: u32,
) -> Result<Vec<DirectoryPodcastDto>, CoreError> {
    Ok(core()
        .podcast_top(
            country,
            genre_id,
            limit.clamp(1, lekis_core::PODCAST_DIRECTORY_MAX),
        )
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// 打开目录里的节目（抓 RSS 并缓存，不自动订阅）。
pub async fn podcast_open_directory(
    itunes_id: Option<i64>,
    feed_url: Option<String>,
) -> Result<PodcastDto, CoreError> {
    Ok(core()
        .podcast_open_directory(itunes_id, feed_url)
        .await?
        .into())
}

/// 按 RSS 地址或 Apple Podcasts 链接添加节目（抓取并缓存，不自动订阅）。
pub async fn podcast_open_feed(address: String) -> Result<PodcastDto, CoreError> {
    Ok(core().podcast_open_feed(address).await?.into())
}

/// 重新抓取一个节目。
pub async fn podcast_refresh(podcast_id: i64) -> Result<PodcastDto, CoreError> {
    Ok(core()
        .podcast_refresh(t::PodcastId(podcast_id))
        .await?
        .into())
}

/// 刷新所有订阅。
pub async fn podcast_refresh_all() -> Result<PodcastRefreshReportDto, CoreError> {
    let r = core().podcast_refresh_all().await?;
    Ok(PodcastRefreshReportDto {
        refreshed: r.refreshed,
        failed: r.failed,
        new_episodes: r.new_episodes,
    })
}

/// 订阅 / 取消订阅。
pub async fn podcast_set_subscribed(podcast_id: i64, subscribed: bool) -> Result<(), CoreError> {
    Ok(core()
        .podcast_set_subscribed(t::PodcastId(podcast_id), subscribed)
        .await?)
}

/// 已订阅的节目。
pub async fn podcast_subscriptions() -> Result<Vec<PodcastDto>, CoreError> {
    Ok(core()
        .podcast_subscriptions()
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// 本地缓存的节目。
pub async fn podcast_get(podcast_id: i64) -> Result<PodcastDto, CoreError> {
    Ok(core().podcast_get(t::PodcastId(podcast_id)).await?.into())
}

/// 节目的单集（新的在前）。
pub async fn podcast_episodes(
    podcast_id: i64,
    offset: u32,
    limit: u32,
) -> Result<Vec<PodcastEpisodeDto>, CoreError> {
    Ok(episodes(
        core()
            .podcast_episodes(t::PodcastId(podcast_id), offset, limit)
            .await?,
    ))
}

/// 订阅里最新的单集。
pub async fn podcast_latest_episodes(limit: u32) -> Result<Vec<PodcastEpisodeDto>, CoreError> {
    Ok(episodes(core().podcast_latest_episodes(limit).await?))
}

/// 听到一半的单集。
pub async fn podcast_in_progress(limit: u32) -> Result<Vec<PodcastEpisodeDto>, CoreError> {
    Ok(episodes(core().podcast_in_progress(limit).await?))
}

/// 标记已播放 / 未播放。
pub async fn podcast_set_played(episode_id: i64, played: bool) -> Result<(), CoreError> {
    Ok(core()
        .podcast_set_played(t::PodcastEpisodeId(episode_id), played)
        .await?)
}

/// 节目全部标记为已播放。
pub async fn podcast_mark_all_played(podcast_id: i64) -> Result<(), CoreError> {
    Ok(core()
        .podcast_mark_all_played(t::PodcastId(podcast_id))
        .await?)
}

/// 用一组单集替换播放队列，从 `start` 开始（有进度时从上次位置接着放）。
pub async fn podcast_play(episode_ids: Vec<i64>, start: u32) -> Result<u32, CoreError> {
    Ok(core()
        .podcast_play(
            episode_ids.into_iter().map(t::PodcastEpisodeId).collect(),
            start,
        )
        .await?)
}

/// 导入 OPML 文本（全部订阅）。
pub async fn podcast_import_opml(text: String) -> Result<OpmlImportReportDto, CoreError> {
    let r = core().podcast_import_opml(text).await?;
    Ok(OpmlImportReportDto {
        total: r.total,
        added: r.added,
        already_subscribed: r.already_subscribed,
        failed: r.failed,
    })
}

/// 导出订阅为 OPML 2.0 文本。
pub async fn podcast_export_opml() -> Result<String, CoreError> {
    Ok(core().podcast_export_opml().await?)
}
