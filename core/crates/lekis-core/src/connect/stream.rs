//! 局域网媒体流（CST-03 的兜底路径）：一个极小的 HTTP/1.1 服务器，只认
//! `GET|HEAD /stream/<令牌>.<扩展名>`，支持 `Range: bytes=a-b`。
//!
//! 令牌是转移队列时为每首歌随机生成的 128 位值，12 小时后失效；不知道令牌就读不到任何文件，
//! 也列不出目录。每个请求处理完就关闭连接（播放器的 Range 读取器会按需重连）。

use crate::Services;
use lekis_playback::MediaLocation;
use lekis_types::{LekisError, Result, TrackId};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
use tokio::net::TcpStream;

/// 令牌有效期。
const TOKEN_TTL: Duration = Duration::from_secs(12 * 3600);
/// 每次往套接字里写多大一块。
const CHUNK: u64 = 256 * 1024;

/// 流令牌表。
#[derive(Default)]
pub(crate) struct StreamTokens {
    map: Mutex<HashMap<String, (TrackId, Instant)>>,
}

impl StreamTokens {
    /// 为一首歌发一个令牌（同一首歌在有效期内复用同一个令牌）。
    pub(crate) fn issue(&self, id: TrackId) -> Result<String> {
        let mut map = self
            .map
            .lock()
            .map_err(|_| LekisError::internal("stream tokens poisoned"))?;
        let now = Instant::now();
        map.retain(|_, (_, at)| now.duration_since(*at) < TOKEN_TTL);
        if let Some((token, _)) = map.iter().find(|(_, (t, _))| *t == id) {
            return Ok(token.clone());
        }
        let token = super::crypto::random_hex(16)?;
        map.insert(token.clone(), (id, now));
        Ok(token)
    }

    pub(crate) fn lookup(&self, token: &str) -> Option<TrackId> {
        let map = self.map.lock().ok()?;
        let (id, at) = map.get(token)?;
        (at.elapsed() < TOKEN_TTL).then_some(*id)
    }
}

/// 根据文件路径猜扩展名（给对方的解码器做探测提示）。
pub(crate) fn extension_of(path: &str) -> Option<&str> {
    let name = path.rsplit(['/', '\\']).next()?;
    let (_, ext) = name.rsplit_once('.')?;
    (!ext.is_empty() && ext.len() <= 5 && ext.bytes().all(|b| b.is_ascii_alphanumeric()))
        .then_some(ext)
}

fn content_type(ext: Option<&str>) -> &'static str {
    match ext.map(str::to_ascii_lowercase).as_deref() {
        Some("flac") => "audio/flac",
        Some("mp3") => "audio/mpeg",
        Some("m4a" | "mp4" | "aac" | "alac") => "audio/mp4",
        Some("ogg" | "oga" | "opus") => "audio/ogg",
        Some("wav") => "audio/wav",
        Some("aif" | "aiff") => "audio/aiff",
        _ => "application/octet-stream",
    }
}

/// 解析 `bytes=a-b` / `bytes=a-` / `bytes=-n`。
fn parse_range(header: &str, total: u64) -> Option<(u64, u64)> {
    let spec = header.trim().strip_prefix("bytes=")?;
    let spec = spec.split(',').next()?.trim();
    let (a, b) = spec.split_once('-')?;
    if total == 0 {
        return None;
    }
    let (start, end) = if a.is_empty() {
        let n: u64 = b.parse().ok()?;
        (total.saturating_sub(n), total - 1)
    } else {
        let start: u64 = a.parse().ok()?;
        let end = if b.is_empty() {
            total - 1
        } else {
            b.parse::<u64>().ok()?.min(total - 1)
        };
        (start, end)
    };
    (start <= end && start < total).then_some((start, end))
}

struct HttpRequest {
    method: String,
    path: String,
    range: Option<String>,
}

async fn read_head(stream: &mut TcpStream) -> Result<HttpRequest> {
    let mut buf = Vec::with_capacity(1024);
    let mut chunk = [0u8; 1024];
    loop {
        let n = stream.read(&mut chunk).await?;
        if n == 0 {
            return Err(LekisError::invalid("connection closed"));
        }
        buf.extend_from_slice(&chunk[..n]);
        if buf.windows(4).any(|w| w == b"\r\n\r\n") {
            break;
        }
        if buf.len() > 16 * 1024 {
            return Err(LekisError::invalid("request head too large"));
        }
    }
    let text = String::from_utf8_lossy(&buf);
    let mut lines = text.split("\r\n");
    let mut first = lines.next().unwrap_or_default().split_whitespace();
    let method = first.next().unwrap_or_default().to_string();
    let path = first.next().unwrap_or_default().to_string();
    let mut range = None;
    for line in lines {
        if let Some((k, v)) = line.split_once(':') {
            if k.trim().eq_ignore_ascii_case("range") {
                range = Some(v.trim().to_string());
            }
        }
    }
    Ok(HttpRequest {
        method,
        path,
        range,
    })
}

async fn respond_status(stream: &mut TcpStream, status: &str) {
    let _ = stream
        .write_all(
            format!("HTTP/1.1 {status}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                .as_bytes(),
        )
        .await;
}

/// 处理一个 HTTP 连接。
pub(crate) async fn serve(mut stream: TcpStream, s: Arc<Services>) {
    let req = match tokio::time::timeout(Duration::from_secs(10), read_head(&mut stream)).await {
        Ok(Ok(req)) => req,
        _ => return,
    };
    if req.method != "GET" && req.method != "HEAD" {
        respond_status(&mut stream, "405 Method Not Allowed").await;
        return;
    }
    let token = req
        .path
        .strip_prefix("/stream/")
        .map(|t| t.split(['.', '?']).next().unwrap_or_default())
        .unwrap_or_default();
    let Some(track_id) = s.connect.tokens.lookup(token) else {
        respond_status(&mut stream, "404 Not Found").await;
        return;
    };
    let media = match s.resolver.resolve(track_id).await {
        Ok(m) => m,
        Err(e) => {
            tracing::warn!(target: "connect", %track_id, error = %e, "stream resolve failed");
            respond_status(&mut stream, "502 Bad Gateway").await;
            return;
        }
    };
    let head_only = req.method == "HEAD";
    let result = match media.location {
        MediaLocation::Vfs { source_id, path } => {
            let vfs = s
                .vfs_get(source_id)
                .or_else(|| lekis_playback::vfs_access::resolve(source_id));
            match vfs {
                Some(vfs) => serve_vfs(&mut stream, vfs, &path, req.range, head_only).await,
                None => Err(LekisError::not_found("source not open")),
            }
        }
        MediaLocation::CachedFile { path } => {
            serve_file(&mut stream, &path, req.range, head_only).await
        }
        MediaLocation::Url { url, headers } => {
            serve_proxy(&mut stream, &url, &headers, req.range, head_only).await
        }
    };
    if let Err(e) = result {
        tracing::debug!(target: "connect", %track_id, error = %e, "stream ended with error");
    }
}

/// 写响应头，返回要发的字节区间。
async fn write_head(
    stream: &mut TcpStream,
    total: u64,
    range: Option<String>,
    ext: Option<&str>,
) -> Result<Option<(u64, u64)>> {
    let ctype = content_type(ext);
    let (status, start, end) = match range.as_deref() {
        Some(r) => match parse_range(r, total) {
            Some((a, b)) => ("206 Partial Content", a, b),
            None => {
                let msg = format!(
                    "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{total}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                );
                stream.write_all(msg.as_bytes()).await?;
                return Ok(None);
            }
        },
        None => ("200 OK", 0, total.saturating_sub(1)),
    };
    let len = if total == 0 { 0 } else { end - start + 1 };
    let mut head = format!(
        "HTTP/1.1 {status}\r\nContent-Type: {ctype}\r\nAccept-Ranges: bytes\r\nContent-Length: {len}\r\nConnection: close\r\n"
    );
    if status.starts_with("206") {
        head.push_str(&format!("Content-Range: bytes {start}-{end}/{total}\r\n"));
    }
    head.push_str("\r\n");
    stream.write_all(head.as_bytes()).await?;
    Ok((len > 0).then_some((start, end)))
}

async fn serve_vfs(
    stream: &mut TcpStream,
    vfs: Arc<dyn lekis_vfs::Vfs>,
    path: &str,
    range: Option<String>,
    head_only: bool,
) -> Result<()> {
    let vpath = lekis_vfs::VfsPath::parse(path).ok_or_else(|| LekisError::invalid("bad path"))?;
    let total = vfs.stat(&vpath).await?.size;
    let Some((start, end)) = write_head(stream, total, range, extension_of(path)).await? else {
        return Ok(());
    };
    if head_only {
        return Ok(());
    }
    let mut pos = start;
    while pos <= end {
        let upto = (pos + CHUNK).min(end + 1);
        let bytes = vfs.read_range(&vpath, pos..upto).await?;
        if bytes.is_empty() {
            break;
        }
        stream.write_all(&bytes).await?;
        pos += bytes.len() as u64;
    }
    Ok(())
}

async fn serve_file(
    stream: &mut TcpStream,
    path: &str,
    range: Option<String>,
    head_only: bool,
) -> Result<()> {
    let mut file = tokio::fs::File::open(path).await?;
    let total = file.metadata().await?.len();
    let Some((start, end)) = write_head(stream, total, range, extension_of(path)).await? else {
        return Ok(());
    };
    if head_only {
        return Ok(());
    }
    file.seek(std::io::SeekFrom::Start(start)).await?;
    let mut left = end - start + 1;
    let mut buf = vec![0u8; CHUNK as usize];
    while left > 0 {
        let want = left.min(CHUNK) as usize;
        let n = file.read(&mut buf[..want]).await?;
        if n == 0 {
            break;
        }
        stream.write_all(&buf[..n]).await?;
        left -= n as u64;
    }
    Ok(())
}

/// 服务器类音源：本机代为请求再转发（被控端没有这台服务器的凭据）。
async fn serve_proxy(
    stream: &mut TcpStream,
    url: &str,
    headers: &[(String, String)],
    range: Option<String>,
    head_only: bool,
) -> Result<()> {
    let client = reqwest::Client::new();
    let mut req = if head_only {
        client.head(url)
    } else {
        client.get(url)
    };
    for (k, v) in headers {
        req = req.header(k.as_str(), v.as_str());
    }
    if let Some(r) = &range {
        req = req.header("Range", r.as_str());
    }
    let mut resp = req
        .send()
        .await
        .map_err(|e| LekisError::new(lekis_types::ErrorCode::Network, e.to_string()))?;
    let status = resp.status();
    let mut head = format!(
        "HTTP/1.1 {} {}\r\nConnection: close\r\nAccept-Ranges: bytes\r\n",
        status.as_u16(),
        status.canonical_reason().unwrap_or("OK")
    );
    for name in ["content-type", "content-length", "content-range"] {
        if let Some(v) = resp.headers().get(name).and_then(|v| v.to_str().ok()) {
            head.push_str(&format!("{name}: {v}\r\n"));
        }
    }
    head.push_str("\r\n");
    stream.write_all(head.as_bytes()).await?;
    if head_only {
        return Ok(());
    }
    while let Some(chunk) = resp
        .chunk()
        .await
        .map_err(|e| LekisError::new(lekis_types::ErrorCode::Network, e.to_string()))?
    {
        stream.write_all(&chunk).await?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ranges_parse_and_clamp() {
        assert_eq!(parse_range("bytes=0-", 100), Some((0, 99)));
        assert_eq!(parse_range("bytes=10-19", 100), Some((10, 19)));
        assert_eq!(parse_range("bytes=90-200", 100), Some((90, 99)));
        assert_eq!(parse_range("bytes=-10", 100), Some((90, 99)));
        assert_eq!(parse_range("bytes=100-", 100), None);
        assert_eq!(parse_range("items=0-1", 100), None);
    }

    #[test]
    fn extensions_are_guessed_from_paths() {
        assert_eq!(extension_of("周杰伦/晴天.flac"), Some("flac"));
        assert_eq!(extension_of("C:\\a\\b.MP3"), Some("MP3"));
        assert_eq!(extension_of("noext"), None);
        assert_eq!(content_type(Some("FLAC")), "audio/flac");
    }

    #[test]
    fn tokens_resolve_and_are_reused() {
        let tokens = StreamTokens::default();
        let a = tokens.issue(TrackId(1)).unwrap_or_default();
        assert_eq!(tokens.issue(TrackId(1)).unwrap_or_default(), a);
        assert_eq!(tokens.lookup(&a), Some(TrackId(1)));
        assert_eq!(tokens.lookup("nope"), None);
        assert_eq!(a.len(), 32);
    }
}
