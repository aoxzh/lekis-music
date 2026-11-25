//! 重复检测与库健康报告（LIB-10 / LIB-11）。
//!
//! 两件事都直接在 SQL 里聚合，只把当前页需要的行取回 Rust：
//! - 重复检测先按规范化元数据 + 2 秒时长窗口分组，再在 Rust 里给每一组挑保留版本；
//! - 健康报告按问题类型分页查询，缺失封面 / 歌词 / 标签不需要把音频文件读进内存。
//!
//! 规范化键由 [`crate::normalize::norm_key`] 提供，通过 SQLite 标量函数 `lekis_norm`
//! 注册到每个连接上（见 [`crate::db`]）。MusicBrainz Recording ID 优先：
//! 同一组里出现多个不同的 Recording ID 时，认为它们是不同录音，不报告为重复。

use crate::db::DbResultExt;
use crate::Library;
use lekis_types::{AlbumId, AudioProps, Codec, Result, SourceId, TrackId, TrackQuery};
use rusqlite::{params, Row};

/// 时长容差（毫秒）。同一组内相邻版本的时长相差不超过这个值。
pub const DUPLICATE_DURATION_TOLERANCE_MS: i64 = 2_000;

/// 重复组里的一个版本。
#[derive(Debug, Clone, PartialEq)]
pub struct DuplicateTrack {
    /// 曲目 ID。
    pub track_id: TrackId,
    /// 这个版本来自哪个音源（服务器曲目没有本地文件时仍会有值）。
    pub source_id: Option<SourceId>,
    /// 标题（可能因标签差异与同组其他版本不同）。
    pub title: String,
    /// 艺人署名。
    pub artist_line: String,
    /// 专辑。
    pub album_title: Option<String>,
    /// 专辑 ID。
    pub album_id: Option<AlbumId>,
    /// MusicBrainz Recording ID（没有时为 `None`）。
    pub mbid_recording: Option<String>,
    /// 文件路径；服务器曲目可能是 external id 或空串。
    pub path: String,
    /// 时长（毫秒）。
    pub duration_ms: u64,
    /// 文件大小（字节；未知为 0）。
    pub size_bytes: u64,
    /// 供 UI 显示的音质标签（如 `FLAC 24/96`、`MP3 320`）。
    pub format: Option<String>,
    /// 编码名（`flac`、`mp3`……）；没有音频属性时为 `None`。
    pub codec: Option<String>,
    /// 平均码率（kbps）。
    pub bitrate_kbps: Option<u32>,
    /// 位深。
    pub bit_depth: Option<u8>,
    /// 采样率（Hz）。
    pub sample_rate: Option<u32>,
    /// 资料库音质分（SRC-13）。
    pub quality_score: i64,
    /// 是否是建议保留的版本。每组恰好一个。
    pub suggested_keep: bool,
}

impl DuplicateTrack {
    fn keep_rank(&self) -> (bool, i64, u8, u32, u32, u64) {
        (
            self.codec_is_lossless(),
            self.quality_score,
            self.bit_depth.unwrap_or(0),
            self.sample_rate.unwrap_or(0),
            self.bitrate_kbps.unwrap_or(0),
            self.size_bytes,
        )
    }

    fn codec_is_lossless(&self) -> bool {
        matches!(
            self.codec.as_deref(),
            Some("flac" | "alac" | "wav" | "aiff" | "ape" | "wavpack" | "tta" | "dsd")
        )
    }
}

/// 一组重复曲目。
#[derive(Debug, Clone, PartialEq)]
pub struct DuplicateGroup {
    /// 分组用的规范化键（不展示给用户）。
    pub key: String,
    /// 代表标题（取自建议保留的版本）。
    pub title: String,
    /// 代表艺人署名。
    pub artist_line: String,
    /// 代表专辑。
    pub album_title: Option<String>,
    /// 代表专辑 ID。
    pub album_id: Option<AlbumId>,
    /// 组内一致的 MusicBrainz Recording ID（没有或冲突时为 `None`）。
    pub mbid_recording: Option<String>,
    /// 建议保留的曲目。
    pub keep_track_id: TrackId,
    /// 组内所有版本，按音质从高到低排列。
    pub tracks: Vec<DuplicateTrack>,
}

/// 库健康问题类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum HealthIssueKind {
    /// 曲目和专辑都没有封面。
    MissingCover,
    /// 没有生效歌词。
    MissingLyrics,
    /// 标题或艺人缺失。
    MissingTags,
    /// 扩展名 / 编码是无损，但码率或文件大小异常低。
    FakeLossless,
    /// 上次健康扫描时打不开或读不了的文件。
    Unreadable,
}

impl HealthIssueKind {
    /// 稳定的字符串形式（日志、测试用）。
    pub fn as_str(self) -> &'static str {
        match self {
            Self::MissingCover => "missing_cover",
            Self::MissingLyrics => "missing_lyrics",
            Self::MissingTags => "missing_tags",
            Self::FakeLossless => "fake_lossless",
            Self::Unreadable => "unreadable",
        }
    }

    /// 从稳定字符串解析（不用 `FromStr`，避免和标准 trait 混淆）。
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "missing_cover" => Some(Self::MissingCover),
            "missing_lyrics" => Some(Self::MissingLyrics),
            "missing_tags" => Some(Self::MissingTags),
            "fake_lossless" => Some(Self::FakeLossless),
            "unreadable" => Some(Self::Unreadable),
            _ => None,
        }
    }
}

/// 库健康汇总。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct LibraryHealthSummary {
    /// 曲目总数。
    pub total_tracks: u64,
    /// 重复组数量。
    pub duplicate_groups: u64,
    /// 缺封面的曲目数。
    pub missing_cover: u64,
    /// 缺歌词的曲目数。
    pub missing_lyrics: u64,
    /// 缺标题或艺人的曲目数。
    pub missing_tags: u64,
    /// 疑似假无损的曲目数。
    pub fake_lossless: u64,
    /// 扫描标记为不可读的文件数。
    pub unreadable_files: u64,
}

/// 健康报告里的一条。
#[derive(Debug, Clone, PartialEq)]
pub struct LibraryHealthEntry {
    /// 问题类型。
    pub kind: HealthIssueKind,
    /// 曲目 ID。
    pub track_id: TrackId,
    /// 标题。
    pub title: String,
    /// 艺人署名。
    pub artist_line: String,
    /// 专辑。
    pub album_title: Option<String>,
    /// 专辑 ID。
    pub album_id: Option<AlbumId>,
    /// 音源。
    pub source_id: Option<SourceId>,
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
    /// 额外说明（不可读文件的错误信息）。
    pub detail: Option<String>,
}

/// 健康扫描时按源分页读取的文件。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HealthScanFile {
    /// `file` 表 ID。
    pub file_id: i64,
    /// 相对音源根目录的路径。
    pub path: String,
}

/// 一批健康扫描结果写入后的统计。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct FileHealthUpdate {
    /// 新标记为不可读的文件数。
    pub marked: u64,
    /// 从不可读恢复成正常的文件数。
    pub cleared: u64,
}

/// 带 `best` CTE 的公共前缀：每首曲目取音质最高的文件。
const BEST_FILE_CTE: &str = "
WITH ranked AS (
  SELECT tf.track_id,
         COALESCE(f.path, tf.external_id, '') AS path,
         COALESCE(f.size, 0) AS size,
         f.audio_json,
         tf.quality_score,
         tf.source_id,
         ROW_NUMBER() OVER (
           PARTITION BY tf.track_id
           ORDER BY tf.quality_score DESC, COALESCE(f.size, 0) DESC,
                    COALESCE(f.path, ''), tf.source_id
         ) AS rn
  FROM track_file tf
  LEFT JOIN file f ON f.id = tf.file_id
),
best AS (
  SELECT t.id AS track_id, t.title, t.title_sort_key, t.artist_line,
         t.album_id, a.title AS album_title,
         COALESCE(t.artwork_id, a.artwork_id) AS effective_artwork_id,
         t.duration_ms, t.mbid_recording,
         COALESCE(r.path, '') AS path, COALESCE(r.size, 0) AS size,
         r.audio_json, COALESCE(r.quality_score, 0) AS quality_score,
         r.source_id
  FROM track t
  LEFT JOIN album a ON a.id = t.album_id
  LEFT JOIN ranked r ON r.track_id = t.id AND r.rn = 1
)
";

/// 重复检测的公共 CTE，末尾的 `groups` 只包含真正要报告的重复组。
const DUPLICATE_CTE: &str = "
WITH ranked_files AS (
  SELECT f.id AS file_id, t.id AS track_id, t.title, t.title_sort_key,
         t.artist_line, t.album_id, a.title AS album_title, t.duration_ms,
         t.mbid_recording, f.path, f.size, f.audio_json, tf.quality_score,
         tf.source_id,
         ROW_NUMBER() OVER (
           PARTITION BY f.id ORDER BY tf.quality_score DESC, t.id
         ) AS rn
  FROM file f
  JOIN track_file tf ON tf.file_id = f.id
  JOIN track t ON t.id = tf.track_id
  LEFT JOIN album a ON a.id = t.album_id
),
versions AS (
  SELECT file_id, track_id, title, title_sort_key, artist_line, album_id,
         album_title, duration_ms, mbid_recording, path, size, audio_json,
         quality_score, source_id,
         'meta:' || lekis_norm(title) || char(31)
                 || lekis_norm(artist_line) || char(31)
                 || lekis_norm(COALESCE(album_title, '')) AS meta_key
  FROM ranked_files
  WHERE rn = 1
),
marked AS (
  SELECT *,
         CASE WHEN meta_key = LAG(meta_key) OVER (
                      ORDER BY meta_key, duration_ms, track_id, file_id
                    )
                   AND duration_ms - LAG(duration_ms) OVER (
                      ORDER BY meta_key, duration_ms, track_id, file_id
                    ) <= 2000
              THEN 0 ELSE 1 END AS is_new
  FROM versions
),
grouped AS (
  SELECT *,
         SUM(is_new) OVER (
           ORDER BY meta_key, duration_ms, track_id, file_id
           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
         ) AS grp
  FROM marked
),
groups AS (
  SELECT grp, COUNT(*) AS n,
         COUNT(DISTINCT NULLIF(TRIM(mbid_recording), '')) AS mbids,
         MIN(title_sort_key) AS sort_key,
         MIN(track_id) AS first_id
  FROM grouped
  GROUP BY grp
  HAVING COUNT(*) > 1
     AND COUNT(DISTINCT NULLIF(TRIM(mbid_recording), '')) <= 1
)
";

/// 缺封面检测条件（仅限本地音乐与 NAS 文件系统源，排除插件与媒体服务器音源）。
/// 插件与媒体服务器有自己的封面拉取机制，不应被计入「缺封面」或送入本地补全队列。
const MISSING_COVER_SQL: &str = "
  b.effective_artwork_id IS NULL
  AND (
    NOT EXISTS (SELECT 1 FROM track_file tf WHERE tf.track_id = b.track_id)
    OR EXISTS (
      SELECT 1
      FROM track_file tf
      JOIN source s ON s.id = tf.source_id
      WHERE tf.track_id = b.track_id
        AND s.kind IN ('local', 'smb', 'webdav', 'nfs', 'sftp')
    )
  )
";

/// 假无损的简单启发式（别名必须是 `b`，表示 [`BEST_FILE_CTE`] 的 `best`）。
const FAKE_LOSSLESS_SQL: &str = "
  ((b.audio_json IS NOT NULL AND json_valid(b.audio_json)
    AND json_extract(b.audio_json, '$.codec') IN
        ('flac', 'alac', 'wav', 'aiff', 'ape', 'wavpack', 'tta', 'dsd')
    AND COALESCE(json_extract(b.audio_json, '$.sample_rate'), 0) <= 44100
    AND COALESCE(json_extract(b.audio_json, '$.bitrate_kbps'), 0) > 0
    AND json_extract(b.audio_json, '$.bitrate_kbps') < 500)
   OR
   (b.duration_ms >= 60000 AND b.size > 0
    AND (b.size * 8 / b.duration_ms) < 500
    AND (lower(b.path) LIKE '%.flac' OR lower(b.path) LIKE '%.alac'
         OR lower(b.path) LIKE '%.wav' OR lower(b.path) LIKE '%.aiff'
         OR lower(b.path) LIKE '%.ape' OR lower(b.path) LIKE '%.wv'
         OR lower(b.path) LIKE '%.tta' OR lower(b.path) LIKE '%.dsf'
         OR lower(b.path) LIKE '%.dff')))
";

impl Library {
    /// 分页列出重复组（LIB-10）。
    ///
    /// 按规范化标题 / 艺人 / 专辑分组，组内相邻版本时长相差不超过
    /// [`DUPLICATE_DURATION_TOLERANCE_MS`]；同一组有多个不同 MusicBrainz
    /// Recording ID 时视为不同录音，不报告。每组的保留版本在 Rust 里按
    /// 无损 > 音质分 > 位深 / 采样率 / 码率 > 文件大小挑选。
    pub async fn duplicate_groups(&self, offset: u32, limit: u32) -> Result<Vec<DuplicateGroup>> {
        validate_page(limit)?;
        let sql_groups = format!(
            "{DUPLICATE_CTE}
             SELECT grp FROM groups ORDER BY sort_key, first_id LIMIT ?1 OFFSET ?2"
        );
        let sql_members = format!(
            "{DUPLICATE_CTE}
             SELECT grp, track_id, title, artist_line, album_title, album_id,
                    duration_ms, mbid_recording, path, size, audio_json,
                    quality_score, source_id, meta_key
             FROM grouped
             WHERE grp IN (SELECT value FROM json_each(?1))
             ORDER BY grp, quality_score DESC, size DESC, track_id"
        );
        let groups = self
            .read(move |c| {
                let page_ids: Vec<i64> = {
                    let mut stmt = c.prepare_cached(&sql_groups).db()?;
                    let rows = stmt
                        .query_map(params![limit, offset], |r| r.get::<_, i64>(0))
                        .db()?;
                    rows.collect::<rusqlite::Result<Vec<_>>>().db()?
                };
                if page_ids.is_empty() {
                    return Ok(Vec::new());
                }
                let ids = serde_json::to_string(&page_ids)
                    .map_err(|e| lekis_types::LekisError::internal(format!("page ids: {e}")))?;
                let mut stmt = c.prepare_cached(&sql_members).db()?;
                let rows = stmt.query_map(params![ids], map_duplicate_member).db()?;
                let mut out: Vec<DuplicateGroup> = Vec::new();
                let mut current_grp: Option<i64> = None;
                for row in rows {
                    let (grp, track, meta_key) = row.db()?;
                    if current_grp != Some(grp) {
                        current_grp = Some(grp);
                        out.push(DuplicateGroup {
                            key: meta_key,
                            title: String::new(),
                            artist_line: String::new(),
                            album_title: None,
                            album_id: None,
                            mbid_recording: None,
                            keep_track_id: track.track_id,
                            tracks: Vec::new(),
                        });
                    }
                    if let Some(group) = out.last_mut() {
                        group.tracks.push(track);
                    }
                }
                for group in &mut out {
                    finish_duplicate_group(group);
                }
                Ok(out)
            })
            .await?;
        Ok(groups)
    }

    /// 重复组总数（分页 / 汇总卡用）。
    pub async fn duplicate_group_count(&self) -> Result<u64> {
        let sql = format!("{DUPLICATE_CTE} SELECT COUNT(*) FROM groups");
        self.read(move |c| {
            c.query_row(&sql, [], |r| r.get::<_, i64>(0))
                .db()
                .map(|n| n.max(0) as u64)
        })
        .await
    }

    /// 库健康汇总（LIB-11）。损坏 / 不可读数量来自最近一次健康扫描。
    pub async fn library_health_summary(&self) -> Result<LibraryHealthSummary> {
        let sql = format!(
            "{BEST_FILE_CTE}
             SELECT COUNT(*),
                    COALESCE(SUM(CASE WHEN {MISSING_COVER_SQL} THEN 1 ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN NOT EXISTS (
                        SELECT 1 FROM lyrics l
                        WHERE l.track_id = b.track_id AND l.is_active = 1
                    ) THEN 1 ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN TRIM(b.title) = '' OR TRIM(b.artist_line) = ''
                                     THEN 1 ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN {FAKE_LOSSLESS_SQL} THEN 1 ELSE 0 END), 0)
             FROM best b"
        );
        let unreadable_sql = "SELECT COUNT(*) FROM file WHERE scan_state = 'error'".to_string();
        let duplicate_groups = self.duplicate_group_count().await?;
        self.read(move |c| {
            let (total, missing_cover, missing_lyrics, missing_tags, fake_lossless) = c
                .query_row(&sql, [], |r| {
                    Ok((
                        r.get::<_, i64>(0)?.max(0) as u64,
                        r.get::<_, i64>(1)?.max(0) as u64,
                        r.get::<_, i64>(2)?.max(0) as u64,
                        r.get::<_, i64>(3)?.max(0) as u64,
                        r.get::<_, i64>(4)?.max(0) as u64,
                    ))
                })
                .db()?;
            let unreadable_files = c
                .query_row(&unreadable_sql, [], |r| r.get::<_, i64>(0))
                .db()?
                .max(0) as u64;
            Ok(LibraryHealthSummary {
                total_tracks: total,
                duplicate_groups,
                missing_cover,
                missing_lyrics,
                missing_tags,
                fake_lossless,
                unreadable_files,
            })
        })
        .await
    }

    /// 某一类健康问题的条目数。
    pub async fn library_health_count(&self, kind: HealthIssueKind) -> Result<u64> {
        let sql = health_count_sql(kind);
        self.read(move |c| {
            c.query_row(&sql, [], |r| r.get::<_, i64>(0))
                .db()
                .map(|n| n.max(0) as u64)
        })
        .await
    }

    /// 按问题类型分页列出健康报告条目。
    ///
    /// `Unreadable` 的条目来自 `file.scan_state = 'error'`，需要先调用
    /// [`Library::record_file_health`] 或由核心的 `scan_library_health` 写入。
    pub async fn library_health_page(
        &self,
        kind: HealthIssueKind,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<LibraryHealthEntry>> {
        validate_page(limit)?;
        let sql = health_page_sql(kind);
        self.read(move |c| {
            let mut stmt = c.prepare_cached(&sql).db()?;
            let rows = stmt
                .query_map(params![limit, offset], |r| map_health_entry(kind, r))
                .db()?;
            rows.collect::<rusqlite::Result<Vec<_>>>().db()
        })
        .await
    }

    /// 有已入库文件的音源（按 ID 排序）。
    pub async fn file_sources(&self) -> Result<Vec<SourceId>> {
        self.read(|c| {
            let mut stmt = c
                .prepare_cached("SELECT DISTINCT source_id FROM file ORDER BY source_id")
                .db()?;
            let rows = stmt.query_map([], |r| r.get::<_, i64>(0)).db()?;
            Ok(rows
                .collect::<rusqlite::Result<Vec<_>>>()
                .db()?
                .into_iter()
                .map(SourceId)
                .collect())
        })
        .await
    }

    /// 健康扫描时按源、按页读取文件路径。
    pub async fn files_for_health_scan(
        &self,
        source_id: SourceId,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<HealthScanFile>> {
        validate_page(limit)?;
        self.read(move |c| {
            let mut stmt = c
                .prepare_cached(
                    "SELECT id, path FROM file
                     WHERE source_id = ?1
                     ORDER BY path, id
                     LIMIT ?2 OFFSET ?3",
                )
                .db()?;
            let rows = stmt
                .query_map(params![source_id.0, limit, offset], |r| {
                    Ok(HealthScanFile {
                        file_id: r.get(0)?,
                        path: r.get(1)?,
                    })
                })
                .db()?;
            rows.collect::<rusqlite::Result<Vec<_>>>().db()
        })
        .await
    }

    /// 写入一批健康扫描结果。
    ///
    /// `results` 是 `(file_id, None)` 表示读取成功，`(file_id, Some(error))`
    /// 表示打不开 / 读不了。成功只清除之前留下的错误状态，不会覆盖正常标签状态。
    pub async fn record_file_health(
        &self,
        results: Vec<(i64, Option<String>)>,
    ) -> Result<FileHealthUpdate> {
        if results.is_empty() {
            return Ok(FileHealthUpdate::default());
        }
        self.write(move |conn| {
            let tx = conn.transaction().db()?;
            let mut update = FileHealthUpdate::default();
            {
                let mut bad = tx
                    .prepare_cached(
                        "UPDATE file SET scan_state = 'error', scan_error = ?2
                         WHERE id = ?1 AND (scan_state <> 'error' OR scan_error IS NOT ?2)",
                    )
                    .db()?;
                let mut good = tx
                    .prepare_cached(
                        "UPDATE file SET scan_state = 'tagged', scan_error = NULL
                         WHERE id = ?1 AND scan_state = 'error'",
                    )
                    .db()?;
                for (file_id, error) in results {
                    match error {
                        Some(message) => {
                            update.marked += bad.execute(params![file_id, message]).db()? as u64;
                        }
                        None => {
                            update.cleared += good.execute(params![file_id]).db()? as u64;
                        }
                    }
                }
            }
            tx.commit().db()?;
            Ok(update)
        })
        .await
    }
}

fn validate_page(limit: u32) -> Result<()> {
    if limit == 0 || limit > TrackQuery::MAX_LIMIT {
        return Err(lekis_types::LekisError::invalid(format!(
            "limit must be 1..={}",
            TrackQuery::MAX_LIMIT
        )));
    }
    Ok(())
}

fn map_duplicate_member(r: &Row<'_>) -> rusqlite::Result<(i64, DuplicateTrack, String)> {
    let duration_ms = r.get::<_, i64>(6)?.max(0) as u64;
    let size = r.get::<_, i64>(9)?.max(0) as u64;
    let audio_json: Option<String> = r.get(10)?;
    let audio = audio_json
        .as_deref()
        .and_then(|s| serde_json::from_str::<AudioProps>(s).ok());
    let AudioDisplay {
        format,
        codec,
        bitrate_kbps,
        bit_depth,
        sample_rate,
    } = audio_fields(audio.as_ref());
    Ok((
        r.get(0)?,
        DuplicateTrack {
            track_id: TrackId(r.get(1)?),
            source_id: r.get::<_, Option<i64>>(12)?.map(SourceId),
            title: r.get(2)?,
            artist_line: r.get(3)?,
            album_title: r.get(4)?,
            album_id: r.get::<_, Option<i64>>(5)?.map(AlbumId),
            mbid_recording: r.get(7)?,
            path: r.get(8)?,
            duration_ms,
            size_bytes: size,
            format,
            codec,
            bitrate_kbps,
            bit_depth,
            sample_rate,
            quality_score: r.get::<_, i64>(11)?,
            suggested_keep: false,
        },
        r.get(13)?,
    ))
}

fn finish_duplicate_group(group: &mut DuplicateGroup) {
    if group.tracks.is_empty() {
        return;
    }
    let keep = group
        .tracks
        .iter()
        .enumerate()
        .max_by(|(_, a), (_, b)| {
            a.keep_rank()
                .cmp(&b.keep_rank())
                .then_with(|| b.track_id.0.cmp(&a.track_id.0))
        })
        .map(|(index, _)| index)
        .unwrap_or(0);
    for (index, track) in group.tracks.iter_mut().enumerate() {
        track.suggested_keep = index == keep;
    }
    let kept = &group.tracks[keep];
    group.keep_track_id = kept.track_id;
    group.title = kept.title.clone();
    group.artist_line = kept.artist_line.clone();
    group.album_title = kept.album_title.clone();
    group.album_id = kept.album_id;
    group.mbid_recording = kept.mbid_recording.clone();
}

fn map_health_entry(kind: HealthIssueKind, r: &Row<'_>) -> rusqlite::Result<LibraryHealthEntry> {
    let audio_json: Option<String> = r.get(7)?;
    let audio = audio_json
        .as_deref()
        .and_then(|s| serde_json::from_str::<AudioProps>(s).ok());
    let AudioDisplay {
        format,
        codec,
        bitrate_kbps,
        bit_depth,
        sample_rate,
    } = audio_fields(audio.as_ref());
    Ok(LibraryHealthEntry {
        kind,
        track_id: TrackId(r.get(0)?),
        title: r.get(1)?,
        artist_line: r.get(2)?,
        album_title: r.get(3)?,
        album_id: r.get::<_, Option<i64>>(4)?.map(AlbumId),
        source_id: r.get::<_, Option<i64>>(10)?.map(SourceId),
        path: r.get::<_, Option<String>>(5)?.unwrap_or_default(),
        format,
        codec,
        bitrate_kbps,
        bit_depth,
        sample_rate,
        size_bytes: r.get::<_, i64>(6)?.max(0) as u64,
        duration_ms: r.get::<_, i64>(8)?.max(0) as u64,
        detail: r.get(9)?,
    })
}

struct AudioDisplay {
    format: Option<String>,
    codec: Option<String>,
    bitrate_kbps: Option<u32>,
    bit_depth: Option<u8>,
    sample_rate: Option<u32>,
}

fn audio_fields(audio: Option<&AudioProps>) -> AudioDisplay {
    match audio {
        Some(a) => AudioDisplay {
            format: Some(a.quality_badge()),
            codec: Some(codec_name(&a.codec).to_string()),
            bitrate_kbps: a.bitrate_kbps,
            bit_depth: a.bit_depth,
            sample_rate: Some(a.sample_rate),
        },
        None => AudioDisplay {
            format: None,
            codec: None,
            bitrate_kbps: None,
            bit_depth: None,
            sample_rate: None,
        },
    }
}

fn codec_name(codec: &Codec) -> &'static str {
    match codec {
        Codec::Mp3 => "mp3",
        Codec::Aac => "aac",
        Codec::Alac => "alac",
        Codec::Flac => "flac",
        Codec::Wav => "wav",
        Codec::Aiff => "aiff",
        Codec::Vorbis => "vorbis",
        Codec::Opus => "opus",
        Codec::Ape => "ape",
        Codec::WavPack => "wavpack",
        Codec::Tta => "tta",
        Codec::Dsd => "dsd",
        Codec::Other(_) => "other",
    }
}

fn health_condition(kind: HealthIssueKind) -> &'static str {
    match kind {
        HealthIssueKind::MissingCover => MISSING_COVER_SQL,
        HealthIssueKind::MissingLyrics => {
            "NOT EXISTS (SELECT 1 FROM lyrics l WHERE l.track_id = b.track_id AND l.is_active = 1)"
        }
        HealthIssueKind::MissingTags => "TRIM(b.title) = '' OR TRIM(b.artist_line) = ''",
        HealthIssueKind::FakeLossless => FAKE_LOSSLESS_SQL,
        HealthIssueKind::Unreadable => "1 = 0",
    }
}

fn health_count_sql(kind: HealthIssueKind) -> String {
    match kind {
        HealthIssueKind::Unreadable => {
            "SELECT COUNT(*) FROM file WHERE scan_state = 'error'".to_string()
        }
        _ => format!(
            "{BEST_FILE_CTE} SELECT COUNT(*) FROM best b WHERE {}",
            health_condition(kind)
        ),
    }
}

fn health_page_sql(kind: HealthIssueKind) -> String {
    if kind == HealthIssueKind::Unreadable {
        return "SELECT t.id, t.title, t.artist_line, a.title, t.album_id,
                       COALESCE(f.path, tf.external_id, ''), COALESCE(f.size, 0),
                       f.audio_json, t.duration_ms, f.scan_error,
                       f.source_id
                FROM file f
                JOIN track_file tf ON tf.file_id = f.id
                JOIN track t ON t.id = tf.track_id
                LEFT JOIN album a ON a.id = t.album_id
                WHERE f.scan_state = 'error'
                GROUP BY f.id, t.id
                ORDER BY f.path, t.id
                LIMIT ?1 OFFSET ?2"
            .to_string();
    }
    format!(
        "{BEST_FILE_CTE}
         SELECT b.track_id, b.title, b.artist_line, b.album_title, b.album_id,
                b.path, b.size, b.audio_json, b.duration_ms, NULL,
                b.source_id
         FROM best b
         WHERE {}
         ORDER BY b.title_sort_key, b.track_id
         LIMIT ?1 OFFSET ?2",
        health_condition(kind)
    )
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::db::test_util::temp_library;
    use crate::{ScannedFile, ScannedTags};
    use lekis_types::{
        Codec, Lyrics, LyricsFormat, SourceConfig, SourceKind, TrackQuery, TrackSort,
    };
    use std::collections::BTreeMap;

    async fn source(lib: &Library) -> Result<SourceId> {
        lib.add_source(SourceConfig {
            id: None,
            kind: SourceKind::Local,
            name: "local".into(),
            addresses: vec![],
            root_path: "/music".into(),
            credential_ref: None,
            options: BTreeMap::new(),
            enabled: true,
        })
        .await
    }

    struct Seed<'a> {
        path: &'a str,
        title: &'a str,
        artist: &'a str,
        album: Option<&'a str>,
        duration_ms: u64,
        size: u64,
        mbid: Option<&'a str>,
        audio: Option<AudioProps>,
    }

    #[allow(clippy::too_many_arguments)]
    fn track<'a>(
        path: &'a str,
        title: &'a str,
        artist: &'a str,
        duration_ms: u64,
        codec: Codec,
        sample_rate: u32,
        bit_depth: Option<u8>,
        bitrate: Option<u32>,
        size: u64,
    ) -> Seed<'a> {
        let audio = AudioProps {
            codec,
            sample_rate,
            bit_depth,
            channels: 2,
            bitrate_kbps: bitrate,
        };
        Seed {
            path,
            title,
            artist,
            album: Some("叶惠美"),
            duration_ms,
            size,
            mbid: None,
            audio: Some(audio),
        }
    }

    async fn seed(lib: &Library, source: SourceId, files: Vec<Seed<'_>>) -> Result<()> {
        lib.upsert_scanned(
            files
                .into_iter()
                .map(|f| ScannedFile {
                    source_id: source,
                    path: f.path.into(),
                    size: f.size,
                    mtime_ms: 1,
                    tags: ScannedTags {
                        title: f.title.into(),
                        artists: if f.artist.is_empty() {
                            Vec::new()
                        } else {
                            vec![f.artist.into()]
                        },
                        album: f.album.map(str::to_string),
                        duration_ms: f.duration_ms,
                        mbid_recording: f.mbid.map(str::to_string),
                        audio: f.audio,
                        ..Default::default()
                    },
                })
                .collect(),
        )
        .await?;
        Ok(())
    }

    async fn row_id(lib: &Library, title: &str) -> Result<TrackId> {
        lib.list_track_rows(TrackQuery {
            sort: TrackSort::Title,
            offset: 0,
            limit: 100,
        })
        .await?
        .into_iter()
        .find(|r| r.title == title)
        .map(|r| r.id)
        .ok_or_else(|| lekis_types::LekisError::not_found(format!("track {title}")))
    }

    #[tokio::test]
    async fn empty_library_has_no_duplicates_or_problems() -> Result<()> {
        let lib = temp_library("health-empty")?;
        assert!(lib.duplicate_groups(0, 10).await?.is_empty());
        assert_eq!(lib.duplicate_group_count().await?, 0);
        let summary = lib.library_health_summary().await?;
        assert_eq!(summary, LibraryHealthSummary::default());
        assert!(lib
            .library_health_page(HealthIssueKind::MissingCover, 0, 10)
            .await?
            .is_empty());
        Ok(())
    }

    #[tokio::test]
    async fn duplicates_respect_metadata_duration_and_normalization() -> Result<()> {
        let lib = temp_library("health-duplicates")?;
        let src = source(&lib).await?;
        seed(
            &lib,
            src,
            vec![
                // 无损 + 24/96，应该保留。
                track(
                    "a/qingtian.flac",
                    "晴天",
                    "周杰伦",
                    200_000,
                    Codec::Flac,
                    96_000,
                    Some(24),
                    Some(2000),
                    30_000_000,
                ),
                // 有损，应该建议删除。
                track(
                    "b/qingtian.mp3",
                    "晴天",
                    "周杰伦",
                    201_500,
                    Codec::Mp3,
                    44_100,
                    None,
                    Some(320),
                    8_000_000,
                ),
                // 繁体 + 多余空白，规范化后仍是同一首。
                track(
                    "c/qingtian.flac",
                    "晴天 ",
                    "周杰倫",
                    200_500,
                    Codec::Flac,
                    44_100,
                    Some(16),
                    Some(900),
                    25_000_000,
                ),
                // 时长差 5 秒，不并进上面那组。
                track(
                    "d/qingtian-live.flac",
                    "晴天",
                    "周杰伦",
                    205_500,
                    Codec::Flac,
                    44_100,
                    Some(16),
                    Some(900),
                    25_000_000,
                ),
            ],
        )
        .await?;

        let groups = lib.duplicate_groups(0, 10).await?;
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].tracks.len(), 3);
        assert_eq!(groups[0].title, "晴天");
        let keep = groups[0]
            .tracks
            .iter()
            .find(|t| t.suggested_keep)
            .expect("must keep one");
        assert_eq!(keep.path, "a/qingtian.flac");
        assert_eq!(keep.format.as_deref(), Some("FLAC 24/96"));
        assert_eq!(groups[0].keep_track_id, keep.track_id);
        Ok(())
    }

    #[tokio::test]
    async fn duplicate_group_picks_bigger_file_between_equal_lossy_versions() -> Result<()> {
        let lib = temp_library("health-duplicates-size")?;
        let src = source(&lib).await?;
        seed(
            &lib,
            src,
            vec![
                track(
                    "a/song.mp3",
                    "Song",
                    "Artist",
                    180_000,
                    Codec::Mp3,
                    44_100,
                    None,
                    Some(320),
                    6_000_000,
                ),
                track(
                    "b/song.mp3",
                    "Song",
                    "Artist",
                    180_000,
                    Codec::Mp3,
                    44_100,
                    None,
                    Some(320),
                    9_000_000,
                ),
            ],
        )
        .await?;
        let groups = lib.duplicate_groups(0, 10).await?;
        assert_eq!(groups.len(), 1);
        let keep = groups[0]
            .tracks
            .iter()
            .find(|t| t.suggested_keep)
            .expect("must keep one");
        assert_eq!(keep.path, "b/song.mp3");
        Ok(())
    }

    #[tokio::test]
    async fn duplicate_groups_are_paged_and_mbid_conflicts_are_skipped() -> Result<()> {
        let lib = temp_library("health-duplicates-pages")?;
        let src = source(&lib).await?;
        seed(
            &lib,
            src,
            vec![
                track(
                    "a/one.flac",
                    "One",
                    "A",
                    100_000,
                    Codec::Flac,
                    44_100,
                    Some(16),
                    Some(900),
                    10,
                ),
                track(
                    "a/one.mp3",
                    "One",
                    "A",
                    100_000,
                    Codec::Mp3,
                    44_100,
                    None,
                    Some(320),
                    5,
                ),
                track(
                    "a/two.flac",
                    "Two",
                    "B",
                    110_000,
                    Codec::Flac,
                    44_100,
                    Some(16),
                    Some(900),
                    10,
                ),
                track(
                    "a/two.mp3",
                    "Two",
                    "B",
                    110_000,
                    Codec::Mp3,
                    44_100,
                    None,
                    Some(320),
                    5,
                ),
                track(
                    "a/three.flac",
                    "Three",
                    "C",
                    120_000,
                    Codec::Flac,
                    44_100,
                    Some(16),
                    Some(900),
                    10,
                ),
                track(
                    "a/three.mp3",
                    "Three",
                    "C",
                    120_000,
                    Codec::Mp3,
                    44_100,
                    None,
                    Some(320),
                    5,
                ),
                // 同一元数据、不同 MBID：MBID 优先，两组都只有一个成员，不报告。
                Seed {
                    mbid: Some("mbid-a"),
                    ..track(
                        "a/conflict.flac",
                        "Conflict",
                        "D",
                        130_000,
                        Codec::Flac,
                        44_100,
                        Some(16),
                        Some(900),
                        10,
                    )
                },
                Seed {
                    mbid: Some("mbid-b"),
                    ..track(
                        "b/conflict.mp3",
                        "Conflict",
                        "D",
                        130_000,
                        Codec::Mp3,
                        44_100,
                        None,
                        Some(320),
                        5,
                    )
                },
            ],
        )
        .await?;

        assert_eq!(lib.duplicate_group_count().await?, 3);
        let first = lib.duplicate_groups(0, 2).await?;
        assert_eq!(first.len(), 2);
        let second = lib.duplicate_groups(2, 2).await?;
        assert_eq!(second.len(), 1);
        assert!(lib.duplicate_groups(99, 2).await?.is_empty());
        assert_eq!(
            lib.duplicate_groups(0, 0).await.unwrap_err().code,
            lekis_types::ErrorCode::InvalidArgument
        );
        Ok(())
    }

    #[tokio::test]
    async fn health_summary_and_pages_classify_issues() -> Result<()> {
        let lib = temp_library("health-report")?;
        let src = source(&lib).await?;
        seed(
            &lib,
            src,
            vec![
                // 正常曲目：稍后补封面和歌词。
                track(
                    "a/normal.flac",
                    "Normal",
                    "Artist",
                    200_000,
                    Codec::Flac,
                    96_000,
                    Some(24),
                    Some(2200),
                    60_000_000,
                ),
                // 疑似假无损：FLAC 44.1k、320 kbps。
                track(
                    "b/fake.flac",
                    "Fake",
                    "Artist",
                    200_000,
                    Codec::Flac,
                    44_100,
                    Some(16),
                    Some(320),
                    1_000_000,
                ),
                // 标签缺失。
                Seed {
                    artist: "",
                    ..track(
                        "c/untagged.mp3",
                        "",
                        "",
                        100_000,
                        Codec::Mp3,
                        44_100,
                        None,
                        Some(192),
                        2_000_000,
                    )
                },
            ],
        )
        .await?;

        let normal = row_id(&lib, "Normal").await?;
        let fake = row_id(&lib, "Fake").await?;
        let untagged = row_id(&lib, "").await?;

        let artwork = lib
            .upsert_artwork("hash-normal".into(), "test".into(), None, None, None)
            .await?;
        lib.set_track_artwork(normal, Some(artwork)).await?;
        lib.save_lyrics(
            normal,
            Lyrics {
                format: LyricsFormat::Plain,
                content: "hello".into(),
                source: "test".into(),
                offset_ms: 0,
                confidence: 1.0,
            },
        )
        .await?;

        let summary = lib.library_health_summary().await?;
        assert_eq!(summary.total_tracks, 3);
        assert_eq!(summary.missing_cover, 2);
        assert_eq!(summary.missing_lyrics, 2);
        assert_eq!(summary.missing_tags, 1);
        assert_eq!(summary.fake_lossless, 1);

        let covers = lib
            .library_health_page(HealthIssueKind::MissingCover, 0, 10)
            .await?;
        assert_eq!(covers.len(), 2);
        assert!(covers.iter().all(|e| e.track_id != normal));

        let fake_page = lib
            .library_health_page(HealthIssueKind::FakeLossless, 0, 10)
            .await?;
        assert_eq!(fake_page.len(), 1);
        assert_eq!(fake_page[0].track_id, fake);
        assert_eq!(fake_page[0].codec.as_deref(), Some("flac"));

        let tag_page = lib
            .library_health_page(HealthIssueKind::MissingTags, 0, 10)
            .await?;
        assert_eq!(tag_page.len(), 1);
        assert_eq!(tag_page[0].track_id, untagged);

        assert_eq!(
            lib.library_health_count(HealthIssueKind::MissingCover)
                .await?,
            2
        );
        Ok(())
    }

    #[tokio::test]
    async fn unreadable_files_are_paged_and_can_recover() -> Result<()> {
        let lib = temp_library("health-unreadable")?;
        let src = source(&lib).await?;
        seed(
            &lib,
            src,
            vec![
                track(
                    "a/one.flac",
                    "One",
                    "A",
                    100_000,
                    Codec::Flac,
                    44_100,
                    Some(16),
                    Some(900),
                    10,
                ),
                track(
                    "b/two.flac",
                    "Two",
                    "B",
                    100_000,
                    Codec::Flac,
                    44_100,
                    Some(16),
                    Some(900),
                    10,
                ),
            ],
        )
        .await?;

        let files = lib.files_for_health_scan(src, 0, 10).await?;
        assert_eq!(files.len(), 2);
        let bad_id = files[0].file_id;
        let good_id = files[1].file_id;

        let update = lib
            .record_file_health(vec![(bad_id, Some("cannot read".into()))])
            .await?;
        assert_eq!(update.marked, 1);
        assert_eq!(lib.library_health_summary().await?.unreadable_files, 1);
        let page = lib
            .library_health_page(HealthIssueKind::Unreadable, 0, 10)
            .await?;
        assert_eq!(page.len(), 1);
        assert_eq!(page[0].detail.as_deref(), Some("cannot read"));

        let update = lib
            .record_file_health(vec![(bad_id, None), (good_id, None)])
            .await?;
        assert_eq!(update.cleared, 1);
        assert_eq!(lib.library_health_summary().await?.unreadable_files, 0);
        Ok(())
    }

    #[tokio::test]
    async fn missing_cover_only_includes_local_and_nas_sources() -> Result<()> {
        let lib = temp_library("health-missing-cover-scope")?;
        let local_src = source(&lib).await?;
        let plugin_src = lib
            .add_source(SourceConfig {
                id: None,
                kind: SourceKind::Plugin,
                name: "online-plugin".into(),
                addresses: vec![],
                root_path: "example.plugin".into(),
                credential_ref: None,
                options: BTreeMap::new(),
                enabled: true,
            })
            .await?;
        let nas_src = lib
            .add_source(SourceConfig {
                id: None,
                kind: SourceKind::Smb,
                name: "nas".into(),
                addresses: vec!["smb://nas/music".into()],
                root_path: "/".into(),
                credential_ref: None,
                options: BTreeMap::new(),
                enabled: true,
            })
            .await?;

        seed(
            &lib,
            local_src,
            vec![track(
                "local.flac",
                "Local Song",
                "Artist",
                100_000,
                Codec::Flac,
                44_100,
                Some(16),
                Some(900),
                10,
            )],
        )
        .await?;
        seed(
            &lib,
            nas_src,
            vec![track(
                "nas.flac",
                "NAS Song",
                "Artist",
                100_000,
                Codec::Flac,
                44_100,
                Some(16),
                Some(900),
                10,
            )],
        )
        .await?;
        lib.append_plugin_tracks(
            plugin_src,
            vec![crate::RemoteTrackRow {
                external_album_id: None,
                album_artists: vec![],
                disc_no: None,
                track_no: None,
                external_id: "pl-1".into(),
                title: "Plugin Song".into(),
                artists: vec!["Artist".into()],
                album: None,
                duration_ms: 100_000,
                mbid_recording: None,
                quality_score: 50,
            }],
        )
        .await?;

        let summary = lib.library_health_summary().await?;
        assert_eq!(summary.total_tracks, 3);
        assert_eq!(
            summary.missing_cover, 2,
            "plugin track must not be counted in missing_cover"
        );
        let missing = lib
            .library_health_page(HealthIssueKind::MissingCover, 0, 10)
            .await?;
        assert_eq!(missing.len(), 2);
        assert!(missing.iter().all(|e| e.title != "Plugin Song"));
        Ok(())
    }
}
