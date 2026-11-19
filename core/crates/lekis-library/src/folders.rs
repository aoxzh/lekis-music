//! 按文件夹浏览（LIB：browse by folder）。
//!
//! 目录结构不单独建表，直接从 `file.path`（相对源根目录、`/` 分隔）推出来：
//! 某个目录下的子文件夹 = 路径在它下面、还带一层 `/` 的文件的第一段；
//! 直属曲目 = 路径在它下面、不再带 `/` 的文件对应的曲目。
//!
//! 范围查询走 `file(source_id, path)` 的唯一索引：`dir/` 下的路径都满足
//! `'dir/' < path < 'dir0'`（`'0'` 是 `'/'` 的下一个字符）。

use crate::db::DbResultExt;
use crate::Library;
use lekis_types::{LekisError, Result, SourceId, TrackId, TrackQuery, TrackRow};
use rusqlite::params;
use std::collections::{BTreeMap, HashSet};

/// 一个可以按文件夹浏览的音源（文件夹视图的第一层）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FolderRoot {
    pub source_id: SourceId,
    /// 音源名。
    pub name: String,
    /// 音源下的曲目数（去重）。
    pub track_count: u32,
}

/// 一个子文件夹。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FolderEntry {
    /// 文件夹名（路径最后一段）。
    pub name: String,
    /// 相对源根目录的完整路径，用来继续往下浏览。
    pub path: String,
    /// 子树里的曲目数（去重，含更深的子文件夹）。
    pub track_count: u32,
}

/// 一个目录的内容：子文件夹（按名字排序）+ 直属曲目数。
///
/// 直属曲目本身用 [`Library::folder_tracks`] 分页取。
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct FolderListing {
    pub folders: Vec<FolderEntry>,
    pub track_count: u32,
}

/// 规范化浏览路径：去掉首尾 / 重复分隔符和 `.`，统一成 `/`；含 `..` 时报错。
pub fn normalize_folder_path(path: &str) -> Result<String> {
    let mut parts = Vec::new();
    for part in path.split(['/', '\\']) {
        match part {
            "" | "." => continue,
            ".." => return Err(LekisError::invalid("folder path must not contain '..'")),
            p => parts.push(p),
        }
    }
    Ok(parts.join("/"))
}

/// `dir` 子树的路径范围（开区间）和前缀。根目录是整个源。
fn subtree_bounds(dir: &str) -> (String, String, String) {
    if dir.is_empty() {
        (String::new(), String::new(), char::MAX.to_string())
    } else {
        let prefix = format!("{dir}/");
        (prefix.clone(), prefix, format!("{dir}0"))
    }
}

/// 自然排序用的比较：忽略大小写，数字段按数值比（"Disc 2" < "Disc 10"）。
fn natural_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    let (mut ia, mut ib) = (a.chars().peekable(), b.chars().peekable());
    loop {
        match (ia.peek().copied(), ib.peek().copied()) {
            (None, None) => return a.cmp(b),
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(ca), Some(cb)) if ca.is_ascii_digit() && cb.is_ascii_digit() => {
                let mut na = String::new();
                while let Some(c) = ia.peek().copied().filter(char::is_ascii_digit) {
                    na.push(c);
                    ia.next();
                }
                let mut nb = String::new();
                while let Some(c) = ib.peek().copied().filter(char::is_ascii_digit) {
                    nb.push(c);
                    ib.next();
                }
                let (ta, tb) = (na.trim_start_matches('0'), nb.trim_start_matches('0'));
                let ord = ta.len().cmp(&tb.len()).then_with(|| ta.cmp(tb));
                if ord != Ordering::Equal {
                    return ord;
                }
            }
            (Some(ca), Some(cb)) => {
                let ord = ca.to_lowercase().cmp(cb.to_lowercase());
                if ord != Ordering::Equal {
                    return ord;
                }
                ia.next();
                ib.next();
            }
        }
    }
}

impl Library {
    /// 文件夹视图的第一层：有曲目的音源。
    pub async fn folder_roots(&self) -> Result<Vec<FolderRoot>> {
        self.read(|c| {
            let mut stmt = c
                .prepare_cached(
                    "SELECT s.id, s.name, COUNT(DISTINCT tf.track_id)
                     FROM source s
                     JOIN file f ON f.source_id = s.id
                     JOIN track_file tf ON tf.file_id = f.id
                     GROUP BY s.id
                     ORDER BY s.name COLLATE NOCASE, s.id",
                )
                .db()?;
            let rows = stmt
                .query_map([], |r| {
                    Ok(FolderRoot {
                        source_id: SourceId(r.get(0)?),
                        name: r.get(1)?,
                        track_count: r.get::<_, i64>(2)?.max(0) as u32,
                    })
                })
                .db()?;
            rows.collect::<rusqlite::Result<Vec<_>>>().db()
        })
        .await
    }

    /// 列出 `source` 下目录 `path`（`""` = 源根目录）的子文件夹和直属曲目数。
    pub async fn list_folder(&self, source: SourceId, path: &str) -> Result<FolderListing> {
        let dir = normalize_folder_path(path)?;
        let (prefix, lo, hi) = subtree_bounds(&dir);
        self.read(move |c| {
            let mut stmt = c
                .prepare_cached(
                    "SELECT f.path, tf.track_id
                     FROM file f JOIN track_file tf ON tf.file_id = f.id
                     WHERE f.source_id = ?1 AND f.path > ?2 AND f.path < ?3",
                )
                .db()?;
            let rows = stmt
                .query_map(params![source.0, lo, hi], |r| {
                    Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?))
                })
                .db()?;
            let mut children: BTreeMap<String, HashSet<i64>> = BTreeMap::new();
            let mut direct: HashSet<i64> = HashSet::new();
            for row in rows {
                let (file_path, track) = row.db()?;
                let Some(rest) = file_path.strip_prefix(&prefix) else {
                    continue;
                };
                match rest.split_once('/') {
                    Some((child, _)) if !child.is_empty() => {
                        children.entry(child.to_string()).or_default().insert(track);
                    }
                    Some(_) => {}
                    None => {
                        direct.insert(track);
                    }
                }
            }
            let mut folders: Vec<FolderEntry> = children
                .into_iter()
                .map(|(name, tracks)| FolderEntry {
                    path: if dir.is_empty() {
                        name.clone()
                    } else {
                        format!("{dir}/{name}")
                    },
                    name,
                    track_count: tracks.len() as u32,
                })
                .collect();
            folders.sort_by(|a, b| natural_cmp(&a.name, &b.name));
            Ok(FolderListing {
                folders,
                track_count: direct.len() as u32,
            })
        })
        .await
    }

    /// 目录 `path` 的直属曲目（不含子文件夹），按文件名排序，分页。
    pub async fn folder_tracks(
        &self,
        source: SourceId,
        path: &str,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<TrackRow>> {
        if limit == 0 || limit > TrackQuery::MAX_LIMIT {
            return Err(LekisError::invalid(format!(
                "limit must be 1..={}",
                TrackQuery::MAX_LIMIT
            )));
        }
        let dir = normalize_folder_path(path)?;
        let (prefix, lo, hi) = subtree_bounds(&dir);
        // SQLite 的 substr 按字符计数（1 起），不是字节。
        let rest_from = prefix.chars().count() as i64 + 1;
        let sql = format!(
            "SELECT {}
             FROM track t
             JOIN track_file tf ON tf.track_id = t.id
             JOIN file f ON f.id = tf.file_id
             LEFT JOIN album a ON a.id = t.album_id
             LEFT JOIN user_state u ON u.track_uid = t.uid
             WHERE f.source_id = ?1 AND f.path > ?2 AND f.path < ?3
               AND instr(substr(f.path, ?4), '/') = 0
             GROUP BY t.id
             ORDER BY MIN(f.path), t.id
             LIMIT ?5 OFFSET ?6",
            crate::tracks::TRACK_ROW_COLUMNS
        );
        self.read(move |c| {
            let mut stmt = c.prepare_cached(&sql).db()?;
            let rows = stmt
                .query_map(
                    params![source.0, lo, hi, rest_from, limit, offset],
                    crate::tracks::map_track_row,
                )
                .db()?;
            rows.collect::<rusqlite::Result<Vec<_>>>().db()
        })
        .await
    }

    /// 目录的全部直属曲目 ID（`TrackContext::Folder` 用）。
    pub(crate) async fn folder_track_ids(
        &self,
        source: SourceId,
        path: &str,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<TrackId>> {
        Ok(self
            .folder_tracks(source, path, offset, limit)
            .await?
            .into_iter()
            .map(|r| r.id)
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::test_util::temp_library;
    use crate::scanned::{ScannedFile, ScannedTags};
    use crate::TrackContext;
    use lekis_types::{SourceConfig, SourceKind};
    use std::collections::BTreeMap;

    async fn source(lib: &Library, name: &str) -> Result<SourceId> {
        lib.add_source(SourceConfig {
            id: None,
            kind: SourceKind::Local,
            name: name.into(),
            addresses: vec![],
            root_path: format!("/{name}"),
            credential_ref: None,
            options: BTreeMap::new(),
            enabled: true,
        })
        .await
    }

    fn file(source: SourceId, path: &str, title: &str) -> ScannedFile {
        ScannedFile {
            source_id: source,
            path: path.into(),
            size: 1_000,
            mtime_ms: 1,
            tags: ScannedTags {
                title: title.into(),
                artists: vec!["someone".into()],
                album: Some(path.rsplit_once('/').map_or("root", |p| p.0).into()),
                ..Default::default()
            },
        }
    }

    #[test]
    fn normalizes_paths() {
        assert_eq!(normalize_folder_path("").unwrap(), "");
        assert_eq!(normalize_folder_path("/a//b/./").unwrap(), "a/b");
        assert_eq!(normalize_folder_path("a\\b").unwrap(), "a/b");
        assert!(normalize_folder_path("a/../b").is_err());
    }

    #[test]
    fn natural_order() {
        let mut v = vec!["Disc 10", "disc 2", "Disc 1", "b", "A"];
        v.sort_by(|a, b| natural_cmp(a, b));
        assert_eq!(v, ["A", "b", "Disc 1", "disc 2", "Disc 10"]);
    }

    #[tokio::test]
    async fn browse_folders() -> Result<()> {
        let lib = temp_library("folders")?;
        let src = source(&lib, "music").await?;
        let other = source(&lib, "other").await?;
        lib.upsert_scanned(vec![
            file(src, "loose.flac", "Loose"),
            file(src, "Artist/Album 10/02 b.flac", "B"),
            file(src, "Artist/Album 10/01 a.flac", "A"),
            file(src, "Artist/Album 2/01 c.flac", "C"),
            file(src, "Artist/single.flac", "Single"),
            // A sibling whose name shares the prefix must not leak in.
            file(src, "Artist2/x.flac", "X"),
            file(other, "Artist/y.flac", "Y"),
        ])
        .await?;

        let roots = lib.folder_roots().await?;
        assert_eq!(
            roots.iter().map(|r| (r.name.as_str(), r.track_count)).collect::<Vec<_>>(),
            [("music", 6), ("other", 1)]
        );

        let root = lib.list_folder(src, "").await?;
        assert_eq!(
            root.folders
                .iter()
                .map(|f| (f.name.as_str(), f.path.as_str(), f.track_count))
                .collect::<Vec<_>>(),
            [("Artist", "Artist", 4), ("Artist2", "Artist2", 1)]
        );
        assert_eq!(root.track_count, 1);

        let artist = lib.list_folder(src, "/Artist/").await?;
        assert_eq!(
            artist.folders.iter().map(|f| f.path.as_str()).collect::<Vec<_>>(),
            ["Artist/Album 2", "Artist/Album 10"]
        );
        assert_eq!(artist.track_count, 1);

        let tracks = lib.folder_tracks(src, "Artist/Album 10", 0, 50).await?;
        assert_eq!(
            tracks.iter().map(|t| t.title.as_str()).collect::<Vec<_>>(),
            ["A", "B"]
        );
        let page = lib.folder_tracks(src, "Artist/Album 10", 1, 1).await?;
        assert_eq!(page.len(), 1);
        assert_eq!(page[0].title, "B");

        let top = lib.folder_tracks(src, "", 0, 50).await?;
        assert_eq!(
            top.iter().map(|t| t.title.as_str()).collect::<Vec<_>>(),
            ["Loose"]
        );

        let ids = lib
            .context_track_ids(TrackContext::Folder {
                source_id: src,
                path: "Artist/Album 10".into(),
            })
            .await?;
        assert_eq!(ids.len(), 2);
        assert_eq!(ids[0], Some(tracks[0].id));

        assert!(lib.list_folder(src, "Nope").await?.folders.is_empty());
        assert!(lib.folder_tracks(src, "..", 0, 10).await.is_err());
        Ok(())
    }
}
