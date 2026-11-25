//! DLNA / UPnP MediaRenderer 发现与推送控制（基于 `rupnp`）。
//!
//! 支持符合 UPnP AVTransport:1 与 RenderingControl:1 的各类局域网音箱、功放、
//! Hi-Fi 数播（WiiM、Eversolo、Denon/Marantz HEOS、Yamaha MusicCast、Sony、Sonos、BubbleUPnP 等）。

use super::{CastDevice, CastKind, CastMediaItem};
use futures_util::TryStreamExt;
use lekis_types::{ErrorCode, LekisError, Result};
use rupnp::ssdp::{SearchTarget, URN};
use rupnp::{Device, Service};
use std::collections::HashMap;
use std::time::Duration;

const AV_TRANSPORT: URN = URN::service("schemas-upnp-org", "AVTransport", 1);
const RENDERING_CONTROL: URN = URN::service("schemas-upnp-org", "RenderingControl", 1);

/// 发现局域网内支持 `AVTransport:1` 的 DLNA / UPnP 音频渲染设备。
pub async fn discover(timeout: Duration) -> Result<Vec<CastDevice>> {
    let target = SearchTarget::URN(AV_TRANSPORT);
    let devices = rupnp::discover(&target, timeout, None)
        .await
        .map_err(|e| LekisError::new(ErrorCode::Network, format!("upnp discover: {e}")))?;
    let mut devices = std::pin::pin!(devices);
    let mut found: HashMap<String, CastDevice> = HashMap::new();
    while let Ok(Some(dev)) = devices.try_next().await {
        if dev.find_service(&AV_TRANSPORT).is_none() {
            continue;
        }
        let uri = dev.url();
        let host = uri.host().unwrap_or_default().to_string();
        if host.is_empty() {
            continue;
        }
        let port = uri.port_u16().unwrap_or(80);
        let id = dev.udn().to_string();
        let name = dev.friendly_name().to_string();
        let model = {
            let m = dev.model_name().trim();
            if m.is_empty() {
                None
            } else {
                Some(m.to_string())
            }
        };
        let location_url = Some(uri.to_string());
        found.insert(
            id.clone(),
            CastDevice {
                id,
                name,
                model,
                kind: CastKind::Dlna,
                host,
                port,
                location_url,
            },
        );
    }
    Ok(found.into_values().collect())
}

/// 一条 DLNA / UPnP 播放控制会话。
pub(crate) struct DlnaSession {
    device: Device,
    av_transport: Service,
    rendering_control: Option<Service>,
}

impl DlnaSession {
    /// 按设备描述 XML URL 连接渲染器，写入音频 URI + DIDL-Lite 元数据并立即起播。
    pub(crate) async fn connect_and_load(location_url: &str, item: &CastMediaItem) -> Result<Self> {
        let uri: rupnp::http::Uri = location_url
            .parse()
            .map_err(|e| LekisError::invalid(format!("invalid dlna url {location_url}: {e}")))?;
        let device = Device::from_url(uri)
            .await
            .map_err(|e| LekisError::new(ErrorCode::Network, format!("dlna device xml: {e}")))?;
        let av_transport = device.find_service(&AV_TRANSPORT).cloned().ok_or_else(|| {
            LekisError::new(
                ErrorCode::Unsupported,
                "DLNA device does not expose AVTransport:1",
            )
        })?;
        let rendering_control = device.find_service(&RENDERING_CONTROL).cloned();

        let sess = Self {
            device,
            av_transport,
            rendering_control,
        };

        // 先停止旧的播放（部分功放不 Stop 直接 SetAVTransportURI 会拒绝）。
        let _ = sess.stop().await;

        let didl = build_didl_lite(item);
        let set_uri_args = format!(
            "<InstanceID>0</InstanceID>\
             <CurrentURI>{}</CurrentURI>\
             <CurrentURIMetaData>{}</CurrentURIMetaData>",
            xml_escape(&item.stream_url),
            xml_escape(&didl),
        );
        sess.av_action("SetAVTransportURI", &set_uri_args).await?;
        sess.play().await?;
        if item.start_position_ms > 0 {
            let _ = sess.seek(item.start_position_ms).await;
        }
        Ok(sess)
    }

    pub(crate) async fn play(&self) -> Result<()> {
        self.av_action("Play", "<InstanceID>0</InstanceID><Speed>1</Speed>")
            .await
            .map(|_| ())
    }

    pub(crate) async fn pause(&self) -> Result<()> {
        self.av_action("Pause", "<InstanceID>0</InstanceID>")
            .await
            .map(|_| ())
    }

    pub(crate) async fn stop(&self) -> Result<()> {
        self.av_action("Stop", "<InstanceID>0</InstanceID>")
            .await
            .map(|_| ())
    }

    pub(crate) async fn seek(&self, position_ms: u64) -> Result<()> {
        let target = format_dlna_time(position_ms);
        let args =
            format!("<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>{target}</Target>");
        self.av_action("Seek", &args).await.map(|_| ())
    }

    pub(crate) async fn set_volume(&self, volume: f32) -> Result<()> {
        let Some(rc) = &self.rendering_control else {
            return Err(LekisError::new(
                ErrorCode::Unsupported,
                "DLNA renderer does not support volume control",
            ));
        };
        let level = (volume.clamp(0.0, 1.0) * 100.0).round() as u32;
        let args = format!(
            "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>{level}</DesiredVolume>"
        );
        rc.action(self.device.url(), "SetVolume", &args)
            .await
            .map_err(|e| LekisError::new(ErrorCode::Network, format!("dlna SetVolume: {e}")))?;
        Ok(())
    }

    pub(crate) async fn get_volume(&self) -> Result<f32> {
        let Some(rc) = &self.rendering_control else {
            return Ok(1.0);
        };
        let resp = rc
            .action(
                self.device.url(),
                "GetVolume",
                "<InstanceID>0</InstanceID><Channel>Master</Channel>",
            )
            .await
            .map_err(|e| LekisError::new(ErrorCode::Network, format!("dlna GetVolume: {e}")))?;
        let vol = resp
            .get("CurrentVolume")
            .and_then(|s| s.trim().parse::<f32>().ok())
            .map(|v| (v / 100.0).clamp(0.0, 1.0))
            .unwrap_or(1.0);
        Ok(vol)
    }

    /// 轮询播放状态，返回 `(is_playing, position_ms, duration_ms)`。
    pub(crate) async fn poll_status(&self) -> Result<(bool, u64, u64)> {
        let transport = self
            .av_action("GetTransportInfo", "<InstanceID>0</InstanceID>")
            .await?;
        let is_playing = transport
            .get("CurrentTransportState")
            .is_some_and(|s| s == "PLAYING" || s == "TRANSITIONING");
        let pos_info = self
            .av_action("GetPositionInfo", "<InstanceID>0</InstanceID>")
            .await?;
        let pos_ms = pos_info
            .get("RelTime")
            .and_then(|s| parse_dlna_time(s))
            .unwrap_or(0);
        let dur_ms = pos_info
            .get("TrackDuration")
            .and_then(|s| parse_dlna_time(s))
            .unwrap_or(0);
        Ok((is_playing, pos_ms, dur_ms))
    }

    async fn av_action(&self, name: &str, args: &str) -> Result<HashMap<String, String>> {
        self.av_transport
            .action(self.device.url(), name, args)
            .await
            .map_err(|e| LekisError::new(ErrorCode::Network, format!("dlna {name}: {e}")))
    }
}

/// 构造标准 DIDL-Lite 曲目元数据 XML（供 DLNA 音箱 / 功放显示曲名、艺人、封面与时长）。
fn build_didl_lite(item: &CastMediaItem) -> String {
    let duration_attr = if item.duration_ms > 0 {
        format!(" duration=\"{}\"", format_dlna_time(item.duration_ms))
    } else {
        String::new()
    };
    let art_elem = match &item.artwork_url {
        Some(url) => format!("<upnp:albumArtURI>{}</upnp:albumArtURI>", xml_escape(url)),
        None => String::new(),
    };
    format!(
        "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" \
         xmlns:dc=\"http://purl.org/dc/elements/1.1/\" \
         xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">\
         <item id=\"lekis-{}\" parentID=\"0\" restricted=\"1\">\
         <dc:title>{}</dc:title>\
         <upnp:artist>{}</upnp:artist>\
         <upnp:album>{}</upnp:album>\
         {art_elem}\
         <upnp:class>object.item.audioItem.musicTrack</upnp:class>\
         <res protocolInfo=\"http-get:*:{}:DLNA.ORG_OP=01;DLNA.ORG_FLAGS=01700000000000000000000000000000\"{duration_attr}>{}</res>\
         </item></DIDL-Lite>",
        item.track_id.0,
        xml_escape(&item.title),
        xml_escape(&item.artist),
        xml_escape(&item.album),
        xml_escape(&item.mime_type),
        xml_escape(&item.stream_url),
    )
}

fn format_dlna_time(ms: u64) -> String {
    let total_secs = ms / 1_000;
    let h = total_secs / 3_600;
    let m = (total_secs % 3_600) / 60;
    let s = total_secs % 60;
    format!("{h:02}:{m:02}:{s:02}")
}

fn parse_dlna_time(text: &str) -> Option<u64> {
    let mut parts = text.trim().split(':');
    let h: u64 = parts.next()?.parse().ok()?;
    let m: u64 = parts.next()?.parse().ok()?;
    let s_str = parts.next()?;
    let s: f64 = s_str.parse().ok()?;
    Some(((h * 3_600 + m * 60) * 1_000) + (s * 1_000.0) as u64)
}

fn xml_escape(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for c in input.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            _ => out.push(c),
        }
    }
    out
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    #[test]
    fn dlna_time_formats_and_parses() {
        assert_eq!(format_dlna_time(226_000), "00:03:46");
        assert_eq!(parse_dlna_time("00:03:46"), Some(226_000));
        assert_eq!(parse_dlna_time("01:02:03.500"), Some(3_723_500));
    }
}
