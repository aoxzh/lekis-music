//! `plugin.json` 清单。字段说明见 `plugin-sdk/schema/plugin.schema.json`。

use lekis_types::{LekisError, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// 插件类型（PLG-01）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PluginKind {
    /// 音源。
    Source,
    /// 歌词提供方。
    Lyrics,
    /// 封面提供方。
    Artwork,
    /// 标签 / 元数据提供方。
    Metadata,
    /// Scrobbler。
    Scrobbler,
    /// 歌单导入器。
    PlaylistImporter,
    /// 主题（只包含设计 Token，不执行代码）。
    Theme,
    /// 歌词样式。
    LyricsStyle,
    /// 可视化。
    Visualizer,
}

/// 能力（= 插件导出的函数名）。新增能力只能往后加。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Capability {
    /// 搜索。
    Search,
    /// 浏览（分类、歌单广场……）。
    Browse,
    /// 解析播放地址。
    Stream,
    /// 歌词。
    Lyrics,
    /// 封面。
    Artwork,
    /// 歌单详情。
    Playlist,
    /// 专辑详情。
    Album,
    /// 艺人详情。
    Artist,
    /// 上报播放。
    Scrobble,
    /// 导入歌单。
    ImportPlaylist,
}

/// 运行时类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeKind {
    /// JS / TS（QuickJS）。
    Js,
    /// WebAssembly 组件（1.x）。
    Wasm,
    /// 不执行代码（主题）。
    None,
}

/// 播放方式。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlaybackMode {
    /// 插件返回音频地址，由本机播放引擎播放。
    #[default]
    Stream,
    /// 插件遥控外部播放器 / 设备，本机不出声。
    Remote,
}

/// 清单里声明的权限。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeclaredPermissions {
    /// 可以访问的域名（支持 `*.example.com`）。
    #[serde(default)]
    pub network: Vec<String>,
    /// 给图片和音频请求附加的请求头（例如 Referer），按域名区分。
    #[serde(default)]
    pub request_headers: BTreeMap<String, BTreeMap<String, String>>,
    /// 可以启动的外部程序（只在桌面端有效，且需要用户在设置里逐个允许）。
    #[serde(default)]
    pub process: Vec<String>,
    /// 是否需要网页登录（`host.webSignIn`）。
    #[serde(default)]
    pub web_sign_in: bool,
    /// 存储配额（KB），默认 1024。
    #[serde(default)]
    pub storage_kb: Option<u32>,
}

/// 设置项类型。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SettingType {
    /// 文本。
    String,
    /// 密码（存系统钥匙串）。
    Password,
    /// 开关。
    Boolean,
    /// 下拉选择。
    Select,
}

/// 一个设置项（宿主据此自动生成设置界面）。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SettingSpec {
    /// 键。
    pub key: String,
    /// 类型。
    #[serde(rename = "type")]
    pub kind: SettingType,
    /// 标签（可以是 `locales` 里的键）。
    pub label: String,
    /// 默认值。
    #[serde(default)]
    pub default: Option<serde_json::Value>,
    /// 下拉选项。
    #[serde(default)]
    pub options: Vec<String>,
}

/// `plugin.json`。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginManifest {
    /// 反向域名 ID。
    pub id: String,
    /// 名称。
    pub name: String,
    /// 插件版本（语义化版本）。
    pub version: String,
    /// 插件 API 版本，例如 `1.0`。
    pub api_version: String,
    /// 最低 App 版本。
    pub min_app_version: String,
    /// 运行时。
    pub runtime: RuntimeKind,
    /// 入口文件（相对插件目录）。
    #[serde(default)]
    pub entry: Option<String>,
    /// 插件类型。
    pub kinds: Vec<PluginKind>,
    /// 播放方式。
    #[serde(default)]
    pub playback: PlaybackMode,
    /// 权限。
    #[serde(default)]
    pub permissions: DeclaredPermissions,
    /// 设置项。
    #[serde(default)]
    pub settings: Vec<SettingSpec>,
    /// 多语言资源目录。
    #[serde(default)]
    pub locales: Option<String>,
    /// 作者。
    #[serde(default)]
    pub author: Option<String>,
    /// 主页 / 仓库。
    #[serde(default)]
    pub homepage: Option<String>,
    /// 更新检查地址。
    #[serde(default)]
    pub update_url: Option<String>,
}

impl PluginManifest {
    /// 解析并校验。
    pub fn parse(json: &str) -> Result<Self> {
        let m: Self = serde_json::from_str(json)
            .map_err(|e| LekisError::invalid(format!("invalid plugin.json: {e}")))?;
        m.validate()?;
        Ok(m)
    }

    /// 校验字段之间的约束（JSON Schema 表达不了的部分）。
    pub fn validate(&self) -> Result<()> {
        let id_ok = self.id.split('.').count() >= 2
            && self.id.split('.').all(|p| {
                !p.is_empty()
                    && p.chars()
                        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
            });
        if !id_ok {
            return Err(LekisError::invalid(
                "plugin id must be reverse-domain, e.g. com.example.lyrics",
            ));
        }
        let major = self
            .api_version
            .split('.')
            .next()
            .and_then(|s| s.parse::<u32>().ok());
        if major != Some(crate::PLUGIN_API_VERSION.0) {
            return Err(LekisError::unsupported(format!(
                "plugin api version {} is not supported (host is {}.{})",
                self.api_version,
                crate::PLUGIN_API_VERSION.0,
                crate::PLUGIN_API_VERSION.1
            )));
        }
        if self.runtime != RuntimeKind::None && self.entry.is_none() {
            return Err(LekisError::invalid(
                "plugins with code must declare `entry`",
            ));
        }
        if self.kinds.is_empty() {
            return Err(LekisError::invalid("`kinds` must not be empty"));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_example_manifest() -> Result<()> {
        let json = include_str!("../../../../plugin-sdk/examples/lrclib-lyrics/plugin.json");
        let m = PluginManifest::parse(json)?;
        assert_eq!(m.id, "dev.lekis.example.lrclib");
        assert_eq!(m.kinds, vec![PluginKind::Lyrics]);
        assert_eq!(m.permissions.network, vec!["lrclib.net".to_string()]);
        Ok(())
    }

    #[test]
    fn rejects_bad_id() {
        let json = r#"{"id":"Bad Id","name":"x","version":"1.0.0","apiVersion":"1.0",
            "minAppVersion":"0.1.0","runtime":"js","entry":"index.ts","kinds":["lyrics"]}"#;
        assert!(PluginManifest::parse(json).is_err());
    }
}
