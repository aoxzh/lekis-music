//! 全文搜索（LIB-07）。目标：10 万首曲目、每次按键 ≤ 50ms。

use crate::db::DbResultExt;
use crate::normalize::fts_query;
use crate::tracks::map_track_row;
use crate::Library;
use lekis_types::{Result, SearchResults};
use rusqlite::params;

impl Library {
    /// 搜索。结果按类型分组，每组最多 `limit` 条。
    ///
    /// TODO：专辑和艺人分组（search_index 里 kind = album / artist 的行，入库时还没写）。
    pub async fn search(&self, text: &str, limit: u32) -> Result<SearchResults> {
        let Some(query) = fts_query(text) else {
            return Ok(SearchResults::default());
        };
        self.read(move |c| {
            let mut stmt = c
                .prepare_cached(
                    "SELECT t.id, t.title, t.artist_line, a.title, t.duration_ms, t.artwork_id,
                            t.quality_badge, COALESCE(u.loved, 0)
                     FROM search_index s
                     JOIN track t ON t.id = s.ref_id
                     LEFT JOIN album a ON a.id = t.album_id
                     LEFT JOIN user_state u ON u.track_uid = t.uid
                     WHERE s.kind = 'track' AND search_index MATCH ?1
                     ORDER BY bm25(search_index)
                     LIMIT ?2",
                )
                .db()?;
            let tracks = stmt
                .query_map(params![query, limit], map_track_row)
                .db()?
                .collect::<rusqlite::Result<Vec<_>>>()
                .db()?;
            Ok(SearchResults {
                tracks,
                ..Default::default()
            })
        })
        .await
    }
}
