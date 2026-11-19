//! 歌单（PL-01、PL-05）。
//!
//! 表结构见 `migrations/0001_init.sql` 的 `playlist` / `playlist_item`，这里只做读写，不建表：
//! - 歌单用 `uid`（UUIDv7 文本形式）跨设备标识，本机自增 `id` 只在本地有意义；
//! - 条目顺序由 `position_key` 决定（[`crate::position`] 的分数索引），拖动排序只改一条，
//!   多台设备同时改也不会把整个列表重排；
//! - 条目按 `track_uid` 引用曲目，找不到对应曲目时显示占位（PL-05），所以
//!   [`Library::playlist_items`] 用 LEFT JOIN，[`PlaylistEntry::track`] 是 `Option<TrackRow>`；
//! - 删除写墓碑（`deleted = 1`）而不是物理删，同步时才知道"这个歌单被删了"。

use crate::db::DbResultExt;
use crate::position::key_between;
use crate::tracks::{map_track_row, TRACK_ROW_COLUMNS};
use crate::Library;
use lekis_types::{
    now_ms, ArtworkId, LekisError, PlaylistId, Result, TrackQuery, TrackRow, TrackUid,
};
use rusqlite::{params, OptionalExtension, Row, Transaction};

/// 分页上限，和 `TrackQuery::MAX_LIMIT` 保持一致。
const MAX_LIMIT: u32 = TrackQuery::MAX_LIMIT;

const PLAYLIST_COLUMNS: &str = "p.id, p.uid, p.name, p.kind, p.folder_uid, p.artwork_id,
     (SELECT COUNT(*) FROM playlist_item pi WHERE pi.playlist_id = p.id),
     p.created_at, p.updated_at";

pub(crate) fn check_limit(limit: u32) -> Result<()> {
    if limit == 0 || limit > MAX_LIMIT {
        return Err(LekisError::invalid(format!(
            "limit must be 1..={MAX_LIMIT}"
        )));
    }
    Ok(())
}

/// 歌单类型。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum PlaylistKind {
    /// 普通歌单：条目手动增删、手动排序。
    #[default]
    Static,
    /// 智能歌单：条目由 `rules_json` 里的规则实时求值（求值器尚未实现）。
    Smart,
}

impl PlaylistKind {
    /// 数据库里存的字符串（snake_case）。
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Static => "static",
            Self::Smart => "smart",
        }
    }

    /// 未知值按 `static` 处理（向前兼容：以后加新类型时旧版本不会报错）。
    fn from_db(value: &str) -> Self {
        match value {
            "smart" => Self::Smart,
            _ => Self::Static,
        }
    }
}

/// 一个歌单。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Playlist {
    /// 本机 ID。
    pub id: PlaylistId,
    /// 跨设备稳定 ID（UUIDv7 文本形式）。
    pub uid: String,
    /// 显示名称。
    pub name: String,
    /// 类型。
    pub kind: PlaylistKind,
    /// 所属文件夹的 `uid`（`None` 表示在根目录）。
    pub folder_uid: Option<String>,
    /// 自定义封面。
    pub artwork_id: Option<ArtworkId>,
    /// 条目数（包括找不到曲目的占位条目）。
    pub track_count: u32,
    /// 创建时间（Unix 毫秒）。
    pub created_at: i64,
    /// 最后修改时间（Unix 毫秒）。
    pub updated_at: i64,
}

/// 歌单里的一个条目（不含曲目信息）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlaylistItem {
    /// 曲目的跨设备稳定 ID。
    pub track_uid: String,
    /// 位置键：按字典序排序就是歌单顺序。
    pub position_key: String,
    /// 加入时间（Unix 毫秒）。
    pub added_at: i64,
}

/// 歌单里的一个条目，附带曲目信息（列表页直接渲染用）。
#[derive(Debug, Clone, PartialEq)]
pub struct PlaylistEntry {
    /// 条目本身（位置键、加入时间）。
    pub item: PlaylistItem,
    /// 对应的曲目；资料库里找不到时为 `None`，UI 显示占位（PL-05）。
    pub track: Option<TrackRow>,
}

fn map_playlist_row(r: &Row<'_>) -> rusqlite::Result<Playlist> {
    let kind: String = r.get(3)?;
    Ok(Playlist {
        id: PlaylistId(r.get(0)?),
        uid: r.get(1)?,
        name: r.get(2)?,
        kind: PlaylistKind::from_db(&kind),
        folder_uid: r.get(4)?,
        artwork_id: r.get::<_, Option<i64>>(5)?.map(ArtworkId),
        track_count: r.get::<_, i64>(6)?.max(0) as u32,
        created_at: r.get(7)?,
        updated_at: r.get(8)?,
    })
}

impl Library {
    /// 新建一个普通歌单，返回它的本机 ID。
    ///
    /// `uid` 是跨设备稳定 ID（UUIDv7 文本形式）；传 `None` 时由本机生成一个。
    /// 名字会去掉首尾空白；空名字、或者 `uid` 已被别的歌单（含墓碑）占用时返回
    /// [`LekisError::invalid`]。
    pub async fn create_playlist(&self, name: &str, uid: Option<String>) -> Result<PlaylistId> {
        let name = name.trim().to_string();
        if name.is_empty() {
            return Err(LekisError::invalid("playlist name must not be empty"));
        }
        let uid = uid.unwrap_or_else(new_playlist_uid);
        self.write(move |conn| {
            let tx = conn.transaction().db()?;
            let taken: Option<i64> = tx
                .query_row(
                    "SELECT id FROM playlist WHERE uid = ?1",
                    params![uid],
                    |r| r.get(0),
                )
                .optional()
                .db()?;
            if taken.is_some() {
                // 墓碑行的 uid 也算占用：uid 是跨设备身份，不能复用。
                return Err(LekisError::invalid(format!(
                    "playlist uid {uid} already exists"
                )));
            }
            let now = now_ms();
            tx.execute(
                "INSERT INTO playlist (uid, name, kind, created_at, updated_at)
                 VALUES (?1, ?2, 'static', ?3, ?3)",
                params![uid, name, now],
            )
            .db()?;
            let id = PlaylistId(tx.last_insert_rowid());
            tx.commit().db()?;
            Ok(id)
        })
        .await
    }

    /// 改名。歌单不存在（或已写墓碑）返回 [`LekisError::not_found`]。
    pub async fn rename_playlist(&self, id: PlaylistId, name: &str) -> Result<()> {
        let name = name.trim().to_string();
        if name.is_empty() {
            return Err(LekisError::invalid("playlist name must not be empty"));
        }
        self.write(move |conn| {
            let now = now_ms();
            let n = conn
                .execute(
                    "UPDATE playlist SET name = ?2, updated_at = ?3
                     WHERE id = ?1 AND deleted = 0",
                    params![id.0, name, now],
                )
                .db()?;
            if n == 0 {
                return Err(not_found(id));
            }
            Ok(())
        })
        .await
    }

    /// 设置 / 清除自定义封面。歌单不存在返回 [`LekisError::not_found`]。
    pub async fn set_playlist_artwork(
        &self,
        id: PlaylistId,
        artwork_id: Option<ArtworkId>,
    ) -> Result<()> {
        self.write(move |conn| {
            let now = now_ms();
            let n = conn
                .execute(
                    "UPDATE playlist SET artwork_id = ?2, updated_at = ?3
                     WHERE id = ?1 AND deleted = 0",
                    params![id.0, artwork_id.map(|a| a.0), now],
                )
                .db()?;
            if n == 0 {
                return Err(not_found(id));
            }
            Ok(())
        })
        .await
    }

    /// 删除歌单：写墓碑（`deleted = 1`），条目不物理删。
    ///
    /// 已经删过的歌单再次删除返回 [`LekisError::not_found`] —— 重复删除没有意义，
    /// 让调用方的 bug 早点暴露出来。
    pub async fn delete_playlist(&self, id: PlaylistId) -> Result<()> {
        self.write(move |conn| {
            let now = now_ms();
            let n = conn
                .execute(
                    "UPDATE playlist SET deleted = 1, updated_at = ?2
                     WHERE id = ?1 AND deleted = 0",
                    params![id.0, now],
                )
                .db()?;
            if n == 0 {
                return Err(not_found(id));
            }
            Ok(())
        })
        .await
    }

    /// 列出所有歌单（不含墓碑），按名称排序。
    pub async fn list_playlists(&self) -> Result<Vec<Playlist>> {
        let sql = format!(
            "SELECT {PLAYLIST_COLUMNS} FROM playlist p
             WHERE p.deleted = 0
             ORDER BY p.name COLLATE NOCASE, p.id"
        );
        self.read(move |c| {
            let mut stmt = c.prepare_cached(&sql).db()?;
            let rows = stmt.query_map([], map_playlist_row).db()?;
            rows.collect::<rusqlite::Result<Vec<_>>>().db()
        })
        .await
    }

    /// 取一个歌单。不存在或者已删除返回 [`LekisError::not_found`]。
    pub async fn get_playlist(&self, id: PlaylistId) -> Result<Playlist> {
        let sql =
            format!("SELECT {PLAYLIST_COLUMNS} FROM playlist p WHERE p.id = ?1 AND p.deleted = 0");
        self.read(move |c| {
            c.query_row(&sql, params![id.0], map_playlist_row)
                .optional()
                .db()?
                .ok_or_else(|| not_found(id))
        })
        .await
    }

    /// 分页取歌单条目（按位置键排序），顺带 JOIN 出曲目信息。
    ///
    /// 找不到曲目的条目照样返回，`track` 为 `None`（PL-05 占位）。
    /// `limit` 必须在 `1..=TrackQuery::MAX_LIMIT`，否则返回 [`LekisError::invalid`]。
    pub async fn playlist_items(
        &self,
        id: PlaylistId,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<PlaylistEntry>> {
        check_limit(limit)?;
        let sql = format!(
            "SELECT {TRACK_ROW_COLUMNS}, pi.track_uid, pi.position_key, pi.added_at
             FROM playlist_item pi
             LEFT JOIN track t ON t.uid = pi.track_uid
             LEFT JOIN album a ON a.id = t.album_id
             LEFT JOIN user_state u ON u.track_uid = t.uid
             WHERE pi.playlist_id = ?1
             ORDER BY pi.position_key
             LIMIT ?2 OFFSET ?3"
        );
        self.read(move |c| {
            ensure_playlist(c, id)?;
            let mut stmt = c.prepare_cached(&sql).db()?;
            let rows = stmt
                .query_map(params![id.0, limit, offset], |r| {
                    // 第 0 列是 t.id：LEFT JOIN 没命中时是 NULL。
                    let track_id: Option<i64> = r.get(0)?;
                    let item = PlaylistItem {
                        track_uid: r.get(8)?,
                        position_key: r.get(9)?,
                        added_at: r.get(10)?,
                    };
                    let track = match track_id {
                        Some(_) => Some(map_track_row(r)?),
                        None => None,
                    };
                    Ok(PlaylistEntry { item, track })
                })
                .db()?;
            rows.collect::<rusqlite::Result<Vec<_>>>().db()
        })
        .await
    }

    /// 往歌单里加一首歌，返回新条目的位置键。
    ///
    /// `before_key` 是插入点**前**一个条目的位置键，`after_key` 是**后**一个条目的位置键：
    /// - 都为 `None`：追加到末尾（先查当前最后一个键，再生成一个更大的）；
    /// - 只有 `after_key`：插到最前面；
    /// - 只有 `before_key`：插到它后面；
    /// - 都有：夹在两者之间。
    ///
    /// 歌单不存在（或已删除）返回 [`LekisError::not_found`]。
    pub async fn add_to_playlist(
        &self,
        id: PlaylistId,
        track_uid: TrackUid,
        before_key: Option<&str>,
        after_key: Option<&str>,
    ) -> Result<String> {
        let before = before_key.map(str::to_string);
        let after = after_key.map(str::to_string);
        let track_uid = track_uid.0;
        self.write(move |conn| {
            let tx = conn.transaction().db()?;
            let now = now_ms();
            ensure_playlist(&tx, id)?;
            let key = insert_position(&tx, id, before.as_deref(), after.as_deref())?;
            tx.execute(
                "INSERT INTO playlist_item (playlist_id, position_key, track_uid, added_at)
                 VALUES (?1, ?2, ?3, ?4)",
                params![id.0, &key, &track_uid, now],
            )
            .db()?;
            touch(&tx, id, now)?;
            tx.commit().db()?;
            Ok(key)
        })
        .await
    }

    /// 按位置键删掉一个条目。
    ///
    /// 歌单或条目不存在返回 [`LekisError::not_found`]。
    pub async fn remove_from_playlist(&self, id: PlaylistId, position_key: &str) -> Result<()> {
        let key = position_key.to_string();
        self.write(move |conn| {
            let tx = conn.transaction().db()?;
            let now = now_ms();
            ensure_playlist(&tx, id)?;
            let n = tx
                .execute(
                    "DELETE FROM playlist_item WHERE playlist_id = ?1 AND position_key = ?2",
                    params![id.0, key],
                )
                .db()?;
            if n == 0 {
                return Err(LekisError::not_found(format!(
                    "playlist item {key} in playlist {id}"
                )));
            }
            touch(&tx, id, now)?;
            tx.commit().db()?;
            Ok(())
        })
        .await
    }

    /// 把条目挪到 `before_key` 和 `after_key` 之间（参数语义同 [`Self::add_to_playlist`]）。
    ///
    /// 拖动排序、拖到列表末尾都用它。歌单或条目不存在返回 [`LekisError::not_found`]。
    pub async fn move_playlist_item(
        &self,
        id: PlaylistId,
        position_key: &str,
        before_key: Option<&str>,
        after_key: Option<&str>,
    ) -> Result<()> {
        let old = position_key.to_string();
        let before = before_key.map(str::to_string);
        let after = after_key.map(str::to_string);
        self.write(move |conn| {
            let tx = conn.transaction().db()?;
            let now = now_ms();
            ensure_playlist(&tx, id)?;
            let exists: Option<i64> = tx
                .query_row(
                    "SELECT 1 FROM playlist_item WHERE playlist_id = ?1 AND position_key = ?2",
                    params![id.0, old],
                    |r| r.get(0),
                )
                .optional()
                .db()?;
            if exists.is_none() {
                return Err(LekisError::not_found(format!(
                    "playlist item {old} in playlist {id}"
                )));
            }
            let new_key = insert_position(&tx, id, before.as_deref(), after.as_deref())?;
            tx.execute(
                "UPDATE playlist_item SET position_key = ?3
                 WHERE playlist_id = ?1 AND position_key = ?2",
                params![id.0, &old, &new_key],
            )
            .db()?;
            touch(&tx, id, now)?;
            tx.commit().db()?;
            Ok(())
        })
        .await
    }
}

/// 生成一个排在 `before` / `after` 之间的新位置键（都为空时追加到末尾）。
fn insert_position(
    tx: &Transaction<'_>,
    id: PlaylistId,
    before: Option<&str>,
    after: Option<&str>,
) -> Result<String> {
    if before.is_some() || after.is_some() {
        return Ok(key_between(before, after));
    }
    // 追加到末尾：先取当前最后一个位置键。
    let last: Option<String> = tx
        .query_row(
            "SELECT position_key FROM playlist_item WHERE playlist_id = ?1
             ORDER BY position_key DESC LIMIT 1",
            params![id.0],
            |r| r.get(0),
        )
        .optional()
        .db()?;
    Ok(key_between(last.as_deref(), None))
}

/// 确认歌单存在且没被写墓碑（读写都先过这一关，错误语义才一致）。
fn ensure_playlist(conn: &rusqlite::Connection, id: PlaylistId) -> Result<()> {
    let alive: Option<i64> = conn
        .query_row(
            "SELECT id FROM playlist WHERE id = ?1 AND deleted = 0",
            params![id.0],
            |r| r.get(0),
        )
        .optional()
        .db()?;
    match alive {
        Some(_) => Ok(()),
        None => Err(not_found(id)),
    }
}

/// 写操作统一刷新 `updated_at`（同步时用来判断这个歌单变没变）。
fn touch(tx: &Transaction<'_>, id: PlaylistId, now: i64) -> Result<()> {
    tx.execute(
        "UPDATE playlist SET updated_at = ?2 WHERE id = ?1",
        params![id.0, now],
    )
    .db()?;
    Ok(())
}

fn not_found(id: PlaylistId) -> LekisError {
    LekisError::not_found(format!("playlist {id}"))
}

/// 生成歌单的跨设备稳定 ID（UUIDv7 文本形式）。
///
/// `lekis-library` 不依赖 `uuid` / `rand`（这个 crate 的依赖越少越好），所以用
/// `RandomState` 的随机种子做熵源：48 位毫秒时间戳 + 72 位随机数，按 v7 的位布局拼出来。
/// 只在新建歌单时调用一次，之后一直存在数据库里。
pub(crate) fn new_playlist_uid() -> String {
    use std::collections::hash_map::RandomState;
    use std::hash::{BuildHasher, Hasher};

    fn random(seed: u64) -> u64 {
        let mut h = RandomState::new().build_hasher();
        h.write_u64(seed);
        h.finish()
    }

    let ts = now_ms().max(0) as u64;
    let r1 = random(1);
    let r2 = random(2);
    let r3 = random(3);
    format!(
        "{:08x}-{:04x}-7{:03x}-{:04x}-{:012x}",
        (ts >> 16) as u32,
        ts & 0xffff,
        (r1 >> 52) as u16 & 0x0fff,
        0x8000 | ((r2 >> 52) as u16 & 0x3fff),
        r3 & 0xffff_ffff_ffff
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::test_util::temp_library;
    use lekis_types::ErrorCode;

    /// 直接写一行 `track`（列表 JOIN 需要真实曲目；只填非空列）。
    async fn add_track(lib: &Library, uid: &str, title: &str) -> Result<()> {
        let uid = uid.to_string();
        let title = title.to_string();
        lib.write(move |c| {
            let now = now_ms();
            c.execute(
                "INSERT INTO track (uid, title, created_at, updated_at) VALUES (?1, ?2, ?3, ?3)",
                params![uid, title, now],
            )
            .db()?;
            Ok(())
        })
        .await
    }

    /// 错误的错误码（不是错误时返回 `None`，交给 assert 报错）。
    fn err_code<T>(result: Result<T>) -> Option<ErrorCode> {
        result.err().map(|e| e.code)
    }

    fn titles(items: &[PlaylistEntry]) -> Vec<String> {
        items
            .iter()
            .map(|e| match &e.track {
                Some(t) => t.title.clone(),
                None => format!("<占位 {}>", e.item.track_uid),
            })
            .collect()
    }

    /// 读一个条目的位置键（按曲目的 `track_uid` 找）。
    fn key_of(items: &[PlaylistEntry], track_uid: &str) -> String {
        match items.iter().find(|e| e.item.track_uid == track_uid) {
            Some(e) => e.item.position_key.clone(),
            None => String::new(),
        }
    }

    #[tokio::test]
    async fn playlist_crud_and_ordering() -> Result<()> {
        let lib = temp_library("playlists-order")?;
        for (uid, title) in [("u-a", "A"), ("u-b", "B"), ("u-c", "C")] {
            add_track(&lib, uid, title).await?;
        }

        let id = lib.create_playlist("  我的歌单  ", None).await?;
        let p = lib.get_playlist(id).await?;
        assert_eq!(p.name, "我的歌单", "首尾空白应当被去掉");
        assert_eq!(p.kind, PlaylistKind::Static);
        assert_eq!(p.track_count, 0);
        assert_eq!(p.uid.len(), 36, "uid 应当是 UUID 文本形式: {}", p.uid);

        // 三次插入：追加到末尾 → 插到最前 → 夹在中间。
        let c = lib
            .add_to_playlist(id, TrackUid("u-c".into()), None, None)
            .await?;
        let a = lib
            .add_to_playlist(id, TrackUid("u-a".into()), None, Some(&c))
            .await?;
        let b = lib
            .add_to_playlist(id, TrackUid("u-b".into()), Some(&a), Some(&c))
            .await?;
        assert!(a < b && b < c, "位置键应当递增: {a} {b} {c}");

        let items = lib.playlist_items(id, 0, 10).await?;
        assert_eq!(titles(&items), vec!["A", "B", "C"]);
        assert_eq!(lib.get_playlist(id).await?.track_count, 3);

        // 把 C 拖到最前面（插在 A 之前）。
        lib.move_playlist_item(id, &c, None, Some(&a)).await?;
        let items = lib.playlist_items(id, 0, 10).await?;
        assert_eq!(titles(&items), vec!["C", "A", "B"]);

        // 把 A 拖到末尾（两个键都为 None = 追加）。
        let a_key = key_of(&items, "u-a");
        lib.move_playlist_item(id, &a_key, None, None).await?;
        let items = lib.playlist_items(id, 0, 10).await?;
        assert_eq!(titles(&items), vec!["C", "B", "A"]);

        // 删掉 B。
        let b_key = key_of(&items, "u-b");
        lib.remove_from_playlist(id, &b_key).await?;
        let items = lib.playlist_items(id, 0, 10).await?;
        assert_eq!(titles(&items), vec!["C", "A"]);
        assert_eq!(lib.get_playlist(id).await?.track_count, 2);

        // 改名 + 自定义封面（artwork 有外键，先插一行图片）。
        lib.rename_playlist(id, "改过的名字").await?;
        assert_eq!(lib.get_playlist(id).await?.name, "改过的名字");
        lib.write(|c| {
            let now = now_ms();
            c.execute(
                "INSERT INTO artwork (id, hash, source, created_at) VALUES (7, 'hash-7', 'embedded', ?1)",
                params![now],
            )
            .db()?;
            Ok(())
        })
        .await?;
        lib.set_playlist_artwork(id, Some(ArtworkId(7))).await?;
        assert_eq!(lib.get_playlist(id).await?.artwork_id, Some(ArtworkId(7)));
        lib.set_playlist_artwork(id, None).await?;
        assert_eq!(lib.get_playlist(id).await?.artwork_id, None);

        // 墓碑：list 里不出现，get / 列条目 / 加曲都报 not_found。
        let other = lib.create_playlist("另一个", None).await?;
        lib.delete_playlist(id).await?;
        let listed = lib.list_playlists().await?;
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].id, other);
        assert_eq!(
            err_code(lib.get_playlist(id).await),
            Some(ErrorCode::NotFound)
        );
        assert_eq!(
            err_code(lib.playlist_items(id, 0, 10).await),
            Some(ErrorCode::NotFound)
        );
        assert_eq!(
            err_code(
                lib.add_to_playlist(id, TrackUid("u-a".into()), None, None)
                    .await
            ),
            Some(ErrorCode::NotFound)
        );
        Ok(())
    }

    #[tokio::test]
    async fn missing_track_is_a_placeholder() -> Result<()> {
        let lib = temp_library("playlists-placeholder")?;
        let id = lib.create_playlist("占位歌单", None).await?;
        lib.add_to_playlist(id, TrackUid("h:not-in-library".into()), None, None)
            .await?;

        let items = lib.playlist_items(id, 0, 10).await?;
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].item.track_uid, "h:not-in-library");
        assert!(items[0].track.is_none(), "找不到曲目时应当是占位（PL-05）");
        // 占位条目照样算进曲目数。
        assert_eq!(lib.get_playlist(id).await?.track_count, 1);
        Ok(())
    }

    #[tokio::test]
    async fn playlist_uids_and_error_semantics() -> Result<()> {
        let lib = temp_library("playlists-errors")?;
        let a = lib.create_playlist("P1", Some("uid-1".into())).await?;
        let b = lib.create_playlist("P2", None).await?;
        assert_eq!(lib.get_playlist(a).await?.uid, "uid-1");
        // 自动生成的 uid 两个歌单不会撞。
        assert_ne!(
            lib.get_playlist(a).await?.uid,
            lib.get_playlist(b).await?.uid
        );

        // 重复 uid 被拒绝（invalid）。
        assert_eq!(
            err_code(lib.create_playlist("P3", Some("uid-1".into())).await),
            Some(ErrorCode::InvalidArgument)
        );
        // 空名字被拒绝。
        assert_eq!(
            err_code(lib.create_playlist("   ", None).await),
            Some(ErrorCode::InvalidArgument)
        );
        assert_eq!(
            err_code(lib.rename_playlist(a, "\t\n").await),
            Some(ErrorCode::InvalidArgument)
        );

        // limit 越界是 invalid。
        assert_eq!(
            err_code(lib.playlist_items(a, 0, 0).await),
            Some(ErrorCode::InvalidArgument)
        );
        assert_eq!(
            err_code(lib.playlist_items(a, 0, TrackQuery::MAX_LIMIT + 1).await),
            Some(ErrorCode::InvalidArgument)
        );

        // 不存在的歌单 / 条目都是 not_found。
        let ghost = PlaylistId(9999);
        assert_eq!(
            err_code(lib.get_playlist(ghost).await),
            Some(ErrorCode::NotFound)
        );
        assert_eq!(
            err_code(lib.delete_playlist(ghost).await),
            Some(ErrorCode::NotFound)
        );
        assert_eq!(
            err_code(lib.remove_from_playlist(a, "zzz").await),
            Some(ErrorCode::NotFound)
        );
        assert_eq!(
            err_code(lib.move_playlist_item(a, "zzz", None, None).await),
            Some(ErrorCode::NotFound)
        );

        // 重复删除墓碑 → not_found。
        lib.delete_playlist(b).await?;
        assert_eq!(
            err_code(lib.delete_playlist(b).await),
            Some(ErrorCode::NotFound)
        );
        Ok(())
    }
}
