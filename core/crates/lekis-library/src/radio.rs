//! 网络电台的持久化（SRC-11）。
//!
//! 浏览结果会 upsert 到 `radio_station`，收藏状态和最近播放时间也在这张表里。
//! 播放队列用负数的合成 `TrackId` 引用电台，不需要往 `track` 表写任何东西。

use crate::db::{DbResultExt, Library};
use lekis_types::{now_ms, LekisError, RadioStation, RadioStationId, Result};
use rusqlite::{params, Connection, OptionalExtension, Row};

const RADIO_COLUMNS: &str = "id, station_uuid, name, url, favicon, country, country_code,
     language, tags_json, codec, bitrate, homepage, is_custom, favorite, last_played_at";

/// 一页电台最多返回多少条。
const MAX_RADIO_LIMIT: u32 = 500;

fn map_station(r: &Row<'_>) -> rusqlite::Result<RadioStation> {
    let tags_json: String = r.get(8)?;
    let tags = serde_json::from_str::<Vec<String>>(&tags_json).unwrap_or_default();
    Ok(RadioStation {
        id: RadioStationId(r.get(0)?),
        station_uuid: r.get(1)?,
        name: r.get(2)?,
        url: r.get(3)?,
        favicon: r.get(4)?,
        country: r.get(5)?,
        country_code: r.get(6)?,
        language: r.get(7)?,
        tags,
        codec: r.get(9)?,
        bitrate: r.get::<_, Option<i64>>(10)?.map(|v| v.max(0) as u32),
        homepage: r.get(11)?,
        is_custom: r.get::<_, i64>(12)? != 0,
        favorite: r.get::<_, i64>(13)? != 0,
        last_played_at: r.get(14)?,
    })
}

fn read_station(c: &Connection, id: i64) -> Result<RadioStation> {
    let sql = format!("SELECT {RADIO_COLUMNS} FROM radio_station WHERE id = ?1");
    c.query_row(&sql, params![id], map_station)
        .optional()
        .db()?
        .ok_or_else(|| LekisError::not_found(format!("radio station {id}")))
}

fn clean_optional(value: Option<String>) -> Option<String> {
    value
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
}

fn tags_json(tags: &[String]) -> Result<String> {
    serde_json::to_string(tags)
        .map_err(|e| LekisError::internal(format!("serialize radio tags: {e}")))
}

fn check_limit(limit: u32) -> Result<usize> {
    if limit == 0 || limit > MAX_RADIO_LIMIT {
        return Err(LekisError::invalid(format!(
            "limit must be 1..={MAX_RADIO_LIMIT}"
        )));
    }
    Ok(limit as usize)
}

impl Library {
    /// 按本机 ID 取电台。
    pub async fn radio_station(&self, id: RadioStationId) -> Result<RadioStation> {
        self.read(move |c| read_station(c, id.0)).await
    }

    /// 批量写入浏览结果（按 Radio Browser UUID，其次按流地址去重）。
    ///
    /// 已存在的电台保留收藏状态、最近播放时间和自定义标记；返回的条目带本机 ID，
    /// 顺序和输入一致。
    pub async fn radio_upsert_many(
        &self,
        stations: Vec<RadioStation>,
    ) -> Result<Vec<RadioStation>> {
        let now = now_ms();
        self.write(move |c| {
            let tx = c.transaction().db()?;
            let mut ids = Vec::with_capacity(stations.len());
            for mut station in stations {
                let uuid = clean_optional(station.station_uuid.take());
                let url = station.url.trim().to_string();
                if url.is_empty() {
                    return Err(LekisError::invalid("radio station url must not be empty"));
                }
                let existing: Option<(i64, i64)> = if let Some(uuid) = &uuid {
                    tx.query_row(
                        "SELECT id, is_custom FROM radio_station WHERE station_uuid = ?1",
                        params![uuid],
                        |r| Ok((r.get(0)?, r.get(1)?)),
                    )
                    .optional()
                    .db()?
                } else {
                    None
                }
                .or_else(|| {
                    // URL 已存在（可能是另一个镜像返回的同一条目，或自定义电台）。
                    tx.query_row(
                        "SELECT id, is_custom FROM radio_station WHERE url = ?1",
                        params![url],
                        |r| Ok((r.get(0)?, r.get(1)?)),
                    )
                    .optional()
                    .ok()
                    .flatten()
                });

                let id = if let Some((id, _is_custom)) = existing {
                    // 自定义电台保留用户起的名字和主页；只补全来自 API 的元数据。
                    tx.execute(
                        "UPDATE radio_station SET
                           station_uuid = COALESCE(?1, station_uuid),
                           name = CASE WHEN is_custom = 1 THEN name ELSE ?2 END,
                           url = ?3,
                           favicon = COALESCE(?4, favicon),
                           country = COALESCE(?5, country),
                           country_code = COALESCE(?6, country_code),
                           language = COALESCE(?7, language),
                           tags_json = CASE WHEN ?8 = '[]' THEN tags_json ELSE ?8 END,
                           codec = COALESCE(?9, codec),
                           bitrate = COALESCE(?10, bitrate),
                           homepage = CASE WHEN is_custom = 1 THEN homepage ELSE COALESCE(?11, homepage) END,
                           updated_at = ?12
                         WHERE id = ?13",
                        params![
                            uuid,
                            station.name.trim(),
                            url,
                            clean_optional(station.favicon),
                            clean_optional(station.country),
                            clean_optional(station.country_code),
                            clean_optional(station.language),
                            tags_json(&station.tags)?,
                            clean_optional(station.codec),
                            station.bitrate,
                            clean_optional(station.homepage),
                            now,
                            id,
                        ],
                    )
                    .db()?;
                    id
                } else {
                    tx.execute(
                        "INSERT INTO radio_station
                           (station_uuid, name, url, favicon, country, country_code, language,
                            tags_json, codec, bitrate, homepage, is_custom, favorite,
                            last_played_at, created_at, updated_at)
                         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, 0, 0, NULL, ?12, ?12)",
                        params![
                            uuid,
                            station.name.trim(),
                            url,
                            clean_optional(station.favicon),
                            clean_optional(station.country),
                            clean_optional(station.country_code),
                            clean_optional(station.language),
                            tags_json(&station.tags)?,
                            clean_optional(station.codec),
                            station.bitrate,
                            clean_optional(station.homepage),
                            now,
                        ],
                    )
                    .db()?;
                    tx.last_insert_rowid()
                };
                ids.push(id);
            }
            let mut out = Vec::with_capacity(ids.len());
            for id in ids {
                out.push(read_station(&tx, id)?);
            }
            tx.commit().db()?;
            Ok(out)
        })
        .await
    }

    /// 新增自定义电台；同一个流地址已存在时更新名称 / 主页并标记为自定义。
    pub async fn radio_add_custom(
        &self,
        name: &str,
        url: &str,
        homepage: Option<&str>,
    ) -> Result<RadioStation> {
        let name = name.trim().to_string();
        let url = url.trim().to_string();
        let homepage = clean_optional(homepage.map(str::to_string));
        if url.is_empty() {
            return Err(LekisError::invalid("radio station url must not be empty"));
        }
        let now = now_ms();
        self.write(move |c| {
            let tx = c.transaction().db()?;
            let existing: Option<i64> = tx
                .query_row(
                    "SELECT id FROM radio_station WHERE url = ?1",
                    params![url],
                    |r| r.get(0),
                )
                .optional()
                .db()?;
            let id = if let Some(id) = existing {
                tx.execute(
                    "UPDATE radio_station SET name = ?1, homepage = COALESCE(?2, homepage),
                       is_custom = 1, updated_at = ?3 WHERE id = ?4",
                    params![name, homepage, now, id],
                )
                .db()?;
                id
            } else {
                tx.execute(
                    "INSERT INTO radio_station
                       (station_uuid, name, url, favicon, country, country_code, language,
                        tags_json, codec, bitrate, homepage, is_custom, favorite,
                        last_played_at, created_at, updated_at)
                     VALUES (NULL, ?1, ?2, NULL, NULL, NULL, NULL, '[]', NULL, NULL, ?3, 1, 0, NULL, ?4, ?4)",
                    params![name, url, homepage, now],
                )
                .db()?;
                tx.last_insert_rowid()
            };
            let station = read_station(&tx, id)?;
            tx.commit().db()?;
            Ok(station)
        })
        .await
    }

    /// 删除一个自定义电台。API 缓存条目不能通过这个入口删除。
    pub async fn radio_delete_custom(&self, id: RadioStationId) -> Result<()> {
        self.write(move |c| {
            let changed = c
                .execute(
                    "DELETE FROM radio_station WHERE id = ?1 AND is_custom = 1",
                    params![id.0],
                )
                .db()?;
            if changed == 0 {
                return Err(LekisError::not_found(format!("custom radio station {id}")));
            }
            Ok(())
        })
        .await
    }

    /// 收藏 / 取消收藏。
    pub async fn radio_set_favorite(&self, id: RadioStationId, favorite: bool) -> Result<()> {
        self.write(move |c| {
            let changed = c
                .execute(
                    "UPDATE radio_station SET favorite = ?1, updated_at = ?2 WHERE id = ?3",
                    params![favorite as i64, now_ms(), id.0],
                )
                .db()?;
            if changed == 0 {
                return Err(LekisError::not_found(format!("radio station {id}")));
            }
            Ok(())
        })
        .await
    }

    /// 记录一次播放（最近播放列表用）。
    pub async fn radio_mark_played(&self, id: RadioStationId, at: i64) -> Result<()> {
        self.write(move |c| {
            let changed = c
                .execute(
                    "UPDATE radio_station SET last_played_at = ?1, updated_at = ?2 WHERE id = ?3",
                    params![at, at, id.0],
                )
                .db()?;
            if changed == 0 {
                return Err(LekisError::not_found(format!("radio station {id}")));
            }
            Ok(())
        })
        .await
    }

    /// 收藏的电台（最近播放优先）。
    pub async fn radio_favorites(&self, limit: u32) -> Result<Vec<RadioStation>> {
        let limit = check_limit(limit)?;
        self.read(move |c| {
            let sql = format!(
                "SELECT {RADIO_COLUMNS} FROM radio_station WHERE favorite = 1
                 ORDER BY COALESCE(last_played_at, 0) DESC, name COLLATE NOCASE
                 LIMIT ?1"
            );
            let mut stmt = c.prepare_cached(&sql).db()?;
            let rows = stmt.query_map(params![limit as i64], map_station).db()?;
            rows.collect::<rusqlite::Result<Vec<_>>>().db()
        })
        .await
    }

    /// 最近播放过的电台。
    pub async fn radio_recent(&self, limit: u32) -> Result<Vec<RadioStation>> {
        let limit = check_limit(limit)?;
        self.read(move |c| {
            let sql = format!(
                "SELECT {RADIO_COLUMNS} FROM radio_station WHERE last_played_at IS NOT NULL
                 ORDER BY last_played_at DESC, name COLLATE NOCASE LIMIT ?1"
            );
            let mut stmt = c.prepare_cached(&sql).db()?;
            let rows = stmt.query_map(params![limit as i64], map_station).db()?;
            rows.collect::<rusqlite::Result<Vec<_>>>().db()
        })
        .await
    }

    /// 用户手动添加的电台。
    pub async fn radio_custom(&self, limit: u32) -> Result<Vec<RadioStation>> {
        let limit = check_limit(limit)?;
        self.read(move |c| {
            let sql = format!(
                "SELECT {RADIO_COLUMNS} FROM radio_station WHERE is_custom = 1
                 ORDER BY created_at DESC, id DESC LIMIT ?1"
            );
            let mut stmt = c.prepare_cached(&sql).db()?;
            let rows = stmt.query_map(params![limit as i64], map_station).db()?;
            rows.collect::<rusqlite::Result<Vec<_>>>().db()
        })
        .await
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::db::test_util::temp_library;

    fn station(uuid: &str, name: &str, url: &str) -> RadioStation {
        RadioStation {
            id: RadioStationId(0),
            station_uuid: Some(uuid.to_string()),
            name: name.to_string(),
            url: url.to_string(),
            favicon: Some("https://example.test/icon.png".into()),
            country: Some("China".into()),
            country_code: Some("CN".into()),
            language: Some("chinese".into()),
            tags: vec!["pop".into(), "news".into()],
            codec: Some("MP3".into()),
            bitrate: Some(128),
            homepage: Some("https://example.test".into()),
            is_custom: false,
            favorite: false,
            last_played_at: None,
        }
    }

    #[tokio::test]
    async fn upsert_dedupes_and_preserves_favorite() -> Result<()> {
        let lib = temp_library("radio-upsert").unwrap();
        let first = lib
            .radio_upsert_many(vec![
                station("uuid-1", "Station One", "https://example.test/one"),
                // 同一个 UUID、不同 URL：Radio Browser 的镜像地址变化。
                station("uuid-1", "Station One", "https://example.test/one-new"),
            ])
            .await?;
        assert_eq!(first.len(), 2);
        assert_eq!(first[0].id, first[1].id);

        let id = first[0].id;
        lib.radio_set_favorite(id, true).await?;
        lib.radio_mark_played(id, 42).await?;
        let again = lib
            .radio_upsert_many(vec![station(
                "uuid-1",
                "Changed",
                "https://example.test/one-new",
            )])
            .await?;
        assert_eq!(again[0].id, id);
        assert!(again[0].favorite);
        assert_eq!(again[0].last_played_at, Some(42));
        assert_eq!(lib.radio_favorites(10).await?.len(), 1);
        assert_eq!(lib.radio_recent(10).await?.len(), 1);
        Ok(())
    }

    #[tokio::test]
    async fn custom_station_roundtrip() -> Result<()> {
        let lib = temp_library("radio-custom").unwrap();
        let station = lib
            .radio_add_custom("测试电台", "http://example.test/live.mp3", None)
            .await?;
        assert!(station.is_custom);
        assert_eq!(lib.radio_custom(10).await?.len(), 1);
        lib.radio_delete_custom(station.id).await?;
        assert!(lib.radio_custom(10).await?.is_empty());
        Ok(())
    }
}
