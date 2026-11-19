//! 音源配置的增删改查，以及每个音源最近一次扫描的结果。

use crate::db::DbResultExt;
use crate::Library;
use lekis_types::{now_ms, ErrorCode, LekisError, Result, SourceConfig, SourceId, SourceKind};
use rusqlite::{params, Row};

/// 一个音源加上它最近一次扫描的状态（音源列表页用）。
#[derive(Debug, Clone, PartialEq)]
pub struct SourceInfo {
    /// 配置。
    pub config: SourceConfig,
    /// 最近一次扫描结束的时间（Unix 毫秒），不论成功失败；从没扫过为 `None`。
    pub last_scan_at: Option<i64>,
    /// 最近一次扫描失败时的错误码；成功或从没扫过时为 `None`。
    pub last_scan_error_code: Option<ErrorCode>,
    /// 最近一次扫描失败时的详情（给开发者看）；成功或从没扫过时为 `None`。
    pub last_scan_error: Option<String>,
}

/// `source` 表读出来的列（顺序和 [`map_source`] 对应）。
const SOURCE_COLUMNS: &str = "id, kind, name, addresses_json, root_path, credential_ref,
                              options_json, enabled, last_scan_at, last_scan_error_code,
                              last_scan_error";

fn kind_to_str(kind: SourceKind) -> Result<String> {
    serde_json::to_value(kind)
        .ok()
        .and_then(|v| v.as_str().map(str::to_owned))
        .ok_or_else(|| LekisError::internal("cannot serialize SourceKind"))
}

/// 库里存的错误码字符串 → [`ErrorCode`]（未知值当成没有，不让一个坏值拖垮整个列表）。
fn code_from_str(raw: &str) -> Option<ErrorCode> {
    serde_json::from_value(serde_json::Value::String(raw.to_string())).ok()
}

/// `source` 表的一行原始数据（JSON 列还没解析）。
struct SourceRow {
    id: i64,
    kind: String,
    name: String,
    addresses_json: String,
    root_path: String,
    credential_ref: Option<String>,
    options_json: String,
    enabled: i64,
    last_scan_at: Option<i64>,
    last_scan_error_code: Option<String>,
    last_scan_error: Option<String>,
}

fn map_source(r: &Row<'_>) -> rusqlite::Result<SourceRow> {
    Ok(SourceRow {
        id: r.get(0)?,
        kind: r.get(1)?,
        name: r.get(2)?,
        addresses_json: r.get(3)?,
        root_path: r.get(4)?,
        credential_ref: r.get(5)?,
        options_json: r.get(6)?,
        enabled: r.get(7)?,
        last_scan_at: r.get(8)?,
        last_scan_error_code: r.get(9)?,
        last_scan_error: r.get(10)?,
    })
}

impl SourceRow {
    fn into_info(self) -> Result<SourceInfo> {
        let kind: SourceKind = serde_json::from_value(serde_json::Value::String(self.kind))
            .map_err(|e| LekisError::internal(format!("bad source kind: {e}")))?;
        let config = SourceConfig {
            id: Some(SourceId(self.id)),
            kind,
            name: self.name,
            addresses: serde_json::from_str(&self.addresses_json).unwrap_or_default(),
            root_path: self.root_path,
            credential_ref: self.credential_ref,
            options: serde_json::from_str(&self.options_json).unwrap_or_default(),
            enabled: self.enabled != 0,
        };
        Ok(SourceInfo {
            config,
            last_scan_at: self.last_scan_at,
            last_scan_error_code: self.last_scan_error_code.as_deref().and_then(code_from_str),
            last_scan_error: self.last_scan_error,
        })
    }
}

impl Library {
    /// 新增音源，返回 ID。
    pub async fn add_source(&self, cfg: SourceConfig) -> Result<SourceId> {
        let kind = kind_to_str(cfg.kind)?;
        let addresses = serde_json::to_string(&cfg.addresses)
            .map_err(|e| LekisError::internal(e.to_string()))?;
        let options =
            serde_json::to_string(&cfg.options).map_err(|e| LekisError::internal(e.to_string()))?;
        self.write(move |c| {
            c.execute(
                "INSERT INTO source (kind, name, addresses_json, root_path, credential_ref,
                                     options_json, enabled, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    kind,
                    cfg.name,
                    addresses,
                    cfg.root_path,
                    cfg.credential_ref,
                    options,
                    cfg.enabled as i64,
                    now_ms()
                ],
            )
            .db()?;
            Ok(SourceId(c.last_insert_rowid()))
        })
        .await
    }

    /// 列出所有音源。
    pub async fn list_sources(&self) -> Result<Vec<SourceConfig>> {
        Ok(self
            .list_source_infos()
            .await?
            .into_iter()
            .map(|i| i.config)
            .collect())
    }

    /// 列出所有音源以及它们最近一次扫描的状态。
    pub async fn list_source_infos(&self) -> Result<Vec<SourceInfo>> {
        self.read(|c| {
            let sql = format!("SELECT {SOURCE_COLUMNS} FROM source ORDER BY priority DESC, id");
            let mut stmt = c.prepare_cached(&sql).db()?;
            let raw = stmt
                .query_map([], map_source)
                .db()?
                .collect::<rusqlite::Result<Vec<_>>>()
                .db()?;
            raw.into_iter().map(SourceRow::into_info).collect()
        })
        .await
    }

    /// 按 ID 取音源。
    pub async fn get_source(&self, id: SourceId) -> Result<SourceConfig> {
        Ok(self.get_source_info(id).await?.config)
    }

    /// 按 ID 取音源及其扫描状态。
    pub async fn get_source_info(&self, id: SourceId) -> Result<SourceInfo> {
        self.read(move |c| {
            let sql = format!("SELECT {SOURCE_COLUMNS} FROM source WHERE id = ?1");
            let mut stmt = c.prepare_cached(&sql).db()?;
            let row = stmt
                .query_row(params![id.0], map_source)
                .db()
                .map_err(|e| match e.code {
                    ErrorCode::NotFound => LekisError::not_found(format!("source {id}")),
                    _ => e,
                })?;
            row.into_info()
        })
        .await
    }

    /// 修改音源配置（`cfg.id` 必须有值）。扫描状态不变。
    pub async fn update_source(&self, cfg: SourceConfig) -> Result<()> {
        let id = cfg
            .id
            .ok_or_else(|| LekisError::invalid("update_source needs a source id"))?;
        let kind = kind_to_str(cfg.kind)?;
        let addresses = serde_json::to_string(&cfg.addresses)
            .map_err(|e| LekisError::internal(e.to_string()))?;
        let options =
            serde_json::to_string(&cfg.options).map_err(|e| LekisError::internal(e.to_string()))?;
        self.write(move |c| {
            let n = c
                .execute(
                    "UPDATE source
                        SET kind = ?1, name = ?2, addresses_json = ?3, root_path = ?4,
                            credential_ref = ?5, options_json = ?6, enabled = ?7
                      WHERE id = ?8",
                    params![
                        kind,
                        cfg.name,
                        addresses,
                        cfg.root_path,
                        cfg.credential_ref,
                        options,
                        cfg.enabled as i64,
                        id.0
                    ],
                )
                .db()?;
            if n == 0 {
                return Err(LekisError::not_found(format!("source {id}")));
            }
            Ok(())
        })
        .await
    }

    /// 删除音源，连带它的文件、曲目关联，以及因此变成孤儿的曲目 / 专辑 / 艺人和搜索索引行。
    ///
    /// 歌单条目按 `track_uid` 引用，故意保留（显示成占位，PL-05）；用户状态（收藏、播放次数）
    /// 也按 uid 存，保留下来，重新添加同一个音源后会自动接上。
    pub async fn remove_source(&self, id: SourceId) -> Result<()> {
        self.write(move |conn| {
            let tx = conn.transaction().db()?;
            // `file` / `track_file` 对 source 都是 ON DELETE CASCADE。
            let n = tx
                .execute("DELETE FROM source WHERE id = ?1", params![id.0])
                .db()?;
            if n == 0 {
                return Err(LekisError::not_found(format!("source {id}")));
            }
            crate::scanned::sweep_orphans(&tx)?;
            tx.commit().db()?;
            Ok(())
        })
        .await
    }

    /// 记录扫描成功完成：更新时间，清掉上一次的失败信息。
    pub async fn mark_scanned(&self, id: SourceId) -> Result<()> {
        self.write(move |c| {
            c.execute(
                "UPDATE source
                    SET last_scan_at = ?1, last_scan_error_code = NULL, last_scan_error = NULL
                  WHERE id = ?2",
                params![now_ms(), id.0],
            )
            .db()?;
            Ok(())
        })
        .await
    }

    /// 记录扫描失败（时间 + 错误码 + 详情）。
    pub async fn mark_scan_failed(&self, id: SourceId, error: &LekisError) -> Result<()> {
        let code = error.code.as_str();
        let detail = error.message.clone();
        self.write(move |c| {
            c.execute(
                "UPDATE source
                    SET last_scan_at = ?1, last_scan_error_code = ?2, last_scan_error = ?3
                  WHERE id = ?4",
                params![now_ms(), code, detail, id.0],
            )
            .db()?;
            Ok(())
        })
        .await
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::db::test_util::temp_library;
    use crate::{ScannedFile, ScannedTags};
    use lekis_types::{TrackQuery, TrackSort};
    use std::collections::BTreeMap;

    fn cfg(name: &str) -> SourceConfig {
        SourceConfig {
            id: None,
            kind: SourceKind::Smb,
            name: name.into(),
            addresses: vec!["smb://nas/music".into()],
            root_path: String::new(),
            credential_ref: None,
            options: BTreeMap::new(),
            enabled: true,
        }
    }

    fn file(source_id: SourceId, path: &str, title: &str, artist: &str) -> ScannedFile {
        ScannedFile {
            source_id,
            path: path.into(),
            size: 1,
            mtime_ms: 1,
            tags: ScannedTags {
                title: title.into(),
                artists: vec![artist.into()],
                album: Some(format!("{title} album")),
                duration_ms: 1000,
                ..Default::default()
            },
        }
    }

    #[tokio::test]
    async fn update_source_roundtrips_and_rejects_missing() -> Result<()> {
        let lib = temp_library("sources-update")?;
        let id = lib.add_source(cfg("nas")).await?;
        let mut changed = lib.get_source(id).await?;
        changed.name = "living room".into();
        changed.kind = SourceKind::WebDav;
        changed.addresses = vec!["https://nas:5006/music".into()];
        changed.credential_ref = Some("lekis.source.nas".into());
        changed.options.insert("username".into(), "ao".into());
        changed.enabled = false;
        lib.update_source(changed.clone()).await?;
        assert_eq!(lib.get_source(id).await?, changed);

        let mut ghost = changed.clone();
        ghost.id = Some(SourceId(9_999));
        assert_eq!(
            lib.update_source(ghost).await.unwrap_err().code,
            ErrorCode::NotFound
        );
        let mut no_id = changed;
        no_id.id = None;
        assert_eq!(
            lib.update_source(no_id).await.unwrap_err().code,
            ErrorCode::InvalidArgument
        );
        assert_eq!(
            lib.get_source(SourceId(9_999)).await.unwrap_err().code,
            ErrorCode::NotFound
        );
        Ok(())
    }

    #[tokio::test]
    async fn remove_source_drops_its_tracks_and_index_rows_only() -> Result<()> {
        let lib = temp_library("sources-remove")?;
        let a = lib.add_source(cfg("a")).await?;
        let b = lib.add_source(cfg("b")).await?;
        lib.upsert_scanned(vec![file(a, "x.flac", "Alphasong", "Alphaband")])
            .await?;
        lib.upsert_scanned(vec![file(b, "y.flac", "Betasong", "Betaband")])
            .await?;

        lib.remove_source(a).await?;

        let rows = lib
            .list_track_rows(TrackQuery {
                sort: TrackSort::Title,
                offset: 0,
                limit: 10,
            })
            .await?;
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].title, "Betasong");
        let gone = lib.search("Alphasong", 10).await?;
        assert!(gone.tracks.is_empty());
        assert!(lib.search("Alphaband", 10).await?.artists.is_empty());
        assert_eq!(lib.search("Betasong", 10).await?.tracks.len(), 1);
        assert_eq!(lib.list_sources().await?.len(), 1);
        assert_eq!(
            lib.remove_source(a).await.unwrap_err().code,
            ErrorCode::NotFound
        );
        Ok(())
    }

    #[tokio::test]
    async fn scan_status_is_recorded_and_cleared() -> Result<()> {
        let lib = temp_library("sources-scan-status")?;
        let id = lib.add_source(cfg("nas")).await?;
        let info = lib.get_source_info(id).await?;
        assert_eq!(info.last_scan_at, None);
        assert_eq!(info.last_scan_error, None);

        lib.mark_scan_failed(id, &LekisError::new(ErrorCode::Auth, "bad password"))
            .await?;
        let info = lib.get_source_info(id).await?;
        assert!(info.last_scan_at.is_some());
        assert_eq!(info.last_scan_error_code, Some(ErrorCode::Auth));
        assert_eq!(info.last_scan_error.as_deref(), Some("bad password"));
        let listed = lib.list_source_infos().await?;
        assert_eq!(listed[0].last_scan_error_code, Some(ErrorCode::Auth));

        lib.mark_scanned(id).await?;
        let info = lib.get_source_info(id).await?;
        assert!(info.last_scan_at.is_some());
        assert_eq!(info.last_scan_error_code, None);
        assert_eq!(info.last_scan_error, None);
        Ok(())
    }
}
