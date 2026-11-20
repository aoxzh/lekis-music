//! 线上协议：TCP 上一行一个 JSON 对象（UTF-8，`\n` 结尾）。
//!
//! 同一个端口还提供媒体流（HTTP/1.1 `GET /stream/<token>`），服务端看第一个字节分流：
//! `{` 是控制通道，其他按 HTTP 处理（见 `stream.rs`）。
//!
//! ```text
//! 控制端                              被控端
//! Hello{id,name,nonce} ─────────────▶
//!                     ◀───────────── Welcome{id,name,nonce,paired,accepting}
//! 已配对： Auth{mac_c} ─────────────▶
//!                     ◀───────────── AuthOk{mac_s}
//! 未配对： PairStart{pub_c} ────────▶   （被控端界面显示 6 位配对码）
//!                     ◀───────────── PairChallenge{pub_s}
//!          PairConfirm{mac_c} ──────▶   （用户在控制端输入配对码）
//!                     ◀───────────── PairOk{mac_s}
//! 之后： Request{id,req} ⇄ Response{id,...}；被控端主动推 Event{state}
//! ```

use lekis_types::{LekisError, PlaybackState, RepeatMode, Result, ShuffleMode, SourceKind};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt};

/// 协议版本。不兼容的修改 +1。
pub const PROTOCOL_VERSION: u32 = 1;
/// DNS-SD 服务类型。
pub const SERVICE_TYPE: &str = "_lekis._tcp.local.";
/// 一行最多多大（封面走 base64，留够余量）。
pub const MAX_LINE: usize = 8 * 1024 * 1024;
/// 一次转移最多带多少首（当前曲目前后各取一段）。
pub const MAX_TRANSFER_ITEMS: usize = 1000;

/// 线上消息。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum Msg {
    Hello {
        device_id: String,
        name: String,
        platform: String,
        version: u32,
        nonce: String,
    },
    Welcome {
        device_id: String,
        name: String,
        platform: String,
        version: u32,
        nonce: String,
        /// 被控端是否认识这个控制端（有长期密钥）。
        paired: bool,
        /// 被控端是否允许被控制。
        accepting: bool,
    },
    Auth {
        mac: String,
    },
    AuthOk {
        mac: String,
    },
    PairStart {
        public_key: String,
    },
    PairChallenge {
        public_key: String,
    },
    PairConfirm {
        mac: String,
    },
    PairOk {
        mac: String,
    },
    /// 拒绝（之后服务端关闭连接）。
    Denied {
        reason: DenyReason,
    },
    Request {
        id: u64,
        req: Request,
    },
    Response {
        id: u64,
        #[serde(default)]
        result: Option<Reply>,
        #[serde(default)]
        error: Option<String>,
    },
    /// 被控端主动推送的状态。
    Event {
        state: RemoteState,
    },
}

/// 拒绝原因。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DenyReason {
    /// 对方关闭了"允许其他设备控制"。
    NotAccepting,
    /// 认证失败（密钥不对，多半是对方删除了配对）。
    AuthFailed,
    /// 配对码不对。
    WrongCode,
    /// 配对请求太频繁。
    RateLimited,
    /// 协议版本不兼容。
    Incompatible,
    /// 协议错误。
    Protocol,
}

/// 请求。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Request {
    /// 当前状态。
    GetState,
    /// 开始推送状态（Event）。
    Subscribe,
    /// 播放控制。
    Control { action: Control },
    /// 替换队列并（可选）开始播放。
    SetQueue {
        items: Vec<TrackRef>,
        start: u32,
        position_ms: u64,
        play: bool,
    },
    /// 队列的一页。
    GetQueue { offset: u32, limit: u32 },
    /// 某首歌的封面（被控端本机的曲目 ID）。
    GetArtwork { track_id: i64 },
}

/// 播放控制动作。
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Control {
    Play,
    Pause,
    Toggle,
    Next,
    Previous,
    Seek { position_ms: u64 },
    Volume { volume: f32 },
    Repeat { mode: RepeatMode },
    Shuffle { mode: ShuffleMode },
    PlayIndex { index: u32 },
}

/// 回复。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Reply {
    Ok,
    State { state: RemoteState },
    Queued { report: QueueReport },
    Queue { items: Vec<RemoteTrack> },
    Artwork { data_base64: Option<String> },
}

/// 一首歌在被控端是怎么播的（CST-03）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MediaVia {
    /// 被控端自己的资料库里有同一首歌。
    Library,
    /// 两边接了同一个音源（同一 NAS 共享 / 同一服务器），被控端直接从音源读。
    SameSource,
    /// 控制端通过局域网把文件流给被控端。
    Stream,
}

/// 控制端发给被控端的曲目描述。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TrackRef {
    /// 跨设备 ID（`TrackUid`）。
    pub uid: String,
    #[serde(default)]
    pub mbid: Option<String>,
    pub title: String,
    pub artist: String,
    #[serde(default)]
    pub album: Option<String>,
    pub duration_ms: u64,
    /// 控制端上这首歌所在的文件（按质量从高到低）。
    #[serde(default)]
    pub files: Vec<FileRef>,
    /// 控制端提供的局域网流地址（兜底）。
    #[serde(default)]
    pub stream_url: Option<String>,
}

/// 控制端上的一个文件位置。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileRef {
    pub kind: SourceKind,
    /// 音源地址（按优先级），不含凭据。
    pub addresses: Vec<String>,
    /// 源内路径（文件系统类源）。
    #[serde(default)]
    pub path: String,
    /// 服务器条目 ID（服务器类源）。
    #[serde(default)]
    pub external_id: Option<String>,
}

/// `SetQueue` 的结果：每种方式各解析了几首。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct QueueReport {
    pub total: u32,
    pub library: u32,
    pub same_source: u32,
    pub stream: u32,
    /// 解析不了、被跳过的。
    pub skipped: u32,
}

/// 被控端上的一首歌（显示用）。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct RemoteTrack {
    /// 被控端本机的曲目 ID。
    pub id: i64,
    #[serde(default)]
    pub uid: Option<String>,
    pub title: String,
    pub artist: String,
    #[serde(default)]
    pub album: Option<String>,
    pub duration_ms: u64,
    #[serde(default)]
    pub via: Option<MediaVia>,
}

/// 被控端的播放状态。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RemoteState {
    pub state: PlaybackState,
    #[serde(default)]
    pub track: Option<RemoteTrack>,
    pub position_ms: u64,
    pub duration_ms: u64,
    pub volume: f32,
    pub queue_len: u32,
    #[serde(default)]
    pub queue_index: Option<u32>,
    pub repeat: RepeatMode,
    pub shuffle: ShuffleMode,
    pub queue_version: u64,
}

/// 写一条消息。
pub(crate) async fn write_msg<W: AsyncWrite + Unpin>(w: &mut W, msg: &Msg) -> Result<()> {
    let mut line =
        serde_json::to_vec(msg).map_err(|e| LekisError::internal(format!("encode: {e}")))?;
    line.push(b'\n');
    w.write_all(&line).await?;
    w.flush().await?;
    Ok(())
}

/// 读一条消息；对方关闭连接时返回 `None`。
pub(crate) async fn read_msg<R: AsyncBufRead + Unpin>(r: &mut R) -> Result<Option<Msg>> {
    let mut buf = Vec::new();
    loop {
        let chunk = r.fill_buf().await?;
        if chunk.is_empty() {
            return if buf.is_empty() {
                Ok(None)
            } else {
                Err(LekisError::invalid("connection closed mid-message"))
            };
        }
        if let Some(pos) = chunk.iter().position(|&b| b == b'\n') {
            buf.extend_from_slice(&chunk[..pos]);
            r.consume(pos + 1);
            break;
        }
        let n = chunk.len();
        buf.extend_from_slice(chunk);
        r.consume(n);
        if buf.len() > MAX_LINE {
            return Err(LekisError::invalid("message too large"));
        }
    }
    serde_json::from_slice(&buf)
        .map(Some)
        .map_err(|e| LekisError::invalid(format!("bad message: {e}")))
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn messages_roundtrip_through_lines() {
        let msgs = vec![
            Msg::Hello {
                device_id: "a".into(),
                name: "客厅".into(),
                platform: "windows".into(),
                version: PROTOCOL_VERSION,
                nonce: "n".into(),
            },
            Msg::Request {
                id: 7,
                req: Request::Control {
                    action: Control::Seek { position_ms: 1234 },
                },
            },
            Msg::Response {
                id: 7,
                result: Some(Reply::Ok),
                error: None,
            },
        ];
        let mut wire = Vec::new();
        for m in &msgs {
            write_msg(&mut wire, m).await.unwrap();
        }
        let mut reader = tokio::io::BufReader::new(&wire[..]);
        let mut n = 0;
        while let Some(m) = read_msg(&mut reader).await.unwrap() {
            assert_eq!(
                serde_json::to_string(&m).unwrap(),
                serde_json::to_string(&msgs[n]).unwrap()
            );
            n += 1;
        }
        assert_eq!(n, 3);
    }
}
