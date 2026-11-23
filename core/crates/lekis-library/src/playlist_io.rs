//! M3U / M3U8 歌单导入导出（PL-03）。
//!
//! 导出只支持普通歌单：条目按位置键顺序写成 `#EXTM3U` + `#EXTINF:<秒>,<艺人> - <标题>` +
//! 路径，UTF-8、`\n` 换行，同样输入永远得到同样输出。文件系统音源优先写绝对路径
//! （`source.root_path` + `file.path`），没配根目录时写源内相对路径；服务器源优先用
//! 已解析 URL（`external_id` 本身是 URL 时），否则写保存的源内路径 / 外部 ID。
//!
//! 导入时按行解析 `#EXTINF`（时长、艺人、标题）和路径 / URL，`#EXT-X-*` 等扩展标签忽略。
//! 匹配只认路径：把 M3U 里的路径统一成正斜杠、做 URL 解码（`%20` / `file://`），
//! 再和 `file.path`、`source.root_path + file.path`、服务器 `external_id` 比较；
//! 大小写不同和只剩文件名的旧路径只在**唯一命中**时才算匹配，避免把同名的不同歌混进来。
//! 匹配不上的条目原样放进 [`PlaylistImportReport::missing`]，UI 负责提示用户。

use crate::db::DbResultExt;
use crate::playlists::new_playlist_uid;
use crate::position::key_between;
use crate::Library;
use lekis_types::{now_ms, LekisError, PlaylistId, Result, SourceKind};
use percent_encoding::{percent_decode_str, utf8_percent_encode, AsciiSet, CONTROLS};
use quick_xml::events::Event;
use quick_xml::Reader;
use rusqlite::{params, OptionalExtension, Transaction};
use std::collections::HashMap;

/// 导入时解析出来的一条 M3U 条目。
#[derive(Debug, Clone, Default, PartialEq)]
pub struct M3uEntry {
    /// 路径或 URL，已经去掉行首行尾空白和成对引号。
    pub path: String,
    /// `#EXTINF` 里的时长（秒）；没有或无法解析时为 `None`。
    pub duration_secs: Option<f64>,
    /// `#EXTINF` 里的艺人（`艺人 - 标题` 的前半段）；没有时为 `None`。
    pub artist: Option<String>,
    /// `#EXTINF` 里的标题；没有时为 `None`。
    pub title: Option<String>,
}

/// M3U 导入结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlaylistImportReport {
    /// 新建歌单的 ID。
    pub playlist_id: PlaylistId,
    /// 成功匹配并加入歌单的条目数（重复条目也算多条）。
    pub matched: u32,
    /// 解析到的条目总数（含未匹配的）。
    pub total: u32,
    /// 没匹配到本地曲目的原始路径，按 M3U 里的顺序；重复的会各出现一次。
    pub missing: Vec<String>,
}

/// 解析 M3U / M3U8 文本。
///
/// 只返回真正对应路径的条目；空行、`#EXTM3U`、`#EXT-X-*` 等注释会被跳过。
/// BOM、CRLF、UTF-8 中文、扩展属性（`#EXTINF:123 tvg-id="..." group-title="...",标题`）
/// 都按常见播放器的写法处理。
pub fn parse_m3u(content: &str) -> Vec<M3uEntry> {
    let content = content.strip_prefix('\u{feff}').unwrap_or(content);
    let mut out = Vec::new();
    let mut pending: Option<PendingExtInf> = None;

    // `lines()` 同时处理 \n 和 \r\n；单独出现的 \r 再兜底替换一次。
    let normalized = content.replace('\r', "\n");
    for line in normalized.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if let Some(rest) = line.strip_prefix("#EXTINF:") {
            pending = Some(parse_extinf(rest));
            continue;
        }
        if line.starts_with('#') {
            continue;
        }
        let path = unquote(line);
        if path.is_empty() {
            continue;
        }
        let ext = pending.take().unwrap_or_default();
        out.push(M3uEntry {
            path: path.to_string(),
            duration_secs: ext.duration_secs,
            artist: ext.artist,
            title: ext.title,
        });
    }
    out
}

#[derive(Debug, Clone, Default)]
struct PendingExtInf {
    duration_secs: Option<f64>,
    artist: Option<String>,
    title: Option<String>,
}

/// Parse an XSPF playlist (PL-03).
///
/// XSPF is namespaced XML; we match on local names so both the default
/// `http://xspf.org/ns/0/` namespace and unnamespaced exports work. Only
/// `location`, `title`, `creator` and `duration` inside `<track>` are used.
pub fn parse_xspf(content: &str) -> Result<Vec<M3uEntry>> {
    let mut reader = Reader::from_str(content);
    reader.config_mut().trim_text(false);
    let mut out = Vec::new();
    let mut current: Option<M3uEntry> = None;
    let mut field: Option<&'static str> = None;
    let mut buffer = String::new();

    loop {
        let event = reader
            .read_event()
            .map_err(|e| LekisError::invalid(format!("XSPF parse failed: {e}")))?;
        match event {
            Event::Start(start) => match start.local_name().as_ref() {
                "track" => {
                    current = Some(M3uEntry::default());
                    field = None;
                    buffer.clear();
                }
                "location" => {
                    field = Some("location");
                    buffer.clear();
                }
                "title" => {
                    field = Some("title");
                    buffer.clear();
                }
                "creator" => {
                    field = Some("creator");
                    buffer.clear();
                }
                "duration" => {
                    field = Some("duration");
                    buffer.clear();
                }
                _ => {}
            },
            Event::Empty(start) => {
                if start.local_name().as_ref() == "track" {
                    if let Some(track) = current.take() {
                        if !track.path.is_empty() {
                            out.push(track);
                        }
                    }
                }
            }
            Event::Text(text) => {
                if field.is_some() {
                    buffer.push_str(text.as_ref());
                }
            }
            Event::CData(text) => {
                if field.is_some() {
                    buffer.push_str(text.as_ref());
                }
            }
            Event::GeneralRef(reference) => {
                if field.is_some() {
                    let raw = format!("&{};", reference.as_ref());
                    match quick_xml::escape::unescape(&raw) {
                        Ok(value) => buffer.push_str(&value),
                        Err(_) => buffer.push_str(&raw),
                    }
                }
            }
            Event::End(end) => match end.local_name().as_ref() {
                "track" => {
                    field = None;
                    buffer.clear();
                    if let Some(track) = current.take() {
                        if !track.path.is_empty() {
                            out.push(track);
                        }
                    }
                }
                "location" | "title" | "creator" | "duration" => {
                    if let Some(name) = field {
                        commit_xspf_field(current.as_mut(), name, buffer.trim());
                    }
                    field = None;
                    buffer.clear();
                }
                _ => {}
            },
            Event::Eof => break,
            _ => {}
        }
    }
    Ok(out)
}

fn commit_xspf_field(track: Option<&mut M3uEntry>, field: &str, value: &str) {
    let Some(track) = track else { return };
    if value.is_empty() {
        return;
    }
    match field {
        "location" => track.path = value.to_string(),
        "title" => track.title = Some(value.to_string()),
        "creator" => track.artist = Some(value.to_string()),
        "duration" => {
            track.duration_secs = value
                .parse::<f64>()
                .ok()
                .filter(|v| v.is_finite())
                .map(|ms| ms / 1000.0);
        }
        _ => {}
    }
}

fn parse_extinf(rest: &str) -> PendingExtInf {
    // 逗号之前可能带扩展属性，属性值里的逗号用引号包着，不能当分隔符。
    let Some(comma) = find_unquoted_comma(rest) else {
        return PendingExtInf::default();
    };
    let head = &rest[..comma];
    let label = rest[comma + 1..].trim();
    let duration_secs = head
        .split_whitespace()
        .next()
        .and_then(|s| s.trim_end_matches(',').parse::<f64>().ok())
        .filter(|v| v.is_finite());
    let (artist, title) = split_artist_title(label);
    PendingExtInf {
        duration_secs,
        artist,
        title,
    }
}

/// `#EXTINF` 的标题部分通常是 `艺人 - 标题`；没有分隔符时整段当标题。
fn split_artist_title(label: &str) -> (Option<String>, Option<String>) {
    let label = label.trim();
    if label.is_empty() {
        return (None, None);
    }
    match label.split_once(" - ") {
        Some((artist, title)) => {
            let artist = artist.trim();
            let title = title.trim();
            (
                (!artist.is_empty()).then(|| artist.to_string()),
                (!title.is_empty()).then(|| title.to_string()),
            )
        }
        None => (None, Some(label.to_string())),
    }
}

fn find_unquoted_comma(s: &str) -> Option<usize> {
    let mut quoted = false;
    for (i, ch) in s.char_indices() {
        match ch {
            '"' => quoted = !quoted,
            ',' if !quoted => return Some(i),
            _ => {}
        }
    }
    None
}

fn unquote(line: &str) -> &str {
    let line = line.trim();
    if line.len() >= 2 {
        let bytes = line.as_bytes();
        let first = bytes[0];
        let last = bytes[line.len() - 1];
        if (first == b'"' && last == b'"') || (first == b'\'' && last == b'\'') {
            return line[1..line.len() - 1].trim();
        }
    }
    line
}

impl Library {
    /// 把普通歌单导出成 M3U8 文本（UTF-8，`#EXTM3U` 开头）。
    ///
    /// 找不到文件的占位条目会跳过；智能歌单没有固定条目，返回
    /// [`LekisError::invalid`]。
    pub async fn export_playlist_m3u(&self, id: PlaylistId) -> Result<String> {
        self.read(move |c| {
            let kind: Option<String> = c
                .query_row(
                    "SELECT kind FROM playlist WHERE id = ?1 AND deleted = 0",
                    params![id.0],
                    |r| r.get(0),
                )
                .optional()
                .db()?;
            let Some(kind) = kind else {
                return Err(not_found(id));
            };
            if kind == "smart" {
                return Err(LekisError::invalid(
                    "smart playlists cannot be exported to M3U",
                ));
            }

            let mut stmt = c
                .prepare_cached(
                    "SELECT pi.position_key, t.title, t.artist_line, t.duration_ms,
                            f.path, s.kind, s.root_path, tf.external_id
                     FROM playlist_item pi
                     LEFT JOIN track t ON t.uid = pi.track_uid
                     LEFT JOIN track_file tf ON tf.track_id = t.id
                     LEFT JOIN file f ON f.id = tf.file_id
                     LEFT JOIN source s ON s.id = tf.source_id
                     WHERE pi.playlist_id = ?1
                     ORDER BY pi.position_key, tf.quality_score DESC, s.priority DESC,
                              s.id, tf.file_id",
                )
                .db()?;
            let rows = stmt
                .query_map(params![id.0], |r| {
                    Ok(ExportRow {
                        position_key: r.get(0)?,
                        title: r.get(1)?,
                        artist_line: r.get(2)?,
                        duration_ms: r.get(3)?,
                        path: r.get(4)?,
                        source_kind: r.get(5)?,
                        root_path: r.get(6)?,
                        external_id: r.get(7)?,
                    })
                })
                .db()?;

            let mut out = String::from("#EXTM3U\n");
            let mut seen = std::collections::HashSet::new();
            for row in rows {
                let row = row.db()?;
                // 一个条目可能有多个文件（本地 + 服务器），只取排在最前面的那个。
                if !seen.insert(row.position_key.clone()) {
                    continue;
                }
                let Some(path) = row.export_path() else {
                    // 曲目不在库里或者是占位条目：M3U 没法表示，跳过。
                    continue;
                };
                let title = single_line(row.title.as_deref().unwrap_or(""));
                let artist = single_line(row.artist_line.as_deref().unwrap_or(""));
                let label = match (artist.is_empty(), title.is_empty()) {
                    (true, true) => String::new(),
                    (true, false) => title,
                    (false, true) => artist,
                    (false, false) => format!("{artist} - {title}"),
                };
                let secs = row.duration_ms.unwrap_or(0).max(0) / 1000;
                out.push_str(&format!("#EXTINF:{secs},{label}\n"));
                out.push_str(&single_line(&path));
                out.push('\n');
            }
            Ok(out)
        })
        .await
    }

    /// 从 M3U / M3U8 文本新建一个普通歌单。
    ///
    /// 匹配到的曲目按 M3U 顺序加入（重复行会生成重复条目）；匹配不上的路径放在
    /// [`PlaylistImportReport::missing`] 里。即使一条都没匹配上也会建一个空歌单，
    /// 这样用户可以重新选择路径后再导入，而不是丢掉刚输入的名字。
    pub async fn import_playlist_m3u(
        &self,
        name: &str,
        content: &str,
    ) -> Result<PlaylistImportReport> {
        self.import_playlist_entries(name, parse_m3u(content)).await
    }

    /// 从 XSPF 文本新建一个普通歌单（PL-03）。
    pub async fn import_playlist_xspf(
        &self,
        name: &str,
        content: &str,
    ) -> Result<PlaylistImportReport> {
        self.import_playlist_entries(name, parse_xspf(content)?)
            .await
    }

    async fn import_playlist_entries(
        &self,
        name: &str,
        entries: Vec<M3uEntry>,
    ) -> Result<PlaylistImportReport> {
        let name = name.trim().to_string();
        if name.is_empty() {
            return Err(LekisError::invalid("playlist name must not be empty"));
        }
        let total = entries.len() as u32;

        self.write(move |conn| {
            let tx = conn.transaction().db()?;
            let index = LookupIndex::load(&tx)?;
            let now = now_ms();
            tx.execute(
                "INSERT INTO playlist (uid, name, kind, created_at, updated_at)
                 VALUES (?1, ?2, 'static', ?3, ?3)",
                params![new_playlist_uid(), name, now],
            )
            .db()?;
            let playlist_id = PlaylistId(tx.last_insert_rowid());

            let mut matched = 0u32;
            let mut missing = Vec::new();
            let mut previous: Option<String> = None;
            for entry in entries {
                let Some(track_uid) = index.lookup(&entry.path) else {
                    missing.push(entry.path);
                    continue;
                };
                let position_key = key_between(previous.as_deref(), None);
                tx.execute(
                    "INSERT INTO playlist_item
                         (playlist_id, position_key, track_uid, added_at)
                     VALUES (?1, ?2, ?3, ?4)",
                    params![playlist_id.0, &position_key, track_uid, now],
                )
                .db()?;
                previous = Some(position_key);
                matched += 1;
            }
            tx.commit().db()?;
            Ok(PlaylistImportReport {
                playlist_id,
                matched,
                total,
                missing,
            })
        })
        .await
    }

    /// 把普通歌单导出成 XSPF 1.0 文本（UTF-8，适合其他播放器）。
    ///
    /// 和 M3U 一样跳过占位条目；智能歌单返回 [`LekisError::invalid`]。
    pub async fn export_playlist_xspf(&self, id: PlaylistId) -> Result<String> {
        self.read(move |c| {
            let playlist: Option<(String, String)> = c
                .query_row(
                    "SELECT kind, name FROM playlist WHERE id = ?1 AND deleted = 0",
                    params![id.0],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()
                .db()?;
            let Some((kind, name)) = playlist else {
                return Err(not_found(id));
            };
            if kind == "smart" {
                return Err(LekisError::invalid(
                    "smart playlists cannot be exported to XSPF",
                ));
            }

            let mut stmt = c
                .prepare_cached(
                    "SELECT pi.position_key, t.title, t.artist_line, t.duration_ms,
                            f.path, s.kind, s.root_path, tf.external_id
                     FROM playlist_item pi
                     LEFT JOIN track t ON t.uid = pi.track_uid
                     LEFT JOIN track_file tf ON tf.track_id = t.id
                     LEFT JOIN file f ON f.id = tf.file_id
                     LEFT JOIN source s ON s.id = tf.source_id
                     WHERE pi.playlist_id = ?1
                     ORDER BY pi.position_key, tf.quality_score DESC, s.priority DESC,
                              s.id, tf.file_id",
                )
                .db()?;
            let rows = stmt
                .query_map(params![id.0], |r| {
                    Ok(ExportRow {
                        position_key: r.get(0)?,
                        title: r.get(1)?,
                        artist_line: r.get(2)?,
                        duration_ms: r.get(3)?,
                        path: r.get(4)?,
                        source_kind: r.get(5)?,
                        root_path: r.get(6)?,
                        external_id: r.get(7)?,
                    })
                })
                .db()?;

            let mut out = String::from(
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
                 <playlist version=\"1\" xmlns=\"http://xspf.org/ns/0/\">\n",
            );
            out.push_str(&format!("  <title>{}</title>\n", xml_escape(&name)));
            out.push_str("  <trackList>\n");
            let mut seen = std::collections::HashSet::new();
            for row in rows {
                let row = row.db()?;
                if !seen.insert(row.position_key.clone()) {
                    continue;
                }
                let Some(path) = row.export_path() else {
                    continue;
                };
                out.push_str("    <track>\n");
                out.push_str(&format!(
                    "      <location>{}</location>\n",
                    xml_escape(&xspf_location(&path))
                ));
                if let Some(title) = row.title.as_deref().map(single_line) {
                    if !title.is_empty() {
                        out.push_str(&format!("      <title>{}</title>\n", xml_escape(&title)));
                    }
                }
                if let Some(artist) = row.artist_line.as_deref().map(single_line) {
                    if !artist.is_empty() {
                        out.push_str(&format!(
                            "      <creator>{}</creator>\n",
                            xml_escape(&artist)
                        ));
                    }
                }
                if let Some(ms) = row.duration_ms.filter(|ms| *ms > 0) {
                    out.push_str(&format!("      <duration>{ms}</duration>\n"));
                }
                out.push_str("    </track>\n");
            }
            out.push_str("  </trackList>\n</playlist>\n");
            Ok(out)
        })
        .await
    }
}

struct ExportRow {
    position_key: String,
    title: Option<String>,
    artist_line: Option<String>,
    duration_ms: Option<i64>,
    path: Option<String>,
    source_kind: Option<String>,
    root_path: Option<String>,
    external_id: Option<String>,
}

impl ExportRow {
    /// 选一条 M3U 能识别的路径：本地文件优先绝对路径；服务器曲目优先已解析 URL，
    /// 没有 URL 时写保存的源内路径，再退回外部 ID。
    fn export_path(&self) -> Option<String> {
        let path = self
            .path
            .as_deref()
            .map(str::trim)
            .filter(|p| !p.is_empty());
        let external = self
            .external_id
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty());
        let kind = self.source_kind.as_deref().and_then(|k| {
            serde_json::from_value::<SourceKind>(serde_json::Value::String(k.to_string())).ok()
        });
        // 未知类型按文件系统处理：绝大多数曲目是本地文件，绝对路径对播放器更友好。
        if kind.map(SourceKind::is_filesystem).unwrap_or(true) {
            return path.map(|p| join_root(self.root_path.as_deref().unwrap_or(""), p));
        }
        if let Some(url) = external.filter(|e| is_url(e)) {
            return Some(url.to_string());
        }
        path.map(normalize_local)
            .or_else(|| external.map(str::to_string))
    }
}

/// 解析出来的所有可匹配文件，按路径 / 外部 ID 建索引。
struct LookupIndex {
    /// 精确匹配（区分大小写）。
    exact: HashMap<String, Target>,
    /// 忽略大小写的兜底（仅在精确匹配失败后用）。
    folded: HashMap<String, Target>,
    /// 只剩文件名时的兜底（仅在唯一命中时用）。
    basename: HashMap<String, Target>,
}

enum Target {
    Unique(String),
    Ambiguous,
}

impl Target {
    fn uid(&self) -> Option<&str> {
        match self {
            Self::Unique(uid) => Some(uid),
            Self::Ambiguous => None,
        }
    }
}

impl LookupIndex {
    fn load(tx: &Transaction<'_>) -> Result<Self> {
        let mut index = Self {
            exact: HashMap::new(),
            folded: HashMap::new(),
            basename: HashMap::new(),
        };
        let mut stmt = tx
            .prepare(
                "SELECT t.uid, f.path, s.root_path, tf.external_id
                 FROM track_file tf
                 JOIN track t ON t.id = tf.track_id
                 JOIN source s ON s.id = tf.source_id
                 LEFT JOIN file f ON f.id = tf.file_id
                 ORDER BY tf.quality_score DESC, s.priority DESC, s.id, tf.file_id",
            )
            .db()?;
        let rows = stmt
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, Option<String>>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, Option<String>>(3)?,
                ))
            })
            .db()?;
        for row in rows {
            let (uid, path, root_path, external_id) = row.db()?;
            if let Some(path) = path.as_deref().filter(|p| !p.trim().is_empty()) {
                for key in stored_path_keys(&root_path, path) {
                    index.add_path(&key, &uid);
                }
            }
            if let Some(external_id) = external_id.as_deref().filter(|e| !e.trim().is_empty()) {
                for key in key_variants(external_id) {
                    add(&mut index.exact, key.clone(), &uid);
                    if !is_url(&key) {
                        add(&mut index.folded, key.to_lowercase(), &uid);
                    }
                }
            }
        }
        Ok(index)
    }

    fn add_path(&mut self, key: &str, uid: &str) {
        if key.is_empty() {
            return;
        }
        add(&mut self.exact, key.to_string(), uid);
        add(&mut self.folded, key.to_lowercase(), uid);
        if let Some(base) = basename(key) {
            add(&mut self.basename, base.to_lowercase(), uid);
        }
    }

    fn lookup(&self, raw: &str) -> Option<String> {
        let variants = key_variants(raw);
        for key in &variants {
            if let Some(uid) = self.exact.get(key).and_then(Target::uid) {
                return Some(uid.to_string());
            }
        }
        // URL 的路径 / query 可能是大小写敏感的；只对本地文件做忽略大小写兜底。
        if variants.iter().any(|v| is_url(v)) {
            return None;
        }
        for key in &variants {
            if let Some(uid) = self.folded.get(&key.to_lowercase()).and_then(Target::uid) {
                return Some(uid.to_string());
            }
        }
        // 旧 M3U 可能来自另一台电脑 / 另一个挂载点：只剩文件名且全库唯一时才算匹配。
        for key in &variants {
            if let Some(base) = basename(key) {
                if let Some(uid) = self
                    .basename
                    .get(&base.to_lowercase())
                    .and_then(Target::uid)
                {
                    return Some(uid.to_string());
                }
            }
        }
        None
    }
}

fn add(map: &mut HashMap<String, Target>, key: String, uid: &str) {
    if key.is_empty() {
        return;
    }
    match map.get(&key) {
        None => {
            map.insert(key, Target::Unique(uid.to_string()));
        }
        Some(Target::Unique(existing)) if existing != uid => {
            map.insert(key, Target::Ambiguous);
        }
        _ => {}
    }
}

/// 库里保存的路径既能按相对路径匹配，也能按 `root_path + path` 的绝对路径匹配。
fn stored_path_keys(root_path: &str, path: &str) -> Vec<String> {
    let mut keys = key_variants(path);
    if !root_path.trim().is_empty() {
        let absolute = join_root(root_path, path);
        keys.extend(key_variants(&absolute));
    }
    keys.sort();
    keys.dedup();
    keys
}

/// 一个路径 / URL 的几种常见写法：原样、URL 解码后、`file://` 去掉后。
fn key_variants(raw: &str) -> Vec<String> {
    let raw = raw.trim();
    let mut out = Vec::new();
    for candidate in [
        raw.to_string(),
        percent_decode_str(raw).decode_utf8_lossy().into_owned(),
    ] {
        let candidate = strip_file_uri(&candidate);
        let normalized = normalize_local(&candidate);
        for key in [candidate.trim().to_string(), normalized] {
            if !key.is_empty() && !out.contains(&key) {
                out.push(key);
            }
        }
    }
    out
}

/// 本地路径统一成正斜杠、去掉 `./`、合并重复斜杠；URL 原样保留。
fn normalize_local(path: &str) -> String {
    let path = path.trim();
    if is_url(path) {
        return path.to_string();
    }
    let mut out = String::with_capacity(path.len());
    let mut previous_slash = false;
    for ch in path.chars() {
        let ch = if ch == '\\' { '/' } else { ch };
        if ch == '/' {
            if previous_slash {
                continue;
            }
            previous_slash = true;
        } else {
            previous_slash = false;
        }
        out.push(ch);
    }
    while out.starts_with("./") {
        out.drain(..2);
    }
    out
}

/// `source.root_path` 和源内相对路径拼成绝对路径（不会重复斜杠）。
fn join_root(root: &str, path: &str) -> String {
    let root = root.trim().trim_end_matches(['/', '\\']);
    let path = path.trim().trim_start_matches(['/', '\\']);
    if root.is_empty() {
        normalize_local(path)
    } else {
        normalize_local(&format!("{root}/{path}"))
    }
}

fn is_url(path: &str) -> bool {
    match path.find("://") {
        Some(index) => !path[..index].eq_ignore_ascii_case("file"),
        None => false,
    }
}

/// `file:///C:/music/a.flac` → `C:/music/a.flac`；`file://nas/share` → `//nas/share`。
fn strip_file_uri(path: &str) -> String {
    let Some(prefix) = path.get(..7) else {
        return path.to_string();
    };
    if !prefix.eq_ignore_ascii_case("file://") {
        return path.to_string();
    }
    let rest = &path[7..];
    let rest = rest.strip_prefix("localhost").unwrap_or(rest);
    if rest.is_empty() {
        return String::new();
    }
    if let Some(no_slash) = rest.strip_prefix('/') {
        let bytes = no_slash.as_bytes();
        if bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' {
            // Windows 盘符：file:///C:/...
            return no_slash.to_string();
        }
        return rest.to_string();
    }
    // file://server/share → UNC 路径
    format!("//{rest}")
}

fn basename(path: &str) -> Option<String> {
    let path = path.trim_end_matches('/');
    let base = path.rsplit('/').next()?.trim();
    (!base.is_empty()).then(|| base.to_string())
}

fn single_line(value: &str) -> String {
    value
        .chars()
        .map(|ch| if ch == '\r' || ch == '\n' { ' ' } else { ch })
        .collect()
}

/// Characters that must be percent-encoded in an XSPF `<location>` URI.
/// `/`, `:` and non-ASCII UTF-8 stay readable; import decodes `%xx` again.
const XSPF_URI_ESCAPE: &AsciiSet = &CONTROLS
    .add(b' ')
    .add(b'"')
    .add(b'&')
    .add(b'#')
    .add(b'%')
    .add(b'<')
    .add(b'>')
    .add(b'?')
    .add(b'[')
    .add(b']');

fn xspf_location(path: &str) -> String {
    if is_url(path) {
        return path.to_string();
    }
    let path = normalize_local(path);
    let uri = if path.starts_with("//") {
        format!("file:{path}")
    } else if path.starts_with('/') {
        format!("file://{path}")
    } else if path.as_bytes().get(1) == Some(&b':') {
        format!("file:///{path}")
    } else {
        path
    };
    utf8_percent_encode(&uri, XSPF_URI_ESCAPE).to_string()
}

fn xml_escape(value: &str) -> String {
    let value = single_line(value);
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

fn not_found(id: PlaylistId) -> LekisError {
    LekisError::not_found(format!("playlist {id}"))
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::db::test_util::temp_library;
    use crate::{PlaylistEntry, ScannedFile, ScannedTags};
    use lekis_types::{SourceConfig, SourceId, TrackQuery, TrackSort, TrackUid};
    use std::collections::BTreeMap;

    async fn local_source(lib: &Library, root: &str) -> Result<SourceId> {
        lib.add_source(SourceConfig {
            id: None,
            kind: SourceKind::Local,
            name: "本地音乐".into(),
            addresses: vec![],
            root_path: root.into(),
            credential_ref: None,
            options: BTreeMap::new(),
            enabled: true,
        })
        .await
    }

    async fn add_file(
        lib: &Library,
        source: SourceId,
        path: &str,
        title: &str,
        artist: &str,
    ) -> Result<()> {
        lib.upsert_scanned(vec![ScannedFile {
            source_id: source,
            path: path.into(),
            size: 1,
            mtime_ms: 1,
            tags: ScannedTags {
                title: title.into(),
                artists: vec![artist.into()],
                album: Some("测试专辑".into()),
                duration_ms: 269_000,
                ..Default::default()
            },
        }])
        .await?;
        Ok(())
    }

    async fn track_uid(lib: &Library, title: &str) -> Result<TrackUid> {
        let rows = lib
            .list_track_rows(TrackQuery {
                sort: TrackSort::Title,
                offset: 0,
                limit: 50,
            })
            .await?;
        let row = rows
            .iter()
            .find(|r| r.title == title)
            .ok_or_else(|| LekisError::internal(format!("missing seeded track {title}")))?;
        Ok(lib.get_track(row.id).await?.uid)
    }

    fn titles(entries: &[PlaylistEntry]) -> Vec<String> {
        entries
            .iter()
            .map(|e| {
                e.track
                    .as_ref()
                    .map(|t| t.title.clone())
                    .unwrap_or_default()
            })
            .collect()
    }

    #[tokio::test]
    async fn roundtrips_three_local_files() -> Result<()> {
        let lib = temp_library("m3u-roundtrip")?;
        let src = local_source(&lib, "/music").await?;
        add_file(&lib, src, "Jay/01 晴天.flac", "晴天", "周杰伦").await?;
        add_file(&lib, src, "Jay/02 以父之名.flac", "以父之名", "周杰伦").await?;
        add_file(&lib, src, "Other/03 普通朋友.flac", "普通朋友", "陶喆").await?;

        let id = lib.create_playlist("通勤", None).await?;
        for title in ["晴天", "以父之名", "普通朋友"] {
            lib.add_to_playlist(id, track_uid(&lib, title).await?, None, None)
                .await?;
        }

        let text = lib.export_playlist_m3u(id).await?;
        assert_eq!(
            text,
            "#EXTM3U\n\
             #EXTINF:269,周杰伦 - 晴天\n\
             /music/Jay/01 晴天.flac\n\
             #EXTINF:269,周杰伦 - 以父之名\n\
             /music/Jay/02 以父之名.flac\n\
             #EXTINF:269,陶喆 - 普通朋友\n\
             /music/Other/03 普通朋友.flac\n"
        );
        // 同样的输入永远得到同样的输出。
        assert_eq!(text, lib.export_playlist_m3u(id).await?);

        let report = lib.import_playlist_m3u("导入：通勤", &text).await?;
        assert_eq!(report.matched, 3);
        assert_eq!(report.total, 3);
        assert!(report.missing.is_empty());
        assert_ne!(report.playlist_id, id);
        let imported = lib.playlist_items(report.playlist_id, 0, 10).await?;
        assert_eq!(titles(&imported), vec!["晴天", "以父之名", "普通朋友"]);
        Ok(())
    }

    #[tokio::test]
    async fn empty_playlist_exports_header_and_imports_empty() -> Result<()> {
        let lib = temp_library("m3u-empty")?;
        let id = lib.create_playlist("空歌单", None).await?;
        assert_eq!(lib.export_playlist_m3u(id).await?, "#EXTM3U\n");

        let report = lib.import_playlist_m3u("空导入", "#EXTM3U\n").await?;
        assert_eq!(report.matched, 0);
        assert_eq!(report.total, 0);
        assert!(report.missing.is_empty());
        assert!(lib
            .playlist_items(report.playlist_id, 0, 10)
            .await?
            .is_empty());

        // 完全空的文本也能导入，不会把名字丢掉。
        let report = lib.import_playlist_m3u(" 空文本 ", "").await?;
        assert_eq!(lib.get_playlist(report.playlist_id).await?.name, "空文本");
        Ok(())
    }

    #[tokio::test]
    async fn imports_chinese_names_and_reports_missing_paths() -> Result<()> {
        let lib = temp_library("m3u-chinese-missing")?;
        let src = local_source(&lib, "/音乐").await?;
        add_file(&lib, src, "周杰伦/晴天.flac", "晴天", "周杰伦").await?;

        let content = "#EXTM3U\r\n\
                       #EXTINF:269,周杰伦 - 晴天\r\n\
                       /音乐/周杰伦/晴天.flac\r\n\
                       #EXTINF:180,不存在 - 没有这首歌\r\n\
                       C:\\旧电脑\\没有这首歌.mp3\r\n";
        let report = lib.import_playlist_m3u("中文歌单", content).await?;
        assert_eq!(report.matched, 1);
        assert_eq!(report.total, 2);
        assert_eq!(
            report.missing,
            vec!["C:\\旧电脑\\没有这首歌.mp3".to_string()]
        );
        let playlist = lib.get_playlist(report.playlist_id).await?;
        assert_eq!(playlist.name, "中文歌单");
        assert_eq!(
            titles(&lib.playlist_items(report.playlist_id, 0, 10).await?),
            vec!["晴天"]
        );
        Ok(())
    }

    #[tokio::test]
    async fn duplicate_entries_are_kept_in_order() -> Result<()> {
        let lib = temp_library("m3u-duplicates")?;
        let src = local_source(&lib, "/music").await?;
        add_file(&lib, src, "a.flac", "A", "Artist").await?;
        add_file(&lib, src, "b.flac", "B", "Artist").await?;

        let content = "#EXTM3U\nmusic/a.flac\nmusic/b.flac\nmusic/a.flac\n";
        let report = lib.import_playlist_m3u("重复", content).await?;
        assert_eq!(report.matched, 3);
        assert!(report.missing.is_empty());
        let entries = lib.playlist_items(report.playlist_id, 0, 10).await?;
        assert_eq!(titles(&entries), vec!["A", "B", "A"]);
        // 重复条目也有各自的位置键，不会互相覆盖。
        assert_ne!(entries[0].item.position_key, entries[2].item.position_key);
        Ok(())
    }

    #[tokio::test]
    async fn m3u8_extended_attrs_and_url_decoding() -> Result<()> {
        let lib = temp_library("m3u8-attrs")?;
        let src = local_source(&lib, "/music").await?;
        add_file(&lib, src, "周杰伦/01 晴天.flac", "晴天", "周杰伦").await?;

        let content = "\u{feff}#EXTM3U\n\
                       #EXT-X-VERSION:3\n\
                       #EXTINF:269.4 tvg-id=\"jay\" group-title=\"华语,流行\" ,周杰伦 - 晴天\n\
                       file:///music/%E5%91%A8%E6%9D%B0%E4%BC%A6/01%20%E6%99%B4%E5%A4%A9.flac\n";
        let parsed = parse_m3u(content);
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].duration_secs, Some(269.4));
        assert_eq!(parsed[0].artist.as_deref(), Some("周杰伦"));
        assert_eq!(parsed[0].title.as_deref(), Some("晴天"));

        let report = lib.import_playlist_m3u("M3U8", content).await?;
        assert_eq!(report.matched, 1);
        assert!(report.missing.is_empty());
        assert_eq!(
            titles(&lib.playlist_items(report.playlist_id, 0, 10).await?),
            vec!["晴天"]
        );
        Ok(())
    }

    #[tokio::test]
    async fn absolute_windows_paths_and_unique_basename_fallback_match() -> Result<()> {
        let lib = temp_library("m3u-path-shapes")?;
        let src = local_source(&lib, "D:\\Music").await?;
        add_file(&lib, src, "Jay/晴天.flac", "晴天", "周杰伦").await?;
        add_file(&lib, src, "Jay/以父之名.flac", "以父之名", "周杰伦").await?;

        let content = "#EXTM3U\n\
                       d:/music/JAY/晴天.flac\n\
                       /old/computer/以父之名.flac\n";
        let report = lib.import_playlist_m3u("路径", content).await?;
        assert_eq!(report.matched, 2);
        assert!(report.missing.is_empty());
        assert_eq!(
            titles(&lib.playlist_items(report.playlist_id, 0, 10).await?),
            vec!["晴天", "以父之名"]
        );
        Ok(())
    }

    #[tokio::test]
    async fn remote_external_url_roundtrips() -> Result<()> {
        let lib = temp_library("m3u-remote")?;
        let src = lib
            .add_source(SourceConfig {
                id: None,
                kind: SourceKind::OpenSubsonic,
                name: "nav".into(),
                addresses: vec!["http://nav.local:4533".into()],
                root_path: String::new(),
                credential_ref: None,
                options: BTreeMap::new(),
                enabled: true,
            })
            .await?;
        lib.upsert_remote_tracks(
            src,
            vec![crate::RemoteTrackRow {
                external_album_id: None,
                album_artists: vec![],
                disc_no: None,
                track_no: None,
                external_id: "https://nav.local/stream?id=42".into(),
                title: "远程晴天".into(),
                artists: vec!["周杰伦".into()],
                album: Some("叶惠美".into()),
                duration_ms: 269_000,
                mbid_recording: None,
                quality_score: 100,
            }],
        )
        .await?;
        let uid = track_uid(&lib, "远程晴天").await?;
        let id = lib.create_playlist("服务器", None).await?;
        lib.add_to_playlist(id, uid, None, None).await?;

        let text = lib.export_playlist_m3u(id).await?;
        assert!(text.contains("https://nav.local/stream?id=42\n"), "{text}");
        let report = lib.import_playlist_m3u("服务器导入", &text).await?;
        assert_eq!(report.matched, 1);
        assert!(report.missing.is_empty());
        Ok(())
    }

    #[tokio::test]
    async fn smart_playlist_export_is_rejected() -> Result<()> {
        let lib = temp_library("m3u-smart")?;
        let id = lib.create_playlist("智能", None).await?;
        let rules = crate::SmartRules {
            root: crate::RuleGroup::All(vec![]),
            limit: None,
            sort: None,
            sort_desc: false,
        };
        lib.set_playlist_rules(id, Some(&rules)).await?;
        let err = lib.export_playlist_m3u(id).await.unwrap_err();
        assert_eq!(err.code, lekis_types::ErrorCode::InvalidArgument);
        Ok(())
    }

    #[test]
    fn parser_handles_quotes_blank_lines_and_bare_paths() {
        let entries = parse_m3u(
            "\n#EXTM3U\n# a comment\n\"C:\\Music\\a b.flac\"\n#EXTINF:12,Title\n'music/b.flac'\n",
        );
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].path, "C:\\Music\\a b.flac");
        assert_eq!(entries[0].title, None);
        assert_eq!(entries[1].path, "music/b.flac");
        assert_eq!(entries[1].title.as_deref(), Some("Title"));
        assert_eq!(entries[1].duration_secs, Some(12.0));
    }

    #[test]
    fn xspf_parser_handles_namespace_entities_and_duration() {
        let xml = r#"<?xml version="1.0" encoding="UTF-8"?>
<playlist version="1" xmlns="http://xspf.org/ns/0/">
  <title>我的歌单</title>
  <trackList>
    <track>
      <location>file:///music/A%20B.flac</location>
      <title>一 &amp; 二</title>
      <creator>周杰伦</creator>
      <duration>123000</duration>
    </track>
    <track>
      <location>C:\Music\b.flac</location>
      <title>普通朋友</title>
    </track>
  </trackList>
</playlist>"#;
        let entries = parse_xspf(xml).expect("valid xspf");
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].path, "file:///music/A%20B.flac");
        assert_eq!(entries[0].title.as_deref(), Some("一 & 二"));
        assert_eq!(entries[0].artist.as_deref(), Some("周杰伦"));
        assert_eq!(entries[0].duration_secs, Some(123.0));
        assert_eq!(entries[1].path, "C:\\Music\\b.flac");
        assert_eq!(entries[1].title.as_deref(), Some("普通朋友"));
        assert_eq!(entries[1].duration_secs, None);
    }

    #[tokio::test]
    async fn xspf_roundtrips_three_local_files() -> Result<()> {
        let lib = temp_library("xspf-roundtrip")?;
        let src = local_source(&lib, "/music").await?;
        add_file(&lib, src, "Jay/01 晴天.flac", "晴天", "周杰伦").await?;
        add_file(&lib, src, "Jay/02 以父之名.flac", "以父之名", "周杰伦").await?;
        add_file(&lib, src, "Other/03 普通朋友.flac", "普通朋友", "陶喆").await?;

        let id = lib.create_playlist("通勤", None).await?;
        for title in ["晴天", "以父之名", "普通朋友"] {
            lib.add_to_playlist(id, track_uid(&lib, title).await?, None, None)
                .await?;
        }

        let text = lib.export_playlist_xspf(id).await?;
        assert!(text.starts_with("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"));
        assert!(text.contains("<title>通勤</title>"));
        assert_eq!(text.matches("<location>").count(), 3);
        assert!(text.contains("<duration>269000</duration>"));
        assert_eq!(text, lib.export_playlist_xspf(id).await?);

        let report = lib.import_playlist_xspf("导入 XSPF", &text).await?;
        assert_eq!(report.matched, 3);
        assert_eq!(report.total, 3);
        assert!(report.missing.is_empty());
        assert_eq!(
            titles(&lib.playlist_items(report.playlist_id, 0, 10).await?),
            vec!["晴天", "以父之名", "普通朋友"]
        );
        Ok(())
    }

    #[tokio::test]
    async fn xspf_empty_and_smart_playlists() -> Result<()> {
        let lib = temp_library("xspf-empty-smart")?;
        let id = lib.create_playlist("空歌单", None).await?;
        let text = lib.export_playlist_xspf(id).await?;
        assert!(text.contains("<trackList>\n  </trackList>"));
        let report = lib.import_playlist_xspf("空导入", &text).await?;
        assert_eq!(report.total, 0);
        assert_eq!(report.matched, 0);

        let smart = lib.create_playlist("智能", None).await?;
        let rules = crate::SmartRules {
            root: crate::RuleGroup::All(vec![]),
            limit: None,
            sort: None,
            sort_desc: false,
        };
        lib.set_playlist_rules(smart, Some(&rules)).await?;
        let err = lib.export_playlist_xspf(smart).await.unwrap_err();
        assert_eq!(err.code, lekis_types::ErrorCode::InvalidArgument);
        Ok(())
    }
}
