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
    /// 控制端开口第一句：自我介绍和本次会话的随机数。
    Hello {
        /// 控制端设备 ID。
        device_id: String,
        /// 界面显示的名字。
        name: String,
        /// 平台（`android` / `windows` / ...）。
        platform: String,
        /// 控制端的 [`PROTOCOL_VERSION`]。
        version: u32,
        /// 控制端抽的随机数（十六进制），后面的所有 MAC 都绑定它。
        nonce: String,
    },
    /// 被控端的回答（和 `Hello` 同样的身份字段，另加两个标志）。
    Welcome {
        /// 被控端设备 ID。
        device_id: String,
        /// 被控端显示的名字。
        name: String,
        /// 被控端平台。
        platform: String,
        /// 被控端的 [`PROTOCOL_VERSION`]。
        version: u32,
        /// 被控端抽的随机数（十六进制）。
        nonce: String,
        /// 被控端是否认识这个控制端（有长期密钥）。
        paired: bool,
        /// 被控端是否允许被控制。
        accepting: bool,
    },
    /// 已配对过：控制端证明自己知道长期密钥。
    Auth {
        /// `auth_mac(key, "c", transcript)`。
        mac: String,
    },
    /// 认证通过：被控端也证明一次（双向认证）。
    AuthOk {
        /// `auth_mac(key, "s", transcript)`。
        mac: String,
    },
    /// 没配对过：控制端的临时 X25519 公钥。
    PairStart {
        /// 控制端临时公钥（十六进制）。
        public_key: String,
    },
    /// 被控端的临时公钥（同时界面上显示 6 位配对码）。
    PairChallenge {
        /// 被控端临时公钥（十六进制）。
        public_key: String,
    },
    /// 用户在控制端输入配对码后，证明两边算出的是同一个配对密钥。
    PairConfirm {
        /// `pair_confirm(pair_key, "c")`。
        mac: String,
    },
    /// 配对成功：双方各自保存派生出的长期密钥。
    PairOk {
        /// `pair_confirm(pair_key, "s")`。
        mac: String,
    },
    /// 拒绝（之后服务端关闭连接）。
    Denied {
        /// 拒绝的原因。
        reason: DenyReason,
    },
    /// 一条请求。
    Request {
        /// 控制端自己的序号（回复里原样带回）。
        id: u64,
        /// 请求内容。
        req: Request,
    },
    /// 请求的回复。
    Response {
        /// 对应请求的序号。
        id: u64,
        /// 成功时的结果。
        #[serde(default)]
        result: Option<Reply>,
        /// 失败时的说明；控制端按内部错误处理。
        #[serde(default)]
        error: Option<String>,
    },
    /// 被控端主动推送的状态。
    Event {
        /// 最新的播放状态。
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
    Control {
        /// 交给被控端的动作。
        action: Control,
    },
    /// 替换队列并（可选）开始播放。
    SetQueue {
        /// 曲目（按控制端队列的顺序）。
        items: Vec<TrackRef>,
        /// 从第几首开始（`items` 的下标）。
        start: u32,
        /// 从这一首的第几毫秒开始。
        position_ms: u64,
        /// 装好队列后是否立刻播放（`false` 时暂停在这一首）。
        play: bool,
    },
    /// 队列的一页。
    GetQueue {
        /// 跳过多少首。
        offset: u32,
        /// 最多返回多少首。
        limit: u32,
    },
    /// 某首歌的封面（被控端本机的曲目 ID）。
    GetArtwork {
        /// 被控端的曲目 ID。
        track_id: i64,
    },
}

/// 播放控制动作。
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Control {
    /// 播放 / 继续。
    Play,
    /// 暂停。
    Pause,
    /// 播放中就暂停，否则开始播放。
    Toggle,
    /// 下一首。
    Next,
    /// 上一首（播了几秒时回到本曲开头）。
    Previous,
    /// 跳转。
    Seek {
        /// 目标位置（毫秒）。
        position_ms: u64,
    },
    /// 音量。
    Volume {
        /// 0..=1。
        volume: f32,
    },
    /// 循环模式。
    Repeat {
        /// 新的循环模式。
        mode: RepeatMode,
    },
    /// 随机模式。
    Shuffle {
        /// 新的随机模式。
        mode: ShuffleMode,
    },
    /// 播放队列里的第 N 首。
    PlayIndex {
        /// 队列下标（越界时取最后一首）。
        index: u32,
    },
}

/// 回复。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Reply {
    /// 完成了，没有返回值。
    Ok,
    /// 当前状态。
    State {
        /// 被控端的状态快照。
        state: RemoteState,
    },
    /// 队列装好了。
    Queued {
        /// 每首歌分别是怎么解析的。
        report: QueueReport,
    },
    /// 队列的一页。
    Queue {
        /// 这一页的曲目（按被控端的播放顺序）。
        items: Vec<RemoteTrack>,
    },
    /// 封面。
    Artwork {
        /// 封面字节的 base64；被控端也没有封面时为 `None`。
        data_base64: Option<String>,
    },
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
    /// MusicBrainz 录音 ID（能拿到时）。
    #[serde(default)]
    pub mbid: Option<String>,
    /// 标题。
    pub title: String,
    /// 艺人（多个用 ` / ` 拼在一起）。
    pub artist: String,
    /// 专辑名。
    #[serde(default)]
    pub album: Option<String>,
    /// 时长（毫秒）。
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
    /// 音源类型。
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
    /// 一共几首。
    pub total: u32,
    /// 从被控端自己的资料库里找到的。
    pub library: u32,
    /// 同一个音源上直接读的。
    pub same_source: u32,
    /// 走控制端局域网流的。
    pub stream: u32,
    /// 解析不了、被跳过的。
    pub skipped: u32,
}

/// 被控端上的一首歌（显示用）。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct RemoteTrack {
    /// 被控端本机的曲目 ID。
    pub id: i64,
    /// 跨设备 ID。
    #[serde(default)]
    pub uid: Option<String>,
    /// 标题。
    pub title: String,
    /// 艺人。
    pub artist: String,
    /// 专辑名。
    #[serde(default)]
    pub album: Option<String>,
    /// 时长（毫秒）。
    pub duration_ms: u64,
    /// 这首歌是怎么解析的（两边都有时用来自哪里）。
    #[serde(default)]
    pub via: Option<MediaVia>,
}

/// 被控端的播放状态。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RemoteState {
    /// 播放 / 暂停 / 缓冲……
    pub state: PlaybackState,
    /// 当前曲目（空队列时为 `None`）。
    #[serde(default)]
    pub track: Option<RemoteTrack>,
    /// 当前位置（毫秒）。
    pub position_ms: u64,
    /// 当前曲目时长（毫秒）。
    pub duration_ms: u64,
    /// 音量（0..=1）。
    pub volume: f32,
    /// 队列长度。
    pub queue_len: u32,
    /// 当前曲目在队列里的下标。
    #[serde(default)]
    pub queue_index: Option<u32>,
    /// 循环模式。
    pub repeat: RepeatMode,
    /// 随机模式。
    pub shuffle: ShuffleMode,
    /// 队列版本（变了就说明队列内容变了）。
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
