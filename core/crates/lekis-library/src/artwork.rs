//! 封面元数据（ENR-01）。
//!
//! 数据库里只存**元数据**：内容哈希、来源、尺寸、调色板。图片字节本身放在本机缓存目录
//! （`<cache>/artwork/<哈希前 2 位>/<哈希>_<尺寸>.webp`，见 `docs/ARCHITECTURE.md` 第 5 节），
//! 因为 UI 直接读文件路径加载，不经 FFI 传图片字节。
//!
//! 同一张图（同一个哈希）只存一行，曲目 / 专辑 / 艺人 / 歌单都通过 `artwork_id` 引用它。

use crate::db::DbResultExt;
use crate::Library;
use lekis_types::{now_ms, AlbumId, ArtistId, ArtworkId, LekisError, Palette, Result, TrackId};
use rusqlite::{params, OptionalExtension};

/// 封面元数据（不含图片字节）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArtworkRow {
    /// 本机 ID。
    pub id: ArtworkId,
    /// 原图内容哈希（`sha256` 十六进制）。
    pub hash: String,
    /// 来源，例如 `embedded` / `sidecar` / `coverartarchive` / `itunes` / `plugin:<id>`。
    pub source: String,
    /// 原图宽度（像素）。
    pub width: Option<u32>,
    /// 原图高度（像素）。
    pub height: Option<u32>,
    /// 调色板（动态背景用）。
    pub palette: Option<Palette>,
    /// 入库时间（Unix 毫秒）。
    pub created_at: i64,
}

fn map_artwork_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<ArtworkRow> {
    let palette_json: Option<String> = r.get(5)?;
    Ok(ArtworkRow {
        id: ArtworkId(r.get(0)?),
        hash: r.get(1)?,
        source: r.get(2)?,
        width: r.get::<_, Option<i64>>(3)?.map(|v| v.max(0) as u32),
        height: r.get::<_, Option<i64>>(4)?.map(|v| v.max(0) as u32),
        palette: palette_json.and_then(|s| serde_json::from_str::<Palette>(&s).ok()),
        created_at: r.get(6)?,
    })
}

const ARTWORK_COLUMNS: &str = "id, hash, source, width, height, palette_json, created_at";

impl Library {
    /// 按内容哈希写入（或更新）一行封面元数据，返回它的 ID。
    ///
    /// 同哈希已存在时只补齐缺失的字段：已有的宽高 / 调色板不会被后来的空值覆盖。
    pub async fn upsert_artwork(
        &self,
        hash: String,
        source: String,
        width: Option<u32>,
        height: Option<u32>,
        palette: Option<Palette>,
    ) -> Result<ArtworkId> {
        if hash.trim().is_empty() {
            return Err(LekisError::invalid("artwork hash must not be empty"));
        }
        if source.trim().is_empty() {
            return Err(LekisError::invalid("artwork source must not be empty"));
        }
        let palette_json = palette
            .as_ref()
            .map(serde_json::to_string)
            .transpose()
            .map_err(|e| LekisError::internal(format!("serialize palette: {e}")))?;
        self.write(move |c| {
            let now = now_ms();
            c.query_row(
                "INSERT INTO artwork (hash, source, width, height, palette_json, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT (hash) DO UPDATE SET
                   width = COALESCE(artwork.width, excluded.width),
                   height = COALESCE(artwork.height, excluded.height),
                   palette_json = COALESCE(artwork.palette_json, excluded.palette_json)
                 RETURNING id",
                params![
                    hash,
                    source,
                    width.map(|v| v as i64),
                    height.map(|v| v as i64),
                    palette_json,
                    now
                ],
                |r| r.get::<_, i64>(0),
            )
            .map(ArtworkId)
            .db()
        })
        .await
    }

    /// 按 ID 取封面元数据。
    pub async fn get_artwork(&self, id: ArtworkId) -> Result<ArtworkRow> {
        self.read(move |c| {
            c.query_row(
                &format!("SELECT {ARTWORK_COLUMNS} FROM artwork WHERE id = ?1"),
                params![id.0],
                map_artwork_row,
            )
            .optional()
            .db()?
            .ok_or_else(|| LekisError::not_found(format!("artwork {id}")))
        })
        .await
    }

    /// 按内容哈希取封面元数据（去重用）。
    pub async fn artwork_by_hash(&self, hash: &str) -> Result<Option<ArtworkRow>> {
        let hash = hash.to_string();
        self.read(move |c| {
            c.query_row(
                &format!("SELECT {ARTWORK_COLUMNS} FROM artwork WHERE hash = ?1"),
                params![hash],
                map_artwork_row,
            )
            .optional()
            .db()
        })
        .await
    }

    /// 更新调色板（分析完封面颜色后回填）。
    pub async fn set_artwork_palette(&self, id: ArtworkId, palette: Palette) -> Result<()> {
        let json = serde_json::to_string(&palette)
            .map_err(|e| LekisError::internal(format!("serialize palette: {e}")))?;
        self.write(move |c| {
            let n = c
                .execute(
                    "UPDATE artwork SET palette_json = ?2 WHERE id = ?1",
                    params![id.0, json],
                )
                .db()?;
            if n == 0 {
                return Err(LekisError::not_found(format!("artwork {id}")));
            }
            Ok(())
        })
        .await
    }

    /// 给曲目设置封面（覆盖层优先级高于专辑封面，调 `get_track` 时已经合并好）。
    pub async fn set_track_artwork(
        &self,
        id: TrackId,
        artwork_id: Option<ArtworkId>,
    ) -> Result<()> {
        self.write(move |c| {
            let n = c
                .execute(
                    "UPDATE track SET artwork_id = ?2, updated_at = ?3 WHERE id = ?1",
                    params![id.0, artwork_id.map(|a| a.0), now_ms()],
                )
                .db()?;
            if n == 0 {
                return Err(LekisError::not_found(format!("track {id}")));
            }
            Ok(())
        })
        .await
    }

    /// 给专辑设置封面。
    pub async fn set_album_artwork(
        &self,
        id: AlbumId,
        artwork_id: Option<ArtworkId>,
    ) -> Result<()> {
        self.write(move |c| {
            let n = c
                .execute(
                    "UPDATE album SET artwork_id = ?2 WHERE id = ?1",
                    params![id.0, artwork_id.map(|a| a.0)],
                )
                .db()?;
            if n == 0 {
                return Err(LekisError::not_found(format!("album {id}")));
            }
            Ok(())
        })
        .await
    }

    /// 给艺人设置头像 / 合影。
    pub async fn set_artist_artwork(
        &self,
        id: ArtistId,
        artwork_id: Option<ArtworkId>,
    ) -> Result<()> {
        self.write(move |c| {
            let n = c
                .execute(
                    "UPDATE artist SET artwork_id = ?2 WHERE id = ?1",
                    params![id.0, artwork_id.map(|a| a.0)],
                )
                .db()?;
            if n == 0 {
                return Err(LekisError::not_found(format!("artist {id}")));
            }
            Ok(())
        })
        .await
    }

    /// 取一首歌最终生效的封面 ID：曲目自己的 → 专辑的 → `None`。
    pub async fn effective_artwork_id(&self, track: TrackId) -> Result<Option<ArtworkId>> {
        self.read(move |c| {
            c.query_row(
                "SELECT COALESCE(t.artwork_id, a.artwork_id)
                 FROM track t LEFT JOIN album a ON a.id = t.album_id
                 WHERE t.id = ?1",
                params![track.0],
                |r| r.get::<_, Option<i64>>(0),
            )
            .optional()
            .db()
            .map(|v| v.flatten().map(ArtworkId))
        })
        .await
    }

    /// 取一首歌最终生效的封面元数据（含调色板）；没有封面返回 `None`。
    pub async fn effective_artwork(&self, track: TrackId) -> Result<Option<ArtworkRow>> {
        let Some(id) = self.effective_artwork_id(track).await? else {
            return Ok(None);
        };
        match self.get_artwork(id).await {
            Ok(row) => Ok(Some(row)),
            Err(e) if e.code == lekis_types::ErrorCode::NotFound => Ok(None),
            Err(e) => Err(e),
        }
    }
}

/// 封面在缓存目录里的相对路径（`artwork/<哈希前 2 位>/<哈希>_<尺寸>.webp`）。
///
/// 核心只负责这个约定，写文件由平台层 / `lekis-core` 的封面缓存做。
pub fn cache_relative_path(hash: &str, width: u32) -> String {
    let prefix = hash.get(..2).unwrap_or("00");
    let sanitized_width = width.clamp(96, 4096);
    format!("artwork/{prefix}/{hash}_{sanitized_width}.webp")
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::db::test_util::temp_library;
    use crate::ScannedFile;
    use lekis_types::{AudioProps, Codec, SourceId};

    fn scanned(source: SourceId, path: &str, title: &str) -> ScannedFile {
        ScannedFile {
            source_id: source,
            path: path.into(),
            size: 1024,
            mtime_ms: 1,
            tags: crate::ScannedTags {
                title: title.into(),
                artists: vec!["周杰伦".into()],
                album: Some("叶惠美".into()),
                duration_ms: 1000,
                audio: Some(AudioProps {
                    codec: Codec::Flac,
                    sample_rate: 44_100,
                    bit_depth: Some(16),
                    channels: 2,
                    bitrate_kbps: Some(900),
                }),
                ..Default::default()
            },
        }
    }

    #[tokio::test]
    async fn artwork_upsert_dedup_and_refs() -> Result<()> {
        let lib = temp_library("artwork")?;
        let source = lib
            .add_source(lekis_types::SourceConfig {
                id: None,
                kind: lekis_types::SourceKind::Local,
                name: "本地".into(),
                addresses: vec!["/music".into()],
                root_path: String::new(),
                credential_ref: None,
                options: Default::default(),
                enabled: true,
            })
            .await?;
        lib.upsert_scanned(vec![scanned(source, "a.flac", "晴天")])
            .await?;

        let track = lib
            .list_track_rows(lekis_types::TrackQuery {
                sort: lekis_types::TrackSort::Title,
                offset: 0,
                limit: 10,
            })
            .await?[0]
            .id;
        assert_eq!(lib.effective_artwork_id(track).await?, None);

        // 同哈希写两次只留一行，后写的补齐调色板。
        let first = lib
            .upsert_artwork(
                "deadbeef00".into(),
                "embedded".into(),
                Some(600),
                Some(600),
                None,
            )
            .await?;
        let second = lib
            .upsert_artwork(
                "deadbeef00".into(),
                "coverartarchive".into(),
                None,
                None,
                Some(Palette {
                    primary: 0x112233,
                    secondary: 0x445566,
                    on_primary: 0xffffff,
                    gradient: vec![0x112233],
                }),
            )
            .await?;
        assert_eq!(first, second);
        let row = lib.get_artwork(first).await?;
        assert_eq!(row.width, Some(600));
        assert_eq!(row.source, "embedded", "首次写入的来源保留");
        assert!(row.palette.is_some(), "第二次写入补上调色板");
        assert_eq!(
            lib.artwork_by_hash("deadbeef00").await?.map(|r| r.id),
            Some(first)
        );

        // 专辑级封面兜底给曲目用。
        let album = lib
            .list_albums(lekis_types::TrackSort::Title, 0, 10)
            .await?[0]
            .id;
        lib.set_album_artwork(album, Some(first)).await?;
        assert_eq!(lib.effective_artwork_id(track).await?, Some(first));

        // 曲目级封面优先于专辑级。
        let other = lib
            .upsert_artwork(
                "cafebabe11".into(),
                "itunes".into(),
                Some(300),
                Some(300),
                None,
            )
            .await?;
        lib.set_track_artwork(track, Some(other)).await?;
        assert_eq!(lib.effective_artwork_id(track).await?, Some(other));
        assert_eq!(
            lib.effective_artwork(track).await?.map(|r| r.hash),
            Some("cafebabe11".to_string())
        );

        // 清空曲目封面后回落到专辑封面。
        lib.set_track_artwork(track, None).await?;
        assert_eq!(lib.effective_artwork_id(track).await?, Some(first));

        assert_eq!(
            cache_relative_path("deadbeef00", 320),
            "artwork/de/deadbeef00_320.webp"
        );
        Ok(())
    }

    #[tokio::test]
    async fn artwork_rejects_bad_input_and_missing_rows() -> Result<()> {
        let lib = temp_library("artwork-err")?;
        assert_eq!(
            lib.upsert_artwork("  ".into(), "embedded".into(), None, None, None)
                .await
                .unwrap_err()
                .code,
            lekis_types::ErrorCode::InvalidArgument
        );
        assert_eq!(
            lib.get_artwork(ArtworkId(42)).await.unwrap_err().code,
            lekis_types::ErrorCode::NotFound
        );
        assert_eq!(
            lib.set_album_artwork(AlbumId(42), None)
                .await
                .unwrap_err()
                .code,
            lekis_types::ErrorCode::NotFound
        );
        Ok(())
    }
}
