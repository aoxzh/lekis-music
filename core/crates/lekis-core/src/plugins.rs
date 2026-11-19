//! 本地插件管理：扫描 `<data_dir>/plugins/*/plugin.json`，安装 / 移除，保存启用状态和设置。
//!
//! 这里只做文件系统和设置持久化，不执行插件代码；运行时仍然由
//! `lekis-plugin-host` 负责。插件目录布局：
//!
//! ```text
//! <data_dir>/plugins/<plugin id>/plugin.json
//! <data_dir>/plugin-data/<plugin id>/        # 插件以后落盘私有存储的位置
//! ```
//!
//! 安装时先复制 / 解压到 `plugins/` 下以 `.install-` 开头的临时目录，校验清单后再
//! `rename` 成最终目录，所以 App 不会看到半安装状态。清单无效的目录会出现在列表里，
//! 错误放在 `error` 字段，不影响其他插件。

use lekis_library::Library;
use lekis_plugin_host::manifest::{PluginManifest, SettingSpec, SettingType};
use lekis_types::{ErrorCode, LekisError, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::fs;
use std::io::Read;
use std::path::{Component, Path, PathBuf};
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
    /// 插件类型列表。
    pub kinds: Vec<String>,
    /// 入口文件（相对插件目录）。
    pub entry: Option<String>,
    /// 是否启用。清单损坏时固定为 `false`。
    pub enabled: bool,
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

/// 文件系统插件管理器。可以廉价克隆，内部只持有路径和资料库句柄。
#[derive(Clone)]
pub struct PluginManager {
    root: PathBuf,
    data_root: PathBuf,
    library: Library,
}

impl PluginManager {
    /// 用数据目录和资料库创建管理器（不会创建目录，扫描 / 安装时再创建）。
    pub fn new(data_dir: &Path, library: Library) -> Self {
        Self {
            root: data_dir.join("plugins"),
            data_root: data_dir.join("plugin-data"),
            library,
        }
    }

    /// 插件目录。
    pub fn root(&self) -> &Path {
        &self.root
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
            plugins.push(self.read_info(&path, &directory, &enabled, &values));
        }
        plugins.sort_by(|a, b| {
            a.name
                .to_lowercase()
                .cmp(&b.name.to_lowercase())
                .then_with(|| a.id.cmp(&b.id))
        });
        Ok(plugins)
    }

    /// 从本地文件夹或 `.zip` 安装插件。目标已存在（同 id）时返回错误。
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

        let result = self.install_staged(source, &staging).await;
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

    /// 移除插件目录、插件数据目录和相关的设置项。
    pub async fn remove(&self, plugin_id: &str) -> Result<()> {
        let (directory, manifest) = self.find_installed(plugin_id)?;
        let directory_name = directory
            .file_name()
            .map(|name| name.to_string_lossy().to_string())
            .ok_or_else(|| LekisError::internal("插件目录没有名字"))?;
        let id = manifest
            .as_ref()
            .map(|m| m.id.clone())
            .unwrap_or_else(|| directory_name.clone());

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

        match self.find_installed(&manifest.id) {
            Ok(_) => {
                return Err(LekisError::invalid(format!(
                    "插件 {} 已经安装",
                    manifest.id
                )))
            }
            Err(error) if error.code == ErrorCode::NotFound => {}
            Err(error) => return Err(error),
        }
        let final_dir = self.root.join(&manifest.id);
        if final_dir.exists() {
            return Err(LekisError::invalid(format!(
                "插件目录 {} 已经存在",
                manifest.id
            )));
        }
        // 同一文件系统内 rename 是原子的：要么完整出现，要么完全不存在。
        fs::rename(&plugin_root, &final_dir)?;
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
                kinds: Vec::new(),
                entry: None,
                enabled: false,
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
        kinds: manifest
            .kinds
            .iter()
            .map(|kind| kind.as_str().to_string())
            .collect(),
        entry: manifest.entry.clone(),
        enabled,
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
    let Some(entry) = manifest.entry.as_deref() else {
        return Ok(());
    };
    let relative = Path::new(entry);
    if relative
        .components()
        .any(|part| !matches!(part, Component::Normal(_)))
    {
        return Err(LekisError::invalid(format!(
            "入口文件必须是插件目录内的相对路径：{entry}"
        )));
    }
    if !plugin_root.join(relative).is_file() {
        return Err(LekisError::invalid(format!("插件入口文件不存在：{entry}")));
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

        let error = manager.install(&source).await.unwrap_err();
        assert_eq!(error.code, ErrorCode::InvalidArgument);
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
