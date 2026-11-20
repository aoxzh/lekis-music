//! 局域网自动发现（SRC-01~03 的"添加音源"入口）。
//!
//! 一次性扫描，跑满 `timeout` 后返回去重后的结果。三条路并行：
//! - **mDNS / DNS-SD**（`mdns-sd` crate）：`_smb._tcp`、`_webdav._tcp`、`_webdavs._tcp`。
//!   群晖、威联通、TrueNAS、macOS 共享默认都会广播 `_smb._tcp`。
//! - **WS-Discovery**（UDP 3702 组播 Probe）：Windows 文件共享和装了 `wsdd` 的 Samba 只走这条，
//!   不广播 mDNS。只拿 IP，不做元数据交换（那要再发一轮 SOAP），所以名字就是 IP。
//! - **SSDP**（UPnP / DLNA，UDP 1900 组播 M-SEARCH）：找 `MediaServer`。大多数 NAS 开着 DLNA，
//!   顺手能拿到"友好名称"（读设备描述 XML）。DLNA 本身不是 Lekis 的音源类型，界面把它当
//!   "这台机器上可能有 SMB 共享"来预填。
//!
//! 所有协议都只做"听"，不注册任何服务，不暴露本机信息。
//! Android 上接收组播需要 `WifiManager.MulticastLock`，由平台层在调用前后获取 / 释放。

use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::time::{Duration, Instant};

use tokio::net::UdpSocket;

/// 发现到的服务类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DiscoveredKind {
    /// SMB 文件共享（mDNS `_smb._tcp` 或 WS-Discovery）。
    Smb,
    /// WebDAV（http）。
    WebDav,
    /// WebDAV（https）。
    WebDavs,
    /// UPnP / DLNA 媒体服务器。
    MediaServer,
}

/// 通过哪种协议发现的。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiscoveryProtocol {
    /// mDNS / DNS-SD。
    Mdns,
    /// WS-Discovery。
    WsDiscovery,
    /// SSDP。
    Ssdp,
}

/// 一条发现结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscoveredService {
    /// 服务类型。
    pub kind: DiscoveredKind,
    /// 显示名称（mDNS 实例名 / DLNA friendlyName；拿不到时是主机地址）。
    pub name: String,
    /// 连接用的主机：优先 IPv4 字面量。
    pub host: String,
    /// mDNS 主机名（`nas.local`），没有时为 `None`。
    pub hostname: Option<String>,
    /// 端口。
    pub port: u16,
    /// WebDAV 的 TXT `path`（如 `/music`），其他类型为 `None`。
    pub path: Option<String>,
    /// 发现途径。
    pub via: DiscoveryProtocol,
}

/// 扫描局域网，`timeout` 后返回。各协议的错误（没有网卡、端口被占……）只记日志，不让整次扫描失败。
pub async fn discover(timeout: Duration) -> Vec<DiscoveredService> {
    let timeout = timeout.clamp(Duration::from_millis(500), Duration::from_secs(30));
    let (mdns, wsd, ssdp) = tokio::join!(
        mdns_browse(timeout),
        ws_discovery(timeout),
        ssdp_search(timeout)
    );
    merge(mdns.into_iter().chain(wsd).chain(ssdp))
}

/// 去重：同一 (类型, 主机, 端口) 只留一条；SMB 以 mDNS 的结果（有名字）优先于 WS-Discovery。
fn merge(items: impl IntoIterator<Item = DiscoveredService>) -> Vec<DiscoveredService> {
    let mut out: Vec<DiscoveredService> = Vec::new();
    let mut index: HashMap<(DiscoveredKind, String, u16), usize> = HashMap::new();
    for item in items {
        let key = (item.kind, item.host.clone(), item.port);
        match index.get(&key) {
            Some(&i) => {
                let existing = &mut out[i];
                if existing.via == DiscoveryProtocol::WsDiscovery
                    && item.via != DiscoveryProtocol::WsDiscovery
                {
                    *existing = item;
                }
            }
            None => {
                index.insert(key, out.len());
                out.push(item);
            }
        }
    }
    // 同一台主机的 SMB 用 mDNS 名字时，WS-Discovery 那条（名字是 IP）也换成这个名字。
    let names: HashMap<String, String> = out
        .iter()
        .filter(|s| s.via != DiscoveryProtocol::WsDiscovery && s.name != s.host)
        .map(|s| (s.host.clone(), s.name.clone()))
        .collect();
    for s in &mut out {
        if s.name == s.host {
            if let Some(n) = names.get(&s.host) {
                s.name.clone_from(n);
            }
        }
    }
    out.sort_by(|a, b| {
        a.name
            .to_lowercase()
            .cmp(&b.name.to_lowercase())
            .then(a.port.cmp(&b.port))
    });
    out
}

// ---------------------------------------------------------------------------
// mDNS
// ---------------------------------------------------------------------------

const MDNS_TYPES: &[(&str, DiscoveredKind)] = &[
    ("_smb._tcp.local.", DiscoveredKind::Smb),
    ("_webdav._tcp.local.", DiscoveredKind::WebDav),
    ("_webdavs._tcp.local.", DiscoveredKind::WebDavs),
];

async fn mdns_browse(timeout: Duration) -> Vec<DiscoveredService> {
    let daemon = match mdns_sd::ServiceDaemon::new() {
        Ok(d) => d,
        Err(e) => {
            tracing::warn!(target: "discovery", error = %e, "mDNS daemon unavailable");
            return Vec::new();
        }
    };
    let deadline = Instant::now() + timeout;
    let mut tasks = Vec::new();
    for &(ty, kind) in MDNS_TYPES {
        match daemon.browse(ty) {
            Ok(rx) => tasks.push(collect_mdns(rx, ty, kind, deadline)),
            Err(e) => tracing::debug!(target: "discovery", ty, error = %e, "mDNS browse failed"),
        }
    }
    let results = futures_join_all(tasks).await;
    for &(ty, _) in MDNS_TYPES {
        let _ = daemon.stop_browse(ty);
    }
    let _ = daemon.shutdown();
    results.into_iter().flatten().collect()
}

async fn collect_mdns(
    rx: mdns_sd::Receiver<mdns_sd::ServiceEvent>,
    ty: &'static str,
    kind: DiscoveredKind,
    deadline: Instant,
) -> Vec<DiscoveredService> {
    let mut out = Vec::new();
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            break;
        }
        let event = match tokio::time::timeout(left, rx.recv_async()).await {
            Ok(Ok(ev)) => ev,
            _ => break,
        };
        if let mdns_sd::ServiceEvent::ServiceResolved(info) = event {
            let Some(host) = pick_address(info.get_addresses().iter().copied()) else {
                continue;
            };
            let name = instance_name(info.get_fullname(), ty);
            let hostname = info.get_hostname().trim_end_matches('.').to_string();
            let path = match kind {
                DiscoveredKind::WebDav | DiscoveredKind::WebDavs => info
                    .get_property_val_str("path")
                    .map(str::to_string)
                    .filter(|p| !p.is_empty()),
                _ => None,
            };
            out.push(DiscoveredService {
                kind,
                name: if name.is_empty() { host.clone() } else { name },
                host,
                hostname: (!hostname.is_empty()).then_some(hostname),
                port: info.get_port(),
                path,
                via: DiscoveryProtocol::Mdns,
            });
        }
    }
    out
}

/// 优先私有 IPv4，其次任意 IPv4，最后 IPv6（带方括号由调用方处理）。
pub(crate) fn pick_address(addrs: impl Iterator<Item = IpAddr>) -> Option<String> {
    let addrs: Vec<IpAddr> = addrs.collect();
    let v4 = |private: bool| {
        addrs.iter().find_map(|a| match a {
            IpAddr::V4(v)
                if !v.is_loopback() && !v.is_link_local() && v.is_private() == private =>
            {
                Some(v.to_string())
            }
            _ => None,
        })
    };
    v4(true)
        .or_else(|| v4(false))
        .or_else(|| addrs.iter().find(|a| a.is_ipv6()).map(ToString::to_string))
}

/// `My NAS._smb._tcp.local.` → `My NAS`（DNS-SD 实例名里的 `\032` 之类转义也还原）。
fn instance_name(fullname: &str, ty: &str) -> String {
    let raw = fullname
        .strip_suffix(ty)
        .unwrap_or(fullname)
        .trim_end_matches('.');
    unescape_dns(raw)
}

fn unescape_dns(raw: &str) -> String {
    let bytes = raw.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\\' && i + 1 < bytes.len() {
            if i + 3 < bytes.len() && bytes[i + 1..i + 4].iter().all(u8::is_ascii_digit) {
                let n = (bytes[i + 1] - b'0') as u32 * 100
                    + (bytes[i + 2] - b'0') as u32 * 10
                    + (bytes[i + 3] - b'0') as u32;
                if let Ok(b) = u8::try_from(n) {
                    out.push(b);
                    i += 4;
                    continue;
                }
            }
            out.push(bytes[i + 1]);
            i += 2;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

// ---------------------------------------------------------------------------
// WS-Discovery
// ---------------------------------------------------------------------------

const MULTICAST_V4: Ipv4Addr = Ipv4Addr::new(239, 255, 255, 250);
const WSD_PORT: u16 = 3702;
const SSDP_PORT: u16 = 1900;

async fn ws_discovery(timeout: Duration) -> Vec<DiscoveredService> {
    let socket = match UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).await {
        Ok(s) => s,
        Err(e) => {
            tracing::debug!(target: "discovery", error = %e, "WS-Discovery socket failed");
            return Vec::new();
        }
    };
    let probe = wsd_probe(&pseudo_uuid());
    let target = SocketAddr::from((MULTICAST_V4, WSD_PORT));
    // UDP 会丢包：发两次。
    for _ in 0..2 {
        if let Err(e) = socket.send_to(probe.as_bytes(), target).await {
            tracing::debug!(target: "discovery", error = %e, "WS-Discovery probe failed");
            return Vec::new();
        }
    }
    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();
    recv_until(&socket, timeout, |from, body| {
        let Ok(text) = std::str::from_utf8(body) else {
            return;
        };
        if !text.contains("ProbeMatch") {
            return;
        }
        // 打印机、扫描仪也走 WSD；只保留像电脑 / 文件服务器的（`pub:Computer`）或没写类型的。
        let types = xml_text(text, "Types").unwrap_or_default();
        if types.contains("print") || types.contains("scan") {
            return;
        }
        let host = xaddr_host(text).unwrap_or_else(|| from.ip().to_string());
        if seen.insert(host.clone()) {
            out.push(DiscoveredService {
                kind: DiscoveredKind::Smb,
                name: host.clone(),
                host,
                hostname: None,
                port: 445,
                path: None,
                via: DiscoveryProtocol::WsDiscovery,
            });
        }
    })
    .await;
    out
}

fn wsd_probe(message_id: &str) -> String {
    format!(
        concat!(
            r#"<?xml version="1.0" encoding="utf-8"?>"#,
            r#"<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope" "#,
            r#"xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing" "#,
            r#"xmlns:wsd="http://schemas.xmlsoap.org/ws/2005/04/discovery" "#,
            r#"xmlns:wsdp="http://schemas.xmlsoap.org/ws/2006/02/devprof">"#,
            r#"<soap:Header>"#,
            r#"<wsa:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</wsa:To>"#,
            r#"<wsa:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</wsa:Action>"#,
            r#"<wsa:MessageID>urn:uuid:{}</wsa:MessageID>"#,
            r#"</soap:Header>"#,
            r#"<soap:Body><wsd:Probe><wsd:Types>wsdp:Device</wsd:Types></wsd:Probe></soap:Body>"#,
            r#"</soap:Envelope>"#
        ),
        message_id
    )
}

/// 从 `<wsd:XAddrs>http://172.26.0.8:5357/…</wsd:XAddrs>` 里取第一个 IPv4 主机。
fn xaddr_host(text: &str) -> Option<String> {
    let xaddrs = xml_text(text, "XAddrs")?;
    xaddrs.split_whitespace().find_map(|u| {
        let parsed = url_host(u)?;
        parsed.parse::<Ipv4Addr>().ok().map(|ip| ip.to_string())
    })
}

/// 取 `scheme://host[:port]/…` 里的 host（不处理 IPv6）。
fn url_host(url: &str) -> Option<String> {
    let rest = url.split_once("://")?.1;
    let authority = rest.split('/').next()?;
    let host = authority.rsplit_once('@').map_or(authority, |(_, h)| h);
    let host = host.split(':').next()?;
    (!host.is_empty()).then(|| host.to_string())
}

/// 取第一个本地名为 `local`（忽略命名空间前缀）的元素的文本。
fn xml_text(text: &str, local: &str) -> Option<String> {
    let mut search = 0;
    while let Some(off) = text[search..].find('<') {
        let start = search + off + 1;
        let end = start + text[start..].find('>')?;
        let tag = &text[start..end];
        search = end + 1;
        if tag.starts_with('/') || tag.starts_with('?') || tag.starts_with('!') {
            continue;
        }
        let name = tag.split_whitespace().next().unwrap_or("");
        let name = name.trim_end_matches('/');
        let bare = name.rsplit_once(':').map_or(name, |(_, n)| n);
        if bare == local {
            if tag.ends_with('/') {
                return Some(String::new());
            }
            let close = text[search..].find("</")?;
            return Some(xml_unescape(text[search..search + close].trim()));
        }
    }
    None
}

fn xml_unescape(s: &str) -> String {
    s.replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
        .replace("&amp;", "&")
}

// ---------------------------------------------------------------------------
// SSDP（UPnP / DLNA）
// ---------------------------------------------------------------------------

async fn ssdp_search(timeout: Duration) -> Vec<DiscoveredService> {
    let socket = match UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).await {
        Ok(s) => s,
        Err(e) => {
            tracing::debug!(target: "discovery", error = %e, "SSDP socket failed");
            return Vec::new();
        }
    };
    let request = concat!(
        "M-SEARCH * HTTP/1.1\r\n",
        "HOST: 239.255.255.250:1900\r\n",
        "MAN: \"ssdp:discover\"\r\n",
        "MX: 2\r\n",
        "ST: urn:schemas-upnp-org:device:MediaServer:1\r\n",
        "USER-AGENT: Lekis/1 UPnP/1.1\r\n",
        "\r\n"
    );
    let target = SocketAddr::from((MULTICAST_V4, SSDP_PORT));
    for _ in 0..2 {
        if let Err(e) = socket.send_to(request.as_bytes(), target).await {
            tracing::debug!(target: "discovery", error = %e, "SSDP M-SEARCH failed");
            return Vec::new();
        }
    }
    // 留出约三分之一的时间去读设备描述拿名字。
    let listen = timeout.mul_f32(0.65);
    let fetch_budget = timeout
        .saturating_sub(listen)
        .max(Duration::from_millis(300));
    let mut found: Vec<(String, String)> = Vec::new(); // (host, location)
    recv_until(&socket, listen, |from, body| {
        let Ok(text) = std::str::from_utf8(body) else {
            return;
        };
        let Some(location) = header(text, "location") else {
            return;
        };
        let host = url_host(&location).unwrap_or_else(|| from.ip().to_string());
        if !found.iter().any(|(h, _)| *h == host) {
            found.push((host, location));
        }
    })
    .await;
    if found.is_empty() {
        return Vec::new();
    }

    let client = reqwest::Client::builder()
        .timeout(fetch_budget)
        .build()
        .ok();
    let fetches = found.into_iter().map(|(host, location)| {
        let client = client.clone();
        async move {
            let name = match client {
                Some(c) => friendly_name(&c, &location).await,
                None => None,
            };
            DiscoveredService {
                kind: DiscoveredKind::MediaServer,
                name: name.unwrap_or_else(|| host.clone()),
                port: url_port(&location).unwrap_or(0),
                host,
                hostname: None,
                path: None,
                via: DiscoveryProtocol::Ssdp,
            }
        }
    });
    futures_join_all(fetches.collect()).await
}

async fn friendly_name(client: &reqwest::Client, location: &str) -> Option<String> {
    let body = client.get(location).send().await.ok()?.text().await.ok()?;
    xml_text(&body, "friendlyName").filter(|n| !n.is_empty())
}

fn url_port(url: &str) -> Option<u16> {
    let rest = url.split_once("://")?.1;
    let authority = rest.split('/').next()?;
    authority.rsplit_once(':')?.1.parse().ok()
}

/// HTTP 风格响应头（大小写不敏感）。
fn header(text: &str, name: &str) -> Option<String> {
    text.lines().find_map(|line| {
        let (k, v) = line.split_once(':')?;
        k.trim()
            .eq_ignore_ascii_case(name)
            .then(|| v.trim().to_string())
    })
}

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

async fn recv_until(socket: &UdpSocket, timeout: Duration, mut on: impl FnMut(SocketAddr, &[u8])) {
    let deadline = Instant::now() + timeout;
    let mut buf = vec![0u8; 16 * 1024];
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            break;
        }
        match tokio::time::timeout(left, socket.recv_from(&mut buf)).await {
            Ok(Ok((n, from))) => on(from, &buf[..n]),
            // Windows 上对端口不可达会收到 ICMP 导致的错误，忽略后继续收。
            Ok(Err(_)) => continue,
            Err(_) => break,
        }
    }
}

/// 不引入额外依赖的 `join_all`：逐个 spawn 到当前运行时再等。
async fn futures_join_all<F>(futs: Vec<F>) -> Vec<F::Output>
where
    F: std::future::Future + Send + 'static,
    F::Output: Send + 'static,
{
    let handles: Vec<_> = futs.into_iter().map(tokio::spawn).collect();
    let mut out = Vec::with_capacity(handles.len());
    for h in handles {
        if let Ok(v) = h.await {
            out.push(v);
        }
    }
    out
}

/// WS-Discovery 的 MessageID 只要求唯一，不需要密码学随机。
fn pseudo_uuid() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let pid = u128::from(std::process::id());
    let v = nanos ^ (pid << 64) ^ 0x4c65_6b69_7300_0000_0000_0000_0000_0000;
    let h = format!("{v:032x}");
    format!(
        "{}-{}-4{}-a{}-{}",
        &h[0..8],
        &h[8..12],
        &h[13..16],
        &h[17..20],
        &h[20..32]
    )
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;

    fn svc(
        kind: DiscoveredKind,
        name: &str,
        host: &str,
        via: DiscoveryProtocol,
    ) -> DiscoveredService {
        DiscoveredService {
            kind,
            name: name.into(),
            host: host.into(),
            hostname: None,
            port: if kind == DiscoveredKind::Smb {
                445
            } else {
                5005
            },
            path: None,
            via,
        }
    }

    #[test]
    fn instance_name_strips_type_and_unescapes() {
        assert_eq!(
            instance_name("My\\032NAS._smb._tcp.local.", "_smb._tcp.local."),
            "My NAS"
        );
        assert_eq!(
            instance_name("DS920\\.home._smb._tcp.local.", "_smb._tcp.local."),
            "DS920.home"
        );
    }

    #[test]
    fn prefers_private_ipv4() {
        let addrs: Vec<IpAddr> = vec![
            "fe80::1".parse().unwrap(),
            "8.8.8.8".parse().unwrap(),
            "192.168.1.5".parse().unwrap(),
        ];
        assert_eq!(
            pick_address(addrs.into_iter()).as_deref(),
            Some("192.168.1.5")
        );
        let only6: Vec<IpAddr> = vec!["fe80::1".parse().unwrap()];
        assert_eq!(pick_address(only6.into_iter()).as_deref(), Some("fe80::1"));
    }

    #[test]
    fn mdns_beats_wsd_and_lends_its_name() {
        let merged = merge(vec![
            svc(
                DiscoveredKind::Smb,
                "10.0.0.2",
                "10.0.0.2",
                DiscoveryProtocol::WsDiscovery,
            ),
            svc(
                DiscoveredKind::Smb,
                "NAS",
                "10.0.0.2",
                DiscoveryProtocol::Mdns,
            ),
            svc(
                DiscoveredKind::MediaServer,
                "10.0.0.2",
                "10.0.0.2",
                DiscoveryProtocol::Ssdp,
            ),
            svc(
                DiscoveredKind::Smb,
                "10.0.0.9",
                "10.0.0.9",
                DiscoveryProtocol::WsDiscovery,
            ),
        ]);
        assert_eq!(merged.len(), 3);
        let smb = merged
            .iter()
            .find(|s| s.kind == DiscoveredKind::Smb && s.host == "10.0.0.2")
            .unwrap();
        assert_eq!(smb.via, DiscoveryProtocol::Mdns);
        let dlna = merged
            .iter()
            .find(|s| s.kind == DiscoveredKind::MediaServer)
            .unwrap();
        assert_eq!(dlna.name, "NAS");
    }

    #[test]
    fn parses_wsd_probe_match() {
        let body = r#"<soap:Envelope><soap:Body><wsd:ProbeMatches><wsd:ProbeMatch>
            <wsd:Types>wsdp:Device pub:Computer</wsd:Types>
            <wsd:XAddrs>http://172.26.0.8:5357/6f2c</wsd:XAddrs>
            </wsd:ProbeMatch></wsd:ProbeMatches></soap:Body></soap:Envelope>"#;
        assert_eq!(
            xml_text(body, "Types").as_deref(),
            Some("wsdp:Device pub:Computer")
        );
        assert_eq!(xaddr_host(body).as_deref(), Some("172.26.0.8"));
    }

    #[test]
    fn parses_ssdp_headers_and_friendly_name() {
        let resp = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nLocation: http://10.0.0.2:50001/desc.xml\r\n\r\n";
        let loc = header(resp, "LOCATION").unwrap();
        assert_eq!(loc, "http://10.0.0.2:50001/desc.xml");
        assert_eq!(url_host(&loc).as_deref(), Some("10.0.0.2"));
        assert_eq!(url_port(&loc), Some(50001));
        let xml = "<root><device><friendlyName>DS920 &amp; Co</friendlyName></device></root>";
        assert_eq!(xml_text(xml, "friendlyName").as_deref(), Some("DS920 & Co"));
    }

    #[test]
    fn probe_is_well_formed() {
        let id = pseudo_uuid();
        assert_eq!(id.len(), 36);
        assert!(wsd_probe(&id).contains(&id));
    }

    /// 真实网络上的发现（手动跑：`cargo test -p lekis-core discovery::tests::live -- --ignored --nocapture`）。
    #[tokio::test(flavor = "multi_thread")]
    #[ignore = "needs a real LAN"]
    async fn live() {
        let found = discover(Duration::from_secs(4)).await;
        for s in &found {
            println!(
                "{:?} {:?} {} {}:{} {:?}",
                s.via, s.kind, s.name, s.host, s.port, s.path
            );
        }
    }
}
