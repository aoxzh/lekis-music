//! Google Cast v2（Chromecast）纯 Rust 异步客户端。
//!
//! - 发现：使用工作区已有的 `mdns-sd` 浏览 `_googlecast._tcp.local.`；
//! - 传输：基于 `tokio-rustls` + `ring`（不引入 `aws-lc-rs`，桌面与 Android 交叉编译零障碍）；
//! - 协议：4 字节大端长度前缀 + 极简 `CastMessage` Protobuf 编解码 + JSON 载荷
//!   （Connection / Heartbeat / Receiver / Default Media Receiver `CC1AD845`）。

use super::{CastDevice, CastKind, CastMediaItem};
use lekis_types::{ErrorCode, LekisError, Result};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{ClientConfig, DigitallySignedStruct, SignatureScheme};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio_rustls::client::TlsStream;
use tokio_rustls::TlsConnector;

const SERVICE_TYPE: &str = "_googlecast._tcp.local.";
const DEFAULT_MEDIA_RECEIVER_APP_ID: &str = "CC1AD845";
const SENDER_ID: &str = "sender-0";
const RECEIVER_ID: &str = "receiver-0";

const NS_CONNECTION: &str = "urn:x-cast:com.google.cast.tp.connection";
const NS_HEARTBEAT: &str = "urn:x-cast:com.google.cast.tp.heartbeat";
const NS_RECEIVER: &str = "urn:x-cast:com.google.cast.receiver";
const NS_MEDIA: &str = "urn:x-cast:com.google.cast.media";

/// 局域网 Chromecast 使用自签名证书；与 `rust_cast::connect_without_host_verification` 一致。
#[derive(Debug)]
struct LanCastCertVerifier;

impl ServerCertVerifier for LanCastCertVerifier {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> std::result::Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        vec![
            SignatureScheme::RSA_PKCS1_SHA256,
            SignatureScheme::RSA_PKCS1_SHA384,
            SignatureScheme::RSA_PKCS1_SHA512,
            SignatureScheme::ECDSA_NISTP256_SHA256,
            SignatureScheme::ECDSA_NISTP384_SHA384,
            SignatureScheme::RSA_PSS_SHA256,
            SignatureScheme::RSA_PSS_SHA384,
            SignatureScheme::RSA_PSS_SHA512,
            SignatureScheme::ED25519,
        ]
    }
}

/// 通过 mDNS 扫描局域网里的 Chromecast / Google Cast 设备。
pub async fn discover(timeout: Duration) -> Result<Vec<CastDevice>> {
    tokio::task::spawn_blocking(move || discover_blocking(timeout))
        .await
        .map_err(|e| LekisError::internal(format!("chromecast mdns task: {e}")))?
}

fn discover_blocking(timeout: Duration) -> Result<Vec<CastDevice>> {
    let mdns = mdns_sd::ServiceDaemon::new()
        .map_err(|e| LekisError::new(ErrorCode::Network, format!("mdns daemon: {e}")))?;
    let rx = mdns
        .browse(SERVICE_TYPE)
        .map_err(|e| LekisError::new(ErrorCode::Network, format!("mdns browse: {e}")))?;
    let deadline = std::time::Instant::now() + timeout;
    let mut found: HashMap<String, CastDevice> = HashMap::new();
    while let Some(rem) = deadline.checked_duration_since(std::time::Instant::now()) {
        match rx.recv_timeout(rem.min(Duration::from_millis(100))) {
            Ok(mdns_sd::ServiceEvent::ServiceResolved(info)) => {
                let ip = info
                    .get_addresses()
                    .iter()
                    .find(|ip| ip.is_ipv4())
                    .or_else(|| info.get_addresses().iter().next())
                    .map(|ip| ip.to_string());
                let Some(host) = ip else { continue };
                let props = info.get_properties();
                let id = props
                    .get_property_val_str("id")
                    .map(str::to_string)
                    .filter(|s| !s.is_empty())
                    .unwrap_or_else(|| info.get_fullname().to_string());
                let name = props
                    .get_property_val_str("fn")
                    .map(str::to_string)
                    .filter(|s| !s.is_empty())
                    .unwrap_or_else(|| info.get_fullname().to_string());
                let model = props
                    .get_property_val_str("md")
                    .map(str::to_string)
                    .filter(|s| !s.is_empty());
                found.insert(
                    id.clone(),
                    CastDevice {
                        id,
                        name,
                        model,
                        kind: CastKind::Chromecast,
                        host,
                        port: info.get_port(),
                        location_url: None,
                    },
                );
            }
            Ok(_) => {}
            Err(_) => break,
        }
    }
    let _ = mdns.stop_browse(SERVICE_TYPE);
    let _ = mdns.shutdown();
    Ok(found.into_values().collect())
}

/// 一条 Cast v2 通道消息。
#[derive(Debug, Clone)]
struct CastMessage {
    source_id: String,
    destination_id: String,
    namespace: String,
    payload_utf8: String,
}

impl CastMessage {
    /// 编码为 `extensions.api.cast_channel.CastMessage` Protobuf 字节流。
    fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(64 + self.payload_utf8.len());
        // field 1: protocol_version = 0 (CASTV2_1_0), varint (wire type 0)
        push_varint(&mut out, 1 << 3);
        push_varint(&mut out, 0);
        // field 2: source_id
        push_string(&mut out, 2, &self.source_id);
        // field 3: destination_id
        push_string(&mut out, 3, &self.destination_id);
        // field 4: namespace
        push_string(&mut out, 4, &self.namespace);
        // field 5: payload_type = 0 (STRING), varint (wire type 0)
        push_varint(&mut out, 5 << 3);
        push_varint(&mut out, 0);
        // field 6: payload_utf8
        push_string(&mut out, 6, &self.payload_utf8);
        out
    }

    /// 从 Protobuf 字节流解码 `CastMessage`。
    fn decode(mut bytes: &[u8]) -> Result<Self> {
        let mut source_id = String::new();
        let mut destination_id = String::new();
        let mut namespace = String::new();
        let mut payload_utf8 = String::new();
        while !bytes.is_empty() {
            let tag = read_varint(&mut bytes)?;
            let field = tag >> 3;
            let wire = tag & 0x7;
            match wire {
                0 => {
                    let _ = read_varint(&mut bytes)?;
                }
                2 => {
                    let len = read_varint(&mut bytes)? as usize;
                    if len > bytes.len() {
                        return Err(LekisError::new(
                            ErrorCode::Network,
                            "truncated cast protobuf message",
                        ));
                    }
                    let (chunk, rest) = bytes.split_at(len);
                    bytes = rest;
                    let text = String::from_utf8_lossy(chunk).into_owned();
                    match field {
                        2 => source_id = text,
                        3 => destination_id = text,
                        4 => namespace = text,
                        6 => payload_utf8 = text,
                        _ => {}
                    }
                }
                5 => {
                    if bytes.len() < 4 {
                        return Err(LekisError::new(
                            ErrorCode::Network,
                            "truncated cast fixed32",
                        ));
                    }
                    bytes = &bytes[4..];
                }
                1 => {
                    if bytes.len() < 8 {
                        return Err(LekisError::new(
                            ErrorCode::Network,
                            "truncated cast fixed64",
                        ));
                    }
                    bytes = &bytes[8..];
                }
                _ => {
                    return Err(LekisError::new(
                        ErrorCode::Network,
                        format!("unsupported cast wire type {wire}"),
                    ))
                }
            }
        }
        Ok(Self {
            source_id,
            destination_id,
            namespace,
            payload_utf8,
        })
    }
}

fn push_varint(out: &mut Vec<u8>, mut v: u64) {
    loop {
        let byte = (v & 0x7f) as u8;
        v >>= 7;
        if v == 0 {
            out.push(byte);
            break;
        }
        out.push(byte | 0x80);
    }
}

fn push_string(out: &mut Vec<u8>, field: u64, value: &str) {
    push_varint(out, (field << 3) | 2);
    push_varint(out, value.len() as u64);
    out.extend_from_slice(value.as_bytes());
}

fn read_varint(bytes: &mut &[u8]) -> Result<u64> {
    let mut result = 0u64;
    let mut shift = 0u32;
    loop {
        let (&b, rest) = bytes
            .split_first()
            .ok_or_else(|| LekisError::new(ErrorCode::Network, "truncated cast varint"))?;
        *bytes = rest;
        result |= u64::from(b & 0x7f) << shift;
        if b & 0x80 == 0 {
            return Ok(result);
        }
        shift += 7;
        if shift >= 64 {
            return Err(LekisError::new(ErrorCode::Network, "cast varint overflow"));
        }
    }
}

/// 一条已建立的 Chromecast 控制会话。
pub(crate) struct CastSession {
    stream: TlsStream<TcpStream>,
    transport_id: String,
    media_session_id: i64,
    next_request_id: u64,
}

impl CastSession {
    /// 连接 Chromecast、启动 Default Media Receiver 并加载音频流。
    pub(crate) async fn connect_and_load(
        host: &str,
        port: u16,
        item: &CastMediaItem,
    ) -> Result<Self> {
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let config = ClientConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()
            .map_err(|e| LekisError::internal(format!("rustls versions: {e}")))?
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(LanCastCertVerifier))
            .with_no_client_auth();

        let connector = TlsConnector::from(Arc::new(config));
        let tcp = tokio::time::timeout(Duration::from_secs(8), TcpStream::connect((host, port)))
            .await
            .map_err(|_| LekisError::new(ErrorCode::Network, "chromecast connect timeout"))?
            .map_err(|e| LekisError::new(ErrorCode::Network, format!("chromecast tcp: {e}")))?;

        let server_name = ServerName::try_from(host.to_string())
            .or_else(|_| ServerName::try_from("chromecast.local".to_string()))
            .map_err(|e| LekisError::invalid(format!("cast server name: {e}")))?;

        let stream =
            tokio::time::timeout(Duration::from_secs(8), connector.connect(server_name, tcp))
                .await
                .map_err(|_| LekisError::new(ErrorCode::Network, "chromecast tls timeout"))?
                .map_err(|e| LekisError::new(ErrorCode::Network, format!("chromecast tls: {e}")))?;

        let mut sess = Self {
            stream,
            transport_id: String::new(),
            media_session_id: 0,
            next_request_id: 1,
        };

        // 1) 建立 receiver-0 连接
        sess.send_json(RECEIVER_ID, NS_CONNECTION, json!({ "type": "CONNECT" }))
            .await?;

        // 2) 启动 Default Media Receiver 应用
        let launch_id = sess.alloc_req();
        sess.send_json(
            RECEIVER_ID,
            NS_RECEIVER,
            json!({
                "type": "LAUNCH",
                "appId": DEFAULT_MEDIA_RECEIVER_APP_ID,
                "requestId": launch_id,
            }),
        )
        .await?;

        // 等待 RECEIVER_STATUS 拿到 transportId
        let transport_id = sess.wait_for_transport_id(Duration::from_secs(10)).await?;
        sess.transport_id = transport_id.clone();

        // 3) 建立媒体应用传输通道连接
        sess.send_json(&transport_id, NS_CONNECTION, json!({ "type": "CONNECT" }))
            .await?;

        // 4) 发送 LOAD 指令
        let load_id = sess.alloc_req();
        let mut images = Vec::new();
        if let Some(art) = &item.artwork_url {
            images.push(json!({ "url": art }));
        }
        sess.send_json(
            &transport_id,
            NS_MEDIA,
            json!({
                "type": "LOAD",
                "requestId": load_id,
                "autoplay": true,
                "currentTime": (item.start_position_ms as f64) / 1000.0,
                "media": {
                    "contentId": item.stream_url,
                    "streamType": "BUFFERED",
                    "contentType": item.mime_type,
                    "metadata": {
                        "metadataType": 3,
                        "title": item.title,
                        "artist": item.artist,
                        "albumName": item.album,
                        "images": images,
                    }
                }
            }),
        )
        .await?;

        // 等待 MEDIA_STATUS 拿到 mediaSessionId
        if let Ok(Some((_, _, mid))) = sess.wait_for_media_status(Duration::from_secs(8)).await {
            sess.media_session_id = mid;
        }
        Ok(sess)
    }

    pub(crate) async fn play(&mut self) -> Result<()> {
        let req = self.alloc_req();
        let dest = self.transport_id.clone();
        self.send_json(
            &dest,
            NS_MEDIA,
            json!({
                "type": "PLAY",
                "mediaSessionId": self.media_session_id,
                "requestId": req,
            }),
        )
        .await
    }

    pub(crate) async fn pause(&mut self) -> Result<()> {
        let req = self.alloc_req();
        let dest = self.transport_id.clone();
        self.send_json(
            &dest,
            NS_MEDIA,
            json!({
                "type": "PAUSE",
                "mediaSessionId": self.media_session_id,
                "requestId": req,
            }),
        )
        .await
    }

    pub(crate) async fn seek(&mut self, position_ms: u64) -> Result<()> {
        let req = self.alloc_req();
        let dest = self.transport_id.clone();
        self.send_json(
            &dest,
            NS_MEDIA,
            json!({
                "type": "SEEK",
                "mediaSessionId": self.media_session_id,
                "currentTime": (position_ms as f64) / 1000.0,
                "requestId": req,
            }),
        )
        .await
    }

    pub(crate) async fn set_volume(&mut self, volume: f32) -> Result<()> {
        let req = self.alloc_req();
        self.send_json(
            RECEIVER_ID,
            NS_RECEIVER,
            json!({
                "type": "SET_VOLUME",
                "volume": { "level": volume.clamp(0.0, 1.0) },
                "requestId": req,
            }),
        )
        .await
    }

    pub(crate) async fn stop(&mut self) -> Result<()> {
        let req = self.alloc_req();
        let dest = self.transport_id.clone();
        let _ = self
            .send_json(
                &dest,
                NS_MEDIA,
                json!({
                    "type": "STOP",
                    "mediaSessionId": self.media_session_id,
                    "requestId": req,
                }),
            )
            .await;
        let _ = self
            .send_json(&dest, NS_CONNECTION, json!({ "type": "CLOSE" }))
            .await;
        Ok(())
    }

    /// 轮询最新媒体状态，返回 `(is_playing, position_ms)`。
    pub(crate) async fn poll_status(&mut self) -> Result<Option<(bool, u64)>> {
        let req = self.alloc_req();
        let dest = self.transport_id.clone();
        self.send_json(
            &dest,
            NS_MEDIA,
            json!({
                "type": "GET_STATUS",
                "requestId": req,
            }),
        )
        .await?;
        match self.wait_for_media_status(Duration::from_secs(2)).await? {
            Some((playing, pos_ms, mid)) => {
                if mid != 0 {
                    self.media_session_id = mid;
                }
                Ok(Some((playing, pos_ms)))
            }
            None => Ok(None),
        }
    }

    fn alloc_req(&mut self) -> u64 {
        let id = self.next_request_id;
        self.next_request_id += 1;
        id
    }

    async fn send_json(&mut self, dest: &str, namespace: &str, payload: Value) -> Result<()> {
        let msg = CastMessage {
            source_id: SENDER_ID.to_string(),
            destination_id: dest.to_string(),
            namespace: namespace.to_string(),
            payload_utf8: payload.to_string(),
        };
        let encoded = msg.encode();
        let len = (encoded.len() as u32).to_be_bytes();
        self.stream
            .write_all(&len)
            .await
            .map_err(|e| LekisError::new(ErrorCode::Network, format!("cast write len: {e}")))?;
        self.stream
            .write_all(&encoded)
            .await
            .map_err(|e| LekisError::new(ErrorCode::Network, format!("cast write body: {e}")))?;
        self.stream
            .flush()
            .await
            .map_err(|e| LekisError::new(ErrorCode::Network, format!("cast flush: {e}")))?;
        Ok(())
    }

    async fn recv_msg(&mut self, timeout: Duration) -> Result<CastMessage> {
        let mut len_buf = [0u8; 4];
        tokio::time::timeout(timeout, self.stream.read_exact(&mut len_buf))
            .await
            .map_err(|_| LekisError::new(ErrorCode::Network, "cast read timeout"))?
            .map_err(|e| LekisError::new(ErrorCode::Network, format!("cast read len: {e}")))?;
        let len = u32::from_be_bytes(len_buf) as usize;
        if len > 2 * 1024 * 1024 {
            return Err(LekisError::new(
                ErrorCode::Network,
                "cast message too large",
            ));
        }
        let mut body = vec![0u8; len];
        tokio::time::timeout(timeout, self.stream.read_exact(&mut body))
            .await
            .map_err(|_| LekisError::new(ErrorCode::Network, "cast body timeout"))?
            .map_err(|e| LekisError::new(ErrorCode::Network, format!("cast read body: {e}")))?;
        let msg = CastMessage::decode(&body)?;
        // 自动回复心跳，防止连接被 Chromecast 踢掉。
        if msg.namespace == NS_HEARTBEAT && msg.payload_utf8.contains("PING") {
            let _ = self
                .send_json(RECEIVER_ID, NS_HEARTBEAT, json!({ "type": "PONG" }))
                .await;
        }
        Ok(msg)
    }

    async fn wait_for_transport_id(&mut self, timeout: Duration) -> Result<String> {
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            let Some(rem) = deadline.checked_duration_since(tokio::time::Instant::now()) else {
                return Err(LekisError::new(
                    ErrorCode::Network,
                    "chromecast did not report media receiver transportId",
                ));
            };
            let msg = self.recv_msg(rem).await?;
            if msg.namespace != NS_RECEIVER {
                continue;
            }
            if let Ok(val) = serde_json::from_str::<Value>(&msg.payload_utf8) {
                if let Some(apps) = val
                    .pointer("/status/applications")
                    .and_then(Value::as_array)
                {
                    for app in apps {
                        if let Some(tid) = app.get("transportId").and_then(Value::as_str) {
                            return Ok(tid.to_string());
                        }
                    }
                }
            }
        }
    }

    async fn wait_for_media_status(
        &mut self,
        timeout: Duration,
    ) -> Result<Option<(bool, u64, i64)>> {
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            let Some(rem) = deadline.checked_duration_since(tokio::time::Instant::now()) else {
                return Ok(None);
            };
            let msg = match self.recv_msg(rem).await {
                Ok(m) => m,
                Err(_) => return Ok(None),
            };
            if msg.namespace != NS_MEDIA {
                continue;
            }
            if let Ok(val) = serde_json::from_str::<Value>(&msg.payload_utf8) {
                if let Some(status) = val.pointer("/status/0").and_then(Value::as_object) {
                    let mid = status
                        .get("mediaSessionId")
                        .and_then(Value::as_i64)
                        .unwrap_or(self.media_session_id);
                    let playing = status
                        .get("playerState")
                        .and_then(Value::as_str)
                        .is_some_and(|s| s == "PLAYING" || s == "BUFFERING");
                    let pos_ms = status
                        .get("currentTime")
                        .and_then(Value::as_f64)
                        .map(|sec| (sec.max(0.0) * 1000.0) as u64)
                        .unwrap_or(0);
                    return Ok(Some((playing, pos_ms, mid)));
                }
            }
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    #[test]
    fn cast_message_protobuf_roundtrips() {
        let msg = CastMessage {
            source_id: "sender-0".into(),
            destination_id: "receiver-0".into(),
            namespace: NS_HEARTBEAT.into(),
            payload_utf8: r#"{"type":"PING"}"#.into(),
        };
        let encoded = msg.encode();
        let decoded = CastMessage::decode(&encoded).unwrap();
        assert_eq!(decoded.source_id, "sender-0");
        assert_eq!(decoded.destination_id, "receiver-0");
        assert_eq!(decoded.namespace, NS_HEARTBEAT);
        assert_eq!(decoded.payload_utf8, r#"{"type":"PING"}"#);
    }
}
