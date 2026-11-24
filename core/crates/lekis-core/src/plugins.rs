//! 本地插件管理：扫描 `<data_dir>/plugins/*/plugin.json`，安装 / 移除，保存启用状态和设置。
//!
//! 管理器负责安装、设置和音源编排，JavaScript 执行由
//! `lekis-plugin-host` 负责。插件目录布局：
//!
//! ```text
//! <data_dir>/plugins/<plugin id>/plugin.json
//! <data_dir>/plugin-data/<plugin id>/        # 插件配额内的私有 JSON 存储
//! ```
//!
//! 安装时先复制 / 解压到 `plugins/` 下以 `.install-` 开头的临时目录，校验清单后再
//! `rename` 成最终目录，所以 App 不会看到半安装状态。清单无效的目录会出现在列表里，
//! 错误放在 `error` 字段，不影响其他插件。

mod artwork;
mod lyrics;

use lekis_library::{DbResultExt, Library};
use lekis_plugin_host::manifest::{PluginManifest, SettingSpec, SettingType};
use lekis_plugin_host::{Capability, JsRuntime, Permissions, PluginRuntime};
use lekis_types::{ErrorCode, LekisError, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

/// 启用状态在 kv 里的前缀，后面接插件 id。
const ENABLED_PREFIX: &str = "plugin.enabled.";
/// 插件设置项在 kv 里的前缀，后面接 `<插件 id>.<设置 key>`。
const SETTING_PREFIX: &str = "plugin.setting.";
/// 安装临时目录前缀。`list` 会跳过以 `.` 开头的目录。
const STAGING_PREFIX: &str = ".install-";
/// 一个 zip 最多包含的文件数，避免恶意包把设备塞满。
const MAX_ZIP_FILES: usize = 10_000;
/// 解压后的总大小上限（128 MB）。
const MAX_ZIP_BYTES: u64 = 128 * 1024 * 1024;

/// 插件声明的权限摘要（给设置页展示，不参与权限判断）。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginPermissions {
    /// 允许访问的域名。
    pub network: Vec<String>,
    /// 允许启动的外部程序。
    pub process: Vec<String>,
    /// 需要附加请求头的域名（只展示域名，不展示头的值）。
    pub request_header_hosts: Vec<String>,
    /// 是否需要网页登录。
    pub web_sign_in: bool,
    /// 存储配额（KB）。
    pub storage_kb: u32,
    /// Declares application-privileged Android code; requires a separate user grant.
    pub native_android: bool,
}

/// 一个设置项的当前值和展示信息。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginSettingView {
    /// 设置 key。
    pub key: String,
    /// 展示标签（可能是 locales 里的键）。
    pub label: String,
    /// 帮助文字（可能是 locales 里的键）。
    pub help: Option<String>,
    /// `string` / `password` / `boolean` / `select`。
    pub kind: String,
    /// 下拉选项。
    pub options: Vec<String>,
    /// 默认值（已转成展示用的字符串；密码不返回）。
    pub default: Option<String>,
    /// 当前值（密码永远为 `None`）。
    pub value: Option<String>,
    /// 是否已经保存过值（或清单提供了默认值）。
    pub has_value: bool,
    /// 是否是密码项。界面不要回填、也不要记录它的值。
    pub secret: bool,
}

/// 已安装插件的信息。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginInfo {
    /// 清单声明的反向域名 id；清单损坏时退化为目录名。
    pub id: String,
    /// 名称；清单损坏时退化为目录名。
    pub name: String,
    /// 版本。
    pub version: String,
    /// 插件 API 版本。
    pub api_version: String,
    /// `js` / `wasm` / `none`。
    pub runtime: String,
    /// Optional foreign-plugin protocol, currently `mygo`.
    pub compatibility: Option<String>,
    /// 插件类型列表。
    pub kinds: Vec<String>,
    /// 入口文件（相对插件目录）。
    pub entry: Option<String>,
    /// 是否启用。清单损坏时固定为 `false`。
    pub enabled: bool,
    /// Separate Android native-code grant, default false.
    pub native_android_granted: bool,
    /// 清单错误（损坏 / 不支持）。正常插件为 `None`。
    pub error: Option<String>,
    /// 插件目录名。
    pub directory: String,
    /// 作者。
    pub author: Option<String>,
    /// 主页。
    pub homepage: Option<String>,
    /// 权限摘要。
    pub permissions: PluginPermissions,
    /// 清单声明的设置项。
    pub settings: Vec<PluginSettingView>,
}

#[derive(Deserialize)]
struct TrackPage {
    items: Vec<SourceTrack>,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SourceTrack {
    id: String,
    title: String,
    #[serde(default)]
    artists: Vec<String>,
    album: Option<String>,
    #[serde(default)]
    duration_ms: u64,
    #[serde(default)]
    artwork_url: Option<String>,
}

/// A validated source-plugin stream, resolved at playback time.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginStream {
    /// HTTPS URL inside the plugin's declared hosts.
    pub url: String,
    /// Optional request headers, requiring a declared header host.
    #[serde(default)]
    pub headers: BTreeMap<String, String>,
    /// Signed URL expiry in Unix milliseconds.
    pub expires_at: Option<u64>,
}

/// A navigable source-plugin folder; its ID is an opaque browse path.
#[derive(Debug, Clone)]
pub struct PluginFolder {
    /// Opaque path supplied by the plugin.
    pub id: String,
    /// Display title.
    pub title: String,
    /// Optional descriptive text.
    pub subtitle: Option<String>,
}

/// One read-only page of a source plugin, with queue-compatible track rows.
#[derive(Debug, Clone, Default)]
pub struct PluginBrowsePage {
    /// Navigable folders, albums, artists and playlists.
    pub folders: Vec<PluginFolder>,
    /// Tracks imported with stable references.
    pub tracks: Vec<lekis_types::TrackRow>,
    /// Opaque next-page cursor.
    pub next: Option<String>,
}

type CallGates = BTreeMap<String, Arc<tokio::sync::Mutex<()>>>;
type RuntimeCache = BTreeMap<String, (String, Arc<JsRuntime>)>;
type ArtworkGates = BTreeMap<lekis_types::TrackId, std::sync::Weak<tokio::sync::Mutex<()>>>;

/// 文件系统插件管理器。可以廉价克隆，共享路径、资料库和运行时缓存。
#[derive(Clone)]
pub struct PluginManager {
    root: PathBuf,
    data_root: PathBuf,
    library: Library,
    execution: Arc<tokio::sync::Mutex<()>>,
    runtimes: Arc<tokio::sync::Mutex<RuntimeCache>>,
    call_gates: Arc<tokio::sync::Mutex<CallGates>>,
    artwork_cache: PathBuf,
    artwork_downloads: Arc<tokio::sync::Semaphore>,
    artwork_gates: Arc<tokio::sync::Mutex<ArtworkGates>>,
    artwork_events: Option<crate::events::EventBus>,
    artwork_retry_after:
        Arc<tokio::sync::Mutex<BTreeMap<lekis_types::TrackId, std::time::Instant>>>,
}

impl PluginManager {
    /// 用数据目录和资料库创建管理器（不会创建目录，扫描 / 安装时再创建）。
    pub fn new(data_dir: &Path, library: Library) -> Self {
        Self {
            root: data_dir.join("plugins"),
            data_root: data_dir.join("plugin-data"),
            library,
            execution: Arc::new(tokio::sync::Mutex::new(())),
            runtimes: Arc::default(),
            call_gates: Arc::default(),
            artwork_cache: data_dir.join("cache"),
            artwork_downloads: Arc::new(tokio::sync::Semaphore::new(4)),
            artwork_gates: Arc::default(),
            artwork_events: None,
            artwork_retry_after: Arc::default(),
        }
    }

    /// Restore an interrupted replacement before exposing plugins at startup.
    pub(crate) fn recover_interrupted_installs(data_dir: &Path) -> Result<()> {
        let root = data_dir.join("plugins");
        if !root.is_dir() {
            return Ok(());
        }
        for entry in fs::read_dir(&root)? {
            let entry = entry?;
            let path = entry.path();
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if !name.starts_with(STAGING_PREFIX) || !name.ends_with(".restore") {
                continue;
            }
            let original = fs::read_to_string(&path)?;
            let mut components = Path::new(&original).components();
            if !matches!(components.next(), Some(std::path::Component::Normal(_)))
                || components.next().is_some()
                || original.starts_with('.')
            {
                return Err(LekisError::invalid("插件恢复记录无效"));
            }
            let backup = path.with_extension("backup");
            if backup.is_dir() {
                let destination = root.join(original);
                if destination.exists() {
                    fs::remove_dir_all(&destination)?;
                }
                fs::rename(&backup, &destination)?;
            }
            fs::remove_file(path)?;
        }
        Ok(())
    }

    /// 插件目录。
    pub fn root(&self) -> &Path {
        &self.root
    }

    async fn call_gate(&self, plugin_id: &str) -> Arc<tokio::sync::Mutex<()>> {
        self.call_gates
            .lock()
            .await
            .entry(plugin_id.to_string())
            .or_default()
            .clone()
    }

    fn storage_path(&self, plugin_id: &str) -> PathBuf {
        self.data_root.join(plugin_id).join("storage.json")
    }

    fn read_storage(&self, plugin_id: &str) -> Result<BTreeMap<String, String>> {
        let path = self.storage_path(plugin_id);
        if !path.exists() {
            return Ok(BTreeMap::new());
        }
        // Bound the serialized representation as well as the runtime's storage quota.
        let mut bytes = Vec::new();
        fs::File::open(path)?
            .take(16 * 1024 * 1024 + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() > 16 * 1024 * 1024 {
            return Err(LekisError::invalid("插件私有存储文件超过 16 MiB"));
        }
        serde_json::from_slice(&bytes)
            .map_err(|_| LekisError::invalid("插件私有存储文件损坏，请先备份并检查 plugin-data"))
    }

    fn write_storage(&self, plugin_id: &str, values: &BTreeMap<String, String>) -> Result<()> {
        let path = self.storage_path(plugin_id);
        let directory = path
            .parent()
            .ok_or_else(|| LekisError::internal("插件存储路径无效"))?;
        fs::create_dir_all(directory)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(directory, fs::Permissions::from_mode(0o700))?;
        }
        let bytes = serde_json::to_vec(values).map_err(|e| LekisError::internal(e.to_string()))?;
        if bytes.len() > 16 * 1024 * 1024 {
            return Err(LekisError::invalid("插件私有存储文件超过 16 MiB"));
        }
        let temporary = directory.join("storage.tmp");
        #[cfg(unix)]
        {
            use std::io::Write;
            use std::os::unix::fs::OpenOptionsExt;
            let mut file = fs::OpenOptions::new()
                .create(true)
                .truncate(true)
                .write(true)
                .mode(0o600)
                .open(&temporary)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
        }
        #[cfg(not(unix))]
        {
            fs::write(&temporary, bytes)?;
        }
        fs::rename(temporary, path)?;
        Ok(())
    }

    /// Invoke an installed plugin using current settings and separately granted processes.
    pub async fn call(
        &self,
        plugin_id: &str,
        capability: Capability,
        params: Value,
    ) -> Result<Value> {
        // The owned task finishes state persistence even when a UI request is
        // cancelled. Uninstall waits on the same per-plugin gate.
        let manager = self.clone();
        let plugin_id = plugin_id.to_owned();
        tokio::spawn(async move { manager.call_inner(&plugin_id, capability, params).await })
            .await
            .map_err(|e| LekisError::internal(format!("插件调用任务异常：{e}")))?
    }

    async fn call_inner(
        &self,
        plugin_id: &str,
        capability: Capability,
        params: Value,
    ) -> Result<Value> {
        let gate = self.call_gate(plugin_id).await;
        let _call_guard = gate.lock().await;
        let (directory, manifest) = self.find_installed(plugin_id)?;
        let mut manifest = manifest.ok_or_else(|| LekisError::invalid("插件清单无效"))?;
        validate_entry(&directory, &manifest)?;
        if self
            .library
            .get_setting(&format!("{ENABLED_PREFIX}{plugin_id}"))
            .await?
            .as_deref()
            == Some("false")
        {
            return Err(LekisError::unsupported("插件已停用"));
        }
        let mut allowed = Vec::new();
        for program in &manifest.permissions.process {
            if self
                .library
                .get_setting(&format!("plugin.process.{plugin_id}.{program}"))
                .await?
                .as_deref()
                == Some("true")
            {
                allowed.push(program.clone());
            }
        }
        for spec in &mut manifest.settings {
            if let Some(value) = self
                .library
                .get_setting(&format!("{SETTING_PREFIX}{plugin_id}.{}", spec.key))
                .await?
            {
                spec.default = Some(
                    serde_json::from_str(&value)
                        .map_err(|e| LekisError::invalid(format!("插件设置无效：{e}")))?,
                );
            }
        }
        let native_granted = self.native_android_allowed(plugin_id).await?;
        let permissions = Permissions::new(&manifest.permissions, &allowed);
        let entry = manifest
            .entry
            .as_deref()
            .ok_or_else(|| LekisError::unsupported("插件没有入口"))?;
        let source = fs::read_to_string(directory.join(entry))?;
        // Keep host.storage between calls. Rebuild on code/settings/grant changes.
        let signature = serde_json::to_string(&(&manifest, &source, &allowed, native_granted))
            .map_err(|e| LekisError::internal(e.to_string()))?;
        let runtime = {
            let mut cache = self.runtimes.lock().await;
            if let Some((_, runtime)) = cache.get(plugin_id).filter(|(old, _)| old == &signature) {
                runtime.clone()
            } else {
                let native_root = directory.clone();
                let runtime = Arc::new(
                    tokio::task::spawn_blocking(move || {
                        let mut runtime = JsRuntime::load_with_native(
                            manifest,
                            permissions,
                            &source,
                            native_root,
                            native_granted,
                        )?;
                        runtime.set_call_timeout(std::time::Duration::from_secs(60));
                        Ok::<_, LekisError>(runtime)
                    })
                    .await
                    .map_err(|e| LekisError::internal(e.to_string()))??,
                );
                runtime.restore_storage(self.read_storage(plugin_id)?)?;
                cache.insert(plugin_id.to_string(), (signature, runtime.clone()));
                runtime
            }
        };
        let locale = if lekis_types::i18n::is_english() {
            "en"
        } else {
            "zh-CN"
        };
        let translations = directory.join("locales").join(format!("{locale}.json"));
        let translations: BTreeMap<String, String> = if translations.is_file() {
            serde_json::from_slice(&fs::read(translations)?)
                .map_err(|_| LekisError::invalid("插件语言文件无效"))?
        } else {
            BTreeMap::new()
        };
        runtime.set_translations(translations)?;
        let result = runtime.call(capability, params).await;
        // State updates made before a structured error (e.g. visitor identity) still survive.
        self.write_storage(plugin_id, &runtime.storage_snapshot()?)?;
        result
    }

    /// Search one source plugin and persist stable references for playback, favorites and playlists.
    pub async fn search(
        &self,
        plugin_id: &str,
        query: &str,
        limit: u32,
    ) -> Result<lekis_types::SearchResults> {
        if query.trim().is_empty() || limit == 0 {
            return Ok(lekis_types::SearchResults::default());
        }
        let (_, manifest) = self.find_installed(plugin_id)?;
        let manifest = manifest.ok_or_else(|| LekisError::invalid("插件清单无效"))?;
        if !manifest
            .kinds
            .contains(&lekis_plugin_host::PluginKind::Source)
        {
            return Err(LekisError::unsupported("插件不是音源"));
        }
        let limit = limit.min(100);
        let result = self
            .call(
                plugin_id,
                Capability::Search,
                serde_json::json!({"query":query.trim(), "type":"track", "limit":limit}),
            )
            .await?;
        let page: TrackPage = serde_json::from_value(result)
            .map_err(|e| LekisError::invalid(format!("插件搜索结果无效：{e}")))?;
        Ok(lekis_types::SearchResults {
            tracks: self
                .import_tracks(
                    plugin_id,
                    manifest.name,
                    page.items.into_iter().take(limit as usize).collect(),
                )
                .await?,
            ..Default::default()
        })
    }

    async fn import_tracks(
        &self,
        plugin_id: &str,
        name: String,
        items: Vec<SourceTrack>,
    ) -> Result<Vec<lekis_types::TrackRow>> {
        let mut seen = std::collections::BTreeSet::new();
        let mut tracks = Vec::new();
        let mut artwork = BTreeMap::new();
        for track in items.into_iter().take(100) {
            if track.id.trim().is_empty()
                || track.title.trim().is_empty()
                || track.duration_ms > i64::MAX as u64
            {
                return Err(LekisError::invalid("插件返回了无效曲目"));
            }
            if seen.insert(track.id.clone()) {
                if let Some(url) = track.artwork_url {
                    artwork.insert(track.id.clone(), url);
                }
                tracks.push(lekis_library::RemoteTrackRow {
                    external_album_id: None,
                    album_artists: vec![],
                    disc_no: None,
                    track_no: None,
                    external_id: track.id,
                    title: track.title,
                    artists: track.artists,
                    album: track.album,
                    duration_ms: track.duration_ms,
                    mbid_recording: None,
                    quality_score: 100,
                });
            }
        }
        let _guard = self.execution.lock().await;
        let sources = self.library.list_sources().await?;
        let existing = sources
            .iter()
            .find(|s| s.kind == lekis_types::SourceKind::Plugin && s.root_path == plugin_id);
        let source_id = if let Some(source) = existing {
            if !source.enabled {
                return Err(LekisError::unsupported("插件音源已停用"));
            }
            source
                .id
                .ok_or_else(|| LekisError::internal("插件音源缺少 ID"))?
        } else {
            self.library
                .add_source(lekis_types::SourceConfig {
                    id: None,
                    kind: lekis_types::SourceKind::Plugin,
                    name,
                    addresses: Vec::new(),
                    root_path: plugin_id.to_string(),
                    credential_ref: None,
                    options: BTreeMap::new(),
                    enabled: true,
                })
                .await?
        };
        let external_ids: Vec<_> = tracks.iter().map(|t| t.external_id.clone()).collect();
        let rows = self.library.append_plugin_tracks(source_id, tracks).await?;
        for (row, external_id) in rows.iter().zip(external_ids.iter()) {
            if let Some(url) = artwork.get(external_id) {
                // Invalid/missing covers never hide otherwise playable songs.
                let _ = self
                    .remember_artwork(plugin_id, row.id, external_id, url)
                    .await;
            }
        }
        Ok(rows)
    }

    /// Browse a source's public home, collections or custom pages without remote mutations.
    pub async fn browse(
        &self,
        plugin_id: &str,
        path: &str,
        cursor: Option<&str>,
    ) -> Result<PluginBrowsePage> {
        let (_, manifest) = self.find_installed(plugin_id)?;
        let manifest = manifest.ok_or_else(|| LekisError::invalid("插件清单无效"))?;
        if !manifest
            .kinds
            .contains(&lekis_plugin_host::PluginKind::Source)
        {
            return Err(LekisError::unsupported("插件不是音源"));
        }
        let result = self
            .call(
                plugin_id,
                Capability::Browse,
                serde_json::json!({"path":path,"cursor":cursor,"limit":100}),
            )
            .await?;
        let entries = result
            .get("items")
            .and_then(Value::as_array)
            .ok_or_else(|| LekisError::invalid("插件浏览结果必须包含 items 数组"))?;
        let mut page = PluginBrowsePage {
            next: result
                .get("next")
                .and_then(Value::as_str)
                .map(str::to_owned),
            ..Default::default()
        };
        let mut tracks = Vec::new();
        for entry in entries.iter().take(500) {
            let kind = entry.get("kind").and_then(Value::as_str).unwrap_or("track");
            if kind == "track" {
                let mut track: SourceTrack = serde_json::from_value(entry.clone())
                    .map_err(|e| LekisError::invalid(format!("插件曲目无效：{e}")))?;
                if track.artists.is_empty() {
                    if let Some(subtitle) = entry.get("subtitle").and_then(Value::as_str) {
                        track.artists.push(subtitle.to_string());
                    }
                }
                tracks.push(track);
            } else if matches!(kind, "folder" | "album" | "playlist" | "artist") {
                let id = entry
                    .get("id")
                    .and_then(Value::as_str)
                    .filter(|id| !id.is_empty())
                    .ok_or_else(|| LekisError::invalid("插件文件夹缺少 ID"))?;
                page.folders.push(PluginFolder {
                    id: id.to_string(),
                    title: entry
                        .get("title")
                        .and_then(Value::as_str)
                        .unwrap_or(id)
                        .to_string(),
                    subtitle: entry
                        .get("subtitle")
                        .and_then(Value::as_str)
                        .map(str::to_owned),
                });
            }
        }
        // Import in bounded chunks while preserving the provider's ordering.
        for chunk in tracks.chunks(100) {
            page.tracks.extend(
                self.import_tracks(plugin_id, manifest.name.clone(), chunk.to_vec())
                    .await?,
            );
        }
        Ok(page)
    }

    /// Resolve just before playback: signed URLs are never stored in the library.
    pub async fn stream(&self, plugin_id: &str, id: &str) -> Result<PluginStream> {
        let result = self
            .call(
                plugin_id,
                Capability::Stream,
                serde_json::json!({"id":id,"quality":"high"}),
            )
            .await?;
        let stream: PluginStream = serde_json::from_value(result)
            .map_err(|e| LekisError::invalid(format!("插件播放地址无效：{e}")))?;
        let (_, manifest) = self.find_installed(plugin_id)?;
        let manifest = manifest.ok_or_else(|| LekisError::invalid("插件清单无效"))?;
        let permissions = Permissions::new(&manifest.permissions, &[]);
        if !permissions.allows_url(&stream.url) {
            return Err(LekisError::unsupported("播放地址超出插件声明的网络权限"));
        }
        if stream
            .expires_at
            .is_some_and(|expiry| expiry <= lekis_types::now_ms() as u64 + 5_000)
        {
            return Err(LekisError::not_found("插件返回的播放地址已过期，请重试"));
        }
        if !stream.headers.is_empty() {
            let url =
                url::Url::parse(&stream.url).map_err(|e| LekisError::invalid(e.to_string()))?;
            let host = url.host_str().unwrap_or_default();
            if !manifest.permissions.request_headers.keys().any(|pattern| {
                pattern == host
                    || pattern.strip_prefix("*.").is_some_and(|suffix| {
                        host == suffix || host.ends_with(&format!(".{suffix}"))
                    })
            }) {
                return Err(LekisError::unsupported("插件未声明播放请求头权限"));
            }
        }
        Ok(stream)
    }

    /// 列出已安装插件。清单损坏的目录也会返回，错误放在 `error` 里，不会让整次扫描失败。
    pub async fn list(&self) -> Result<Vec<PluginInfo>> {
        fs::create_dir_all(&self.root)?;
        let enabled = rows_to_map(self.library.settings_with_prefix(ENABLED_PREFIX).await?);
        let values = rows_to_map(self.library.settings_with_prefix(SETTING_PREFIX).await?);

        let mut plugins = Vec::new();
        for entry in fs::read_dir(&self.root)? {
            let entry = entry?;
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            let directory = entry.file_name().to_string_lossy().to_string();
            if directory.starts_with('.') || !path.join("plugin.json").is_file() {
                continue;
            }
            let mut info = self.read_info(&path, &directory, &enabled, &values);
            info.native_android_granted = self
                .library
                .get_setting(&format!("plugin.native.{}.android", info.id))
                .await?
                .as_deref()
                == Some("true");
            plugins.push(info);
        }
        plugins.sort_by(|a, b| {
            a.name
                .to_lowercase()
                .cmp(&b.name.to_lowercase())
                .then_with(|| a.id.cmp(&b.id))
        });
        Ok(plugins)
    }

    /// 从本地文件夹或 `.zip` 安装或更新插件，保留同 ID 的用户数据。
    pub async fn install(&self, source: &Path) -> Result<PluginInfo> {
        if !source.exists() {
            return Err(LekisError::not_found(format!(
                "plugin source does not exist: {}",
                source.display()
            )));
        }
        fs::create_dir_all(&self.root)?;
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let staging = self
            .root
            .join(format!("{STAGING_PREFIX}{}-{stamp}", std::process::id()));
        let _ = fs::remove_dir_all(&staging);
        fs::create_dir_all(&staging)?;

        let manager = self.clone();
        let source = source.to_owned();
        let task_staging = staging.clone();
        let result = tokio::spawn(async move {
            let result = manager.install_staged(&source, &task_staging).await;
            if task_staging.exists() {
                let _ = fs::remove_dir_all(&task_staging);
            }
            result
        })
        .await
        .map_err(|e| LekisError::internal(format!("插件安装任务异常：{e}")))?;
        // 成功时 staging 已经被 rename 成最终目录；失败时清掉临时目录。
        if staging.exists() {
            let _ = fs::remove_dir_all(&staging);
        }
        result
    }

    /// 启用 / 停用一个插件。状态存在资料库的 kv 表里（`plugin.enabled.<id>`）。
    pub async fn set_enabled(&self, plugin_id: &str, enabled: bool) -> Result<()> {
        let (_, manifest) = self.find_installed(plugin_id)?;
        let Some(manifest) = manifest else {
            return Err(LekisError::invalid(format!(
                "插件 {plugin_id} 的清单无效，不能切换启用状态"
            )));
        };
        let value = if enabled { "true" } else { "false" };
        self.library
            .set_setting(&format!("{ENABLED_PREFIX}{}", manifest.id), value)
            .await
    }

    /// Read the separate Android code grant; only literal "true" authorizes it.
    pub async fn native_android_allowed(&self, plugin_id: &str) -> Result<bool> {
        Ok(self
            .library
            .get_setting(&format!("plugin.native.{plugin_id}.android"))
            .await?
            .as_deref()
            == Some("true"))
    }

    /// Grant application-privileged code separately; revocation waits for active work.
    pub async fn set_native_android_allowed(&self, plugin_id: &str, allowed: bool) -> Result<()> {
        let gate = self.call_gate(plugin_id).await;
        let _guard = gate.lock().await;
        let (_, manifest) = self.find_installed(plugin_id)?;
        let manifest = manifest.ok_or_else(|| LekisError::invalid("插件清单无效"))?;
        if manifest
            .native
            .as_ref()
            .and_then(|native| native.android.as_ref())
            .is_none()
        {
            return Err(LekisError::invalid("插件未声明 Android 原生扩展"));
        }
        self.library
            .set_setting(
                &format!("plugin.native.{plugin_id}.android"),
                if allowed { "true" } else { "false" },
            )
            .await?;
        self.runtimes.lock().await.remove(plugin_id);
        Ok(())
    }

    /// 移除插件目录、插件数据目录和相关的设置项。
    pub async fn remove(&self, plugin_id: &str) -> Result<()> {
        // Once uninstall starts, finish revocation and cleanup even if the UI
        // drops its request. Reinstallation waits on this same per-plugin gate.
        let manager = self.clone();
        let plugin_id = plugin_id.to_owned();
        tokio::spawn(async move { manager.remove_inner(&plugin_id).await })
            .await
            .map_err(|e| LekisError::internal(format!("插件移除任务异常：{e}")))?
    }

    async fn remove_inner(&self, plugin_id: &str) -> Result<()> {
        let gate = self.call_gate(plugin_id).await;
        let _call_guard = gate.lock().await;
        let (directory, manifest) = self.find_installed(plugin_id)?;
        let directory_name = directory
            .file_name()
            .map(|name| name.to_string_lossy().to_string())
            .ok_or_else(|| LekisError::internal("插件目录没有名字"))?;
        let id = manifest
            .as_ref()
            .map(|m| m.id.clone())
            .unwrap_or_else(|| directory_name.clone());

        self.runtimes.lock().await.remove(plugin_id);
        // Revoke privileges before deleting the installation, including when a
        // subsequent filesystem/data cleanup fails and the user reinstalls it.
        self.reset_host_grants(&id).await?;
        fs::remove_dir_all(&directory)?;
        for name in [&id, &directory_name] {
            let data = self.data_root.join(name);
            if data.exists() {
                fs::remove_dir_all(&data)?;
            }
        }

        let keys = self
            .library
            .settings_with_prefix(&format!("{SETTING_PREFIX}{id}."))
            .await?;
        for (key, _) in keys {
            self.library.delete_setting(&key).await?;
        }
        self.library
            .delete_setting(&format!("{ENABLED_PREFIX}{id}"))
            .await?;
        if id != directory_name {
            self.library
                .delete_setting(&format!("{ENABLED_PREFIX}{directory_name}"))
                .await?;
        }
        Ok(())
    }

    async fn reset_host_grants(&self, plugin_id: &str) -> Result<()> {
        let native_key = format!("plugin.native.{plugin_id}.android");
        let process_prefix = format!("plugin.process.{plugin_id}.");
        self.library
            .write(move |connection| {
                // One statement revokes both grants atomically. Use a literal
                // prefix rather than LIKE so plugin IDs cannot act as patterns.
                connection
                    .execute(
                        "DELETE FROM kv WHERE key = ?1 OR substr(key, 1, length(?2)) = ?2",
                        [&native_key, &process_prefix],
                    )
                    .db()?;
                Ok(())
            })
            .await
    }

    /// 读一个插件的全部设置项（含当前值）。密码项不返回值。
    pub async fn settings(&self, plugin_id: &str) -> Result<Vec<PluginSettingView>> {
        let (_, manifest) = self.find_installed(plugin_id)?;
        let Some(manifest) = manifest else {
            return Err(LekisError::invalid(format!(
                "插件 {plugin_id} 的清单无效，无法读取设置"
            )));
        };
        let values = self
            .library
            .settings_with_prefix(&format!("{SETTING_PREFIX}{}.", manifest.id))
            .await?;
        let values = rows_to_map(values);
        Ok(manifest
            .settings
            .iter()
            .map(|spec| setting_view(&manifest.id, spec, &values))
            .collect())
    }

    /// 写一个设置项。值的格式按清单里的类型校验（布尔 / 下拉选项）。
    pub async fn set_setting(&self, plugin_id: &str, key: &str, value: &str) -> Result<()> {
        let (_, manifest) = self.find_installed(plugin_id)?;
        let Some(manifest) = manifest else {
            return Err(LekisError::invalid(format!(
                "插件 {plugin_id} 的清单无效，无法保存设置"
            )));
        };
        let Some(spec) = manifest.settings.iter().find(|s| s.key == key) else {
            return Err(LekisError::not_found(format!(
                "插件 {} 没有设置项 {key}",
                manifest.id
            )));
        };
        let encoded = encode_setting_value(spec, value)?;
        self.library
            .set_setting(&format!("{SETTING_PREFIX}{}.{key}", manifest.id), &encoded)
            .await
    }

    async fn install_staged(&self, source: &Path, staging: &Path) -> Result<PluginInfo> {
        if source.is_dir() {
            // 用户如果选了插件目录的父目录（甚至数据目录），直接拒绝，避免把临时目录也递归复制进去。
            let source = source.canonicalize()?;
            let target = staging.canonicalize()?;
            if target.starts_with(&source) {
                return Err(LekisError::invalid(
                    "不能从包含插件临时目录的文件夹安装插件",
                ));
            }
            copy_tree(&source, staging)?;
        } else if is_zip(source) {
            extract_zip(source, staging)?;
        } else {
            return Err(LekisError::invalid("插件来源必须是文件夹或 .zip 文件"));
        }

        let plugin_root = locate_plugin_root(staging)?;
        let manifest = read_manifest(&plugin_root)?;
        validate_entry(&plugin_root, &manifest)?;

        let gate = self.call_gate(&manifest.id).await;
        let _guard = gate.lock().await;
        let previous = match self.find_installed(&manifest.id) {
            Ok(installed) => Some(installed),
            Err(error) if error.code == ErrorCode::NotFound => None,
            Err(error) => return Err(error),
        };
        let final_dir = previous
            .as_ref()
            .map(|(path, _)| path.clone())
            .unwrap_or_else(|| self.root.join(&manifest.id));
        if previous.is_none() && final_dir.exists() {
            return Err(LekisError::invalid("插件目标目录已存在"));
        }
        // A backup sits beside hidden staging, on the same filesystem. Calls
        // hold this same gate, so no invocation can observe a partial package.
        let backup = staging.with_extension("backup");
        let journal = staging.with_extension("restore");
        if previous.is_some() {
            let name = final_dir
                .file_name()
                .and_then(|n| n.to_str())
                .ok_or_else(|| LekisError::invalid("插件目录名无法用于恢复"))?;
            fs::write(&journal, name)?;
        }
        let retain_native = previous.as_ref().is_some_and(|(path, old)| {
            old.as_ref() == Some(&manifest)
                && manifest.entry.as_ref().is_none_or(|entry| {
                    fs::read(path.join(entry)).ok() == fs::read(plugin_root.join(entry)).ok()
                })
                && manifest
                    .native
                    .as_ref()
                    .and_then(|n| n.android.as_ref())
                    .is_none_or(|n| {
                        fs::read(path.join(&n.entry)).ok()
                            == fs::read(plugin_root.join(&n.entry)).ok()
                    })
        });
        let retained_processes: Vec<String> = previous
            .as_ref()
            .and_then(|(_, old)| old.as_ref())
            .map(|old| {
                manifest
                    .permissions
                    .process
                    .iter()
                    .filter(|p| old.permissions.process.contains(p))
                    .cloned()
                    .collect()
            })
            .unwrap_or_default();
        if previous.is_some() {
            fs::rename(&final_dir, &backup)?;
        }
        if let Err(error) = fs::rename(&plugin_root, &final_dir) {
            if previous.is_some() {
                fs::rename(&backup, &final_dir)?;
            }
            return Err(error.into());
        }
        let id = manifest.id.clone();
        let grant_result = self
            .library
            .write(move |connection| {
                let tx = connection.transaction().db()?;
                if !retain_native {
                    tx.execute(
                        "DELETE FROM kv WHERE key = ?1",
                        [format!("plugin.native.{id}.android")],
                    )
                    .db()?;
                }
                let prefix = format!("plugin.process.{id}.");
                let keep: Vec<String> = retained_processes
                    .iter()
                    .map(|p| format!("{prefix}{p}"))
                    .collect();
                let keys = {
                    let mut query = tx
                        .prepare("SELECT key FROM kv WHERE substr(key, 1, length(?1)) = ?1")
                        .db()?;
                    let rows = query
                        .query_map([&prefix], |row| row.get::<_, String>(0))
                        .db()?;
                    rows.collect::<std::result::Result<Vec<_>, _>>().db()?
                };
                for key in keys {
                    if !keep.contains(&key) {
                        tx.execute("DELETE FROM kv WHERE key = ?1", [&key]).db()?;
                    }
                }
                tx.commit().db()?;
                Ok(())
            })
            .await;
        if let Err(error) = grant_result {
            fs::remove_dir_all(&final_dir)?;
            if previous.is_some() {
                fs::rename(&backup, &final_dir)?;
            }
            return Err(error);
        }
        self.runtimes.lock().await.remove(&manifest.id);
        if backup.exists() {
            fs::remove_dir_all(&backup)?;
        }
        if journal.exists() {
            fs::remove_file(&journal)?;
        }
        Ok(info_from_manifest(
            &manifest,
            &manifest.id,
            &BTreeMap::new(),
            &BTreeMap::new(),
        ))
    }

    /// 找到插件目录。清单损坏时 `manifest` 为 `None`，仍可按目录名删除。
    fn find_installed(&self, plugin_id: &str) -> Result<(PathBuf, Option<PluginManifest>)> {
        if !self.root.is_dir() {
            return Err(not_installed(plugin_id));
        }
        for entry in fs::read_dir(&self.root)? {
            let entry = entry?;
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            let directory = entry.file_name().to_string_lossy().to_string();
            if directory.starts_with('.') {
                continue;
            }
            let manifest = read_manifest(&path).ok();
            match &manifest {
                Some(manifest) if manifest.id == plugin_id => {
                    return Ok((path, Some(manifest.clone())));
                }
                None if directory == plugin_id => return Ok((path, None)),
                _ => {}
            }
        }
        Err(not_installed(plugin_id))
    }

    fn read_info(
        &self,
        path: &Path,
        directory: &str,
        enabled: &BTreeMap<String, String>,
        values: &BTreeMap<String, String>,
    ) -> PluginInfo {
        match read_manifest(path) {
            Ok(manifest) => info_from_manifest(&manifest, directory, enabled, values),
            Err(error) => PluginInfo {
                id: directory.to_string(),
                name: directory.to_string(),
                version: String::new(),
                api_version: String::new(),
                runtime: String::new(),
                compatibility: None,
                kinds: Vec::new(),
                entry: None,
                enabled: false,
                native_android_granted: false,
                error: Some(error.message),
                directory: directory.to_string(),
                author: None,
                homepage: None,
                permissions: PluginPermissions::default(),
                settings: Vec::new(),
            },
        }
    }
}

fn rows_to_map(rows: Vec<(String, String)>) -> BTreeMap<String, String> {
    rows.into_iter().collect()
}

fn not_installed(plugin_id: &str) -> LekisError {
    LekisError::not_found(format!("plugin {plugin_id} is not installed"))
}

fn info_from_manifest(
    manifest: &PluginManifest,
    directory: &str,
    enabled: &BTreeMap<String, String>,
    values: &BTreeMap<String, String>,
) -> PluginInfo {
    let enabled = enabled
        .get(&format!("{ENABLED_PREFIX}{}", manifest.id))
        .map(|value| value != "false")
        .unwrap_or(true);
    let storage_kb = manifest.permissions.storage_kb.unwrap_or(1024);
    PluginInfo {
        id: manifest.id.clone(),
        name: manifest.name.clone(),
        version: manifest.version.clone(),
        api_version: manifest.api_version.clone(),
        runtime: manifest.runtime.as_str().to_string(),
        compatibility: manifest
            .compatibility
            .map(|format| format.as_str().to_string()),
        kinds: manifest
            .kinds
            .iter()
            .map(|kind| kind.as_str().to_string())
            .collect(),
        entry: manifest.entry.clone(),
        enabled,
        native_android_granted: false,
        error: None,
        directory: directory.to_string(),
        author: manifest.author.clone(),
        homepage: manifest.homepage.clone(),
        permissions: PluginPermissions {
            network: manifest.permissions.network.clone(),
            process: manifest.permissions.process.clone(),
            request_header_hosts: manifest
                .permissions
                .request_headers
                .keys()
                .cloned()
                .collect(),
            web_sign_in: manifest.permissions.web_sign_in,
            storage_kb,
            native_android: manifest
                .native
                .as_ref()
                .and_then(|native| native.android.as_ref())
                .is_some(),
        },
        settings: manifest
            .settings
            .iter()
            .map(|spec| setting_view(&manifest.id, spec, values))
            .collect(),
    }
}

fn setting_view(
    plugin_id: &str,
    spec: &SettingSpec,
    values: &BTreeMap<String, String>,
) -> PluginSettingView {
    let stored = values.get(&format!("{SETTING_PREFIX}{plugin_id}.{}", spec.key));
    let secret = spec.kind == SettingType::Password;
    let stored_value = stored.and_then(|raw| serde_json::from_str::<Value>(raw).ok());
    PluginSettingView {
        key: spec.key.clone(),
        label: spec.label.clone(),
        help: spec.help.clone(),
        kind: spec.kind.as_str().to_string(),
        options: spec.options.clone(),
        default: if secret {
            None
        } else {
            spec.default.as_ref().map(display_value)
        },
        value: if secret {
            None
        } else {
            stored_value.as_ref().map(display_value)
        },
        has_value: stored.is_some() || spec.default.is_some(),
        secret,
    }
}

fn display_value(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

fn encode_setting_value(spec: &SettingSpec, value: &str) -> Result<String> {
    let value = match spec.kind {
        SettingType::Boolean => match value.trim() {
            "true" | "1" | "on" => Value::Bool(true),
            "false" | "0" | "off" => Value::Bool(false),
            _ => {
                return Err(LekisError::invalid(format!(
                    "设置项 {} 的值必须是 true 或 false",
                    spec.key
                )))
            }
        },
        SettingType::Select => {
            if !spec.options.iter().any(|option| option == value) {
                return Err(LekisError::invalid(format!(
                    "设置项 {} 的值不在可选范围内",
                    spec.key
                )));
            }
            Value::String(value.to_string())
        }
        SettingType::String | SettingType::Password => Value::String(value.to_string()),
    };
    serde_json::to_string(&value)
        .map_err(|error| LekisError::internal(format!("设置项 {} 无法序列化：{error}", spec.key)))
}

fn is_zip(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| extension.eq_ignore_ascii_case("zip"))
}

fn read_manifest(plugin_root: &Path) -> Result<PluginManifest> {
    let file = plugin_root.join("plugin.json");
    let json = fs::read_to_string(&file)
        .map_err(|error| LekisError::invalid(format!("无法读取 {}：{error}", file.display())))?;
    PluginManifest::parse(&json)
}

fn locate_plugin_root(staging: &Path) -> Result<PathBuf> {
    if staging.join("plugin.json").is_file() {
        return Ok(staging.to_path_buf());
    }
    let mut candidates = Vec::new();
    for entry in fs::read_dir(staging)? {
        let entry = entry?;
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with('.') {
            continue;
        }
        if path.is_dir() && path.join("plugin.json").is_file() {
            candidates.push(path);
        }
    }
    match candidates.len() {
        0 => Err(LekisError::invalid(
            "插件包根目录缺少 plugin.json（也不在唯一的顶层文件夹里）",
        )),
        1 => Ok(candidates.remove(0)),
        _ => Err(LekisError::invalid(
            "插件包里有多个顶层插件目录，无法确定要安装哪一个",
        )),
    }
}

fn validate_entry(plugin_root: &Path, manifest: &PluginManifest) -> Result<()> {
    if let Some(entry) = &manifest.entry {
        lekis_plugin_host::native::validate_plugin_entry(plugin_root, entry)?;
    }
    if let Some(spec) = manifest
        .native
        .as_ref()
        .and_then(|native| native.android.as_ref())
    {
        lekis_plugin_host::native::validate_native_entry(plugin_root, spec)?;
    }
    Ok(())
}

fn copy_tree(source: &Path, destination: &Path) -> Result<()> {
    fs::create_dir_all(destination)?;
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let file_type = entry.file_type()?;
        let target = destination.join(entry.file_name());
        if file_type.is_symlink() {
            return Err(LekisError::invalid("插件目录不能包含符号链接"));
        }
        if file_type.is_dir() {
            copy_tree(&entry.path(), &target)?;
        } else if file_type.is_file() {
            fs::copy(entry.path(), &target)?;
        }
    }
    Ok(())
}

fn extract_zip(zip_path: &Path, destination: &Path) -> Result<()> {
    let file = fs::File::open(zip_path)?;
    let mut archive = zip::ZipArchive::new(file)
        .map_err(|error| LekisError::invalid(format!("无法读取 zip：{error}")))?;
    if archive.len() > MAX_ZIP_FILES {
        return Err(LekisError::invalid("zip 里的文件太多"));
    }

    let mut total = 0u64;
    for index in 0..archive.len() {
        let entry = archive
            .by_index(index)
            .map_err(|error| LekisError::invalid(format!("无法读取 zip 条目：{error}")))?;
        let Some(relative) = entry.enclosed_name() else {
            return Err(LekisError::invalid("zip 包含不安全的路径"));
        };
        if relative.as_os_str().is_empty() {
            continue;
        }
        let target = destination.join(relative);
        if entry.is_dir() {
            fs::create_dir_all(&target)?;
            continue;
        }
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }
        let remaining = MAX_ZIP_BYTES.saturating_sub(total);
        let mut limited = entry.take(remaining.saturating_add(1));
        let mut output = fs::File::create(&target)?;
        let copied = std::io::copy(&mut limited, &mut output)?;
        if copied > remaining {
            return Err(LekisError::invalid("zip 解压后太大"));
        }
        total = total.saturating_add(copied);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::sync::atomic::{AtomicU32, Ordering};

    static NEXT: AtomicU32 = AtomicU32::new(0);

    fn test_root(name: &str) -> PathBuf {
        let id = NEXT.fetch_add(1, Ordering::SeqCst);
        let root = std::env::temp_dir().join(format!(
            "lekis-plugin-manager-{name}-{}-{id}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        root
    }

    fn manifest_json(id: &str) -> String {
        format!(
            r#"{{
                "id": "{id}",
                "name": "测试插件",
                "version": "1.2.3",
                "apiVersion": "1.0",
                "minAppVersion": "0.1.0",
                "runtime": "js",
                "entry": "index.js",
                "kinds": ["lyrics"],
                "permissions": {{ "network": ["example.com"], "storageKb": 2048 }},
                "settings": [
                    {{ "key": "preferSynced", "type": "boolean", "label": "优先同步歌词", "default": true }},
                    {{ "key": "apiKey", "type": "password", "label": "API key" }}
                ]
            }}"#
        )
    }

    fn write_plugin(directory: &Path, id: &str) {
        fs::create_dir_all(directory).unwrap();
        fs::write(directory.join("plugin.json"), manifest_json(id)).unwrap();
        fs::write(
            directory.join("index.js"),
            "export function lyrics() { return null; }\n",
        )
        .unwrap();
    }

    fn open_manager(root: &Path) -> (Library, PluginManager) {
        let library = Library::open(&root.join("library.sqlite")).unwrap();
        let manager = PluginManager::new(root, library.clone());
        (library, manager)
    }

    fn write_zip(path: &Path, name: &str, id: &str, top_level_folder: bool) {
        let file = fs::File::create(path).unwrap();
        let mut zip = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default();
        let prefix = if top_level_folder {
            format!("{name}/")
        } else {
            String::new()
        };
        zip.start_file(format!("{prefix}plugin.json"), options)
            .unwrap();
        zip.write_all(manifest_json(id).as_bytes()).unwrap();
        zip.start_file(format!("{prefix}index.js"), options)
            .unwrap();
        zip.write_all(b"export function lyrics() { return null; }\n")
            .unwrap();
        zip.finish().unwrap();
    }

    fn write_source_plugin(root: &Path, source: &str) -> PathBuf {
        write_source_plugin_process(root, source, "printf")
    }

    /// 同 [`write_source_plugin`]，但声明要启动的外部程序由调用方指定
    /// （Windows 上没有 `printf`，测试要用 `cmd`）。
    fn write_source_plugin_process(root: &Path, source: &str, process: &str) -> PathBuf {
        let directory = root.join("source");
        fs::create_dir_all(&directory).unwrap();
        fs::write(
            directory.join("plugin.json"),
            format!(
                r#"{{
            "id":"dev.lekis.test.source", "name":"Source", "version":"1.0.0",
            "apiVersion":"1.0", "minAppVersion":"0.1.0", "runtime":"js", "entry":"index.js",
            "kinds":["source"], "permissions":{{"network":["media.example.com"], "process":["{process}"],
                "requestHeaders":{{"media.example.com":{{}}}}}},
            "settings":[{{"key":"prefix","label":"Prefix","type":"string","default":"default"}}]
        }}"#
            ),
        )
        .unwrap();
        fs::write(directory.join("index.js"), source).unwrap();
        directory
    }

    #[tokio::test]
    async fn enabled_lyrics_plugins_receive_metadata_without_foreign_track_ids() -> Result<()> {
        let root = test_root("lyric-provider-flow");
        let source = write_source_plugin(&root, "export function search() { return {items:[{id:'ExactA',title:'Song',artists:['Singer']}]}; }");
        let (_, manager) = open_manager(&root);
        manager.install(&source).await?;
        let item = manager
            .search("dev.lekis.test.source", "Song", 1)
            .await?
            .tracks
            .remove(0);
        let plugin_id = "dev.lekis.test.lyrics";
        let directory = root.join("lyric-provider");
        write_plugin(&directory, plugin_id);
        fs::write(directory.join("index.js"), "export function lyrics(p) { return p.id == null && p.track.title === 'Song' ? {format:'lrc',content:'[00:01]sample',confidence:1} : null; }")?;
        manager.install(&directory).await?;
        let hint = lekis_enrich::TrackHint {
            title: "Song".into(),
            ..Default::default()
        };
        let rows = manager
            .lyric_candidates(manager.list().await?, item.id, &hint)
            .await?;
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].payload.content, "[00:01]sample");
        assert!(rows[0].provider_confidence < lekis_enrich::AUTO_APPLY_THRESHOLD);
        manager.set_enabled(plugin_id, false).await?;
        assert!(manager
            .lyric_candidates(manager.list().await?, item.id, &hint)
            .await?
            .is_empty());
        Ok(())
    }

    #[tokio::test]
    async fn builtin_qq_skips_only_its_legacy_example() -> Result<()> {
        let root = test_root("builtin-qq");
        let (library, manager) = open_manager(&root);
        let source = write_source_plugin(
            &root,
            "export function search() { return {items:[{id:'1',title:'Song'}]}; }",
        );
        manager.install(&source).await?;
        let track = manager
            .search("dev.lekis.test.source", "Song", 1)
            .await?
            .tracks
            .remove(0);
        for id in ["dev.lekis.example.qq-lyrics", "dev.lekis.test.other-lyrics"] {
            let directory = root.join(id);
            write_plugin(&directory, id);
            fs::write(
                directory.join("index.js"),
                "export function lyrics() { return {format:'lrc',content:'[00:01]sample'}; }",
            )?;
            manager.install(&directory).await?;
        }
        let pipeline = crate::enrich::EnrichPipeline::new(&crate::CoreConfig::for_tests(&root));
        pipeline
            .fetch_plugin_lyrics(&library, &manager, track.id)
            .await?;
        let versions = library.list_lyrics(track.id).await?;
        assert_eq!(versions.len(), 1);
        assert_eq!(
            versions[0].lyrics.source,
            "plugin:dev.lekis.test.other-lyrics"
        );
        Ok(())
    }

    #[tokio::test]
    async fn source_search_keeps_queue_references_and_resolves_fresh_streams() -> Result<()> {
        let root = test_root("source-flow");
        let source = write_source_plugin(
            &root,
            r#"
            export function search(p) {
                return {items:[{id:p.query,title:host.setting('prefix') + p.query,artists:['Artist'],durationMs:12000}]};
            }
            export async function stream(p) {
                const count = Number(await host.storage.get('count') || 0) + 1;
                await host.storage.set('count', String(count));
                return {url:'https://media.example.com/' + p.id + '?call=' + count,headers:{'User-Agent':'Lekis'}};
            }
        "#,
        );
        let (library, manager) = open_manager(&root);
        manager.install(&source).await?;
        manager
            .set_setting("dev.lekis.test.source", "prefix", "saved-")
            .await?;
        let first = manager
            .search("dev.lekis.test.source", "one", 10)
            .await?
            .tracks;
        assert_eq!(first[0].title, "saved-one");
        let second = manager
            .search("dev.lekis.test.source", "two", 10)
            .await?
            .tracks;
        assert_ne!(first[0].id, second[0].id);
        assert_eq!(library.get_track(first[0].id).await?.title, "saved-one");
        assert_eq!(
            manager
                .search("dev.lekis.test.source", "one", 10)
                .await?
                .tracks[0]
                .id,
            first[0].id
        );
        let manager = Arc::new(manager);
        let resolver = crate::resolver::Resolver::new(
            library.clone(),
            Arc::new(crate::selection::SourceHealth::new()),
            Arc::new(crate::MemoryCredentialStore::default()),
        )
        .with_plugins(manager.clone());
        for call in 1..=2 {
            let media = resolver.resolve(first[0].id).await?;
            match media.location {
                lekis_playback::MediaLocation::Url { url, headers } => {
                    assert_eq!(url, format!("https://media.example.com/one?call={call}"));
                    assert_eq!(headers, vec![("User-Agent".into(), "Lekis".into())]);
                }
                _ => panic!("expected plugin URL"),
            }
            assert_eq!(media.duration_hint_ms, 12000);
        }
        manager.set_enabled("dev.lekis.test.source", false).await?;
        assert_eq!(
            resolver.resolve(first[0].id).await.unwrap_err().code,
            ErrorCode::Unsupported
        );
        let _ = fs::remove_dir_all(root);
        Ok(())
    }

    #[tokio::test]
    async fn storage_survives_restart_setting_changes_errors_and_concurrent_calls() -> Result<()> {
        let root = test_root("persistent-storage");
        let source = write_source_plugin(
            &root,
            r#"
            export async function stream(p) {
                const count = Number(await host.storage.get('count') || 0) + 1;
                await host.storage.set('count', String(count));
                if (p.id === 'fail') throw new Error('after saving');
                return {url:'https://media.example.com/' + count};
            }
        "#,
        );
        let (library, manager) = open_manager(&root);
        manager.install(&source).await?;
        assert!(manager
            .stream("dev.lekis.test.source", "fail")
            .await
            .is_err());
        let restarted = PluginManager::new(&root, library);
        assert!(restarted
            .stream("dev.lekis.test.source", "ok")
            .await?
            .url
            .ends_with("/2"));
        restarted
            .set_setting("dev.lekis.test.source", "prefix", "changed")
            .await?;
        assert!(restarted
            .stream("dev.lekis.test.source", "ok")
            .await?
            .url
            .ends_with("/3"));
        let (a, b) = tokio::join!(
            restarted.stream("dev.lekis.test.source", "a"),
            restarted.stream("dev.lekis.test.source", "b")
        );
        let urls = [a?.url, b?.url];
        assert!(urls.iter().any(|u| u.ends_with("/4")));
        assert!(urls.iter().any(|u| u.ends_with("/5")));
        restarted.remove("dev.lekis.test.source").await?;
        assert!(!restarted.storage_path("dev.lekis.test.source").exists());
        let _ = fs::remove_dir_all(root);
        Ok(())
    }

    #[tokio::test]
    async fn cancelled_caller_does_not_abandon_storage_or_release_call_gate() -> Result<()> {
        let root = test_root("cancelled-caller");
        let source = write_source_plugin(
            &root,
            r#"
            export async function stream(p) {
                const count = Number(await host.storage.get('count') || 0) + 1;
                await host.storage.set('count', String(count));
                if (p.id === 'slow') {
                    const until = Date.now() + 300;
                    while (Date.now() < until) {}
                }
                return {url:'https://media.example.com/' + count};
            }
        "#,
        );
        let (_, manager) = open_manager(&root);
        manager.install(&source).await?;
        let active = manager.clone();
        let caller =
            tokio::spawn(async move { active.stream("dev.lekis.test.source", "slow").await });
        // Observe that the owned invocation has acquired its gate, rather than
        // assuming the executor has started it after a fixed delay.
        let gate = manager.call_gate("dev.lekis.test.source").await;
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            loop {
                if gate.try_lock().is_err() {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .map_err(|_| LekisError::internal("call did not start"))?;
        caller.abort();
        assert!(manager
            .stream("dev.lekis.test.source", "next")
            .await?
            .url
            .ends_with("/2"));
        assert_eq!(
            manager
                .read_storage("dev.lekis.test.source")?
                .get("count")
                .map(String::as_str),
            Some("2")
        );
        let _ = fs::remove_dir_all(root);
        Ok(())
    }

    #[tokio::test]
    async fn browse_preserves_folder_paths_cursors_and_track_identity() -> Result<()> {
        let root = test_root("browse");
        let source = write_source_plugin(
            &root,
            r#"
            export function browse(p) {
                if (!p.path) return {items:[{kind:'folder',id:'page:mix',title:'Mix'}]};
                return {items:[{kind:'track',id:'same',title:p.cursor ? 'Enriched' : 'Song',
                    artists:['Artist'],durationMs:p.cursor ? 1000 : 0}],next:p.cursor ? null : 'next'};
            }
        "#,
        );
        let (library, manager) = open_manager(&root);
        manager.install(&source).await?;
        let home = manager.browse("dev.lekis.test.source", "", None).await?;
        assert_eq!(home.folders[0].id, "page:mix");
        let first = manager
            .browse("dev.lekis.test.source", &home.folders[0].id, None)
            .await?;
        assert_eq!(first.next.as_deref(), Some("next"));
        let next = manager
            .browse("dev.lekis.test.source", "page:mix", first.next.as_deref())
            .await?;
        assert_eq!(first.tracks[0].id, next.tracks[0].id);
        assert_eq!(
            library.get_track(first.tracks[0].id).await?.title,
            "Enriched"
        );
        assert!(next.next.is_none());
        let _ = fs::remove_dir_all(root);
        Ok(())
    }

    #[tokio::test]
    async fn rejects_invalid_stream_hosts_headers_and_expiry() -> Result<()> {
        for (name, stream) in [
            ("host", r#"{url:'https://evil.example.com/audio'}"#),
            ("http", r#"{url:'http://media.example.com/audio'}"#),
            (
                "expiry",
                r#"{url:'https://media.example.com/audio',expiresAt:1}"#,
            ),
        ] {
            let root = test_root(name);
            let source = write_source_plugin(
                &root,
                &format!("export function stream() {{ return {stream}; }}"),
            );
            let (_, manager) = open_manager(&root);
            manager.install(&source).await?;
            assert!(manager
                .stream("dev.lekis.test.source", "one")
                .await
                .is_err());
            let _ = fs::remove_dir_all(root);
        }
        let root = test_root("undeclared-header");
        let source = write_source_plugin(&root, "export function stream() {return {url:'https://media.example.com/a',headers:{Cookie:'private'}};}");
        let path = source.join("plugin.json");
        let mut manifest: Value = serde_json::from_str(&fs::read_to_string(&path)?).unwrap();
        manifest["permissions"]["requestHeaders"] = serde_json::json!({});
        fs::write(path, manifest.to_string())?;
        let (_, manager) = open_manager(&root);
        manager.install(&source).await?;
        assert_eq!(
            manager
                .stream("dev.lekis.test.source", "one")
                .await
                .unwrap_err()
                .code,
            ErrorCode::Unsupported
        );
        let _ = fs::remove_dir_all(root);
        Ok(())
    }

    fn write_native_source(root: &Path, source: &str) -> PathBuf {
        let directory = write_source_plugin(root, source);
        let path = directory.join("plugin.json");
        let mut manifest: Value =
            serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        manifest["apiVersion"] = serde_json::json!("1.2");
        manifest["native"] = serde_json::json!({"android":{"entry":"android/classes.dex","className":"dev.example.NativePlugin"}});
        fs::write(path, manifest.to_string()).unwrap();
        fs::create_dir_all(directory.join("android")).unwrap();
        fs::write(
            directory.join("android/classes.dex"),
            b"offline fake DEX fixture",
        )
        .unwrap();
        directory
    }

    #[tokio::test]
    async fn cancelled_uninstall_finishes_cleanup_before_reinstall() -> Result<()> {
        let root = test_root("cancelled-uninstall");
        let source = write_native_source(&root, "export function search() { return {items:[]}; }");
        let (library, manager) = open_manager(&root);
        let id = "dev.lekis.test.source";
        manager.install(&source).await?;
        manager.set_native_android_allowed(id, true).await?;
        let process_key = format!("plugin.process.{id}.printf");
        library.set_setting(&process_key, "true").await?;
        manager.set_setting(id, "prefix", "old-install").await?;
        manager.write_storage(id, &BTreeMap::from([("old".into(), "data".into())]))?;

        // Hold the writer so removal cannot finish revoking grants. Observing
        // the acquired gate makes cancellation deterministic without sleeps.
        let (started_tx, started_rx) = tokio::sync::oneshot::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let blocked_library = library.clone();
        let blocker = tokio::spawn(async move {
            blocked_library
                .write(move |_| {
                    let _ = started_tx.send(());
                    release_rx
                        .recv()
                        .map_err(|e| LekisError::internal(e.to_string()))?;
                    Ok(())
                })
                .await
        });
        started_rx.await.unwrap();
        let caller = {
            let manager = manager.clone();
            tokio::spawn(async move { manager.remove(id).await })
        };
        let gate = manager.call_gate(id).await;
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            while gate.try_lock().is_ok() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        assert!(manager.root.join(id).is_dir());
        caller.abort();
        assert!(caller.await.unwrap_err().is_cancelled());
        assert!(gate.try_lock().is_err());
        release_tx.send(()).unwrap();
        blocker.await.unwrap()?;

        // Installation takes the same gate and therefore sees completed cleanup.
        manager.install(&source).await?;
        assert!(!manager.native_android_allowed(id).await?);
        assert_eq!(library.get_setting(&process_key).await?, None);
        assert_eq!(
            library
                .get_setting(&format!("plugin.setting.{id}.prefix"))
                .await?,
            None
        );
        assert!(!manager.storage_path(id).exists());
        let _ = fs::remove_dir_all(root);
        Ok(())
    }

    #[tokio::test]
    async fn fresh_install_resets_orphan_grants_but_failed_install_preserves_existing_grants(
    ) -> Result<()> {
        let root = test_root("install-grants");
        let source = write_native_source(&root, "export function search() { return {items:[]}; }");
        let (library, manager) = open_manager(&root);
        let id = "dev.lekis.test.source";
        let native_key = format!("plugin.native.{id}.android");
        let process_key = format!("plugin.process.{id}.printf");
        library.set_setting(&native_key, "true").await?;
        library.set_setting(&process_key, "true").await?;
        manager.install(&source).await?;
        assert!(!manager.native_android_allowed(id).await?);
        assert_eq!(library.get_setting(&process_key).await?, None);

        manager.set_native_android_allowed(id, true).await?;
        library.set_setting(&process_key, "true").await?;
        manager.install(&source).await?;
        assert!(manager.native_android_allowed(id).await?);
        assert_eq!(
            library.get_setting(&process_key).await?.as_deref(),
            Some("true")
        );
        fs::remove_file(source.join("android/classes.dex"))?;
        assert!(manager.install(&source).await.is_err());
        assert!(manager.native_android_allowed(id).await?);
        assert_eq!(
            library.get_setting(&process_key).await?.as_deref(),
            Some("true")
        );
        let _ = fs::remove_dir_all(root);
        Ok(())
    }

    #[tokio::test]
    async fn startup_recovers_interrupted_upgrade() -> Result<()> {
        let root = test_root("upgrade-recovery");
        let source = write_source_plugin(&root, "export function search() { return {items:[]}; }");
        let (_, manager) = open_manager(&root);
        manager.install(&source).await?;
        let plugins = root.join("plugins");
        let installed = plugins.join("dev.lekis.test.source");
        let backup = plugins.join(".install-test.backup");
        let journal = plugins.join(".install-test.restore");
        fs::write(&journal, "dev.lekis.test.source")?;
        fs::rename(&installed, &backup)?;
        // Simulate a crash after the new package was moved into place.
        fs::create_dir_all(&installed)?;
        fs::write(installed.join("plugin.json"), "broken replacement")?;
        PluginManager::recover_interrupted_installs(&root)?;
        assert_eq!(manager.list().await?.pop().unwrap().version, "1.0.0");
        assert!(!backup.exists());
        assert!(!journal.exists());
        // Recovery is idempotent, including a crash after backup cleanup.
        fs::write(&journal, "dev.lekis.test.source")?;
        PluginManager::recover_interrupted_installs(&root)?;
        assert!(!journal.exists());
        let _ = fs::remove_dir_all(root);
        Ok(())
    }

    #[tokio::test]
    async fn upgrade_restores_old_package_if_grant_update_fails() -> Result<()> {
        let root = test_root("upgrade-rollback");
        let source = write_native_source(&root, "export function search() { return {items:[]}; }");
        let (library, manager) = open_manager(&root);
        let id = "dev.lekis.test.source";
        manager.install(&source).await?;
        manager.set_native_android_allowed(id, true).await?;
        library.write(|connection| {
            connection.execute_batch("CREATE TRIGGER fail_grant_delete BEFORE DELETE ON kv WHEN OLD.key LIKE 'plugin.native.%' BEGIN SELECT RAISE(ABORT, 'test failure'); END;").db()?;
            Ok(())
        }).await?;
        let manifest_path = source.join("plugin.json");
        let mut manifest: serde_json::Value =
            serde_json::from_slice(&fs::read(&manifest_path)?).unwrap();
        manifest["version"] = serde_json::json!("2.0.0");
        fs::write(&manifest_path, serde_json::to_vec(&manifest).unwrap())?;
        assert!(manager.install(&source).await.is_err());
        assert_eq!(manager.list().await?.pop().unwrap().version, "1.0.0");
        assert!(manager.native_android_allowed(id).await?);
        let _ = fs::remove_dir_all(root);
        Ok(())
    }

    #[tokio::test]
    async fn upgrade_preserves_data_and_revokes_changed_native_grant() -> Result<()> {
        let root = test_root("upgrade-data");
        let source = write_native_source(&root, "export function search() { return {items:[]}; }");
        let (library, manager) = open_manager(&root);
        let id = "dev.lekis.test.source";
        manager.install(&source).await?;
        manager.set_enabled(id, false).await?;
        manager.set_setting(id, "prefix", "kept").await?;
        manager.write_storage(id, &BTreeMap::from([("token".into(), "kept".into())]))?;
        manager.set_native_android_allowed(id, true).await?;
        library
            .set_setting(&format!("plugin.process.{id}.printf"), "true")
            .await?;

        let manifest_path = source.join("plugin.json");
        let mut manifest: serde_json::Value =
            serde_json::from_slice(&fs::read(&manifest_path)?).unwrap();
        manifest["version"] = serde_json::json!("2.0.0");
        manifest["permissions"]["process"] = serde_json::json!(["other"]);
        fs::write(&manifest_path, serde_json::to_vec(&manifest).unwrap())?;
        manager.install(&source).await?;
        let installed = manager.list().await?.pop().unwrap();
        assert_eq!(installed.version, "2.0.0");
        assert!(!installed.enabled);
        assert!(!manager.native_android_allowed(id).await?);
        assert_eq!(
            library
                .get_setting(&format!("plugin.process.{id}.printf"))
                .await?,
            None
        );
        assert_eq!(
            library
                .get_setting(&format!("plugin.process.{id}.other"))
                .await?,
            None
        );
        assert_eq!(
            library
                .get_setting(&format!("plugin.setting.{id}.prefix"))
                .await?
                .as_deref(),
            Some("\"kept\"")
        );
        assert_eq!(
            manager.read_storage(id)?.get("token").map(String::as_str),
            Some("kept")
        );

        fs::remove_file(source.join("android/classes.dex"))?;
        assert!(manager.install(&source).await.is_err());
        assert_eq!(manager.list().await?.pop().unwrap().version, "2.0.0");
        assert_eq!(
            manager.read_storage(id)?.get("token").map(String::as_str),
            Some("kept")
        );
        let _ = fs::remove_dir_all(root);
        Ok(())
    }

    #[tokio::test]
    async fn native_grant_is_separate_persistent_and_part_of_runtime_cache() -> Result<()> {
        let root = test_root("native-grant");
        let source = write_native_source(
            &root,
            r#"export async function search() { const n=Number(await host.storage.get('n')||0)+1; await host.storage.set('n',String(n)); return {count:n,available:host.native.available}; }"#,
        );
        let (library, manager) = open_manager(&root);
        let installed = manager.install(&source).await?;
        assert!(installed.permissions.native_android);
        assert!(!installed.native_android_granted);
        let id = "dev.lekis.test.source";
        assert!(!manager.native_android_allowed(id).await?);
        assert_eq!(
            manager
                .call(id, Capability::Search, serde_json::json!({}))
                .await?["count"],
            1
        );
        let first = manager.runtimes.lock().await.get(id).unwrap().1.clone();
        // A directly persisted grant must also invalidate the cache fingerprint.
        library
            .set_setting(&format!("plugin.native.{id}.android"), "true")
            .await?;
        assert_eq!(
            manager
                .call(id, Capability::Search, serde_json::json!({}))
                .await?["count"],
            2
        );
        assert!(!Arc::ptr_eq(
            &first,
            &manager.runtimes.lock().await.get(id).unwrap().1
        ));
        assert!(manager.list().await?[0].native_android_granted);
        let restarted = PluginManager::new(&root, library.clone());
        assert!(restarted.native_android_allowed(id).await?);
        manager.set_native_android_allowed(id, false).await?;
        assert!(!manager.runtimes.lock().await.contains_key(id));
        assert!(!manager.native_android_allowed(id).await?);
        manager.set_native_android_allowed(id, true).await?;
        manager.remove(id).await?;
        assert!(library
            .get_setting(&format!("plugin.native.{id}.android"))
            .await?
            .is_none());
        manager.install(&source).await?;
        assert!(!manager.native_android_allowed(id).await?);
        let _ = fs::remove_dir_all(root);
        Ok(())
    }

    #[tokio::test]
    async fn native_entry_install_validation_and_grant_revocation_wait_for_active_call(
    ) -> Result<()> {
        let root = test_root("native-boundaries");
        let source = write_native_source(
            &root,
            r#"export async function search() { await host.storage.set('started','true'); const until=Date.now()+150; while(Date.now()<until) {} await host.storage.set('finished','true'); return {items:[]}; }"#,
        );
        let (_, manager) = open_manager(&root);
        fs::remove_file(source.join("android/classes.dex"))?;
        assert!(manager.install(&source).await.is_err());
        fs::write(source.join("android/classes.dex"), b"fixture")?;
        manager.install(&source).await?;
        let id = "dev.lekis.test.source";
        manager.set_native_android_allowed(id, true).await?;
        let task = {
            let manager = manager.clone();
            tokio::spawn(async move {
                manager
                    .call(id, Capability::Search, serde_json::json!({}))
                    .await
            })
        };
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            while !manager.runtimes.lock().await.contains_key(id) {
                tokio::time::sleep(std::time::Duration::from_millis(1)).await;
            }
        })
        .await
        .unwrap();
        assert!(tokio::time::timeout(
            std::time::Duration::from_millis(10),
            manager.set_native_android_allowed(id, false)
        )
        .await
        .is_err());
        assert!(manager.native_android_allowed(id).await?);
        task.abort();
        manager.set_native_android_allowed(id, false).await?;
        assert_eq!(
            manager
                .read_storage(id)?
                .get("finished")
                .map(String::as_str),
            Some("true")
        );
        #[cfg(unix)]
        {
            fs::remove_file(manager.root.join(id).join("android/classes.dex"))?;
            std::os::unix::fs::symlink(
                "/etc/hosts",
                manager.root.join(id).join("android/classes.dex"),
            )?;
            assert!(manager
                .call(id, Capability::Search, serde_json::json!({}))
                .await
                .is_err());
        }
        let _ = fs::remove_dir_all(root);
        Ok(())
    }

    // 三个平台都跑：之前加了 `cfg(unix)`，Windows 上一直跳过，结果宿主里
    // 「嵌套 Tokio 运行时」的 panic 没人发现（见 js_host.rs 的 run_program_blocking）。
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    #[tokio::test]
    async fn process_requires_grant_and_revocation_takes_effect() -> Result<()> {
        let root = test_root("process-grant");
        // Windows 没有 printf；用 cmd /C echo 打同一段文本（多一个换行，下面 trim 掉）。
        let (program, args) = if cfg!(windows) {
            ("cmd", r#"["/C","echo","https://media.example.com/audio"]"#)
        } else {
            ("printf", r#"["https://media.example.com/audio"]"#)
        };
        let source = write_source_plugin_process(
            &root,
            &format!(
                r#"
            export async function stream() {{
                const result = await host.spawn({program:?}, {args});
                return {{url:result.stdout.trim()}};
            }}
        "#
            ),
            program,
        );
        let (library, manager) = open_manager(&root);
        manager.install(&source).await?;
        assert_eq!(
            manager
                .stream("dev.lekis.test.source", "x")
                .await
                .unwrap_err()
                .code,
            ErrorCode::InvalidArgument
        );
        let key = format!("plugin.process.dev.lekis.test.source.{program}");
        library.set_setting(&key, "true").await?;
        assert_eq!(
            manager.stream("dev.lekis.test.source", "x").await?.url,
            "https://media.example.com/audio"
        );
        library.set_setting(&key, "false").await?;
        assert!(manager.stream("dev.lekis.test.source", "x").await.is_err());
        manager.remove("dev.lekis.test.source").await?;
        assert_eq!(library.get_setting(&key).await?, None);
        let _ = fs::remove_dir_all(root);
        Ok(())
    }

    #[tokio::test]
    async fn installs_from_folder_and_lists_metadata() -> Result<()> {
        let root = test_root("folder");
        let source = root.join("source");
        write_plugin(&source, "dev.lekis.test.folder");
        let (_, manager) = open_manager(&root);

        let info = manager.install(&source).await?;
        assert_eq!(info.id, "dev.lekis.test.folder");
        assert_eq!(info.name, "测试插件");
        assert_eq!(info.version, "1.2.3");
        assert_eq!(info.kinds, vec!["lyrics"]);
        assert!(info.enabled);
        assert!(info.error.is_none());
        assert_eq!(info.permissions.storage_kb, 2048);
        assert_eq!(info.permissions.network, vec!["example.com"]);
        assert!(root
            .join("plugins/dev.lekis.test.folder/plugin.json")
            .is_file());

        let listed = manager.list().await?;
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].id, info.id);
        assert_eq!(listed[0].author, None);
        let _ = fs::remove_dir_all(root);
        Ok(())
    }

    #[tokio::test]
    async fn installs_from_zip_with_root_or_single_folder() -> Result<()> {
        let root = test_root("zip");
        let (_, manager) = open_manager(&root);

        let root_zip = root.join("root.zip");
        write_zip(&root_zip, "ignored", "dev.lekis.test.zip-root", false);
        let root_info = manager.install(&root_zip).await?;
        assert_eq!(root_info.id, "dev.lekis.test.zip-root");

        let folder_zip = root.join("folder.zip");
        write_zip(&folder_zip, "pkg", "dev.lekis.test.zip-folder", true);
        let folder_info = manager.install(&folder_zip).await?;
        assert_eq!(folder_info.id, "dev.lekis.test.zip-folder");

        assert_eq!(manager.list().await?.len(), 2);
        let _ = fs::remove_dir_all(root);
        Ok(())
    }

    #[tokio::test]
    async fn rejects_duplicate_and_invalid_install() -> Result<()> {
        let root = test_root("duplicate");
        let source = root.join("source");
        write_plugin(&source, "dev.lekis.test.duplicate");
        let (_, manager) = open_manager(&root);
        manager.install(&source).await?;

        manager.install(&source).await?;
        assert_eq!(manager.list().await?.len(), 1);

        let broken = root.join("broken");
        fs::create_dir_all(&broken).unwrap();
        fs::write(
            broken.join("plugin.json"),
            r#"{"id":"dev.lekis.test.broken","name":"x","version":"1.0.0",
                "apiVersion":"1.0","minAppVersion":"0.1.0","runtime":"js",
                "kinds":["lyrics"]}"#,
        )
        .unwrap();
        let error = manager.install(&broken).await.unwrap_err();
        assert_eq!(error.code, ErrorCode::InvalidArgument);
        assert!(!root.join("plugins/dev.lekis.test.broken").exists());
        let _ = fs::remove_dir_all(root);
        Ok(())
    }

    #[tokio::test]
    async fn enable_disable_persists_in_database() -> Result<()> {
        let root = test_root("enabled");
        let source = root.join("source");
        write_plugin(&source, "dev.lekis.test.enabled");
        let (library, manager) = open_manager(&root);
        manager.install(&source).await?;
        manager.set_enabled("dev.lekis.test.enabled", false).await?;
        assert!(!manager.list().await?[0].enabled);

        drop(manager);
        drop(library);
        let (_, reopened) = open_manager(&root);
        assert!(!reopened.list().await?[0].enabled);
        reopened.set_enabled("dev.lekis.test.enabled", true).await?;
        assert!(reopened.list().await?[0].enabled);
        let _ = fs::remove_dir_all(root);
        Ok(())
    }

    #[tokio::test]
    async fn saves_settings_without_returning_passwords() -> Result<()> {
        let root = test_root("settings");
        let source = root.join("source");
        write_plugin(&source, "dev.lekis.test.settings");
        let (_, manager) = open_manager(&root);
        manager.install(&source).await?;

        manager
            .set_setting("dev.lekis.test.settings", "preferSynced", "false")
            .await?;
        manager
            .set_setting("dev.lekis.test.settings", "apiKey", "top-secret")
            .await?;

        let settings = manager.settings("dev.lekis.test.settings").await?;
        let synced = settings.iter().find(|s| s.key == "preferSynced").unwrap();
        assert_eq!(synced.value.as_deref(), Some("false"));
        let secret = settings.iter().find(|s| s.key == "apiKey").unwrap();
        assert!(secret.secret);
        assert!(secret.has_value);
        assert!(secret.value.is_none());
        assert!(secret.default.is_none());

        let listed = manager.list().await?;
        let listed_synced = listed[0]
            .settings
            .iter()
            .find(|setting| setting.key == "preferSynced")
            .unwrap();
        assert_eq!(listed_synced.value.as_deref(), Some("false"));
        let listed_secret = listed[0]
            .settings
            .iter()
            .find(|setting| setting.key == "apiKey")
            .unwrap();
        assert!(listed_secret.value.is_none());
        assert!(listed_secret.has_value);
        assert_eq!(
            manager
                .set_setting("dev.lekis.test.settings", "preferSynced", "maybe")
                .await
                .unwrap_err()
                .code,
            ErrorCode::InvalidArgument
        );
        let _ = fs::remove_dir_all(root);
        Ok(())
    }

    #[tokio::test]
    async fn removes_plugin_data_and_settings() -> Result<()> {
        let root = test_root("remove");
        let source = root.join("source");
        write_plugin(&source, "dev.lekis.test.remove");
        let (library, manager) = open_manager(&root);
        manager.install(&source).await?;
        manager.set_enabled("dev.lekis.test.remove", false).await?;
        let data = root.join("plugin-data/dev.lekis.test.remove");
        fs::create_dir_all(&data).unwrap();
        fs::write(data.join("cache.txt"), "x").unwrap();

        manager.remove("dev.lekis.test.remove").await?;
        assert!(!root.join("plugins/dev.lekis.test.remove").exists());
        assert!(!data.exists());
        assert!(manager.list().await?.is_empty());
        assert_eq!(
            library
                .get_setting("plugin.enabled.dev.lekis.test.remove")
                .await?,
            None
        );
        let _ = fs::remove_dir_all(root);
        Ok(())
    }

    #[tokio::test]
    async fn malformed_manifest_is_listed_without_crashing() -> Result<()> {
        let root = test_root("malformed");
        let (_, manager) = open_manager(&root);
        let broken = root.join("plugins/broken-plugin");
        fs::create_dir_all(&broken).unwrap();
        fs::write(broken.join("plugin.json"), "{ not json").unwrap();

        let listed = manager.list().await?;
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].id, "broken-plugin");
        assert_eq!(listed[0].name, "broken-plugin");
        assert!(!listed[0].enabled);
        assert!(listed[0].error.is_some());

        let error = manager
            .set_enabled("broken-plugin", true)
            .await
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::InvalidArgument);
        // 清单损坏的目录仍然可以移除。
        manager.remove("broken-plugin").await?;
        assert!(!broken.exists());
        let _ = fs::remove_dir_all(root);
        Ok(())
    }
}
