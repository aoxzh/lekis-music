//! 迁移执行器。新增迁移：在 `migrations/` 下加文件，并在 [`MIGRATIONS`] 末尾追加一行。

use crate::db::DbResultExt;
use lekis_types::{now_ms, Result};
use rusqlite::Connection;

/// 所有迁移（版本号严格递增，已合入的不能修改）。
const MIGRATIONS: &[(i64, &str)] = &[
    (1, include_str!("../migrations/0001_init.sql")),
    (
        2,
        include_str!("../migrations/0002_remote_track_unique.sql"),
    ),
    (3, include_str!("../migrations/0003_source_scan_error.sql")),
    (4, include_str!("../migrations/0004_search_index_rowid.sql")),
    (
        5,
        include_str!("../migrations/0005_local_track_file_unique.sql"),
    ),
    (6, include_str!("../migrations/0006_playback_state.sql")),
    (7, include_str!("../migrations/0007_offline_download.sql")),
    (8, include_str!("../migrations/0008_library_health.sql")),
    (
        9,
        include_str!("../migrations/0009_track_tag_overrides.sql"),
    ),
    (10, include_str!("../migrations/0010_radio_station.sql")),
];

pub(crate) fn run(conn: &mut Connection) -> Result<()> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS schema_migrations (
           version    INTEGER PRIMARY KEY,
           applied_at INTEGER NOT NULL
         );",
    )
    .db()?;

    let current: i64 = conn
        .query_row(
            "SELECT COALESCE(MAX(version), 0) FROM schema_migrations",
            [],
            |r| r.get(0),
        )
        .db()?;

    for (version, sql) in MIGRATIONS.iter().filter(|(v, _)| *v > current) {
        tracing::info!(target: "library", version, "applying migration");
        let tx = conn.transaction().db()?;
        tx.execute_batch(sql).db()?;
        tx.execute(
            "INSERT INTO schema_migrations (version, applied_at) VALUES (?1, ?2)",
            (version, now_ms()),
        )
        .db()?;
        tx.commit().db()?;
    }
    Ok(())
}
