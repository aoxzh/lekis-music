//! 音源配置的增删查。

use crate::db::DbResultExt;
use crate::Library;
use lekis_types::{now_ms, LekisError, Result, SourceConfig, SourceId, SourceKind};
use rusqlite::{params, Row};

fn kind_to_str(kind: SourceKind) -> Result<String> {
    serde_json::to_value(kind)
        .ok()
        .and_then(|v| v.as_str().map(str::to_owned))
        .ok_or_else(|| LekisError::internal("cannot serialize SourceKind"))
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
    })
}

impl SourceRow {
    fn into_config(self) -> Result<SourceConfig> {
        let kind: SourceKind = serde_json::from_value(serde_json::Value::String(self.kind))
            .map_err(|e| LekisError::internal(format!("bad source kind: {e}")))?;
        Ok(SourceConfig {
            id: Some(SourceId(self.id)),
            kind,
            name: self.name,
            addresses: serde_json::from_str(&self.addresses_json).unwrap_or_default(),
            root_path: self.root_path,
            credential_ref: self.credential_ref,
            options: serde_json::from_str(&self.options_json).unwrap_or_default(),
            enabled: self.enabled != 0,
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
        self.read(|c| {
            let mut stmt = c
                .prepare_cached(
                    "SELECT id, kind, name, addresses_json, root_path, credential_ref,
                            options_json, enabled
                     FROM source ORDER BY priority DESC, id",
                )
                .db()?;
            let raw = stmt
                .query_map([], map_source)
                .db()?
                .collect::<rusqlite::Result<Vec<_>>>()
                .db()?;
            raw.into_iter().map(SourceRow::into_config).collect()
        })
        .await
    }

    /// 按 ID 取音源。
    pub async fn get_source(&self, id: SourceId) -> Result<SourceConfig> {
        self.list_sources()
            .await?
            .into_iter()
            .find(|s| s.id == Some(id))
            .ok_or_else(|| LekisError::not_found(format!("source {id}")))
    }

    /// 记录扫描完成时间。
    pub async fn mark_scanned(&self, id: SourceId) -> Result<()> {
        self.write(move |c| {
            c.execute(
                "UPDATE source SET last_scan_at = ?1 WHERE id = ?2",
                params![now_ms(), id.0],
            )
            .db()?;
            Ok(())
        })
        .await
    }
}
