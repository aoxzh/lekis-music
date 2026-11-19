//! 同步操作的本地队列（SYN-01）。
//!
//! 这个模块只认"HLC 字符串 + JSON 负载"，不认识同步的业务语义 —— `SyncOp` 的类型定义在
//! `lekis-sync` 里，而依赖方向只允许 `lekis-sync → lekis-library`，所以由 `lekis-core`
//! 负责把 `SyncOp` 序列化后塞进来。
//!
//! 表结构见 `migrations/0001_init.sql`：`sync_outbox`（待推送）和 `sync_cursor`（每个通道读到哪了）。

use crate::db::DbResultExt;
use crate::Library;
use lekis_types::{now_ms, Result};
use rusqlite::{params, OptionalExtension};

/// 一条待推送的同步操作（原样是 JSON）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutboxEntry {
    /// 混合逻辑时钟的字符串形式（同时是主键，字典序等于时间序）。
    pub hlc: String,
    /// `SyncOp` 的 JSON。
    pub op_json: String,
}

impl Library {
    /// 追加一条待推送操作。同一个 HLC 重复写入会被忽略（幂等）。
    pub async fn enqueue_sync_op(&self, hlc: String, op_json: String) -> Result<()> {
        self.write(move |c| {
            c.execute(
                "INSERT OR IGNORE INTO sync_outbox (hlc, op_json, created_at) VALUES (?1, ?2, ?3)",
                params![hlc, op_json, now_ms()],
            )
            .db()?;
            Ok(())
        })
        .await
    }

    /// 取出最老的一批待推送操作。
    pub async fn pending_sync_ops(&self, limit: u32) -> Result<Vec<OutboxEntry>> {
        self.read(move |c| {
            let mut stmt = c
                .prepare_cached("SELECT hlc, op_json FROM sync_outbox ORDER BY hlc LIMIT ?1")
                .db()?;
            let rows = stmt
                .query_map(params![limit], |r| {
                    Ok(OutboxEntry {
                        hlc: r.get(0)?,
                        op_json: r.get(1)?,
                    })
                })
                .db()?;
            rows.collect::<rusqlite::Result<Vec<_>>>().db()
        })
        .await
    }

    /// 推送成功后删除这些操作。
    pub async fn ack_sync_ops(&self, hlcs: Vec<String>) -> Result<u64> {
        if hlcs.is_empty() {
            return Ok(0);
        }
        self.write(move |c| {
            let tx = c.transaction().db()?;
            let mut n = 0u64;
            {
                let mut stmt = tx.prepare("DELETE FROM sync_outbox WHERE hlc = ?1").db()?;
                for h in &hlcs {
                    n += stmt.execute(params![h]).db()? as u64;
                }
            }
            tx.commit().db()?;
            Ok(n)
        })
        .await
    }

    /// 读取某个通道对某台远端设备的读取游标（最后应用过的 HLC）。
    pub async fn sync_cursor(&self, channel: &str, device_id: &str) -> Result<Option<String>> {
        let channel = channel.to_string();
        let device_id = device_id.to_string();
        self.read(move |c| {
            let found: Option<String> = c
                .query_row(
                    "SELECT last_hlc FROM sync_cursor WHERE channel = ?1 AND device_id = ?2",
                    params![channel, device_id],
                    |r| r.get::<_, String>(0),
                )
                .optional()
                .db()?;
            Ok(found.filter(|s| !s.is_empty()))
        })
        .await
    }

    /// 记录某个通道对某台远端设备的读取游标。
    pub async fn set_sync_cursor(
        &self,
        channel: &str,
        device_id: &str,
        last_hlc: &str,
    ) -> Result<()> {
        let channel = channel.to_string();
        let device_id = device_id.to_string();
        let last_hlc = last_hlc.to_string();
        self.write(move |c| {
            c.execute(
                "INSERT INTO sync_cursor (channel, device_id, last_hlc) VALUES (?1, ?2, ?3)
                 ON CONFLICT (channel, device_id) DO UPDATE SET last_hlc = excluded.last_hlc",
                params![channel, device_id, last_hlc],
            )
            .db()?;
            Ok(())
        })
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::test_util::temp_library;

    #[tokio::test]
    async fn outbox_and_cursor_roundtrip() -> Result<()> {
        let lib = temp_library("sync-outbox")?;
        lib.enqueue_sync_op("0000000000000000001-00000000-a".into(), "{\"v\":1}".into())
            .await?;
        lib.enqueue_sync_op("0000000000000000002-00000000-a".into(), "{\"v\":2}".into())
            .await?;
        // 幂等
        lib.enqueue_sync_op("0000000000000000002-00000000-a".into(), "{\"v\":2}".into())
            .await?;

        let pending = lib.pending_sync_ops(10).await?;
        assert_eq!(pending.len(), 2);
        assert_eq!(pending[0].op_json, "{\"v\":1}");

        let n = lib.ack_sync_ops(vec![pending[0].hlc.clone()]).await?;
        assert_eq!(n, 1);
        assert_eq!(lib.pending_sync_ops(10).await?.len(), 1);

        assert_eq!(lib.sync_cursor("nas", "dev-b").await?, None);
        lib.set_sync_cursor("nas", "dev-b", "0000000000000000002-00000000-a")
            .await?;
        assert_eq!(
            lib.sync_cursor("nas", "dev-b").await?,
            Some("0000000000000000002-00000000-a".to_string())
        );
        Ok(())
    }
}
