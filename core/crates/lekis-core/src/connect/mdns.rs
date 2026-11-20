//! 局域网发现（CST-01）：用 mDNS / DNS-SD 广播本机并浏览其他 Lekis。
//!
//! 服务类型是 [`protocol::SERVICE_TYPE`]（`_lekis._tcp.local.`）。实例名用设备 ID（每台机器唯一，
//! 不会因为两台设备改了同一个名字就冲突），人看的名字放在 TXT 里：
//!
//! | TXT | 内容 |
//! |-----|------|
//! | `id` | 设备 ID（和 `Hello` / 配对里的 ID 一致） |
//! | `name` | 当前设备名（用户在设置里改的那个） |
//! | `platform` | `android` / `windows` / ... |
//!
//! 收到的服务直接喂给 [`ConnectHub::upsert_device`](super::ConnectHub)，设备列表和界面都只认那份状态。
//! 组播被路由器挡住、或者双方不在同一个网段时，走"手动按 IP:端口添加"（`client::probe`）。
//!
//! mDNS 起不来（没有网卡、5353 端口被占）不算致命错误：调用方只记一条日志，控制通道照常可用。

use super::protocol;
use super::{ConnectSettings, Discovered};
use crate::Services;
use lekis_types::{ErrorCode, LekisError, Result};
use mdns_sd::{ServiceDaemon, ServiceEvent, ServiceInfo};
use std::sync::{Arc, Mutex, Weak};

/// TXT：设备 ID。
const TXT_ID: &str = "id";
/// TXT：设备名。
const TXT_NAME: &str = "name";
/// TXT：平台。
const TXT_PLATFORM: &str = "platform";

/// 广播 + 浏览的运行句柄；`ConnectHub` 拿着它，改设置或停止 Connect 时用。
pub(crate) struct MdnsHandle {
    daemon: ServiceDaemon,
    /// 当前注册的实例全名（`<设备 ID>._lekis._tcp.local.`），没在广播时为 `None`。
    fullname: Mutex<Option<String>>,
    browse_task: Option<tokio::task::JoinHandle<()>>,
}

/// 开始浏览局域网里的 Lekis，并按 `settings` 决定要不要广播本机。
pub(crate) fn start(
    s: &Arc<Services>,
    port: u16,
    settings: &ConnectSettings,
) -> Result<MdnsHandle> {
    let daemon = ServiceDaemon::new().map_err(|e| {
        LekisError::new(ErrorCode::Network, format!("mDNS daemon unavailable: {e}"))
    })?;
    let events = match daemon.browse(protocol::SERVICE_TYPE) {
        Ok(events) => events,
        Err(e) => {
            // 起不来的守护线程别留着（它自己一个线程）。
            let _ = daemon.shutdown();
            return Err(LekisError::new(
                ErrorCode::Network,
                format!("mDNS browse failed: {e}"),
            ));
        }
    };
    let mut handle = MdnsHandle {
        daemon,
        fullname: Mutex::new(None),
        browse_task: None,
    };
    if settings.allow_control {
        if let Err(e) = handle.advertise(s, port, settings) {
            handle.shutdown();
            return Err(e);
        }
    }
    handle.browse_task = Some(tokio::spawn(browse(events, Arc::downgrade(s))));
    tracing::debug!(target: "connect", port, "mDNS started");
    Ok(handle)
}

impl MdnsHandle {
    /// 设置变了：改名 / 改端口重新广播，关掉"允许其他设备控制"就停止广播（继续浏览）。
    pub(crate) fn update(&self, s: &Services, port: u16, settings: &ConnectSettings) {
        if !settings.allow_control {
            self.stop_advertising();
            return;
        }
        if let Err(e) = self.advertise(s, port, settings) {
            tracing::warn!(target: "connect", error = %e, "cannot re-advertise over mDNS");
        }
    }

    /// 停止浏览、撤掉广播、关掉守护线程。
    pub(crate) fn shutdown(mut self) {
        if let Some(task) = self.browse_task.take() {
            task.abort();
        }
        let _ = self.daemon.stop_browse(protocol::SERVICE_TYPE);
        if let Some(fullname) = self.fullname.lock().ok().and_then(|mut f| f.take()) {
            if let Err(e) = self.daemon.unregister(&fullname) {
                tracing::debug!(target: "connect", error = %e, "mDNS unregister failed");
            }
        }
        if let Err(e) = self.daemon.shutdown() {
            tracing::debug!(target: "connect", error = %e, "mDNS shutdown failed");
        }
    }

    /// 用当前名字 / 端口注册（同名再次注册就是更新记录，不需要先撤销）。
    fn advertise(&self, s: &Services, port: u16, settings: &ConnectSettings) -> Result<()> {
        let info = service_info(s, port, settings)?;
        let fullname = info.get_fullname().to_string();
        self.daemon.register(info).map_err(|e| {
            LekisError::new(ErrorCode::Network, format!("mDNS register failed: {e}"))
        })?;
        if let Ok(mut current) = self.fullname.lock() {
            *current = Some(fullname);
        }
        tracing::info!(target: "connect", port, name = %settings.device_name, "advertising over mDNS");
        Ok(())
    }

    fn stop_advertising(&self) {
        let fullname = self.fullname.lock().ok().and_then(|mut f| f.take());
        let Some(fullname) = fullname else { return };
        if let Err(e) = self.daemon.unregister(&fullname) {
            tracing::debug!(target: "connect", error = %e, "mDNS unregister failed");
        }
        tracing::info!(target: "connect", "stopped advertising over mDNS");
    }
}

/// 本机的 DNS-SD 记录。地址交给 `mdns-sd` 按网卡自动填（换 Wi-Fi / 插网线都会跟着变）。
fn service_info(s: &Services, port: u16, settings: &ConnectSettings) -> Result<ServiceInfo> {
    let instance = s.device_id.0.as_str();
    let hostname = format!("{instance}.local.");
    let platform = super::platform_name(s);
    let properties = [
        (TXT_ID, instance),
        (TXT_NAME, settings.device_name.as_str()),
        (TXT_PLATFORM, platform.as_str()),
    ];
    let info = ServiceInfo::new(
        protocol::SERVICE_TYPE,
        instance,
        &hostname,
        "",
        port,
        &properties[..],
    )
    .map_err(|e| LekisError::new(ErrorCode::Network, format!("cannot build mDNS record: {e}")))?;
    Ok(info.enable_addr_auto())
}

/// 浏览任务：解析到的设备塞进设备列表，撤掉的移出去。只持有 `Services` 的弱引用，
/// 免得核心退出后这个任务还把整个服务图留在内存里。
async fn browse(events: mdns_sd::Receiver<ServiceEvent>, s: Weak<Services>) {
    while let Ok(event) = events.recv_async().await {
        let Some(s) = s.upgrade() else { return };
        match event {
            ServiceEvent::ServiceResolved(info) => {
                if let Some(d) = discovered_from_info(&info, &s.device_id.0) {
                    s.connect.upsert_device(d);
                }
            }
            ServiceEvent::ServiceRemoved(_, fullname) => {
                s.connect.remove_device_by_fullname(&fullname);
            }
            _ => {}
        }
    }
    tracing::debug!(target: "connect", "mDNS browse ended");
}

/// 一条已解析的 DNS-SD 记录 → 设备列表里的一台设备。
///
/// 没有 `id` 的记录（不是 Lekis，或者是很旧的版本）直接跳过：没有设备 ID 就没法配对。
fn discovered_from_info(info: &ServiceInfo, self_id: &str) -> Option<Discovered> {
    let device_id = info
        .get_property_val_str(TXT_ID)
        .map(str::trim)
        .filter(|id| !id.is_empty())?
        .to_string();
    if device_id == self_id {
        return None;
    }
    let port = info.get_port();
    if port == 0 {
        return None;
    }
    let host = crate::discovery::pick_address(info.get_addresses().iter().copied())?;
    let name = info
        .get_property_val_str(TXT_NAME)
        .map(str::trim)
        .filter(|n| !n.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| device_id.clone());
    let platform = info
        .get_property_val_str(TXT_PLATFORM)
        .unwrap_or_default()
        .to_string();
    Some(Discovered {
        device_id,
        name,
        platform,
        host,
        port,
        fullname: info.get_fullname().to_string(),
    })
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn info(id: &str, name: &str) -> ServiceInfo {
        ServiceInfo::new(
            protocol::SERVICE_TYPE,
            "instance",
            "instance.local.",
            "192.168.1.7",
            47655,
            &[(TXT_ID, id), (TXT_NAME, name), (TXT_PLATFORM, "windows")][..],
        )
        .unwrap()
    }

    #[test]
    fn resolves_a_peer_from_txt_records() {
        let d = discovered_from_info(&info("device-a", "客厅"), "device-self").expect("peer");
        assert_eq!(d.device_id, "device-a");
        assert_eq!(d.name, "客厅");
        assert_eq!(d.platform, "windows");
        assert_eq!(d.host, "192.168.1.7");
        assert_eq!(d.port, 47655);
        assert_eq!(d.fullname, "instance._lekis._tcp.local.");
    }

    #[test]
    fn ignores_this_device_and_records_without_an_id() {
        assert!(discovered_from_info(&info("device-self", "这里"), "device-self").is_none());
        let anonymous = ServiceInfo::new(
            protocol::SERVICE_TYPE,
            "other",
            "other.local.",
            "192.168.1.8",
            1234,
            None,
        )
        .unwrap();
        assert!(discovered_from_info(&anonymous, "device-self").is_none());
    }

    #[test]
    fn name_falls_back_to_the_device_id() {
        let unnamed = ServiceInfo::new(
            protocol::SERVICE_TYPE,
            "other",
            "other.local.",
            "192.168.1.8",
            1234,
            &[(TXT_ID, "device-b")][..],
        )
        .unwrap();
        let d = discovered_from_info(&unnamed, "device-self").expect("peer");
        assert_eq!(d.name, "device-b");
        assert!(d.platform.is_empty());
    }

    fn core(name: &str) -> crate::LekisCore {
        let root = std::env::temp_dir().join(format!(
            "lekis-mdns-{name}-{}-{}",
            std::process::id(),
            lekis_types::now_ms()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("data dir");
        crate::LekisCore::new(
            crate::config::CoreConfig::for_tests(&root),
            crate::PlatformServices::in_memory(),
        )
        .expect("core")
    }

    /// 真实局域网上的广播 + 浏览：两台核心互相发现（手动跑：
    /// `cargo test -p lekis-core connect::mdns::tests::live -- --ignored`）。
    #[tokio::test(flavor = "multi_thread")]
    #[ignore = "needs a real LAN (and multicast permission)"]
    async fn live() {
        let advertising = core("advertising");
        let browsing = core("browsing");
        let port = advertising
            .connect_start(super::super::ConnectStartOptions {
                port: Some(0),
                mdns: true,
            })
            .await
            .expect("advertise");
        browsing
            .connect_start(super::super::ConnectStartOptions {
                port: Some(0),
                mdns: true,
            })
            .await
            .expect("browse");
        let device_id = advertising.device_id().0;
        let mut found = None;
        for _ in 0..50 {
            if let Some(d) = browsing
                .connect_devices()
                .into_iter()
                .find(|d| d.device_id == device_id)
            {
                found = Some(d);
                break;
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
        let found = found.expect("the other core should appear in the device list");
        assert_eq!(found.port, port);
        assert_eq!(found.name, "test");
        advertising.connect_stop().await.expect("stop advertising");
        browsing.connect_stop().await.expect("stop browsing");
    }
}
