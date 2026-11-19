//! 键值设置（SET-01~04）。
//!
//! 设置项分两类：
//! - **本机设置**：只影响这台设备（输出设备、缓存上限……），不同步；
//! - **同步设置**：跟着账号走（音量均衡、主题、排序偏好……），写 `sync_outbox` 由 lekis-core 负责。
//!
//! 这里只提供最低层的 KV 读写，语义和默认值由 `lekis-core` / 平台层决定。

use crate::db::DbResultExt;
use crate::Library;
use lekis_types::Result;
use rusqlite::{params, OptionalExtension};

impl Library {
    /// 读一个设置项（不存在返回 `None`）。
    pub async fn get_setting(&self, key: &str) -> Result<Option<String>> {
        let key = key.to_string();
        self.read(move |c| {
            c.query_row("SELECT value FROM kv WHERE key = ?1", params![key], |r| {
                r.get::<_, String>(0)
            })
            .optional()
            .db()
        })
        .await
    }

    /// 写一个设置项。
    pub async fn set_setting(&self, key: &str, value: &str) -> Result<()> {
        let key = key.to_string();
        let value = value.to_string();
        self.write(move |c| {
            c.execute(
                "INSERT INTO kv (key, value) VALUES (?1, ?2)
                 ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                params![key, value],
            )
            .db()?;
            Ok(())
        })
        .await
    }

    /// 删除一个设置项。
    pub async fn delete_setting(&self, key: &str) -> Result<()> {
        let key = key.to_string();
        self.write(move |c| {
            c.execute("DELETE FROM kv WHERE key = ?1", params![key])
                .db()?;
            Ok(())
        })
        .await
    }

    /// 列出某个前缀下的所有设置项（按键排序）。
    pub async fn settings_with_prefix(&self, prefix: &str) -> Result<Vec<(String, String)>> {
        let pattern = format!("{prefix}%");
        self.read(move |c| {
            let mut stmt = c
                .prepare_cached("SELECT key, value FROM kv WHERE key LIKE ?1 ORDER BY key")
                .db()?;
            let rows = stmt
                .query_map(params![pattern], |r| {
                    Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
                })
                .db()?;
            rows.collect::<rusqlite::Result<Vec<_>>>().db()
        })
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::test_util::temp_library;

    #[tokio::test]
    async fn settings_roundtrip() -> Result<()> {
        let lib = temp_library("settings")?;
        assert_eq!(lib.get_setting("ui.theme").await?, None);
        lib.set_setting("ui.theme", "dark").await?;
        assert_eq!(lib.get_setting("ui.theme").await?, Some("dark".into()));
        // 重复写是更新，不是新增。
        lib.set_setting("ui.theme", "light").await?;
        assert_eq!(lib.get_setting("ui.theme").await?, Some("light".into()));

        lib.set_setting("ui.sort", "album").await?;
        lib.set_setting("audio.device", "wasapi").await?;
        let ui = lib.settings_with_prefix("ui.").await?;
        assert_eq!(
            ui,
            vec![
                ("ui.sort".to_string(), "album".to_string()),
                ("ui.theme".to_string(), "light".to_string()),
            ]
        );

        lib.delete_setting("ui.theme").await?;
        assert_eq!(lib.get_setting("ui.theme").await?, None);
        Ok(())
    }
}
