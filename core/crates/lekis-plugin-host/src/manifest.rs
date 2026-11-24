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
    /// 官方视频页（音源插件的可选能力）。
    Video,
}

impl PluginKind {
    /// 稳定的字符串形式（和清单 JSON 里的值一致）。
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Source => "source",
            Self::Lyrics => "lyrics",
            Self::Artwork => "artwork",
            Self::Metadata => "metadata",
            Self::Scrobbler => "scrobbler",
            Self::PlaylistImporter => "playlist_importer",
            Self::Theme => "theme",
            Self::LyricsStyle => "lyrics_style",
            Self::Visualizer => "visualizer",
            Self::Video => "video",
        }
    }
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
    /// 官方视频页。
    Video,
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

impl RuntimeKind {
    /// 稳定的字符串形式（和清单 JSON 里的值一致）。
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Js => "js",
            Self::Wasm => "wasm",
            Self::None => "none",
        }
    }
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

impl SettingType {
    /// 稳定的字符串形式（和清单 JSON 里的值一致）。
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::String => "string",
            Self::Password => "password",
            Self::Boolean => "boolean",
            Self::Select => "select",
        }
    }
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
    /// 帮助文本（可选，可以是 `locales` 里的键）。
    #[serde(default)]
    pub help: Option<String>,
    /// 默认值。
    #[serde(default)]
    pub default: Option<serde_json::Value>,
    /// 下拉选项。
    #[serde(default)]
    pub options: Vec<String>,
}

/// Foreign plugin contract interpreted by the host.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Compatibility {
    /// Documented MyGO source-plugin contract (stream playback subset).
    Mygo,
}

impl Compatibility {
    /// Stable identifier for settings and runtime cache keys.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Mygo => "mygo",
        }
    }
}

/// Optional native extensions. Each platform requires its own user grant.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct NativeSpec {
    /// Android DEX extension, invoked by the registered Android executor.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub android: Option<AndroidNativeSpec>,
}

/// Android native entry. The class must implement the runner's JSON contract.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AndroidNativeSpec {
    /// Plugin-relative .dex file or multi-DEX .jar container; absolute paths, parent traversal and symlinks are rejected.
    pub entry: String,
    /// Fully qualified Java class name.
    pub class_name: String,
}

/// `plugin.json`。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginManifest {
    /// Native code runs with full application privileges and is disabled by default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub native: Option<NativeSpec>,
    /// Optional public-contract compatibility adapter.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub compatibility: Option<Compatibility>,
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
        let mut value: serde_json::Value = serde_json::from_str(json)
            .map_err(|e| LekisError::invalid(format!("invalid plugin.json: {e}")))?;
        if value.get("apiVersion").is_none() && value.get("main").is_some() {
            normalize_mygo(&mut value)?;
        }
        let m: Self = serde_json::from_value(value)
            .map_err(|e| LekisError::invalid(format!("invalid plugin.json: {e}")))?;
        m.validate()?;
        Ok(m)
    }

    /// 校验字段之间的约束（JSON Schema 表达不了的部分）。
    pub fn validate(&self) -> Result<()> {
        if self.compatibility == Some(Compatibility::Mygo) && self.playback != PlaybackMode::Stream
        {
            return Err(LekisError::unsupported(
                "MyGO remote playback is not supported",
            ));
        }
        if let Some(android) = self
            .native
            .as_ref()
            .and_then(|native| native.android.as_ref())
        {
            let path = std::path::Path::new(&android.entry);
            if android.entry.is_empty()
                || android.entry.contains('\\')
                || path
                    .components()
                    .any(|part| !matches!(part, std::path::Component::Normal(_)))
            {
                return Err(LekisError::invalid(
                    "Native entry must be a plugin-relative path",
                ));
            }
            if android.class_name.split('.').count() < 2
                || !android.class_name.split('.').all(|part| {
                    let mut chars = part.chars();
                    chars
                        .next()
                        .is_some_and(|c| c.is_ascii_alphabetic() || c == '_' || c == '$')
                        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '$')
                })
            {
                return Err(LekisError::invalid(
                    "Android native className must be a fully qualified Java class name",
                ));
            }
        }
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

/// Normalize metadata only; the JavaScript adapter is independently implemented
/// from MyGO's README contracts. No MyGO application code is embedded here.
fn normalize_mygo(value: &mut serde_json::Value) -> Result<()> {
    use serde_json::{json, Value};
    let object = value
        .as_object_mut()
        .ok_or_else(|| LekisError::invalid("manifest must be an object"))?;
    let id = object
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| LekisError::invalid("MyGO manifest requires an id"))?;
    object.insert("id".into(), json!(format!("dev.mygo.{id}")));
    object.insert("compatibility".into(), json!("mygo"));
    object.insert("apiVersion".into(), json!("1.1"));
    // MyGO's minAppVersion names its own app, not a Lekis requirement.
    object.insert("minAppVersion".into(), json!("0.1.0"));
    object.insert("runtime".into(), json!("js"));
    object.insert(
        "entry".into(),
        object.get("main").cloned().unwrap_or(Value::Null),
    );
    object.insert("kinds".into(), json!(["source"]));
    object.entry("locales").or_insert(json!("locales"));
    if let Some(settings) = object.get_mut("settings").and_then(Value::as_array_mut) {
        for setting in settings {
            let Some(setting) = setting.as_object_mut() else {
                continue;
            };
            let kind = match setting.get("type").and_then(Value::as_str) {
                Some("password") => "password",
                Some("boolean") => "boolean",
                Some("select") => "select",
                _ => "string",
            };
            setting.insert("type".into(), json!(kind));
            if let Some(options) = setting.get_mut("options").and_then(Value::as_array_mut) {
                for option in options {
                    if let Some(v) = option.get("value").and_then(Value::as_str) {
                        *option = json!(v);
                    }
                }
            }
        }
    }
    let permissions = object.entry("permissions").or_insert(json!({}));
    let permissions = permissions
        .as_object_mut()
        .ok_or_else(|| LekisError::invalid("permissions must be an object"))?;
    let network: Vec<String> = permissions
        .get("network")
        .cloned()
        .map(serde_json::from_value)
        .transpose()
        .map_err(|_| LekisError::invalid("MyGO network permissions must be domain strings"))?
        .unwrap_or_default();
    if network.iter().any(|host| host == "*" || host.contains('{')) {
        return Err(LekisError::unsupported("MyGO wildcard-all and dynamic network permissions are not supported; declare explicit domains"));
    }
    if let Some(process) = permissions.get("process") {
        if !process.is_array()
            || process.as_array().is_some_and(|items| {
                items
                    .iter()
                    .any(|p| p.as_str().is_none_or(|p| p.contains('*')))
            })
        {
            return Err(LekisError::unsupported(
                "MyGO process permissions must name exact programs",
            ));
        }
    }
    // Network permission also authorizes stream-returned headers in MyGO.
    let mut headers: BTreeMap<String, BTreeMap<String, String>> = network
        .iter()
        .map(|h| (h.clone(), BTreeMap::new()))
        .collect();
    if let Some(rules) = permissions.get("requestHeaders") {
        let rules = rules
            .as_array()
            .ok_or_else(|| LekisError::invalid("MyGO requestHeaders must be an array"))?;
        for rule in rules {
            if rule.get("kinds").is_some() {
                return Err(LekisError::unsupported("MyGO requestHeaders kinds require separate image/audio policies and are not supported"));
            }
            let hosts: Vec<String> =
                serde_json::from_value(rule.get("hosts").cloned().unwrap_or(Value::Null))
                    .map_err(|_| LekisError::invalid("MyGO requestHeaders requires hosts"))?;
            let values: BTreeMap<String, String> =
                serde_json::from_value(rule.get("headers").cloned().unwrap_or(Value::Null))
                    .map_err(|_| {
                        LekisError::invalid("MyGO requestHeaders requires string headers")
                    })?;
            if hosts.iter().any(|h| !network.contains(h))
                || values
                    .values()
                    .any(|v| v.contains("{setting:") || v.contains("{storage:"))
            {
                return Err(LekisError::unsupported("MyGO dynamic requestHeaders are not supported; use literal headers and declared hosts"));
            }
            for host in hosts {
                headers.entry(host).or_default().extend(values.clone());
            }
        }
    }
    permissions.insert("requestHeaders".into(), json!(headers));
    Ok(())
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
    use super::*;

    #[test]
    fn normalizes_mygo_metadata_and_rejects_unimplemented_permissions() {
        let m = PluginManifest::parse(r#"{"id":"example","name":"Example","version":"1.0.0","main":"index.js","minAppVersion":"99.0.0","permissions":{"network":["api.example.com"]},"settings":[{"key":"key","label":"Key"}]}"#).unwrap();
        assert_eq!(m.id, "dev.mygo.example");
        assert_eq!(m.compatibility, Some(Compatibility::Mygo));
        assert_eq!(m.min_app_version, "0.1.0");
        assert_eq!(m.entry.as_deref(), Some("index.js"));
        assert_eq!(m.settings[0].kind, SettingType::String);
        assert!(m
            .permissions
            .request_headers
            .contains_key("api.example.com"));
        for extra in [
            r#""playback":"remote""#,
            r#""permissions":{"network":["*"]}"#,
            r#""permissions":{"process":true}"#,
            r#""permissions":{"network":["api.example.com"],"requestHeaders":[{"hosts":["api.example.com"],"headers":{"cookie":"{storage:token}"}}]}"#,
        ] {
            let json = format!(
                r#"{{"id":"example","name":"Example","version":"1.0.0","main":"index.js",{extra}}}"#
            );
            assert_eq!(
                PluginManifest::parse(&json).unwrap_err().code,
                lekis_types::ErrorCode::Unsupported
            );
        }
    }

    #[test]
    fn native_manifest_requires_safe_entry_and_java_class_name() {
        let mut value: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../plugin-sdk/examples/lrclib-lyrics/plugin.json"
        ))
        .unwrap();
        value["native"] = serde_json::json!({"android":{"entry":"android/classes.dex","className":"dev.example.NativePlugin"}});
        assert_eq!(
            PluginManifest::parse(&value.to_string())
                .unwrap()
                .native
                .unwrap()
                .android
                .unwrap()
                .class_name,
            "dev.example.NativePlugin"
        );
        for (entry, class_name) in [
            ("../classes.dex", "dev.example.Plugin"),
            ("/tmp/classes.dex", "dev.example.Plugin"),
            ("android/classes.dex", "Bad Class"),
            ("android/classes.dex", "dev..Plugin"),
        ] {
            value["native"]["android"]["entry"] = serde_json::json!(entry);
            value["native"]["android"]["className"] = serde_json::json!(class_name);
            assert!(PluginManifest::parse(&value.to_string()).is_err());
        }
    }

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

    #[test]
    fn rejects_code_plugin_without_entry() {
        let json = r#"{"id":"dev.lekis.example.no-entry","name":"x","version":"1.0.0",
            "apiVersion":"1.0","minAppVersion":"0.1.0","runtime":"js","kinds":["lyrics"]}"#;
        let error = PluginManifest::parse(json).unwrap_err();
        assert_eq!(error.code, lekis_types::ErrorCode::InvalidArgument);
    }

    #[test]
    fn rejects_unsupported_api_major() {
        let json = r#"{"id":"dev.lekis.example.api2","name":"x","version":"1.0.0",
            "apiVersion":"2.0","minAppVersion":"0.1.0","runtime":"js","entry":"index.js",
            "kinds":["lyrics"]}"#;
        let error = PluginManifest::parse(json).unwrap_err();
        assert_eq!(error.code, lekis_types::ErrorCode::Unsupported);
    }

    #[test]
    fn rejects_empty_kinds() {
        let json = r#"{"id":"dev.lekis.example.empty","name":"x","version":"1.0.0",
            "apiVersion":"1.0","minAppVersion":"0.1.0","runtime":"none","kinds":[]}"#;
        assert!(PluginManifest::parse(json).is_err());
    }

    #[test]
    fn accepts_theme_without_entry() {
        let json = r#"{"id":"dev.lekis.example.theme","name":"x","version":"1.0.0",
            "apiVersion":"1.0","minAppVersion":"0.1.0","runtime":"none","kinds":["theme"]}"#;
        let manifest = PluginManifest::parse(json).unwrap();
        assert_eq!(manifest.runtime, RuntimeKind::None);
        assert_eq!(manifest.kinds, vec![PluginKind::Theme]);
    }
}
