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
    (11, include_str!("../migrations/0011_podcast.sql")),
    (12, include_str!("../migrations/0012_remote_albums.sql")),
    (13, include_str!("../migrations/0013_perf_indexes.sql")),
    (14, include_str!("../migrations/0014_source_indexes.sql")),
    (15, include_str!("../migrations/0015_lyric_search.sql")),
];

pub(crate) fn run(conn: &mut Connection) -> Result<bool> {
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

    let mut applied = false;
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
        applied = true;
    }
    Ok(applied)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lyric_search_schema_upgrades_v14_and_preserves_selection() -> Result<()> {
        let mut conn = Connection::open_in_memory().db()?;
        conn.execute_batch("CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL)").db()?;
        for &(version, sql) in MIGRATIONS.iter().take_while(|(v, _)| *v <= 14) {
            conn.execute_batch(sql).db()?;
            conn.execute("INSERT INTO schema_migrations VALUES(?1,0)", [version])
                .db()?;
        }
        conn.execute_batch(
            "INSERT INTO track(uid,title,created_at,updated_at) VALUES('test','test',0,0);
            INSERT INTO lyrics(track_id,format,content,source,is_active,created_at) VALUES
            (1,'plain','chosen','manual',1,0),(1,'plain','previous','embedded',0,0);",
        )
        .db()?;
        assert!(run(&mut conn)?);
        assert!(!run(&mut conn)?);
        let version: i64 = conn
            .query_row("SELECT MAX(version) FROM schema_migrations", [], |row| {
                row.get(0)
            })
            .db()?;
        assert_eq!(version, 15);
        let selected: i64 = conn
            .query_row("SELECT id FROM lyrics WHERE selected_by_user=1", [], |r| {
                r.get(0)
            })
            .db()?;
        assert_eq!(selected, 1);
        conn.execute(
            "INSERT INTO lyric_recording(lyrics_id,artists) VALUES(1,'[]')",
            [],
        )
        .db()?;
        Ok(())
    }
}
