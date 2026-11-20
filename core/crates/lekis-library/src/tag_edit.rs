//! 本地音频标签编辑与写回（LIB-13 / ENR-08）。
//!
//! 两条路径严格分开：
//!
//! 1. **资料库覆盖层**：`set_track_tag_overrides` 只写数据库，扫描和展示时优先使用，
//!    不碰原文件；
//! 2. **写回文件**：用户二次确认后 `write_track_tags` 才修改音频。写之前在同目录生成
//!    `<文件名>.lekis-tags-backup.json`，写入用临时文件 + 原子替换，失败时尝试用备份恢复。
//!
//! 只支持本地文件源（[`SourceKind::Local`]）里的 MP3 / FLAC / M4A / AAC / OGG / Opus；
//! 远程源、WAV / APE 等格式返回 [`ErrorCode::Unsupported`]。

use crate::db::DbResultExt;
use crate::Library;
use lekis_types::{now_ms, ErrorCode, LekisError, Result, TrackId, TrackTagOverrides};
use lofty::config::WriteOptions;
use lofty::file::{FileType, TaggedFile, TaggedFileExt};
use lofty::probe::Probe;
use lofty::tag::{ItemKey, ItemValue, Tag, TagExt, TagItem, TagType};
use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::io::ErrorKind;
use std::path::{Component, Path, PathBuf};
use std::time::UNIX_EPOCH;

/// 备份 JSON 的格式版本。以后字段有变化时递增，旧版本仍然能读。
pub const TAG_BACKUP_VERSION: u32 = 1;

/// 备份文件的后缀（和音频同目录）。
pub const TAG_BACKUP_SUFFIX: &str = ".lekis-tags-backup.json";

/// 单个标签文本字段的最大长度。防手滑把整个文件贴进标签。
const MAX_FIELD_CHARS: usize = 4096;

/// 一次成功写回的结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TagWriteResult {
    /// 曲目 ID。
    pub track_id: TrackId,
    /// 被修改的音频文件绝对路径。
    pub file_path: String,
    /// 备份文件路径。
    pub backup_path: String,
    /// 实际写入的字段（`title`、`artist`……）。
    pub fields: Vec<String>,
}

/// 批量写回时的一项结果。失败不会中断其余曲目。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BatchTagWriteItem {
    /// 曲目 ID。
    pub track_id: TrackId,
    /// 成功时的结果。
    pub result: Option<TagWriteResult>,
    /// 失败时的错误码。
    pub error_code: Option<ErrorCode>,
    /// 失败时的详情（给开发者看）。
    pub error: Option<String>,
}

/// 备份文件里保存的原标签快照。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TagBackup {
    /// 格式版本。
    pub version: u32,
    /// 备份时间（Unix 毫秒）。
    pub created_at_ms: i64,
    /// 音频文件路径（写备份时的绝对路径）。
    pub file_path: String,
    /// 写备份时的文件大小。
    pub file_size: u64,
    /// 写备份时的 mtime（Unix 毫秒；平台拿不到时为 0）。
    pub file_mtime_ms: i64,
    /// 原标签快照。
    pub tags: TrackTagOverrides,
}

/// 本地文件源里的一个可写目标。
#[derive(Debug, Clone)]
struct LocalTagTarget {
    file_id: i64,
    path: PathBuf,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TagField {
    Title,
    Artist,
    Album,
    AlbumArtist,
    TrackNo,
    DiscNo,
    Year,
    Genre,
    Comment,
    Composer,
    Lyricist,
    MusicBrainzTrackId,
    MusicBrainzAlbumId,
}

const FIELDS: [TagField; 13] = [
    TagField::Title,
    TagField::Artist,
    TagField::Album,
    TagField::AlbumArtist,
    TagField::TrackNo,
    TagField::DiscNo,
    TagField::Year,
    TagField::Genre,
    TagField::Comment,
    TagField::Composer,
    TagField::Lyricist,
    TagField::MusicBrainzTrackId,
    TagField::MusicBrainzAlbumId,
];

impl TagField {
    fn key(self) -> &'static str {
        match self {
            Self::Title => "title",
            Self::Artist => "artist",
            Self::Album => "album",
            Self::AlbumArtist => "album_artist",
            Self::TrackNo => "track_no",
            Self::DiscNo => "disc_no",
            Self::Year => "year",
            Self::Genre => "genre",
            Self::Comment => "comment",
            Self::Composer => "composer",
            Self::Lyricist => "lyricist",
            Self::MusicBrainzTrackId => "musicbrainz_track_id",
            Self::MusicBrainzAlbumId => "musicbrainz_album_id",
        }
    }

    fn value(self, values: &TrackTagOverrides) -> Option<&str> {
        match self {
            Self::Title => values.title.as_deref(),
            Self::Artist => values.artist.as_deref(),
            Self::Album => values.album.as_deref(),
            Self::AlbumArtist => values.album_artist.as_deref(),
            Self::TrackNo => values.track_no.map(|_| ""), // 数字字段单独处理
            Self::DiscNo => values.disc_no.map(|_| ""),
            Self::Year => values.year.map(|_| ""),
            Self::Genre => values.genre.as_deref(),
            Self::Comment => values.comment.as_deref(),
            Self::Composer => values.composer.as_deref(),
            Self::Lyricist => values.lyricist.as_deref(),
            Self::MusicBrainzTrackId => values.musicbrainz_track_id.as_deref(),
            Self::MusicBrainzAlbumId => values.musicbrainz_album_id.as_deref(),
        }
    }

    fn is_set(self, values: &TrackTagOverrides) -> bool {
        match self {
            Self::TrackNo => values.track_no.is_some(),
            Self::DiscNo => values.disc_no.is_some(),
            Self::Year => values.year.is_some(),
            _ => self.value(values).is_some(),
        }
    }

    fn read_keys(self) -> &'static [ItemKey] {
        match self {
            Self::Title => &[ItemKey::TrackTitle],
            Self::Artist => &[ItemKey::TrackArtist, ItemKey::TrackArtists],
            Self::Album => &[ItemKey::AlbumTitle],
            Self::AlbumArtist => &[ItemKey::AlbumArtist, ItemKey::AlbumArtists],
            Self::TrackNo => &[ItemKey::TrackNumber],
            Self::DiscNo => &[ItemKey::DiscNumber],
            Self::Year => &[ItemKey::RecordingDate, ItemKey::Year],
            Self::Genre => &[ItemKey::Genre],
            Self::Comment => &[ItemKey::Comment],
            Self::Composer => &[ItemKey::Composer],
            Self::Lyricist => &[ItemKey::Lyricist],
            Self::MusicBrainzTrackId => &[ItemKey::MusicBrainzRecordingId],
            Self::MusicBrainzAlbumId => &[ItemKey::MusicBrainzReleaseId],
        }
    }

    fn write_key(self) -> ItemKey {
        match self {
            Self::Title => ItemKey::TrackTitle,
            Self::Artist => ItemKey::TrackArtist,
            Self::Album => ItemKey::AlbumTitle,
            Self::AlbumArtist => ItemKey::AlbumArtist,
            Self::TrackNo => ItemKey::TrackNumber,
            Self::DiscNo => ItemKey::DiscNumber,
            Self::Year => ItemKey::RecordingDate,
            Self::Genre => ItemKey::Genre,
            Self::Comment => ItemKey::Comment,
            Self::Composer => ItemKey::Composer,
            Self::Lyricist => ItemKey::Lyricist,
            Self::MusicBrainzTrackId => ItemKey::MusicBrainzRecordingId,
            Self::MusicBrainzAlbumId => ItemKey::MusicBrainzReleaseId,
        }
    }

    /// 艺人 / 流派是用户输入的一个字符串，写文件时按约定拆成多值标签。
    fn split_values(self, value: &str) -> Vec<&str> {
        let parts: Vec<&str> = match self {
            Self::Artist | Self::AlbumArtist => value.split(" / ").collect(),
            Self::Genre => value.split(';').collect(),
            _ => vec![value],
        };
        parts
            .into_iter()
            .map(str::trim)
            .filter(|part| !part.is_empty())
            .collect()
    }

    fn write(self, tag: &mut Tag, values: &TrackTagOverrides) -> bool {
        for key in self.read_keys() {
            tag.remove_key(*key);
        }
        match self {
            Self::TrackNo => match values.track_no {
                Some(value) => tag.insert_text(ItemKey::TrackNumber, value.to_string()),
                None => true,
            },
            Self::DiscNo => match values.disc_no {
                Some(value) => tag.insert_text(ItemKey::DiscNumber, value.to_string()),
                None => true,
            },
            Self::Year => match values.year {
                Some(value) => tag.insert_text(ItemKey::RecordingDate, value.to_string()),
                None => true,
            },
            _ => {
                let Some(value) = self.value(values) else {
                    return true;
                };
                let mut ok = true;
                for part in self.split_values(value) {
                    ok &= tag.push(TagItem::new(
                        self.write_key(),
                        ItemValue::Text(part.to_owned()),
                    ));
                }
                ok
            }
        }
    }
}

/// 一条曲目的本地文件源目标。远程曲目返回 `Unsupported`。
impl Library {
    /// 读取数据库里的手工标签覆盖层；没有覆盖层时返回 `None`。
    pub async fn track_tag_overrides(&self, id: TrackId) -> Result<Option<TrackTagOverrides>> {
        self.read(move |c| {
            let row: Option<Option<String>> = c
                .query_row(
                    "SELECT tag_overrides_json FROM track WHERE id = ?1",
                    params![id.0],
                    |r| r.get(0),
                )
                .optional()
                .db()?;
            let Some(json) = row else {
                return Err(LekisError::not_found(format!("track {id}")));
            };
            match json {
                Some(json) => serde_json::from_str(&json)
                    .map(Some)
                    .map_err(|e| LekisError::internal(format!("parse tag overrides: {e}"))),
                None => Ok(None),
            }
        })
        .await
    }

    /// 保存手工标签覆盖层（只改数据库，不碰文件）。
    ///
    /// 传空覆盖层等价于清除。远程曲目没有可写的本地文件，返回
    /// [`ErrorCode::Unsupported`]。
    pub async fn set_track_tag_overrides(
        &self,
        id: TrackId,
        fields: TrackTagOverrides,
    ) -> Result<()> {
        let fields = normalize_overrides(fields)?;
        // 远程曲目（或没有本地文件）不能编辑标签。
        self.local_tag_target(id).await?;
        let json = if fields.is_empty() {
            None
        } else {
            Some(
                serde_json::to_string(&fields)
                    .map_err(|e| LekisError::internal(format!("serialize tag overrides: {e}")))?,
            )
        };
        self.write(move |conn| {
            let tx = conn.transaction().db()?;
            let n = tx
                .execute(
                    "UPDATE track SET tag_overrides_json = ?2, updated_at = ?3 WHERE id = ?1",
                    params![id.0, json, now_ms()],
                )
                .db()?;
            if n == 0 {
                return Err(LekisError::not_found(format!("track {id}")));
            }
            crate::browse::refresh_track_index(&tx, id.0)?;
            tx.commit().db()?;
            Ok(())
        })
        .await
    }

    /// 清除手工标签覆盖层。文件本身不变。
    pub async fn clear_track_tag_overrides(&self, id: TrackId) -> Result<()> {
        self.write(move |conn| {
            let tx = conn.transaction().db()?;
            let n = tx
                .execute(
                    "UPDATE track SET tag_overrides_json = NULL, updated_at = ?2 WHERE id = ?1",
                    params![id.0, now_ms()],
                )
                .db()?;
            if n == 0 {
                return Err(LekisError::not_found(format!("track {id}")));
            }
            crate::browse::refresh_track_index(&tx, id.0)?;
            tx.commit().db()?;
            Ok(())
        })
        .await
    }

    /// 读取本地音频文件里现有的标签（不读覆盖层）。
    ///
    /// 用于编辑对话框预填字段。远程曲目 / 不支持的格式返回相应错误。
    pub async fn read_track_file_tags(&self, id: TrackId) -> Result<TrackTagOverrides> {
        let target = self.local_tag_target(id).await?;
        tokio::task::spawn_blocking(move || read_file_tags(&target.path))
            .await
            .map_err(|e| LekisError::internal(format!("tag read task failed: {e}")))?
    }

    /// 把当前覆盖层写回本地音频文件。
    ///
    /// 写之前生成 `<文件名>.lekis-tags-backup.json`；临时文件 + 原子替换，保留权限。
    /// 失败时会尝试恢复原标签，返回的错误里会说明恢复是否失败。
    pub async fn write_track_tags(&self, id: TrackId) -> Result<TagWriteResult> {
        let target = self.local_tag_target(id).await?;
        let overrides = self
            .track_tag_overrides(id)
            .await?
            .ok_or_else(|| LekisError::invalid("这首歌还没有标签覆盖，请先保存到资料库"))?;
        if overrides.is_empty() {
            return Err(LekisError::invalid(
                "这首歌还没有标签覆盖，请先保存到资料库",
            ));
        }
        let path = target.path.clone();
        let file_path = path.to_string_lossy().into_owned();
        let fields: Vec<String> = FIELDS
            .iter()
            .filter(|field| field.is_set(&overrides))
            .map(|field| field.key().to_owned())
            .collect();
        let written =
            tokio::task::spawn_blocking(move || write_tags_with_backup(&path, &overrides))
                .await
                .map_err(|e| LekisError::internal(format!("tag write task failed: {e}")))??;
        self.refresh_file_metadata(target.file_id, written.file_size, written.file_mtime_ms)
            .await;
        Ok(TagWriteResult {
            track_id: id,
            file_path,
            backup_path: written.backup_path,
            fields,
        })
    }

    /// 从 `<文件名>.lekis-tags-backup.json` 恢复上一份原标签。
    ///
    /// 成功后清除数据库覆盖层，让界面回到文件里的真实标签。
    pub async fn restore_track_tags(&self, id: TrackId) -> Result<TagWriteResult> {
        let target = self.local_tag_target(id).await?;
        let path = target.path.clone();
        let file_path = path.to_string_lossy().into_owned();
        let fields: Vec<String> = FIELDS.iter().map(|field| field.key().to_owned()).collect();
        let restored = tokio::task::spawn_blocking(move || restore_tags_with_backup(&path))
            .await
            .map_err(|e| LekisError::internal(format!("tag restore task failed: {e}")))??;
        self.refresh_file_metadata(target.file_id, restored.file_size, restored.file_mtime_ms)
            .await;
        self.clear_track_tag_overrides(id).await?;
        Ok(TagWriteResult {
            track_id: id,
            file_path,
            backup_path: restored.backup_path,
            fields,
        })
    }

    /// 批量写回。逐项返回结果，一首失败不会中断后面的曲目。
    pub async fn batch_write_track_tags(
        &self,
        ids: Vec<TrackId>,
    ) -> Result<Vec<BatchTagWriteItem>> {
        let mut out = Vec::with_capacity(ids.len());
        for id in ids {
            match self.write_track_tags(id).await {
                Ok(result) => out.push(BatchTagWriteItem {
                    track_id: id,
                    result: Some(result),
                    error_code: None,
                    error: None,
                }),
                Err(error) => out.push(BatchTagWriteItem {
                    track_id: id,
                    result: None,
                    error_code: Some(error.code),
                    error: Some(error.message),
                }),
            }
        }
        Ok(out)
    }

    /// 找这首歌优先级最高的本地文件。
    async fn local_tag_target(&self, id: TrackId) -> Result<LocalTagTarget> {
        self.read(move |c| {
            let exists: Option<i64> = c
                .query_row("SELECT id FROM track WHERE id = ?1", params![id.0], |r| {
                    r.get(0)
                })
                .optional()
                .db()?;
            if exists.is_none() {
                return Err(LekisError::not_found(format!("track {id}")));
            }

            let row: Option<(String, String, i64, String)> = c
                .query_row(
                    "SELECT s.kind, s.root_path, f.id, f.path
                     FROM track_file tf
                     JOIN source s ON s.id = tf.source_id
                     JOIN file f ON f.id = tf.file_id
                     WHERE tf.track_id = ?1 AND f.id IS NOT NULL AND s.kind = 'local'
                     ORDER BY tf.quality_score DESC, f.id
                     LIMIT 1",
                    params![id.0],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
                )
                .optional()
                .db()?;

            let Some((_kind, root, file_id, relative)) = row else {
                return Err(LekisError::unsupported(
                    "只有本地文件源里的曲目才能编辑标签",
                ));
            };
            let joined = join_source_path(&root, &relative)?;
            if !joined.exists() {
                return Err(LekisError::not_found(format!(
                    "音频文件不存在：{}",
                    joined.to_string_lossy()
                )));
            }
            Ok(LocalTagTarget {
                file_id,
                path: joined,
            })
        })
        .await
    }

    async fn refresh_file_metadata(&self, file_id: i64, size: u64, mtime_ms: i64) {
        let result = self
            .write(move |c| {
                c.execute(
                    "UPDATE file SET size = ?2, mtime_ms = ?3, last_seen_at = ?4 WHERE id = ?1",
                    params![file_id, size as i64, mtime_ms, now_ms()],
                )
                .db()?;
                Ok(())
            })
            .await;
        if let Err(error) = result {
            tracing::warn!(
                target: "library",
                file_id,
                error = %error,
                "tag write succeeded but file metadata refresh failed"
            );
        }
    }
}

/// 规范化用户输入：去空白、空串当 `None`、校验长度 / 数字范围 / NUL。
fn normalize_overrides(mut fields: TrackTagOverrides) -> Result<TrackTagOverrides> {
    fn clean(value: Option<String>) -> Result<Option<String>> {
        let Some(value) = value else { return Ok(None) };
        if value.contains('\0') {
            return Err(LekisError::invalid("标签不能包含 NUL 字符"));
        }
        let value = value.trim().to_owned();
        if value.is_empty() {
            return Ok(None);
        }
        if value.chars().count() > MAX_FIELD_CHARS {
            return Err(LekisError::invalid(format!(
                "标签字段过长（最多 {MAX_FIELD_CHARS} 个字符）"
            )));
        }
        Ok(Some(value))
    }

    fields.title = clean(fields.title)?;
    fields.artist = clean(fields.artist)?;
    fields.album = clean(fields.album)?;
    fields.album_artist = clean(fields.album_artist)?;
    fields.genre = clean(fields.genre)?;
    fields.comment = clean(fields.comment)?;
    fields.composer = clean(fields.composer)?;
    fields.lyricist = clean(fields.lyricist)?;
    fields.musicbrainz_track_id = clean(fields.musicbrainz_track_id)?;
    fields.musicbrainz_album_id = clean(fields.musicbrainz_album_id)?;

    fields.track_no = fields.track_no.filter(|value| *value > 0);
    fields.disc_no = fields.disc_no.filter(|value| *value > 0);
    if let Some(value) = fields.track_no {
        if value > 9999 {
            return Err(LekisError::invalid("曲目号超出范围（1~9999）"));
        }
    }
    if let Some(value) = fields.disc_no {
        if value > 9999 {
            return Err(LekisError::invalid("碟片号超出范围（1~9999）"));
        }
    }
    if let Some(year) = fields.year {
        if !(1000..=9999).contains(&year) {
            return Err(LekisError::invalid("年份必须是 1000~9999"));
        }
    }
    Ok(fields)
}

/// 把源根目录和 VfsPath 拼成真实路径，并拒绝 `..` / 绝对路径。
fn join_source_path(root: &str, relative: &str) -> Result<PathBuf> {
    if root.trim().is_empty() {
        return Err(LekisError::unsupported("本地音源根目录为空"));
    }
    let relative_path = Path::new(relative);
    if relative_path.is_absolute()
        || relative_path.components().any(|part| {
            matches!(
                part,
                Component::ParentDir | Component::RootDir | Component::Prefix(_)
            )
        })
    {
        return Err(LekisError::invalid(format!("音频路径不合法：{relative}")));
    }
    Ok(Path::new(root).join(relative_path))
}

/// 备份文件路径：`<音频文件名>.lekis-tags-backup.json`，和音频同目录。
pub fn backup_path_for(file: &Path) -> PathBuf {
    let mut name = file
        .file_name()
        .map(|name| name.to_os_string())
        .unwrap_or_default();
    name.push(TAG_BACKUP_SUFFIX);
    file.with_file_name(name)
}

fn read_file_tags(path: &Path) -> Result<TrackTagOverrides> {
    let metadata = std::fs::metadata(path).map_err(|e| io_error("读取音频文件信息", path, e))?;
    if !metadata.is_file() {
        return Err(LekisError::invalid(format!(
            "不是普通文件：{}",
            path.to_string_lossy()
        )));
    }
    let tagged = probe_file(path)?;
    ensure_supported(tagged.file_type(), path)?;
    let Some(tag) = tagged.primary_tag() else {
        return Ok(TrackTagOverrides::default());
    };
    Ok(snapshot_from_tag(tag))
}

fn probe_file(path: &Path) -> Result<TaggedFile> {
    let probe = Probe::open(path).map_err(|e| parse_error(path, e))?;
    let probe = probe.guess_file_type().map_err(|e| {
        if e.kind() == ErrorKind::NotFound || e.kind() == ErrorKind::PermissionDenied {
            io_error("读取音频文件", path, e)
        } else {
            LekisError::new(
                ErrorCode::Decode,
                format!("无法识别音频格式（{}）：{e}", path.to_string_lossy()),
            )
        }
    })?;
    probe.read().map_err(|e| parse_error(path, e))
}

fn parse_error(path: &Path, error: lofty::error::FileParseError) -> LekisError {
    let code = if error.is_unknown_format() {
        ErrorCode::Unsupported
    } else {
        ErrorCode::Decode
    };
    LekisError::new(
        code,
        format!("解析音频标签失败（{}）：{error}", path.to_string_lossy()),
    )
}

fn ensure_supported(file_type: FileType, path: &Path) -> Result<()> {
    match file_type {
        FileType::Mpeg
        | FileType::Flac
        | FileType::Mp4
        | FileType::Aac
        | FileType::Vorbis
        | FileType::Opus => Ok(()),
        _ => Err(LekisError::unsupported(format!(
            "不支持的音频格式（只支持 MP3 / FLAC / M4A / AAC / OGG / Opus）：{}",
            path.to_string_lossy()
        ))),
    }
}

fn snapshot_from_tag(tag: &Tag) -> TrackTagOverrides {
    TrackTagOverrides {
        title: text(tag, ItemKey::TrackTitle),
        artist: joined_text(tag, &[ItemKey::TrackArtist, ItemKey::TrackArtists], " / "),
        album: text(tag, ItemKey::AlbumTitle),
        album_artist: joined_text(tag, &[ItemKey::AlbumArtist, ItemKey::AlbumArtists], " / "),
        track_no: number(tag, ItemKey::TrackNumber),
        disc_no: number(tag, ItemKey::DiscNumber),
        year: year(tag),
        genre: joined_text(tag, &[ItemKey::Genre], "; "),
        comment: text(tag, ItemKey::Comment),
        composer: text(tag, ItemKey::Composer),
        lyricist: text(tag, ItemKey::Lyricist),
        musicbrainz_track_id: musicbrainz_id(tag, ItemKey::MusicBrainzRecordingId),
        musicbrainz_album_id: text(tag, ItemKey::MusicBrainzReleaseId),
    }
}

fn text(tag: &Tag, key: ItemKey) -> Option<String> {
    tag.get_string(key)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

fn joined_text(tag: &Tag, keys: &[ItemKey], separator: &str) -> Option<String> {
    let mut values = Vec::new();
    for key in keys {
        for value in tag.get_strings(*key) {
            let value = value.trim();
            if !value.is_empty() && !values.iter().any(|existing| existing == value) {
                values.push(value.to_owned());
            }
        }
    }
    if values.is_empty() {
        None
    } else {
        Some(values.join(separator))
    }
}

fn number(tag: &Tag, key: ItemKey) -> Option<u32> {
    let raw = tag.get_string(key)?;
    raw.split(['/', ';', ','])
        .map(str::trim)
        .find_map(|part| part.parse::<u32>().ok())
        .filter(|value| *value > 0)
}

fn year(tag: &Tag) -> Option<i32> {
    for key in [ItemKey::RecordingDate, ItemKey::Year] {
        if let Some(raw) = tag.get_string(key) {
            let digits: String = raw
                .trim()
                .chars()
                .take_while(char::is_ascii_digit)
                .collect();
            if digits.len() >= 4 {
                if let Ok(value) = digits[..4].parse::<i32>() {
                    if (1000..=9999).contains(&value) {
                        return Some(value);
                    }
                }
            }
        }
    }
    None
}

fn musicbrainz_id(tag: &Tag, key: ItemKey) -> Option<String> {
    if let Some(value) = text(tag, key) {
        return Some(value);
    }
    tag.get_binary(key, true)
        .and_then(|bytes| std::str::from_utf8(bytes).ok())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

struct TagWriteOutput {
    backup_path: String,
    file_size: u64,
    file_mtime_ms: i64,
}

fn write_tags_with_backup(file: &Path, overrides: &TrackTagOverrides) -> Result<TagWriteOutput> {
    let metadata = std::fs::metadata(file).map_err(|e| io_error("读取音频文件信息", file, e))?;
    if metadata.permissions().readonly() {
        return Err(LekisError::new(
            ErrorCode::PermissionDenied,
            format!("文件是只读的：{}", file.to_string_lossy()),
        ));
    }
    let original = read_file_tags(file)?;
    let backup = TagBackup {
        version: TAG_BACKUP_VERSION,
        created_at_ms: now_ms(),
        file_path: file.to_string_lossy().into_owned(),
        file_size: metadata.len(),
        file_mtime_ms: modified_ms(&metadata),
        tags: original.clone(),
    };
    let backup_path = backup_path_for(file);
    write_backup_json(&backup_path, &backup)?;

    let write_result = write_tags_atomic(file, overrides, false);
    if let Err(error) = write_result {
        let recovery = ensure_original(file, &original);
        return Err(match recovery {
            Ok(()) => LekisError::new(
                error.code,
                format!("{}；已尝试从备份恢复原标签", error.message),
            ),
            Err(recovery_error) => LekisError::new(
                error.code,
                format!(
                    "{}；自动恢复也失败：{}（备份：{}）",
                    error.message,
                    recovery_error.message,
                    backup_path.to_string_lossy()
                ),
            ),
        });
    }

    #[cfg(test)]
    if take_forced_failure(file) {
        let recovery = ensure_original(file, &original);
        return Err(match recovery {
            Ok(()) => LekisError::internal("forced post-write failure (test); original restored"),
            Err(error) => LekisError::internal(format!(
                "forced post-write failure (test); restore failed: {}",
                error.message
            )),
        });
    }

    let written = read_file_tags(file)?;
    let mismatched = mismatched_fields(overrides, &written, false);
    if !mismatched.is_empty() {
        let recovery = ensure_original(file, &original);
        return Err(match recovery {
            Ok(()) => LekisError::new(
                ErrorCode::Decode,
                format!(
                    "写入后重新读取的标签不一致（{}）；已从备份恢复",
                    mismatched.join(", ")
                ),
            ),
            Err(error) => LekisError::new(
                ErrorCode::Decode,
                format!(
                    "写入后重新读取的标签不一致（{}），自动恢复失败：{}（备份：{}）",
                    mismatched.join(", "),
                    error.message,
                    backup_path.to_string_lossy()
                ),
            ),
        });
    }

    let new_metadata =
        std::fs::metadata(file).map_err(|e| io_error("读取写入后的文件信息", file, e))?;
    Ok(TagWriteOutput {
        backup_path: backup_path.to_string_lossy().into_owned(),
        file_size: new_metadata.len(),
        file_mtime_ms: modified_ms(&new_metadata),
    })
}

fn mismatched_fields(
    expected: &TrackTagOverrides,
    actual: &TrackTagOverrides,
    all_fields: bool,
) -> Vec<String> {
    let mut out = Vec::new();
    for field in FIELDS {
        if !all_fields && !field.is_set(expected) {
            continue;
        }
        let matches = match field {
            TagField::TrackNo => expected.track_no == actual.track_no,
            TagField::DiscNo => expected.disc_no == actual.disc_no,
            TagField::Year => expected.year == actual.year,
            _ => {
                let expected = field.value(expected);
                let actual = field.value(actual);
                match (expected, actual) {
                    (Some(expected), Some(actual)) => values_equivalent(field, expected, actual),
                    (None, None) => true,
                    _ => false,
                }
            }
        };
        if !matches {
            out.push(field.key().to_owned());
        }
    }
    out
}

/// 多值字段写回后读出来会重新拼接；把预期值也按同样规则折叠后比较。
fn values_equivalent(field: TagField, expected: &str, actual: &str) -> bool {
    match field {
        TagField::Artist | TagField::AlbumArtist => {
            let expected: Vec<&str> = field.split_values(expected);
            let actual: Vec<&str> = actual.split(" / ").map(str::trim).collect();
            expected == actual
        }
        TagField::Genre => {
            let expected: Vec<&str> = field.split_values(expected);
            let actual: Vec<&str> = actual.split(';').map(str::trim).collect();
            expected == actual
        }
        _ => expected.trim() == actual.trim(),
    }
}

fn write_tags_atomic(file: &Path, values: &TrackTagOverrides, explicit_all: bool) -> Result<()> {
    let metadata = std::fs::metadata(file).map_err(|e| io_error("读取音频文件信息", file, e))?;
    if metadata.permissions().readonly() {
        return Err(LekisError::new(
            ErrorCode::PermissionDenied,
            format!("文件是只读的：{}", file.to_string_lossy()),
        ));
    }
    let parent = file.parent().ok_or_else(|| {
        LekisError::invalid(format!("文件没有父目录：{}", file.to_string_lossy()))
    })?;
    let temp = temp_path(parent, file)?;
    let cleanup = TempFileGuard(&temp);

    std::fs::copy(file, &temp).map_err(|e| io_error("复制到临时文件", &temp, e))?;
    apply_tags_to_path(&temp, values, explicit_all)?;
    std::fs::set_permissions(&temp, metadata.permissions())
        .map_err(|e| io_error("保留文件权限", &temp, e))?;
    // 尽量把数据刷到磁盘再替换，减少断电时留下半截文件的概率。
    if let Ok(handle) = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(&temp)
    {
        let _ = handle.sync_all();
    }
    std::fs::rename(&temp, file).map_err(|e| {
        if is_file_busy(&e) {
            LekisError::new(
                ErrorCode::PermissionDenied,
                format!(
                    "文件可能正在播放或被其它程序占用：{}（{e}）",
                    file.to_string_lossy()
                ),
            )
        } else {
            io_error("替换音频文件", file, e)
        }
    })?;
    cleanup.disarm();
    Ok(())
}

fn apply_tags_to_path(path: &Path, values: &TrackTagOverrides, explicit_all: bool) -> Result<()> {
    let mut tag = {
        let tagged = probe_file(path)?;
        let file_type = tagged.file_type();
        ensure_supported(file_type, path)?;
        let tag_type = primary_tag_type(file_type, path)?;
        tagged
            .primary_tag()
            .cloned()
            .unwrap_or_else(|| Tag::new(tag_type))
    };

    for field in FIELDS {
        if !explicit_all && !field.is_set(values) {
            continue;
        }
        if !field.write(&mut tag, values) {
            return Err(LekisError::unsupported(format!(
                "当前格式不支持写入字段 {}：{}",
                field.key(),
                path.to_string_lossy()
            )));
        }
    }

    tag.save_to_path(path, WriteOptions::default())
        .map_err(|e| {
            LekisError::new(
                ErrorCode::Decode,
                format!("写入标签失败（{}）：{e}", path.to_string_lossy()),
            )
        })
}

fn primary_tag_type(file_type: FileType, path: &Path) -> Result<TagType> {
    match file_type {
        FileType::Mpeg
        | FileType::Flac
        | FileType::Mp4
        | FileType::Aac
        | FileType::Vorbis
        | FileType::Opus => {
            let tag_type = file_type.primary_tag_type();
            if file_type.tag_support(tag_type).is_writable() {
                Ok(tag_type)
            } else {
                Err(LekisError::unsupported(format!(
                    "这种格式不支持写入标签：{}",
                    path.to_string_lossy()
                )))
            }
        }
        _ => Err(LekisError::unsupported(format!(
            "不支持的音频格式：{}",
            path.to_string_lossy()
        ))),
    }
}

fn write_backup_json(path: &Path, backup: &TagBackup) -> Result<()> {
    let json = serde_json::to_vec_pretty(backup)
        .map_err(|e| LekisError::internal(format!("serialize tag backup: {e}")))?;
    let parent = path.parent().ok_or_else(|| {
        LekisError::invalid(format!("备份文件没有父目录：{}", path.to_string_lossy()))
    })?;
    let temp = temp_path(parent, path)?;
    let cleanup = TempFileGuard(&temp);
    {
        use std::io::Write;
        let mut file =
            std::fs::File::create(&temp).map_err(|e| io_error("创建标签备份", &temp, e))?;
        file.write_all(&json)
            .map_err(|e| io_error("写入标签备份", &temp, e))?;
        file.sync_all()
            .map_err(|e| io_error("同步标签备份", &temp, e))?;
    }
    std::fs::rename(&temp, path).map_err(|e| io_error("替换标签备份", path, e))?;
    cleanup.disarm();
    Ok(())
}

fn read_backup(path: &Path) -> Result<TagBackup> {
    let bytes = std::fs::read(path).map_err(|e| io_error("读取标签备份", path, e))?;
    let backup: TagBackup = serde_json::from_slice(&bytes).map_err(|e| {
        LekisError::new(
            ErrorCode::InvalidArgument,
            format!("标签备份格式不对（{}）：{e}", path.to_string_lossy()),
        )
    })?;
    if backup.version != TAG_BACKUP_VERSION {
        return Err(LekisError::unsupported(format!(
            "不支持的标签备份版本：{}",
            backup.version
        )));
    }
    Ok(backup)
}

struct RestoreOutput {
    backup_path: String,
    file_size: u64,
    file_mtime_ms: i64,
}

fn restore_tags_with_backup(file: &Path) -> Result<RestoreOutput> {
    let backup_path = backup_path_for(file);
    let backup = read_backup(&backup_path)?;
    write_tags_atomic(file, &backup.tags, true)?;
    let restored = read_file_tags(file)?;
    if !all_fields_match(&backup.tags, &restored) {
        return Err(LekisError::new(
            ErrorCode::Decode,
            format!(
                "从备份恢复后重新读取的标签不一致（备份：{}）",
                backup_path.to_string_lossy()
            ),
        ));
    }
    let metadata =
        std::fs::metadata(file).map_err(|e| io_error("读取恢复后的文件信息", file, e))?;
    Ok(RestoreOutput {
        backup_path: backup_path.to_string_lossy().into_owned(),
        file_size: metadata.len(),
        file_mtime_ms: modified_ms(&metadata),
    })
}

fn all_fields_match(expected: &TrackTagOverrides, actual: &TrackTagOverrides) -> bool {
    mismatched_fields(expected, actual, true).is_empty()
}

fn ensure_original(file: &Path, original: &TrackTagOverrides) -> Result<()> {
    if let Ok(current) = read_file_tags(file) {
        if all_fields_match(original, &current) {
            return Ok(());
        }
    }
    write_tags_atomic(file, original, true)
}

fn temp_path(parent: &Path, file: &Path) -> Result<PathBuf> {
    let stamp = std::time::SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_nanos())
        .unwrap_or(0);
    let name = file
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "track".to_owned());
    Ok(parent.join(format!(
        ".{name}.lekis-tag-{}-{stamp}.tmp",
        std::process::id()
    )))
}

struct TempFileGuard<'a>(&'a Path);

impl TempFileGuard<'_> {
    fn disarm(self) {
        std::mem::forget(self);
    }
}

impl Drop for TempFileGuard<'_> {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(self.0);
    }
}

fn modified_ms(metadata: &std::fs::Metadata) -> i64 {
    metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0)
}

fn is_file_busy(error: &std::io::Error) -> bool {
    // Windows: ERROR_SHARING_VIOLATION (32) / ERROR_LOCK_VIOLATION (33)。
    matches!(error.kind(), ErrorKind::PermissionDenied)
        || matches!(error.raw_os_error(), Some(32 | 33))
}

fn io_error(context: &str, path: &Path, error: std::io::Error) -> LekisError {
    let code = match error.kind() {
        ErrorKind::NotFound => ErrorCode::NotFound,
        ErrorKind::PermissionDenied => ErrorCode::PermissionDenied,
        _ if matches!(error.raw_os_error(), Some(32 | 33)) => ErrorCode::PermissionDenied,
        _ => ErrorCode::Io,
    };
    LekisError::new(
        code,
        format!("{context}失败（{}）：{error}", path.to_string_lossy()),
    )
}

#[cfg(test)]
static FORCE_POST_WRITE_FAILURE: std::sync::Mutex<Option<PathBuf>> = std::sync::Mutex::new(None);

#[cfg(test)]
fn take_forced_failure(file: &Path) -> bool {
    let Ok(mut target) = FORCE_POST_WRITE_FAILURE.lock() else {
        return false;
    };
    if target.as_deref() == Some(file) {
        *target = None;
        true
    } else {
        false
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::db::test_util::temp_library;
    use crate::{ScannedFile, ScannedTags};
    use lekis_types::{SourceConfig, SourceId, SourceKind, TrackQuery, TrackSort};
    use std::collections::BTreeMap;

    const MP3_FIXTURE: &[u8] = include_bytes!("../testdata/minimal.mp3");
    const FLAC_FIXTURE: &[u8] = include_bytes!("../testdata/minimal.flac");
    const OPUS_FIXTURE: &[u8] = include_bytes!("../testdata/minimal.opus");
    const OGG_FIXTURE: &[u8] = include_bytes!("../testdata/minimal.ogg");
    const M4A_FIXTURE: &[u8] = include_bytes!("../testdata/minimal.m4a");
    const AAC_FIXTURE: &[u8] = include_bytes!("../testdata/minimal.aac");

    struct TestLibrary {
        library: Library,
        source_id: SourceId,
        root: PathBuf,
    }

    fn temp_root(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "lekis-tag-edit-{name}-{}-{}",
            std::process::id(),
            now_ms()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        root
    }

    async fn setup(name: &str, kind: SourceKind) -> TestLibrary {
        let library = temp_library(name).unwrap();
        let root = temp_root(name);
        let source_id = library
            .add_source(SourceConfig {
                id: None,
                kind,
                name: "local".into(),
                addresses: vec![],
                root_path: root.to_string_lossy().into_owned(),
                credential_ref: None,
                options: BTreeMap::new(),
                enabled: true,
            })
            .await
            .unwrap();
        TestLibrary {
            library,
            source_id,
            root,
        }
    }

    async fn add_file(env: &TestLibrary, name: &str, bytes: &[u8], title: &str) -> TrackId {
        let path = env.root.join(name);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).unwrap();
        }
        std::fs::write(&path, bytes).unwrap();
        let relative = name.replace('\\', "/");
        env.library
            .upsert_scanned(vec![ScannedFile {
                source_id: env.source_id,
                path: relative,
                size: bytes.len() as u64,
                mtime_ms: 1,
                tags: ScannedTags {
                    title: title.into(),
                    artists: vec!["原艺人".into()],
                    album: Some("原专辑".into()),
                    duration_ms: 1000,
                    ..Default::default()
                },
            }])
            .await
            .unwrap();
        track_id_by_title(&env.library, title).await
    }

    async fn track_id_by_title(library: &Library, title: &str) -> TrackId {
        library
            .list_track_rows(TrackQuery {
                sort: TrackSort::Title,
                offset: 0,
                limit: 100,
            })
            .await
            .unwrap()
            .into_iter()
            .find(|row| row.title == title)
            .unwrap()
            .id
    }

    fn sample_overrides() -> TrackTagOverrides {
        TrackTagOverrides {
            title: Some("新标题".into()),
            artist: Some("新艺人 / 合作艺人".into()),
            album: Some("新专辑".into()),
            album_artist: Some("新专辑艺人".into()),
            track_no: Some(7),
            disc_no: Some(2),
            year: Some(2024),
            genre: Some("流行; 摇滚".into()),
            comment: Some("测试评论".into()),
            composer: Some("作曲人".into()),
            lyricist: Some("作词人".into()),
            musicbrainz_track_id: Some("11111111-1111-1111-1111-111111111111".into()),
            musicbrainz_album_id: Some("22222222-2222-2222-2222-222222222222".into()),
        }
    }

    #[tokio::test]
    async fn overrides_win_in_rows_detail_and_search() {
        let env = setup("precedence", SourceKind::Local).await;
        let id = add_file(&env, "song.mp3", MP3_FIXTURE, "文件标题").await;

        let fields = TrackTagOverrides {
            title: Some("覆盖标题".into()),
            artist: Some("覆盖艺人".into()),
            album: Some("覆盖专辑".into()),
            genre: Some("流派甲; 流派乙".into()),
            year: Some(2020),
            track_no: Some(4),
            disc_no: Some(1),
            musicbrainz_track_id: Some("33333333-3333-3333-3333-333333333333".into()),
            ..Default::default()
        };
        env.library
            .set_track_tag_overrides(id, fields.clone())
            .await
            .unwrap();
        assert_eq!(
            env.library.track_tag_overrides(id).await.unwrap(),
            Some(fields)
        );

        let rows = env
            .library
            .list_track_rows(TrackQuery {
                sort: TrackSort::Title,
                offset: 0,
                limit: 10,
            })
            .await
            .unwrap();
        assert_eq!(rows[0].title, "覆盖标题");
        assert_eq!(rows[0].artist_line, "覆盖艺人");
        assert_eq!(rows[0].album_title.as_deref(), Some("覆盖专辑"));

        let track = env.library.get_track(id).await.unwrap();
        assert_eq!(track.title, "覆盖标题");
        assert_eq!(track.artists[0].name, "覆盖艺人");
        assert_eq!(track.year, Some(2020));
        assert_eq!(track.track_no, Some(4));
        assert_eq!(track.genres, vec!["流派甲", "流派乙"]);
        assert_eq!(
            track.mbid_recording.as_deref(),
            Some("33333333-3333-3333-3333-333333333333")
        );

        let found = env.library.search("覆盖标题", 10).await.unwrap();
        assert_eq!(found.tracks.len(), 1);
        assert_eq!(found.tracks[0].id, id);

        env.library.clear_track_tag_overrides(id).await.unwrap();
        assert!(env.library.track_tag_overrides(id).await.unwrap().is_none());
        assert_eq!(env.library.get_track(id).await.unwrap().title, "文件标题");
    }

    #[tokio::test]
    async fn writes_all_supported_formats_with_backup_and_restore() {
        let cases: [(&str, &[u8]); 6] = [
            ("song.mp3", MP3_FIXTURE),
            ("song.flac", FLAC_FIXTURE),
            ("song.opus", OPUS_FIXTURE),
            ("song.ogg", OGG_FIXTURE),
            ("song.m4a", M4A_FIXTURE),
            ("song.aac", AAC_FIXTURE),
        ];
        for (name, bytes) in cases {
            let env = setup(
                &format!("format-{}", name.replace('.', "-")),
                SourceKind::Local,
            )
            .await;
            let id = add_file(&env, name, bytes, "格式测试").await;
            let before = env.library.read_track_file_tags(id).await.unwrap();
            let backup_path = backup_path_for(&env.root.join(name));
            assert!(!backup_path.exists());

            env.library
                .set_track_tag_overrides(id, sample_overrides())
                .await
                .unwrap();
            let result = env.library.write_track_tags(id).await.unwrap();
            assert_eq!(result.track_id, id);
            assert_eq!(result.fields.len(), 13);
            assert!(backup_path.exists(), "{name} 没有生成备份");
            assert_eq!(result.backup_path, backup_path.to_string_lossy());

            let after = env.library.read_track_file_tags(id).await.unwrap();
            assert_eq!(after, sample_overrides(), "{name} 写回后读出的标签不一致");
            let backup = read_backup(&backup_path).unwrap();
            assert_eq!(backup.tags, before);
            assert!(backup.file_size > 0);
            assert!(backup.file_mtime_ms > 0);

            env.library.restore_track_tags(id).await.unwrap();
            let restored = env.library.read_track_file_tags(id).await.unwrap();
            assert_eq!(restored, before, "{name} 恢复后不一致");
            assert!(env.library.track_tag_overrides(id).await.unwrap().is_none());
        }
    }

    #[tokio::test]
    async fn batch_write_reports_per_item_failures() {
        let env = setup("batch", SourceKind::Local).await;
        let good = add_file(&env, "good.mp3", MP3_FIXTURE, "好文件").await;
        let bad = add_file(&env, "bad.wav", WAV_FIXTURE, "坏文件").await;
        env.library
            .set_track_tag_overrides(good, sample_overrides())
            .await
            .unwrap();
        // 让 bad 有覆盖层：先伪装成本地可写格式，再换成 WAV 内容。
        env.library
            .set_track_tag_overrides(
                bad,
                TrackTagOverrides {
                    title: Some("坏标题".into()),
                    ..Default::default()
                },
            )
            .await
            .unwrap();

        let report = env
            .library
            .batch_write_track_tags(vec![good, bad, TrackId(999_999)])
            .await
            .unwrap();
        assert_eq!(report.len(), 3);
        assert!(report[0].result.is_some());
        assert_eq!(report[1].error_code, Some(ErrorCode::Unsupported));
        assert_eq!(report[2].error_code, Some(ErrorCode::NotFound));
    }

    #[tokio::test]
    async fn remote_source_and_missing_file_are_rejected() {
        let env = setup("remote", SourceKind::OpenSubsonic).await;
        let path = env.root.join("remote.mp3");
        std::fs::write(&path, MP3_FIXTURE).unwrap();
        env.library
            .upsert_scanned(vec![ScannedFile {
                source_id: env.source_id,
                path: "remote.mp3".into(),
                size: MP3_FIXTURE.len() as u64,
                mtime_ms: 1,
                tags: ScannedTags {
                    title: "远程曲目".into(),
                    artists: vec!["远程艺人".into()],
                    ..Default::default()
                },
            }])
            .await
            .unwrap();
        let id = track_id_by_title(&env.library, "远程曲目").await;
        let error = env
            .library
            .set_track_tag_overrides(
                id,
                TrackTagOverrides {
                    title: Some("改不了".into()),
                    ..Default::default()
                },
            )
            .await
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::Unsupported);

        let local = setup("missing-file", SourceKind::Local).await;
        let id = add_file(&local, "gone.mp3", MP3_FIXTURE, "会消失").await;
        std::fs::remove_file(local.root.join("gone.mp3")).unwrap();
        let error = local
            .library
            .set_track_tag_overrides(
                id,
                TrackTagOverrides {
                    title: Some("不存在".into()),
                    ..Default::default()
                },
            )
            .await
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::NotFound);
    }

    #[tokio::test]
    async fn readonly_file_fails_without_touching_it() {
        let env = setup("readonly", SourceKind::Local).await;
        let id = add_file(&env, "readonly.mp3", MP3_FIXTURE, "只读文件").await;
        env.library
            .set_track_tag_overrides(
                id,
                TrackTagOverrides {
                    title: Some("写不进去".into()),
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        let path = env.root.join("readonly.mp3");
        let before = std::fs::read(&path).unwrap();
        let mut permissions = std::fs::metadata(&path).unwrap().permissions();
        permissions.set_readonly(true);
        std::fs::set_permissions(&path, permissions).unwrap();

        let error = env.library.write_track_tags(id).await.unwrap_err();
        assert_eq!(error.code, ErrorCode::PermissionDenied);
        assert_eq!(std::fs::read(&path).unwrap(), before);

        let mut permissions = std::fs::metadata(&path).unwrap().permissions();
        #[allow(clippy::permissions_set_readonly_false)]
        permissions.set_readonly(false);
        std::fs::set_permissions(&path, permissions).unwrap();
    }

    #[tokio::test]
    async fn failed_write_restores_from_backup() {
        let env = setup("rollback", SourceKind::Local).await;
        let id = add_file(&env, "rollback.mp3", MP3_FIXTURE, "回滚文件").await;
        let before = env.library.read_track_file_tags(id).await.unwrap();
        env.library
            .set_track_tag_overrides(
                id,
                TrackTagOverrides {
                    title: Some("失败的标题".into()),
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        *FORCE_POST_WRITE_FAILURE.lock().unwrap() = Some(env.root.join("rollback.mp3"));
        let error = env.library.write_track_tags(id).await.unwrap_err();
        assert!(error.message.contains("forced post-write failure"));
        let after = env.library.read_track_file_tags(id).await.unwrap();
        assert_eq!(after, before, "失败后没有从备份恢复");
    }

    #[tokio::test]
    async fn invalid_overrides_are_rejected() {
        let env = setup("validation", SourceKind::Local).await;
        let id = add_file(&env, "validation.mp3", MP3_FIXTURE, "校验").await;
        let nul = TrackTagOverrides {
            title: Some("坏\0标题".into()),
            ..Default::default()
        };
        assert_eq!(
            env.library
                .set_track_tag_overrides(id, nul)
                .await
                .unwrap_err()
                .code,
            ErrorCode::InvalidArgument
        );
        let year = TrackTagOverrides {
            year: Some(99),
            ..Default::default()
        };
        assert_eq!(
            env.library
                .set_track_tag_overrides(id, year)
                .await
                .unwrap_err()
                .code,
            ErrorCode::InvalidArgument
        );

        let broken = add_file(&env, "broken.mp3", b"not audio", "坏文件").await;
        assert_eq!(
            env.library
                .read_track_file_tags(broken)
                .await
                .unwrap_err()
                .code,
            ErrorCode::Decode
        );
        env.library
            .set_track_tag_overrides(
                broken,
                TrackTagOverrides {
                    title: Some("坏标题".into()),
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        assert_eq!(
            env.library.write_track_tags(broken).await.unwrap_err().code,
            ErrorCode::Decode
        );
    }

    const WAV_FIXTURE: &[u8] = b"RIFF\x28\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\x44\xac\x00\x00\x88\x58\x01\x00\x02\x00\x10\x00data\x04\x00\x00\x00\x00\x00\x00\x00";
}
