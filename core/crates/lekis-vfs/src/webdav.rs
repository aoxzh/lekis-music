//! WebDAV（SRC-03）：覆盖 Alist/OpenList、Nextcloud、群晖 WebDAV。
//!
//! 实现方式：基于 reqwest 自己实现，只需要 `PROPFIND`（Depth: 1 / 0）、`GET` + `Range`、
//! `PUT`、`MKCOL`、`MOVE`。
//!
//! 注意：
//! - 有些服务（Alist 的部分存储驱动）会 302 跳转到网盘直链，Range 请求要跟随跳转；
//!   reqwest 的默认跳转策略会保留 `Range` 头（只在跨主机的跳转上丢弃 `Authorization`），
//!   所以直链场景下拿到的仍然是 206 分片。
//! - 有些服务不返回 `getlastmodified`，此时 [`VfsCapabilities::reliable_dir_mtime`] 为 `false`，
//!   增量扫描退化。这里用「实际见过 getlastmodified」作为开关。
//! - XML 命名空间前缀不可信：Alist 用 `d:`、Nextcloud 用 `d:`、群晖有的版本用 `D:` 或 `lp1:`、
//!   还有不带前缀的。**解析只按本地名（local name）匹配**，见 [`parse_propfind`]。
//! - 认证：Basic（URL userinfo 或 `open()` 传入的密码）+ Digest（收到 401 挑战后自动切换）。
//!   凭据只放在请求头里，**不会**出现在 URL、`tracing` 输出或错误消息中。

use crate::{DirEntry, EntryKind, FileMeta, Vfs, VfsCapabilities, VfsPath};
use async_trait::async_trait;
use bytes::Bytes;
use futures_util::StreamExt;
use lekis_types::{ErrorCode, LekisError, Result, SourceKind};
use percent_encoding::{percent_decode_str, utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};
use quick_xml::events::{BytesStart, Event};
use quick_xml::Reader;
use reqwest::header::AUTHORIZATION;
use reqwest::{Method, RequestBuilder, Response, StatusCode};
use std::ops::Range;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};

/// PROPFIND 请求体：只问三个属性，尽量小。
const PROPFIND_BODY: &str = r#"<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:resourcetype/>
    <d:getcontentlength/>
    <d:getlastmodified/>
  </d:prop>
</d:propfind>"#;

/// 单次 PROPFIND 最多接受多少个条目（防御性上限，避免被超大目录拖死）。
const MAX_ENTRIES: usize = 200_000;

/// 路径分段编码集合：`/` 分段后每段只放行 RFC 3986 unreserved 字符。
const PATH_SEGMENT: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'.')
    .remove(b'_')
    .remove(b'~');

/// Digest 认证挑战（`WWW-Authenticate: Digest ...`）。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct DigestChallenge {
    realm: String,
    nonce: String,
    qop: Option<String>,
    opaque: Option<String>,
    algorithm: Option<String>,
}

/// WebDAV 文件系统。
pub struct WebDavVfs {
    /// 源根 URL（已去掉结尾 `/`，**已剥掉 userinfo**）。
    base_url: String,
    /// 源根在服务器上的绝对路径（percent 解码后，无结尾 `/`）。
    base_path: String,
    /// 用户名（来自 URL userinfo）。
    user: String,
    /// 密码（来自 `open()` 的参数，其次 URL userinfo）。
    password: String,
    /// 是否有可用凭据。
    has_credentials: bool,
    /// HTTP 客户端（连接池 + 跳转策略）。
    client: reqwest::Client,
    /// 服务器给的 Digest 挑战；有值后所有请求都走 Digest。
    digest: tokio::sync::Mutex<Option<DigestChallenge>>,
    /// Digest 的 nonce 计数（`nc`）。
    nc: AtomicU32,
    /// Digest 的 cnonce（每个实例固定，够用）。
    cnonce: String,
    /// 是否真的从服务器拿到过 `getlastmodified`。
    saw_mtime: AtomicBool,
}

impl WebDavVfs {
    /// 以 `http(s)://[user[:pass]@]host[:port]/path` 为根创建。
    ///
    /// 构造是同步且不发网络请求的：能力、路径解析都在本地完成。
    pub fn new(base_url: &str, password: Option<String>) -> Result<Self> {
        let parsed = parse_base_url(base_url)?;
        let client = reqwest::Client::builder()
            .user_agent(concat!("lekis/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|e| LekisError::internal(format!("webdav: 创建 HTTP 客户端失败: {e}")))?;
        // 钥匙串里取来的密码也算"有凭据"：地址里不带 userinfo 时同样要发 Basic 认证。
        let keychain = password.filter(|p| !p.is_empty());
        let has_credentials = parsed.has_credentials || keychain.is_some();
        Ok(Self {
            base_url: parsed.base_url,
            base_path: parsed.base_path,
            user: parsed.user,
            password: keychain.or(parsed.password).unwrap_or_default(),
            has_credentials,
            client,
            digest: tokio::sync::Mutex::new(None),
            nc: AtomicU32::new(1),
            cnonce: cnonce(),
            saw_mtime: AtomicBool::new(false),
        })
    }

    /// 某个 [`VfsPath`] 对应的绝对 URL（已 percent 编码）。
    fn url_for(&self, path: &VfsPath) -> String {
        url_for_base(&self.base_url, path)
    }

    /// 发一个请求，必要时自动补认证头；收到 `401 + Digest` 挑战时切换成 Digest 再试一次。
    ///
    /// `build` 可能被调用两次，所以必须是 `Fn`（每次返回新的 builder）。
    async fn send<F>(&self, method: &str, url: &str, build: F) -> Result<Response>
    where
        F: Fn() -> RequestBuilder,
    {
        let challenge = self.digest.lock().await.clone();
        let rb = self.apply_auth(build(), challenge.as_ref(), method, url);
        let resp = rb.send().await.map_err(net_err)?;

        if resp.status() != StatusCode::UNAUTHORIZED || !self.has_credentials || challenge.is_some()
        {
            return Ok(resp);
        }
        // 第一次 401：看服务器是不是想要 Digest。
        let Some(fresh) = resp
            .headers()
            .get("www-authenticate")
            .and_then(|v| v.to_str().ok())
            .and_then(parse_digest_challenge)
        else {
            return Ok(resp);
        };
        tracing::debug!(
            target: "vfs::webdav",
            realm = %fresh.realm,
            "服务器要求 Digest 认证，重试请求"
        );
        let rb = self.apply_auth(build(), Some(&fresh), method, url);
        let resp = rb.send().await.map_err(net_err)?;
        if resp.status() != StatusCode::UNAUTHORIZED {
            *self.digest.lock().await = Some(fresh);
        }
        Ok(resp)
    }

    /// 给请求补上认证头（Digest 优先，其次 Basic）。
    fn apply_auth(
        &self,
        rb: RequestBuilder,
        challenge: Option<&DigestChallenge>,
        method: &str,
        url: &str,
    ) -> RequestBuilder {
        if let Some(ch) = challenge {
            let uri = request_uri(url);
            let nc = self.nc.fetch_add(1, Ordering::Relaxed);
            let header = digest_authorization(
                &self.user,
                &self.password,
                ch,
                method,
                &uri,
                nc,
                &self.cnonce,
            );
            return rb.header(AUTHORIZATION, header);
        }
        if self.has_credentials {
            return rb.basic_auth(&self.user, Some(&self.password));
        }
        rb
    }

    /// 记下「服务器给过 getlastmodified」这件事，供 [`VfsCapabilities`] 使用。
    fn note_mtime(&self, entries: &[DavEntry]) {
        if entries.iter().any(|e| e.mtime_ms != 0) {
            self.saw_mtime.store(true, Ordering::Relaxed);
        }
    }

    /// 发一次 PROPFIND，返回解析后的条目（含自身条目，调用方自己筛）。
    async fn propfind(&self, path: &VfsPath, depth: u8) -> Result<Vec<DavEntry>> {
        let url = self.url_for(path);
        let method = extension_method("PROPFIND")?;
        let depth = depth.to_string();
        let resp = self
            .send("PROPFIND", &url, || {
                self.client
                    .request(method.clone(), &url)
                    .header("Depth", depth.clone())
                    .header("Content-Type", "application/xml; charset=utf-8")
                    .body(PROPFIND_BODY)
            })
            .await?;
        if !resp.status().is_success() {
            return Err(status_err(resp.status(), "PROPFIND"));
        }
        let xml = resp.text().await.map_err(net_err)?;
        let entries = parse_propfind(&xml)?;
        self.note_mtime(&entries);
        Ok(entries)
    }
}

#[async_trait]
impl Vfs for WebDavVfs {
    fn kind(&self) -> SourceKind {
        SourceKind::WebDav
    }

    fn capabilities(&self) -> VfsCapabilities {
        VfsCapabilities {
            writable: true,
            watch: false,
            // 只有真的见过 getlastmodified 才敢说目录 mtime 可靠。
            reliable_dir_mtime: self.saw_mtime.load(Ordering::Relaxed),
            suggested_concurrency: 4,
        }
    }

    async fn list_dir(&self, dir: &VfsPath) -> Result<Vec<DirEntry>> {
        let entries = self.propfind(dir, 1).await?;
        let mut out = Vec::with_capacity(entries.len());
        for entry in &entries {
            // Depth: 1 会把目录自己也算进来，跳过。
            let Some(path) = href_to_path(&self.base_path, &entry.href) else {
                tracing::debug!(target: "vfs::webdav", href = %entry.href, "跳过无法映射到源根的 href");
                continue;
            };
            if &path == dir {
                continue;
            }
            if out.len() >= MAX_ENTRIES {
                return Err(crate::too_many_entries(dir, MAX_ENTRIES));
            }
            out.push(DirEntry {
                meta: entry.meta(),
                path,
            });
        }
        Ok(out)
    }

    async fn stat(&self, path: &VfsPath) -> Result<FileMeta> {
        let entries = self.propfind(path, 0).await?;
        // Depth: 0 只应返回一个条目；挑第一个能对上号的。
        for entry in &entries {
            if let Some(found) = href_to_path(&self.base_path, &entry.href) {
                if &found == path {
                    return Ok(entry.meta());
                }
            }
        }
        entries
            .first()
            .map(DavEntry::meta)
            .ok_or_else(|| LekisError::not_found(format!("webdav: 服务器没有返回 {path} 的属性")))
    }

    async fn read_range(&self, path: &VfsPath, range: Range<u64>) -> Result<Bytes> {
        if range.end < range.start {
            return Err(LekisError::invalid("webdav: 读取范围 end < start"));
        }
        let want = range.end - range.start;
        if want == 0 {
            return Ok(Bytes::new());
        }
        let url = self.url_for(path);
        let method = Method::GET;
        let range_header = format!("bytes={}-{}", range.start, range.end - 1);
        let resp = self
            .send("GET", &url, || {
                self.client
                    .request(method.clone(), &url)
                    .header("Range", range_header.clone())
                    .header("Accept-Encoding", "identity")
            })
            .await?;

        match resp.status() {
            StatusCode::PARTIAL_CONTENT => read_body_capped(resp, want, 0).await,
            // 服务器忽略 Range 直接给了整个文件：自己跳过前 start 字节。
            StatusCode::OK => read_body_capped(resp, want, range.start).await,
            // 范围完全在文件末尾之外。
            StatusCode::RANGE_NOT_SATISFIABLE => Ok(Bytes::new()),
            status => Err(status_err(status, "GET")),
        }
    }

    async fn write_atomic(&self, path: &VfsPath, data: Bytes) -> Result<()> {
        let target = self.url_for(path);
        let tmp_path = VfsPath::parse(&format!("{}.lekis-tmp", path.as_str()))
            .ok_or_else(|| LekisError::invalid("webdav: 临时文件路径非法"))?;
        let tmp_url = self.url_for(&tmp_path);

        let put = Method::PUT;
        let resp = self
            .send("PUT", &tmp_url, || {
                self.client
                    .request(put.clone(), &tmp_url)
                    .header("Content-Type", "application/octet-stream")
                    .body(data.clone())
            })
            .await?;
        if !resp.status().is_success() {
            return Err(status_err(resp.status(), "PUT"));
        }

        let mv = extension_method("MOVE")?;
        let resp = self
            .send("MOVE", &tmp_url, || {
                self.client
                    .request(mv.clone(), &tmp_url)
                    .header("Destination", target.clone())
                    .header("Overwrite", "T")
            })
            .await?;
        if resp.status().is_success() {
            return Ok(());
        }
        let err = status_err(resp.status(), "MOVE");
        // 尽力清理临时文件，失败也不覆盖原始错误。
        let cleanup = self
            .send("DELETE", &tmp_url, || {
                self.client.request(Method::DELETE, &tmp_url)
            })
            .await;
        match cleanup {
            Ok(r) if r.status().is_success() => {}
            other => tracing::debug!(
                target: "vfs::webdav",
                ok = other.is_ok(),
                "清理 MOVE 失败的临时文件时出错"
            ),
        }
        Err(err)
    }

    async fn delete_file(&self, path: &VfsPath) -> Result<()> {
        if path.is_root() {
            return Err(LekisError::invalid("webdav: 不能删除根目录"));
        }
        let target = self.url_for(path);
        let resp = self
            .send("DELETE", &target, || {
                self.client.request(Method::DELETE, &target)
            })
            .await?;
        if resp.status().is_success() || resp.status() == reqwest::StatusCode::NOT_FOUND {
            Ok(())
        } else {
            Err(status_err(resp.status(), "DELETE"))
        }
    }

    async fn create_dir_all(&self, dir: &VfsPath) -> Result<()> {
        if dir.is_root() {
            return Ok(());
        }
        let mkcol = extension_method("MKCOL")?;
        let mut prefix = VfsPath::root();
        for part in dir.as_str().split('/') {
            prefix = prefix.join(part);
            let url = self.url_for(&prefix);
            let resp = self
                .send("MKCOL", &url, || self.client.request(mkcol.clone(), &url))
                .await?;
            let status = resp.status();
            // 201 新建；405 已存在（RFC 4918 允许两种语义，都当成功）。
            if status.is_success() || status == StatusCode::METHOD_NOT_ALLOWED {
                continue;
            }
            return Err(status_err(status, "MKCOL"));
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// PROPFIND 解析
// ---------------------------------------------------------------------------

/// PROPFIND 响应里的一个 `<response>` 条目（还没换算成 [`VfsPath`]）。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct DavEntry {
    /// 原始 `href` 文本（未解码）。
    href: String,
    /// 是否目录（`<resourcetype>` 里有 `<collection/>`）。
    is_dir: bool,
    /// `getcontentlength`，拿不到时为 0。
    size: u64,
    /// `getlastmodified` 换算成 Unix 毫秒，拿不到时为 0。
    mtime_ms: i64,
}

impl DavEntry {
    /// 换算成本 crate 的元数据。
    fn meta(&self) -> FileMeta {
        FileMeta {
            kind: if self.is_dir {
                EntryKind::Dir
            } else {
                EntryKind::File
            },
            size: if self.is_dir { 0 } else { self.size },
            mtime_ms: self.mtime_ms,
        }
    }
}

/// 解析 `multistatus` 状态机。
#[derive(Default)]
struct DavParser {
    entries: Vec<DavEntry>,
    current: Option<DavEntry>,
    /// 正在收集文本的元素：`(本地名, 缓冲区)`。
    capture: Option<(String, String)>,
}

impl DavParser {
    /// 遇到开始标签。
    fn on_start(&mut self, name: &str, empty: bool) {
        match name {
            "response" => self.current = Some(DavEntry::default()),
            "collection" => {
                if let Some(cur) = self.current.as_mut() {
                    cur.is_dir = true;
                }
            }
            "href" | "getcontentlength" | "getlastmodified" => {
                self.capture = Some((name.to_string(), String::new()));
            }
            _ => {}
        }
        // `<collection/>`、`<href/>` 这类自闭合标签不会再有 End 事件。
        if empty {
            self.on_end(name);
        }
    }

    /// 遇到结束标签。
    fn on_end(&mut self, name: &str) {
        if let Some((captured, text)) = self.capture.take() {
            if captured == name {
                if let Some(cur) = self.current.as_mut() {
                    match name {
                        "href" => cur.href = text.trim().to_string(),
                        "getcontentlength" => {
                            cur.size = text.trim().parse::<u64>().unwrap_or(0);
                        }
                        "getlastmodified" => {
                            cur.mtime_ms = parse_http_date_ms(text.trim());
                        }
                        _ => {}
                    }
                }
                return;
            }
            // 不是我们关心的元素，放回去继续收集。
            self.capture = Some((captured, text));
        }
        if name == "response" {
            if let Some(cur) = self.current.take() {
                // 多留两条（目录自己 + 1），让 list_dir 能发现超限而不是悄悄截断。
                if !cur.href.is_empty() && self.entries.len() < MAX_ENTRIES + 2 {
                    self.entries.push(cur);
                }
            }
        }
    }

    /// 遇到文本 / CDATA / 实体引用。
    fn on_text(&mut self, text: &str) {
        if let Some((_, buf)) = self.capture.as_mut() {
            buf.push_str(text);
        }
    }
}

/// 解析 PROPFIND / multistatus 响应。**只看本地名**，前缀（`d:` / `D:` / `lp1:` / 无）一律忽略。
fn parse_propfind(xml: &str) -> Result<Vec<DavEntry>> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().allow_dangling_amp = true;
    let mut parser = DavParser::default();
    loop {
        let event = reader.read_event().map_err(|e| {
            LekisError::new(
                ErrorCode::Decode,
                format!("webdav: PROPFIND 响应不是合法 XML: {e}"),
            )
        })?;
        match &event {
            Event::Start(start) => {
                let name = local_name(start);
                parser.on_start(&name, false);
            }
            Event::Empty(start) => {
                let name = local_name(start);
                parser.on_start(&name, true);
            }
            Event::End(end) => {
                let name = end.name().local_name().into_inner().to_ascii_lowercase();
                parser.on_end(&name);
            }
            Event::Text(text) => parser.on_text(&text.xml10_content()),
            Event::CData(data) => parser.on_text(data),
            Event::GeneralRef(reference) => {
                // `BytesRef` 解引用即实体名（如 `amp`、`#x4E2D`）。
                let name: &str = reference;
                if let Some(ch) = resolve_entity(name) {
                    let mut buf = [0u8; 4];
                    parser.on_text(ch.encode_utf8(&mut buf));
                }
            }
            Event::Eof => break,
            _ => {}
        }
    }
    if parser.current.is_some() {
        // 服务器故意截断响应时，最后一条也能收下。
        if let Some(cur) = parser.current.take() {
            if !cur.href.is_empty() {
                parser.entries.push(cur);
            }
        }
    }
    Ok(parser.entries)
}

/// 取开始标签的本地名（小写）。XML 名字大小写敏感，但各家服务器的实际写法不统一，统一小写更稳。
fn local_name(start: &BytesStart<'_>) -> String {
    start.name().local_name().into_inner().to_ascii_lowercase()
}

/// 解析 XML 预定义实体和数字字符引用。拿不准就返回 `None`（宁缺勿错）。
fn resolve_entity(name: &str) -> Option<char> {
    match name {
        "amp" => Some('&'),
        "lt" => Some('<'),
        "gt" => Some('>'),
        "quot" => Some('"'),
        "apos" => Some('\''),
        _ => {
            let rest = name.strip_prefix('#')?;
            let code = match rest.strip_prefix(['x', 'X']) {
                Some(hex) => u32::from_str_radix(hex, 16).ok()?,
                None => rest.parse::<u32>().ok()?,
            };
            char::from_u32(code)
        }
    }
}

/// `getlastmodified` 的 HTTP 日期（RFC 1123）换算成 Unix 毫秒。
fn parse_http_date_ms(text: &str) -> i64 {
    if text.is_empty() {
        return 0;
    }
    let Ok(time) = httpdate::parse_http_date(text) else {
        return 0;
    };
    match time.duration_since(std::time::UNIX_EPOCH) {
        Ok(d) => i64::try_from(d.as_millis()).unwrap_or(i64::MAX),
        // 1970 之前的时间不重要，按 0 处理。
        Err(_) => 0,
    }
}

// ---------------------------------------------------------------------------
// URL / 路径互转（纯函数，便于单测）
// ---------------------------------------------------------------------------

/// [`WebDavVfs::new`] 解析出来的东西。
#[derive(Debug, Clone, PartialEq, Eq)]
struct ParsedBase {
    /// 不含 userinfo、不含结尾 `/` 的 URL。
    base_url: String,
    /// percent 解码后、不含结尾 `/` 的绝对路径。
    base_path: String,
    /// URL userinfo 里的用户名（percent 解码后）。
    user: String,
    /// URL userinfo 里的密码（percent 解码后）。
    password: Option<String>,
    /// URL 是否带了 userinfo（带空的也算）。
    has_credentials: bool,
}

/// 解析源地址，顺便把凭据从 URL 里剥干净（凭据不能留在 URL 里被日志打出来）。
fn parse_base_url(base_url: &str) -> Result<ParsedBase> {
    if !(base_url.starts_with("http://") || base_url.starts_with("https://")) {
        return Err(LekisError::invalid(
            "WebDAV address must start with http(s)://",
        ));
    }
    let mut url = url::Url::parse(base_url)
        .map_err(|e| LekisError::invalid(format!("WebDAV 地址不合法: {e}")))?;
    let user = percent_decode_str(url.username())
        .decode_utf8_lossy()
        .to_string();
    let password = url
        .password()
        .map(|p| percent_decode_str(p).decode_utf8_lossy().to_string());
    let has_credentials = !user.is_empty() || password.is_some();
    let base_path = percent_decode_str(url.path())
        .decode_utf8_lossy()
        .trim_end_matches('/')
        .to_string();

    // 剥掉 userinfo。
    let _ = url.set_username("");
    let _ = url.set_password(None);
    let clean = url.as_str().trim_end_matches('/').to_string();

    Ok(ParsedBase {
        base_url: clean,
        base_path,
        user,
        password,
        has_credentials,
    })
}

/// [`VfsPath`] → 绝对 URL。
fn url_for_base(base_url: &str, path: &VfsPath) -> String {
    if path.is_root() {
        format!("{base_url}/")
    } else {
        let encoded: Vec<String> = path
            .as_str()
            .split('/')
            .map(|seg| utf8_percent_encode(seg, PATH_SEGMENT).to_string())
            .collect();
        format!("{base_url}/{}", encoded.join("/"))
    }
}

/// 服务器返回的 `href` → [`VfsPath`]。
///
/// 服务器可能返回绝对 URL（`https://host/dav/a.mp3`）、协议相对 URL（`//host/dav/a.mp3`）、
/// 也可能只给绝对路径（`/dav/a.mp3`），三种都要能处理；路径还要 percent 解码。
fn href_to_path(base_path: &str, href: &str) -> Option<VfsPath> {
    let href = href.trim();
    if href.is_empty() {
        return None;
    }
    let raw_path = if href.starts_with("http://") || href.starts_with("https://") {
        url::Url::parse(href).ok()?.path().to_string()
    } else if let Some(rest) = href.strip_prefix("//") {
        url::Url::parse(&format!("http:{rest}"))
            .ok()?
            .path()
            .to_string()
    } else {
        href.to_string()
    };
    let decoded = percent_decode_str(&raw_path).decode_utf8().ok()?;
    let decoded = decoded.trim_end_matches('/');
    let rest = decoded.strip_prefix(base_path)?;
    if !rest.is_empty() && !rest.starts_with('/') {
        // 只是前缀相同（`/dav` vs `/davos`），不是同一个源。
        return None;
    }
    VfsPath::parse(rest)
}

/// Digest 认证要用请求行里的 `uri`（path + query）。
fn request_uri(url: &str) -> String {
    match url::Url::parse(url) {
        Ok(parsed) => {
            let mut uri = parsed.path().to_string();
            if let Some(query) = parsed.query() {
                uri.push('?');
                uri.push_str(query);
            }
            uri
        }
        Err(_) => url.to_string(),
    }
}

/// 每个实例固定一个 cnonce。
fn cnonce() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{:x}", md5::compute(nanos.to_le_bytes()))
}

/// 构造 `Authorization: Digest ...`。
fn digest_authorization(
    user: &str,
    password: &str,
    challenge: &DigestChallenge,
    method: &str,
    uri: &str,
    nc: u32,
    cnonce: &str,
) -> String {
    let hex_md5 = |input: &str| format!("{:x}", md5::compute(input.as_bytes()));
    let algorithm = challenge
        .algorithm
        .clone()
        .unwrap_or_else(|| "MD5".to_string());
    let mut ha1 = hex_md5(&format!("{user}:{}:{password}", challenge.realm));
    if algorithm.eq_ignore_ascii_case("MD5-sess") {
        ha1 = hex_md5(&format!("{ha1}:{}:{cnonce}", challenge.nonce));
    }
    let ha2 = hex_md5(&format!("{method}:{uri}"));
    let qop = challenge
        .qop
        .as_deref()
        .and_then(|set| set.split(',').map(str::trim).find(|q| *q == "auth"));
    let nc_hex = format!("{nc:08x}");
    let response = match qop {
        Some(_) => hex_md5(&format!(
            "{ha1}:{}:{nc_hex}:{cnonce}:auth:{ha2}",
            challenge.nonce
        )),
        None => hex_md5(&format!("{ha1}:{}:{ha2}", challenge.nonce)),
    };
    let mut header = format!(
        "Digest username=\"{user}\", realm=\"{}\", nonce=\"{}\", uri=\"{uri}\", \
         algorithm={algorithm}, response=\"{response}\"",
        challenge.realm, challenge.nonce
    );
    if qop.is_some() {
        header.push_str(&format!(", qop=auth, nc={nc_hex}, cnonce=\"{cnonce}\""));
    }
    if let Some(opaque) = &challenge.opaque {
        header.push_str(&format!(", opaque=\"{opaque}\""));
    }
    header
}

/// 解析 `WWW-Authenticate: Digest realm="..", nonce="..", qop="auth", ...`。
fn parse_digest_challenge(raw: &str) -> Option<DigestChallenge> {
    let rest = raw.trim();
    // 用字节切片比较，避免在多字节字符边界上切 `&str`（会 panic）。
    let rest = if rest.as_bytes().get(..6)?.eq_ignore_ascii_case(b"digest") {
        rest.get(6..)?
    } else {
        return None;
    };
    let mut challenge = DigestChallenge::default();
    for (key, value) in split_auth_params(rest) {
        match key.to_ascii_lowercase().as_str() {
            "realm" => challenge.realm = value,
            "nonce" => challenge.nonce = value,
            "qop" => challenge.qop = Some(value),
            "opaque" => challenge.opaque = Some(value),
            "algorithm" => challenge.algorithm = Some(value),
            _ => {}
        }
    }
    if challenge.nonce.is_empty() {
        return None;
    }
    Some(challenge)
}

/// 把 `k=v, k="v", ...` 拆成键值对（值去掉引号和转义）。
fn split_auth_params(input: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let mut chars = input.chars().peekable();
    loop {
        // 跳过逗号和空白。
        while matches!(chars.peek(), Some(c) if *c == ',' || c.is_whitespace()) {
            chars.next();
        }
        if chars.peek().is_none() {
            break;
        }
        let mut key = String::new();
        while let Some(c) = chars.peek() {
            if *c == '=' || *c == ',' {
                break;
            }
            key.push(*c);
            chars.next();
        }
        if chars.peek() == Some(&'=') {
            chars.next();
        }
        while matches!(chars.peek(), Some(c) if c.is_whitespace()) {
            chars.next();
        }
        let mut value = String::new();
        if chars.peek() == Some(&'"') {
            chars.next();
            while let Some(c) = chars.next() {
                match c {
                    '"' => break,
                    '\\' => {
                        if let Some(next) = chars.next() {
                            value.push(next);
                        }
                    }
                    _ => value.push(c),
                }
            }
        } else {
            while let Some(c) = chars.peek() {
                if *c == ',' {
                    break;
                }
                value.push(*c);
                chars.next();
            }
        }
        let key = key.trim().to_string();
        if key.is_empty() {
            break;
        }
        out.push((key, value.trim().to_string()));
    }
    out
}

// ---------------------------------------------------------------------------
// 杂项
// ---------------------------------------------------------------------------

/// 构造扩展 HTTP 方法（PROPFIND / MKCOL / MOVE 都不在 `http::Method` 的常量里）。
fn extension_method(name: &str) -> Result<Method> {
    Method::from_bytes(name.as_bytes())
        .map_err(|_| LekisError::internal(format!("webdav: 无法构造 HTTP 方法 {name}")))
}

/// 把 HTTP 状态码翻译成错误。**不要**把 URL 拼进消息（里面虽然已经没有凭据，但没必要外泄）。
fn status_err(status: StatusCode, what: &str) -> LekisError {
    let code = match status.as_u16() {
        401 => ErrorCode::Auth,
        403 => ErrorCode::PermissionDenied,
        404 => ErrorCode::NotFound,
        409 | 422 | 423 => ErrorCode::InvalidArgument,
        429 => ErrorCode::RateLimited,
        500..=599 => ErrorCode::Network,
        400..=499 => ErrorCode::InvalidArgument,
        _ => ErrorCode::Io,
    };
    LekisError::new(
        code,
        format!("webdav: {what} 失败，HTTP {}", status.as_u16()),
    )
}

/// reqwest 错误 → [`LekisError`]。URL 里不含凭据（构造时已剥掉），可以安全带出来。
fn net_err(err: reqwest::Error) -> LekisError {
    let code = if err.is_timeout() || err.is_connect() {
        ErrorCode::Network
    } else if err.is_decode() {
        ErrorCode::Decode
    } else {
        ErrorCode::Io
    };
    LekisError::new(code, format!("webdav: {err}"))
}

/// 边收边裁：跳过前 `skip` 字节，最多收 `want` 字节。
///
/// 服务器忽略 `Range`（返回 200 + 整个文件）时不必把整首歌读进内存。
async fn read_body_capped(resp: Response, want: u64, skip: u64) -> Result<Bytes> {
    let mut stream = resp.bytes_stream();
    let mut to_skip = skip;
    let mut out: Vec<u8> = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(net_err)?;
        let mut chunk = chunk.as_ref();
        if to_skip > 0 {
            let len = chunk.len() as u64;
            if to_skip >= len {
                to_skip -= len;
                continue;
            }
            chunk = &chunk[to_skip as usize..];
            to_skip = 0;
        }
        let remaining = want - out.len() as u64;
        let take = (chunk.len() as u64).min(remaining) as usize;
        out.extend_from_slice(&chunk[..take]);
        if out.len() as u64 >= want {
            break;
        }
    }
    Ok(Bytes::from(out))
}

#[cfg(test)]
mod tests {
    // 测试里允许 unwrap/expect/panic：失败信息比返回 Result 更直观。
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;

    /// 四种命名空间前缀混排 + 中文文件名 + percent 编码 + 绝对 URL / 绝对路径两种 href。
    const SAMPLE: &str = r#"<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:" xmlns:lp1="DAV:">
  <d:response>
    <d:href>/dav/Music/</d:href>
    <d:propstat>
      <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <D:response xmlns:D="DAV:">
    <D:href>/dav/Music/%E5%91%A8%E6%9D%B0%E4%BC%A6/%E6%99%B4%E5%A4%A9.flac</D:href>
    <D:propstat>
      <D:prop>
        <D:resourcetype/>
        <D:getcontentlength>12345678</D:getcontentlength>
        <D:getlastmodified>Wed, 21 Oct 2015 07:28:00 GMT</D:getlastmodified>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
  <response xmlns="DAV:">
    <href>https://example.com/dav/readme.txt</href>
    <propstat><prop><resourcetype/><getcontentlength>42</getcontentlength></prop></propstat>
  </response>
  <lp1:response xmlns:lp1="DAV:">
    <lp1:href>https://example.com/dav/Album%20A/track%201.mp3</lp1:href>
    <lp1:propstat>
      <lp1:prop>
        <lp1:resourcetype/>
        <lp1:getcontentlength>7</lp1:getcontentlength>
        <lp1:getlastmodified>Wed, 21 Oct 2015 07:28:00 GMT</lp1:getlastmodified>
      </lp1:prop>
    </lp1:propstat>
  </lp1:response>
</d:multistatus>"#;

    #[test]
    fn parses_propfind_with_any_namespace_prefix() {
        let entries = parse_propfind(SAMPLE).expect("解析失败");
        assert_eq!(entries.len(), 4, "四个 response 都要解析出来: {entries:?}");
        assert_eq!(entries[0].href, "/dav/Music/");
        assert!(entries[0].is_dir);
        assert_eq!(entries[1].size, 12_345_678);
        assert!(!entries[1].is_dir);
        // 2015-10-21T07:28:00Z
        assert_eq!(entries[1].mtime_ms, 1_445_412_480_000);
        assert_eq!(entries[2].size, 42);
        assert_eq!(entries[3].size, 7);
        assert_eq!(entries[3].mtime_ms, 1_445_412_480_000);
    }

    #[test]
    fn href_absolute_url_and_path_both_work() {
        let base = "/dav";
        let cases = [
            ("/dav/Music/a.flac", "Music/a.flac"),
            ("https://example.com/dav/Music/a.flac", "Music/a.flac"),
            ("//example.com/dav/Music/a.flac", "Music/a.flac"),
            (
                "/dav/Music/%E5%91%A8%E6%9D%B0%E4%BC%A6/%E6%99%B4%E5%A4%A9.flac",
                "Music/周杰伦/晴天.flac",
            ),
            (
                "https://example.com/dav/Album%20A/track%201.mp3",
                "Album A/track 1.mp3",
            ),
            ("/dav/Music/", "Music"),
            ("/dav/", ""),
            ("/dav", ""),
        ];
        for (href, expected) in cases {
            let path = href_to_path(base, href).unwrap_or_else(|| panic!("{href} 解析失败"));
            assert_eq!(path.as_str(), expected, "href={href}");
        }
    }

    #[test]
    fn href_outside_base_is_rejected() {
        assert!(href_to_path("/dav", "/davos/x.mp3").is_none());
        assert!(href_to_path("/dav", "/other/x.mp3").is_none());
        assert!(href_to_path("/dav", "").is_none());
    }

    #[test]
    fn root_base_path_keeps_everything() {
        let path = href_to_path("", "/Music/周杰伦/晴天.flac").expect("应能解析");
        assert_eq!(path.as_str(), "Music/周杰伦/晴天.flac");
    }

    #[test]
    fn url_encodes_chinese_and_spaces() {
        let path = VfsPath::parse("Music/周杰伦/晴天 1.flac").expect("路径非法");
        let url = url_for_base("https://example.com/dav", &path);
        assert_eq!(
            url,
            "https://example.com/dav/Music/%E5%91%A8%E6%9D%B0%E4%BC%A6/%E6%99%B4%E5%A4%A9%201.flac"
        );
        // 能反解回 VfsPath。
        let back = href_to_path("/dav", &url).expect("应能反解");
        assert_eq!(back, path);
    }

    #[test]
    fn root_path_url_has_trailing_slash() {
        assert_eq!(
            url_for_base("https://example.com/dav", &VfsPath::root()),
            "https://example.com/dav/"
        );
    }

    #[test]
    fn base_url_strips_credentials() {
        let parsed = parse_base_url("https://bob:s3cret@example.com/dav/Music/").expect("应能解析");
        assert_eq!(parsed.base_url, "https://example.com/dav/Music");
        assert_eq!(parsed.base_path, "/dav/Music");
        assert_eq!(parsed.user, "bob");
        assert_eq!(parsed.password.as_deref(), Some("s3cret"));
        assert!(parsed.has_credentials);
        // 凭据绝不能留在 base_url 里被日志打出去。
        assert!(!parsed.base_url.contains("s3cret"));
        assert!(!parsed.base_url.contains("bob"));
    }

    #[test]
    fn base_url_decodes_userinfo() {
        let parsed = parse_base_url("http://a%40b:p%20w@host:8080/dav").expect("应能解析");
        assert_eq!(parsed.user, "a@b");
        assert_eq!(parsed.password.as_deref(), Some("p w"));
        assert_eq!(parsed.base_url, "http://host:8080/dav");
        assert_eq!(parsed.base_path, "/dav");
    }

    #[test]
    fn bad_base_url_is_invalid() {
        assert!(parse_base_url("ftp://example.com/dav").is_err());
        assert!(parse_base_url("not a url").is_err());
    }

    #[test]
    fn digest_challenge_is_parsed() {
        let challenge = parse_digest_challenge(
            r#"Digest realm="NAS", qop="auth,auth-int", nonce="abc123", opaque="xyz", algorithm=MD5"#,
        )
        .expect("应能解析");
        assert_eq!(challenge.realm, "NAS");
        assert_eq!(challenge.nonce, "abc123");
        assert_eq!(challenge.qop.as_deref(), Some("auth,auth-int"));
        assert_eq!(challenge.opaque.as_deref(), Some("xyz"));
        assert_eq!(challenge.algorithm.as_deref(), Some("MD5"));
        assert!(parse_digest_challenge(r#"Basic realm="NAS""#).is_none());
        assert!(parse_digest_challenge("Digest realm=\"x\"").is_none());
    }

    #[test]
    fn digest_authorization_matches_rfc2617_example() {
        // RFC 7616 / RFC 2617 的经典例子。
        let challenge = DigestChallenge {
            realm: "testrealm@host.com".to_string(),
            nonce: "dcd98b7102dd2f0e8b11d0f600bfb0c093".to_string(),
            qop: Some("auth".to_string()),
            opaque: Some("5ccc069c403ebaf9f0171e9517f40e41".to_string()),
            algorithm: Some("MD5".to_string()),
        };
        let header = digest_authorization(
            "Mufasa",
            "Circle Of Life",
            &challenge,
            "GET",
            "/dir/index.html",
            1,
            "0a4f113b",
        );
        assert!(
            header.contains(r#"response="6629fae49393a05397450978507c4ef1""#),
            "实际: {header}"
        );
        assert!(header.contains("qop=auth"));
        assert!(header.contains("nc=00000001"));
    }

    #[test]
    fn request_uri_keeps_query() {
        assert_eq!(
            request_uri("https://example.com/dav/a.mp3?x=1"),
            "/dav/a.mp3?x=1"
        );
        assert_eq!(request_uri("https://example.com/dav/a.mp3"), "/dav/a.mp3");
    }

    #[test]
    fn entity_refs_resolve() {
        assert_eq!(resolve_entity("amp"), Some('&'));
        assert_eq!(resolve_entity("#65"), Some('A'));
        assert_eq!(resolve_entity("#x4E2D"), Some('中'));
        assert_eq!(resolve_entity("nope"), None);
    }

    #[test]
    fn status_codes_map_to_error_codes() {
        assert_eq!(
            status_err(StatusCode::NOT_FOUND, "GET").code,
            ErrorCode::NotFound
        );
        assert_eq!(
            status_err(StatusCode::UNAUTHORIZED, "GET").code,
            ErrorCode::Auth
        );
        assert_eq!(
            status_err(StatusCode::FORBIDDEN, "GET").code,
            ErrorCode::PermissionDenied
        );
        assert_eq!(
            status_err(StatusCode::TOO_MANY_REQUESTS, "GET").code,
            ErrorCode::RateLimited
        );
        assert_eq!(
            status_err(StatusCode::BAD_GATEWAY, "GET").code,
            ErrorCode::Network
        );
    }
}
