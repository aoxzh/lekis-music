//! 全文搜索（LIB-07）。目标：10 万首曲目、每次按键 ≤ 50ms。
//!
//! `search_index` 里有三类行（track / album / artist），`keys` 列在入库时已经展开成
//! "原文 / 简体 / 全拼 / 首字母"，所以这里只要把用户输入做同样展开再 MATCH 即可。

use crate::browse::map_album_row;
use crate::db::DbResultExt;
use crate::normalize::fts_query;
use crate::tracks::map_track_row;
use crate::Library;
use lekis_types::{Result, SearchResults};
use rusqlite::params;

/// 分页上限，和 `TrackQuery::MAX_LIMIT` 保持一致。
const MAX_LIMIT: u32 = 500;

impl Library {
    /// 搜索。结果按类型分组，每组最多 `limit` 条。
    ///
    /// 三组查询在同一个只读连接上顺序执行，各自的 `ORDER BY bm25(...)` 用本组的索引行打分。
    pub async fn search(&self, text: &str, limit: u32) -> Result<SearchResults> {
        let Some(query) = fts_query(text) else {
            return Ok(SearchResults::default());
        };
        let limit = limit.clamp(1, MAX_LIMIT);
        self.read(move |c| {
            // 曲目。
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

            // 专辑。
            let mut stmt = c
                .prepare_cached(
                    "SELECT al.id, al.title, al.artist_line, al.year,
                            (SELECT COUNT(*) FROM track t WHERE t.album_id = al.id),
                            al.artwork_id, al.mbid_release,
                            (SELECT ar.hash FROM artwork ar WHERE ar.id = COALESCE(al.artwork_id,
                               (SELECT t2.artwork_id FROM track t2
                                 WHERE t2.album_id = al.id AND t2.artwork_id IS NOT NULL
                                 ORDER BY t2.disc_no, t2.track_no LIMIT 1)))
                     FROM search_index s
                     JOIN album al ON al.id = s.ref_id
                     WHERE s.kind = 'album' AND search_index MATCH ?1
                     ORDER BY bm25(search_index)
                     LIMIT ?2",
                )
                .db()?;
            let albums = stmt
                .query_map(params![query, limit], map_album_row)
                .db()?
                .collect::<rusqlite::Result<Vec<_>>>()
                .db()?;

            // 艺人。
            let mut stmt = c
                .prepare_cached(
                    "SELECT ar.id, ar.name, ar.sort_name, ar.aliases_json, ar.artwork_id, ar.mbid
                     FROM search_index s
                     JOIN artist ar ON ar.id = s.ref_id
                     WHERE s.kind = 'artist' AND search_index MATCH ?1
                     ORDER BY bm25(search_index)
                     LIMIT ?2",
                )
                .db()?;
            let artists = stmt
                .query_map(params![query, limit], crate::browse::map_artist_row)
                .db()?
                .collect::<rusqlite::Result<Vec<_>>>()
                .db()?;

            Ok(SearchResults {
                tracks,
                albums,
                artists,
            })
        })
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::test_util::temp_library;
    use crate::scanned::{ScannedFile, ScannedTags};
    use lekis_types::{SourceConfig, SourceKind};
    use std::collections::BTreeMap;

    #[tokio::test]
    async fn search_groups_tracks_albums_artists() -> Result<()> {
        let lib = temp_library("search-groups")?;
        let source = lib
            .add_source(SourceConfig {
                id: None,
                kind: SourceKind::Local,
                name: "local".into(),
                addresses: vec![],
                root_path: "/music".into(),
                credential_ref: None,
                options: BTreeMap::new(),
                enabled: true,
            })
            .await?;
        lib.upsert_scanned(vec![ScannedFile {
            source_id: source,
            path: "a/1.flac".into(),
            size: 1,
            mtime_ms: 1,
            tags: ScannedTags {
                title: "晴天".into(),
                artists: vec!["周杰伦".into()],
                album: Some("叶惠美".into()),
                ..Default::default()
            },
        }])
        .await?;

        let hits = lib.search("周杰伦", 10).await?;
        assert_eq!(hits.tracks.len(), 1);
        assert_eq!(hits.albums.len(), 1, "专辑按艺人行也进了索引");
        assert_eq!(hits.artists.len(), 1);
        assert_eq!(hits.artists[0].name, "周杰伦");

        let hits = lib.search("zjl", 10).await?;
        assert_eq!(hits.artists.len(), 1, "拼音首字母能搜到艺人");

        // 空查询返回空结果，不是报错。
        let none = lib.search("   ", 10).await?;
        assert!(none.tracks.is_empty() && none.albums.is_empty() && none.artists.is_empty());
        Ok(())
    }
}
