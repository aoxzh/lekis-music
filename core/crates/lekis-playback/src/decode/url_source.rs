//! 通过 HTTP Range 分块读取的 symphonia 媒体源（PLY-08）。
//!
//! 播放网络源（服务器源、插件源、网络电台）时 `MediaSource::location` 是
//! [`MediaLocation::Url`](crate::MediaLocation::Url)。symphonia 要的是同步 `Read + Seek`，
//! 这里用 **reqwest 的 blocking 客户端**把 HTTP Range 请求包成一个可 seek 的媒体源：
//!
//! ```text
//! symphonia ──read/seek──► HttpRangeSource ──Range: bytes=a-b──► 服务器
//!                              │
//!                              └── 256 KiB 对齐的块缓存（最多 8 块，顺序读时预取下一块）
//! ```
//!
//! **线程模型**：只在专用解码线程上用。`reqwest::blocking` 内部会起自己的运行时线程，
//! 不能在 tokio worker 上调用（会被 `block_in_place` 的检查拦住），而解码线程本来就不是
//! tokio worker（见 [`crate::session`]）。
//!
//! **请求头**：[`MediaLocation::Url`] 带的那组 header（服务器源的 token 之类）会附加到
//! **每一个**请求上（HEAD / 长度探测 / Range），否则鉴权源会 401。
//!
//! 长度探测（决定能不能 seek）：先 `HEAD` 看 `Content-Length`；拿不到就 `GET` +
//! `Range: bytes=0-0`，从 `Content-Range: bytes 0-0/总长` 里读总长。两条路都失败
//! （例如网络电台不发长度）就退化成**不可 seek 的流式读取**：`is_seekable()` 为 `false`，
//! `byte_len()` 为 `None`，symphonia 会把它当直播流处理，只做顺序读。
//!
//! [`MediaLocation::Url`]: crate::MediaLocation::Url

use lekis_types::{ErrorCode, LekisError, Result};
use reqwest::header::{CONTENT_LENGTH, CONTENT_RANGE, RANGE};
use reqwest::{Method, StatusCode};
use std::collections::VecDeque;
use std::io::{Error as IoError, ErrorKind, Read, Seek, SeekFrom};
use std::time::Duration;

/// 一块的大小：一次 Range 请求拉 256 KiB。
const CHUNK_BYTES: u64 = 256 * 1024;

/// 块缓存最多保留几块，超出丢最旧的（8 × 256 KiB = 2 MiB 上限）。
const MAX_CACHED_CHUNKS: usize = 8;

/// 当前块剩余不到这个量时，顺手把下一块拉进缓存。
const PREFETCH_MARGIN: u64 = CHUNK_BYTES / 4;

/// 建立 TCP 连接的超时。
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// 单次请求（含读 body）的超时。
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

/// 请求头里的默认 UA（有些服务器会拒绝没有 UA 的请求）。
const USER_AGENT: &str = "Lekis/0.1 (playback)";

/// 一块缓存数据。
struct CachedChunk {
    /// 这一块在文件里的起始偏移（`CHUNK_BYTES` 对齐）。
    start: u64,
    /// 这一块的字节。
    data: Vec<u8>,
}

/// 通过 HTTP Range 分块读取的 symphonia 媒体源。
///
/// 构造时就会做一次长度探测（可能需要一次网络往返）。之后 `read` 只在必要时发
/// Range 请求，`seek` 只改游标不发请求。
pub struct HttpRangeSource {
    client: reqwest::blocking::Client,
    url: String,
    headers: Vec<(String, String)>,
    /// 当前读位置。
    pos: u64,
    /// 总长度；`None` 表示服务器没给长度（直播流），此时不可 seek。
    len: Option<u64>,
    /// 块缓存（最多 [`MAX_CACHED_CHUNKS`] 块，先进先出淘汰）。
    chunks: VecDeque<CachedChunk>,
    /// 不可 seek 时的流式响应体。
    stream: Option<Box<dyn Read + Send + Sync>>,
    /// 累计读到的字节数（诊断用）。
    bytes_read: u64,
    /// 累计发出的 HTTP 请求数（诊断用）。
    requests: u64,
}

impl HttpRangeSource {
    /// 打开一个 HTTP(S) 地址。
    ///
    /// `headers` 会附加到每一个请求上。长度探测失败意味着流不可 seek，但**不算错误**——
    /// 网络电台就是这样，照样能顺序播放。
    ///
    /// **只能在非 tokio worker 线程上调用**（内部用 blocking 客户端）。
    pub fn new(url: impl Into<String>, headers: Vec<(String, String)>) -> Result<Self> {
        let client = reqwest::blocking::Client::builder()
            .connect_timeout(CONNECT_TIMEOUT)
            .timeout(REQUEST_TIMEOUT)
            .pool_max_idle_per_host(2)
            .user_agent(USER_AGENT)
            .build()
            .map_err(|e| {
                LekisError::new(ErrorCode::Network, format!("cannot build http client: {e}"))
            })?;
        Self::with_client(client, url, headers)
    }

    /// 用一个已经配置好的客户端打开地址（代理、证书、测试里的 `no_proxy` 等）。
    pub fn with_client(
        client: reqwest::blocking::Client,
        url: impl Into<String>,
        headers: Vec<(String, String)>,
    ) -> Result<Self> {
        let url = url.into();
        let mut source = Self {
            client,
            url,
            headers,
            pos: 0,
            len: None,
            chunks: VecDeque::new(),
            stream: None,
            bytes_read: 0,
            requests: 0,
        };
        source.len = source.probe_len()?;
        Ok(source)
    }

    /// 总长度；`None` = 服务器没给（不可 seek）。
    pub fn byte_len(&self) -> Option<u64> {
        self.len
    }

    /// 是否可以 seek（只有在知道总长度时才行）。
    pub fn is_seekable(&self) -> bool {
        self.len.is_some()
    }

    /// 已经从网络读到的字节数。
    pub fn bytes_read(&self) -> u64 {
        self.bytes_read
    }

    /// 累计发出的 HTTP 请求数。
    pub fn requests(&self) -> u64 {
        self.requests
    }

    /// 长度探测：先 HEAD，再 `GET Range: bytes=0-0`。
    ///
    /// - 拿到长度 → `Ok(Some(len))`，可 seek；
    /// - 服务器正常响应但没给长度（网络电台、chunked 流）→ `Ok(None)`，退化成顺序读；
    /// - 鉴权失败 / 404 / 网络不通 → `Err`，这种源根本没救，早点报错。
    fn probe_len(&mut self) -> Result<Option<u64>> {
        match self.send(Method::HEAD, None) {
            Ok(resp) => {
                let status = resp.status();
                if status.is_success() {
                    if let Some(len) = header_u64(resp.headers(), CONTENT_LENGTH) {
                        return Ok(Some(len));
                    }
                } else if is_fatal_status(status) {
                    return Err(map_status(status, &self.url));
                } else {
                    // 有些服务器（CDN、签名直链）不允许 HEAD：别当错误，改用 Range 探测。
                    tracing::debug!(
                        target: "playback::decode",
                        url = %self.url,
                        %status,
                        "http HEAD rejected, probing length with a ranged GET"
                    );
                }
            }
            Err(e) => {
                if is_fatal_request_error(&e) {
                    return Err(LekisError::new(
                        ErrorCode::Network,
                        format!("GET {}: {e}", self.url),
                    ));
                }
                tracing::debug!(
                    target: "playback::decode",
                    url = %self.url,
                    error = %e,
                    "http HEAD failed, probing length with a ranged GET"
                );
            }
        }

        let resp = self
            .send(Method::GET, Some("bytes=0-0".to_string()))
            .map_err(|e| LekisError::new(ErrorCode::Network, format!("GET {}: {e}", self.url)))?;
        let status = resp.status();
        if status == StatusCode::PARTIAL_CONTENT {
            return Ok(content_range_total(resp.headers()));
        }
        if is_fatal_status(status) {
            return Err(map_status(status, &self.url));
        }
        // 服务器忽略了 Range（返回 200 / 或干脆不是 2xx）：当直播流处理。
        tracing::debug!(
            target: "playback::decode",
            url = %self.url,
            %status,
            "server did not honour the probe range, treating stream as non-seekable"
        );
        Ok(None)
    }

    /// 发一个请求，带上固定的 header 组。`range` 是 `Range` 头的值。
    fn send(
        &mut self,
        method: Method,
        range: Option<String>,
    ) -> reqwest::Result<reqwest::blocking::Response> {
        self.requests += 1;
        let mut req = self.client.request(method, &self.url);
        if let Some(range) = range {
            req = req.header(RANGE, range);
        }
        for (name, value) in &self.headers {
            req = req.header(name.as_str(), value.as_str());
        }
        req.send()
    }

    /// 用 Range 拉一整块（`start` 必须是 [`CHUNK_BYTES`] 对齐的）。
    fn fetch_chunk(&mut self, start: u64) -> Result<Vec<u8>> {
        let len = self.len.unwrap_or(u64::MAX);
        let end = (start + CHUNK_BYTES - 1).min(len.saturating_sub(1));
        let range = format!("bytes={start}-{end}");
        let resp = self
            .send(Method::GET, Some(range.clone()))
            .map_err(|e| LekisError::new(ErrorCode::Network, format!("GET {}: {e}", self.url)))?;
        let status = resp.status();
        if status == StatusCode::PARTIAL_CONTENT {
            let data = resp.bytes().map_err(|e| {
                LekisError::new(
                    ErrorCode::Network,
                    format!("cannot read body of {}: {e}", self.url),
                )
            })?;
            if data.is_empty() {
                return Err(LekisError::new(
                    ErrorCode::Decode,
                    format!("range {range} of {} returned no data", self.url),
                ));
            }
            return Ok(data.to_vec());
        }
        if status == StatusCode::OK {
            // 服务器无视 Range 直接回整个文件：这样没法假装自己是可 seek 的源，
            // 明确报 Decode 而不是静默读出错误数据。
            return Err(LekisError::new(
                ErrorCode::Decode,
                format!(
                    "{} ignored Range {range}, cannot stream it as a seekable source",
                    self.url
                ),
            ));
        }
        Err(map_status(status, &self.url))
    }

    /// 找一块起点恰好是 `start` 的缓存。
    fn chunk_index(&self, start: u64) -> Option<usize> {
        self.chunks.iter().position(|c| c.start == start)
    }

    /// 放入一块缓存，超出上限丢最旧的。
    fn cache_put(&mut self, start: u64, data: Vec<u8>) {
        if let Some(idx) = self.chunk_index(start) {
            let _ = self.chunks.remove(idx);
        }
        self.chunks.push_back(CachedChunk { start, data });
        while self.chunks.len() > MAX_CACHED_CHUNKS {
            let _ = self.chunks.pop_front();
        }
    }

    /// 丢掉起点是 `start` 的缓存（块已经耗尽时用）。
    fn cache_drop(&mut self, start: u64) {
        if let Some(idx) = self.chunk_index(start) {
            let _ = self.chunks.remove(idx);
        }
    }

    /// 可 seek 时的读：按块取数据，块不满就补一次 Range。
    fn read_ranged(&mut self, buf: &mut [u8]) -> Result<usize> {
        let len = self.len.unwrap_or(0);
        if self.pos >= len {
            return Ok(0);
        }
        let want = usize::try_from((len - self.pos).min(buf.len() as u64)).unwrap_or(buf.len());
        let start = self.pos / CHUNK_BYTES * CHUNK_BYTES;

        // 缓存命中要求这一块还能覆盖住当前游标（服务器少给字节时旧块会"用完"）。
        let usable = self.chunk_index(start).filter(|&idx| {
            let chunk = &self.chunks[idx];
            self.pos >= chunk.start && self.pos < chunk.start + chunk.data.len() as u64
        });
        let idx = match usable {
            Some(idx) => idx,
            None => {
                self.cache_drop(start);
                let data = self.fetch_chunk(start)?;
                self.bytes_read += data.len() as u64;
                self.cache_put(start, data);
                // 刚放进去的块在队尾；长度未知的情况下按起点再查一次。
                self.chunk_index(start).unwrap_or(0)
            }
        };

        let (chunk_end, copied) = {
            let chunk = &self.chunks[idx];
            let offset = usize::try_from(self.pos - chunk.start).unwrap_or(0);
            let available = chunk.data.len().saturating_sub(offset);
            let n = available.min(want);
            buf[..n].copy_from_slice(&chunk.data[offset..offset + n]);
            (chunk.start + (offset + n) as u64, n)
        };
        self.pos += copied as u64;
        self.maybe_prefetch(chunk_end);
        Ok(copied)
    }

    /// 顺序读时提前把下一块拉进缓存（失败只记日志，不影响本次读）。
    fn maybe_prefetch(&mut self, chunk_end: u64) {
        let Some(len) = self.len else {
            return;
        };
        if self.pos >= len || chunk_end.saturating_sub(self.pos) > PREFETCH_MARGIN {
            return;
        }
        let next_start = self.pos / CHUNK_BYTES * CHUNK_BYTES;
        if self.chunk_index(next_start).is_some() {
            return;
        }
        match self.fetch_chunk(next_start) {
            Ok(data) => {
                self.bytes_read += data.len() as u64;
                self.cache_put(next_start, data);
            }
            Err(e) => {
                tracing::debug!(
                    target: "playback::decode",
                    url = %self.url,
                    offset = next_start,
                    error = %e,
                    "http range prefetch failed"
                );
            }
        }
    }

    /// 不可 seek 时的读：第一次读时发起一个普通 GET，之后接着读这个响应体。
    fn read_stream(&mut self, buf: &mut [u8]) -> Result<usize> {
        if self.stream.is_none() {
            let resp = self.send(Method::GET, None).map_err(|e| {
                LekisError::new(ErrorCode::Network, format!("GET {}: {e}", self.url))
            })?;
            let status = resp.status();
            if !status.is_success() {
                return Err(map_status(status, &self.url));
            }
            self.stream = Some(Box::new(resp));
        }
        let Some(stream) = self.stream.as_mut() else {
            return Ok(0);
        };
        let n = stream.read(buf).map_err(|e| {
            LekisError::new(
                ErrorCode::Network,
                format!("cannot read stream of {}: {e}", self.url),
            )
        })?;
        self.bytes_read += n as u64;
        Ok(n)
    }
}

impl std::fmt::Debug for HttpRangeSource {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // 客户端里带着连接池和证书，不打出来。
        f.debug_struct("HttpRangeSource")
            .field("url", &self.url)
            .field("pos", &self.pos)
            .field("len", &self.len)
            .field("cached_chunks", &self.chunks.len())
            .field("streaming", &self.stream.is_some())
            .field("bytes_read", &self.bytes_read)
            .field("requests", &self.requests)
            .finish()
    }
}

impl Read for HttpRangeSource {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        if self.len.is_some() {
            self.read_ranged(buf).map_err(to_io)
        } else {
            self.read_stream(buf).map_err(to_io)
        }
    }
}

impl Seek for HttpRangeSource {
    fn seek(&mut self, from: SeekFrom) -> std::io::Result<u64> {
        // 只改游标：真正的数据在 read 时按块拉，所以 seek 不会卡住。
        let new_pos = match from {
            SeekFrom::Start(offset) => offset as i128,
            SeekFrom::Current(delta) => self.pos as i128 + delta as i128,
            SeekFrom::End(delta) => match self.len {
                Some(len) => len as i128 + delta as i128,
                None => {
                    return Err(IoError::new(
                        ErrorKind::Unsupported,
                        "cannot seek from end with unknown length",
                    ))
                }
            },
        };
        if new_pos < 0 {
            return Err(IoError::new(
                ErrorKind::InvalidInput,
                "seek to negative offset",
            ));
        }
        self.pos = new_pos as u64;
        Ok(self.pos)
    }
}

impl symphonia::core::io::MediaSource for HttpRangeSource {
    fn is_seekable(&self) -> bool {
        self.len.is_some()
    }

    fn byte_len(&self) -> Option<u64> {
        self.len
    }
}

/// 编译期确认适配器满足 symphonia 对 `MediaSource` 的线程安全要求。
#[allow(dead_code)]
fn assert_source_traits() {
    fn check<T: symphonia::core::io::MediaSource + Send + Sync>() {}
    check::<HttpRangeSource>();
}

/// 读 `Content-Length` 这类整数头。
///
/// 不用 `Response::content_length()`：它对 HEAD 响应会返回 body 的长度（0），
/// 而我们要的是响应头里声明的资源长度。
fn header_u64(
    headers: &reqwest::header::HeaderMap,
    name: reqwest::header::HeaderName,
) -> Option<u64> {
    headers
        .get(name)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.trim().parse::<u64>().ok())
}

/// 从 `Content-Range: bytes 0-0/12345` 里取总长度（`*` 表示未知）。
fn content_range_total(headers: &reqwest::header::HeaderMap) -> Option<u64> {
    let raw = headers.get(CONTENT_RANGE)?.to_str().ok()?;
    let total = raw.rsplit('/').next()?.trim();
    total.parse::<u64>().ok()
}

/// 把 HTTP 状态码映射成播放侧的 [`ErrorCode`]。
fn map_status(status: StatusCode, url: &str) -> LekisError {
    let code = match status {
        StatusCode::UNAUTHORIZED
        | StatusCode::FORBIDDEN
        | StatusCode::PROXY_AUTHENTICATION_REQUIRED => ErrorCode::Auth,
        StatusCode::NOT_FOUND | StatusCode::GONE => ErrorCode::NotFound,
        // 416：请求的范围超出资源长度，说明流内容有问题（或者文件不完整）。
        StatusCode::RANGE_NOT_SATISFIABLE => ErrorCode::Decode,
        _ => ErrorCode::Network,
    };
    LekisError::new(code, format!("http {status} for {url}"))
}

/// 这个状态码是不是「这个源根本没救」的（而不是「换个方法还能试」）。
///
/// 401/403/404 这类直接失败，没必要再用 Range GET 探一遍；
/// 405（Method Not Allowed）之类的要放过去走 GET 探测。
fn is_fatal_status(status: StatusCode) -> bool {
    matches!(
        status,
        StatusCode::UNAUTHORIZED
            | StatusCode::FORBIDDEN
            | StatusCode::PROXY_AUTHENTICATION_REQUIRED
            | StatusCode::NOT_FOUND
            | StatusCode::GONE
    )
}

/// 这个请求错误是不是连接层面的硬失败（DNS 解析不了、连不上、TLS 握手失败）。
///
/// 请求超时、重定向次数超限这类还有救，不值得让整个源构造失败。
fn is_fatal_request_error(e: &reqwest::Error) -> bool {
    e.is_connect() || e.is_request() || e.is_body() || e.is_decode()
}

/// 把播放错误转成 `std::io::Error`（symphonia 的 `Read`/`Seek` 只能返回 io 错误）。
///
/// 错误类型保留下来，上层诊断时能看出是鉴权问题还是网络问题。
fn to_io(e: LekisError) -> IoError {
    let kind = match e.code {
        ErrorCode::Auth | ErrorCode::PermissionDenied => ErrorKind::PermissionDenied,
        ErrorCode::Decode => ErrorKind::InvalidData,
        ErrorCode::NotFound => ErrorKind::NotFound,
        ErrorCode::InvalidArgument => ErrorKind::InvalidInput,
        _ => ErrorKind::Other,
    };
    IoError::new(kind, e.to_string())
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use std::io::Write as _;
    use std::net::{SocketAddr, TcpListener, TcpStream};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::Duration as StdDuration;

    /// 测试用的假 HTTP 服务行为。
    #[derive(Clone)]
    struct Behaviour {
        /// 资源内容。
        body: Vec<u8>,
        /// 是否在响应里发 `Content-Length`。
        send_length: bool,
        /// 是否支持 Range（支持就回 206 + `Content-Range`）。
        support_range: bool,
        /// 非 0 时直接把所有请求打成这个状态码。
        forced_status: u16,
        /// 请求必须带这个头，否则 401。
        required_header: Option<(String, String)>,
    }

    impl Behaviour {
        fn new(body: Vec<u8>) -> Self {
            Self {
                body,
                send_length: true,
                support_range: true,
                forced_status: 0,
                required_header: None,
            }
        }
    }

    /// 记录下来的一个请求（方法 + 小写头名）。
    #[derive(Clone, Debug)]
    struct Recorded {
        method: String,
        headers: Vec<(String, String)>,
    }

    /// 本地假 HTTP 服务：返回固定字节、可选地支持 Range / 校验 header。
    struct FakeServer {
        addr: SocketAddr,
        log: Arc<Mutex<Vec<Recorded>>>,
        stop: Arc<AtomicBool>,
        join: Option<std::thread::JoinHandle<()>>,
    }

    impl FakeServer {
        fn start(behaviour: Behaviour) -> Self {
            let listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind fake server");
            let addr = listener.local_addr().expect("local addr");
            let log = Arc::new(Mutex::new(Vec::new()));
            let stop = Arc::new(AtomicBool::new(false));
            let thread_log = log.clone();
            let thread_stop = stop.clone();
            let join = std::thread::spawn(move || {
                for incoming in listener.incoming() {
                    if thread_stop.load(Ordering::Acquire) {
                        return;
                    }
                    let Ok(mut stream) = incoming else { continue };
                    let _ = stream.set_read_timeout(Some(StdDuration::from_secs(5)));
                    let _ = handle_connection(&mut stream, &behaviour, &thread_log);
                }
            });
            Self {
                addr,
                log,
                stop,
                join: Some(join),
            }
        }

        fn url(&self, path: &str) -> String {
            format!("http://{}{path}", self.addr)
        }

        fn recorded(&self) -> Vec<Recorded> {
            self.log.lock().expect("log mutex").clone()
        }
    }

    impl Drop for FakeServer {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::Release);
            // 唤醒阻塞在 accept 上的线程。
            let _ = TcpStream::connect(self.addr);
            if let Some(join) = self.join.take() {
                let _ = join.join();
            }
        }
    }

    /// 读一个请求、按行为回响应。
    fn handle_connection(
        stream: &mut TcpStream,
        behaviour: &Behaviour,
        log: &Mutex<Vec<Recorded>>,
    ) -> std::io::Result<()> {
        let mut raw = Vec::new();
        let mut buf = [0u8; 2048];
        let head_end = loop {
            let n = stream.read(&mut buf)?;
            if n == 0 {
                return Ok(());
            }
            raw.extend_from_slice(&buf[..n]);
            if let Some(pos) = raw.windows(4).position(|w| w == b"\r\n\r\n") {
                break pos;
            }
            if raw.len() > 32 * 1024 {
                return Ok(());
            }
        };
        let head = String::from_utf8_lossy(&raw[..head_end]).to_string();
        let mut lines = head.split("\r\n");
        let request_line = lines.next().unwrap_or_default();
        let mut parts = request_line.split_whitespace();
        let method = parts.next().unwrap_or_default().to_ascii_uppercase();
        let headers: Vec<(String, String)> = lines
            .filter_map(|line| {
                line.split_once(':').map(|(name, value)| {
                    (name.trim().to_ascii_lowercase(), value.trim().to_string())
                })
            })
            .collect();
        log.lock().expect("log mutex").push(Recorded {
            method: method.clone(),
            headers: headers.clone(),
        });

        let missing_auth = behaviour
            .required_header
            .as_ref()
            .is_some_and(|(name, value)| !headers.iter().any(|(k, v)| k == name && v == value));
        if behaviour.forced_status != 0 || missing_auth {
            let status = if behaviour.forced_status != 0 {
                behaviour.forced_status
            } else {
                401
            };
            write!(
                stream,
                "HTTP/1.1 {status} Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            )?;
            return Ok(());
        }

        if method == "HEAD" {
            write!(stream, "HTTP/1.1 200 OK\r\n")?;
            if behaviour.send_length {
                write!(stream, "Content-Length: {}\r\n", behaviour.body.len())?;
            }
            write!(stream, "Accept-Ranges: bytes\r\nConnection: close\r\n\r\n")?;
            return Ok(());
        }

        let range = headers
            .iter()
            .find(|(name, _)| name == "range")
            .and_then(|(_, value)| parse_range(value));
        if behaviour.support_range {
            if let Some((first, last)) = range {
                let total = behaviour.body.len() as u64;
                if first >= total {
                    write!(
                        stream,
                        "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{total}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    )?;
                    return Ok(());
                }
                let end = last.min(total - 1) as usize;
                let slice = &behaviour.body[first as usize..=end];
                write!(
                    stream,
                    "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes {first}-{end}/{total}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    slice.len()
                )?;
                stream.write_all(slice)?;
                return Ok(());
            }
        }

        write!(stream, "HTTP/1.1 200 OK\r\n")?;
        if behaviour.send_length {
            write!(stream, "Content-Length: {}\r\n", behaviour.body.len())?;
        }
        write!(stream, "Connection: close\r\n\r\n")?;
        stream.write_all(&behaviour.body)?;
        Ok(())
    }

    /// 解析 `bytes=a-b` / `bytes=a-`。
    fn parse_range(raw: &str) -> Option<(u64, u64)> {
        let spec = raw.trim().strip_prefix("bytes=")?;
        let (first, last) = spec.split_once('-')?;
        let first = first.trim().parse::<u64>().ok()?;
        let last = if last.trim().is_empty() {
            u64::MAX
        } else {
            last.trim().parse::<u64>().ok()?
        };
        Some((first, last))
    }

    /// 测试里用的确定性内容。
    fn pattern(len: usize) -> Vec<u8> {
        (0..len).map(|i| (i * 31 % 251) as u8).collect()
    }

    /// 测试用的客户端：`no_proxy` 保证本地回环请求不会被环境里的代理拦走。
    fn test_client() -> reqwest::blocking::Client {
        reqwest::blocking::Client::builder()
            .no_proxy()
            .timeout(StdDuration::from_secs(10))
            .build()
            .expect("build test client")
    }

    fn open(server: &FakeServer, headers: Vec<(String, String)>) -> HttpRangeSource {
        HttpRangeSource::with_client(test_client(), server.url("/track.flac"), headers)
            .expect("open http source")
    }

    /// 顺序读要能跨块拼回完整内容，且请求数被块缓存压住（不是每次 read 都发请求）。
    #[test]
    fn reads_sequentially_across_chunks() {
        let body = pattern(CHUNK_BYTES as usize * 3 + 12_345);
        let server = FakeServer::start(Behaviour::new(body.clone()));
        let mut source = open(&server, Vec::new());
        assert_eq!(source.byte_len(), Some(body.len() as u64));
        assert!(source.is_seekable());

        let mut got = Vec::new();
        let mut buf = [0u8; 8 * 1024];
        loop {
            let n = source.read(&mut buf).expect("read");
            if n == 0 {
                break;
            }
            got.extend_from_slice(&buf[..n]);
        }
        assert_eq!(got.len(), body.len(), "读到的字节数必须等于资源长度");
        assert_eq!(got, body);
        assert_eq!(source.bytes_read(), body.len() as u64);
        // 4 块 → 探测 1 次 + 4 次 Range（+ 预取也在其中），绝不该一次 read 一个请求。
        assert!(
            source.requests() <= 6,
            "请求数应该接近块数，实际 {}",
            source.requests()
        );
    }

    /// seek 之后读到的必须是那一块的正确字节（随机定位，跨越块边界）。
    #[test]
    fn seeks_then_reads_correct_bytes() {
        let body = pattern(CHUNK_BYTES as usize * 2 + 5_000);
        let server = FakeServer::start(Behaviour::new(body.clone()));
        let mut source = open(&server, Vec::new());

        let targets = [
            300_000u64,
            0,
            (CHUNK_BYTES * 2) - 100,
            body.len() as u64 - 10,
        ];
        for target in targets {
            // seek 只挪游标，不该发请求；读才发。
            let requests_before_seek = source.requests();
            let pos = source
                .seek(SeekFrom::Start(target))
                .expect("seek should only move the cursor");
            assert_eq!(pos, target);
            assert_eq!(
                source.requests(),
                requests_before_seek,
                "seek 到 {target} 不应该发 http 请求"
            );

            let mut buf = [0u8; 256];
            let n = source.read(&mut buf).expect("read after seek");
            let expected = &body[target as usize..(target as usize + n).min(body.len())];
            assert_eq!(&buf[..n], expected, "seek 到 {target} 后数据不对");
        }
    }

    /// `MediaLocation::Url` 里的 header 必须出现在每一个请求上（服务器源的 token）。
    #[test]
    fn forwards_location_headers_on_every_request() {
        let body = pattern(CHUNK_BYTES as usize + 4_096);
        let mut behaviour = Behaviour::new(body.clone());
        behaviour.required_header =
            Some(("authorization".to_string(), "Bearer token-42".to_string()));
        let server = FakeServer::start(behaviour);

        let mut source = open(
            &server,
            vec![("Authorization".to_string(), "Bearer token-42".to_string())],
        );
        let mut got = Vec::new();
        let mut buf = [0u8; 16 * 1024];
        loop {
            let n = source.read(&mut buf).expect("read with auth header");
            if n == 0 {
                break;
            }
            got.extend_from_slice(&buf[..n]);
        }
        assert_eq!(got, body);

        let recorded = server.recorded();
        assert!(recorded.len() >= 2, "至少要有探测 + 读取两类请求");
        for request in &recorded {
            assert!(
                request
                    .headers
                    .iter()
                    .any(|(k, v)| k == "authorization" && v == "Bearer token-42"),
                "{} 请求漏带了鉴权头",
                request.method
            );
        }
    }

    /// 服务器不发 `Content-Length`、也不支持 Range：不可 seek，但顺序读照常。
    #[test]
    fn without_length_is_not_seekable_but_still_reads() {
        let body = pattern(9_000);
        let mut behaviour = Behaviour::new(body.clone());
        behaviour.send_length = false;
        behaviour.support_range = false;
        let server = FakeServer::start(behaviour);

        let mut source = open(&server, Vec::new());
        assert_eq!(source.byte_len(), None);
        assert!(!source.is_seekable(), "没有长度时必须报不可 seek");

        let mut got = Vec::new();
        let mut buf = [0u8; 1_024];
        loop {
            let n = source.read(&mut buf).expect("stream read");
            if n == 0 {
                break;
            }
            got.extend_from_slice(&buf[..n]);
        }
        assert_eq!(got, body);
    }

    /// HEAD 不给长度但 Range 探测能拿到：变成可 seek。
    #[test]
    fn learns_length_from_content_range() {
        let body = pattern(4_000);
        let mut behaviour = Behaviour::new(body.clone());
        behaviour.send_length = false;
        let server = FakeServer::start(behaviour);

        let mut source = open(&server, Vec::new());
        assert_eq!(source.byte_len(), Some(body.len() as u64));
        assert!(source.is_seekable());
        source.seek(SeekFrom::Start(3_990)).expect("seek");
        let mut buf = [0u8; 32];
        let n = source.read(&mut buf).expect("read tail");
        assert_eq!(&buf[..n], &body[3_990..]);
    }

    /// 401 / 403 必须映射成 Auth，而不是笼统的网络错误。
    #[test]
    fn auth_failure_maps_to_auth_error() {
        let mut behaviour = Behaviour::new(pattern(128));
        behaviour.forced_status = 403;
        let server = FakeServer::start(behaviour);
        let err = HttpRangeSource::with_client(test_client(), server.url("/denied"), Vec::new())
            .expect_err("403 必须让构造失败");
        assert_eq!(err.code, ErrorCode::Auth, "403 应该是 Auth: {err}");
    }

    /// 服务器无视 Range：明确报 Decode（不能悄悄返回错位的数据）。
    #[test]
    fn ignored_range_is_a_decode_error() {
        let body = pattern(6_000);
        let mut behaviour = Behaviour::new(body);
        // HEAD 给长度 → 走可 seek 路径；但 GET 不支持 Range → 回 200。
        behaviour.support_range = false;
        let server = FakeServer::start(behaviour);

        let mut source = open(&server, Vec::new());
        assert!(source.is_seekable());
        let mut buf = [0u8; 64];
        let err = source.read(&mut buf).expect_err("无视 Range 时必须报错");
        assert_eq!(err.kind(), ErrorKind::InvalidData);
    }
}
