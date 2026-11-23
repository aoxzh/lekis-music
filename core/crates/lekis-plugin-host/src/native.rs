//! Optional application-privileged native extensions. JS never selects a path.
use crate::manifest::AndroidNativeSpec;
use lekis_types::{LekisError, Result};
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, OnceLock};

/// One native invocation, configured by the application plugin manager.
#[derive(Debug, Clone)]
pub struct NativePluginRequest {
    /// Canonical plugin directory validated by the host.
    pub plugin_root: PathBuf,
    /// Entry and class declared in the installed manifest.
    pub spec: AndroidNativeSpec,
    /// Plugin-defined operation name.
    pub operation: String,
    /// JSON parameters, without host-selected file paths.
    pub params: serde_json::Value,
}

/// Android integration implements this outside the generic plugin host.
/// Native code has the application's privileges, rather than the JS sandbox.
pub trait NativePluginExecutor: Send + Sync {
    /// Execute one operation and return a JSON value or structured error.
    fn call(&self, request: NativePluginRequest) -> Result<serde_json::Value>;
}

static EXECUTOR: OnceLock<Arc<dyn NativePluginExecutor>> = OnceLock::new();

/// Register the process-global Android executor. Re-registering the same Arc is
/// idempotent; replacing it with a different executor is rejected.
pub fn register_native_plugin_executor(executor: Arc<dyn NativePluginExecutor>) -> Result<()> {
    if let Err(candidate) = EXECUTOR.set(executor) {
        if EXECUTOR
            .get()
            .is_some_and(|current| Arc::ptr_eq(current, &candidate))
        {
            return Ok(());
        }
        return Err(LekisError::invalid(
            "A native plugin executor is already registered",
        ));
    }
    Ok(())
}

pub(crate) fn executor() -> Option<&'static Arc<dyn NativePluginExecutor>> {
    EXECUTOR.get()
}

/// Validate an entry as a regular file strictly inside a plugin directory.
/// Both the root and every entry component must be free of symbolic links.
pub fn validate_native_entry(plugin_root: &Path, spec: &AndroidNativeSpec) -> Result<PathBuf> {
    validate_plugin_entry(plugin_root, &spec.entry)
}

/// Validate a JS or native entry with identical path and symlink boundaries.
pub fn validate_plugin_entry(plugin_root: &Path, entry: &str) -> Result<PathBuf> {
    let relative = Path::new(entry);
    if entry.is_empty()
        || entry.contains('\\')
        || relative
            .components()
            .any(|part| !matches!(part, Component::Normal(_)))
    {
        return Err(LekisError::invalid(
            "Plugin entry must be a relative path inside the plugin directory",
        ));
    }
    // Reject a linked root too, even when canonicalization would remain local.
    if std::fs::symlink_metadata(plugin_root)?
        .file_type()
        .is_symlink()
    {
        return Err(LekisError::invalid(
            "Plugin directory cannot be a symbolic link",
        ));
    }
    let root = plugin_root.canonicalize()?;
    let mut candidate = root.clone();
    for part in relative.components() {
        candidate.push(part);
        if std::fs::symlink_metadata(&candidate)?
            .file_type()
            .is_symlink()
        {
            return Err(LekisError::invalid(
                "Plugin entries cannot contain symbolic links",
            ));
        }
    }
    let canonical = candidate.canonicalize()?;
    if !canonical.starts_with(&root) || !canonical.is_file() {
        return Err(LekisError::invalid(
            "Plugin entry must be a file inside its plugin directory",
        ));
    }
    Ok(canonical)
}

/// Host-owned context; no JavaScript API can modify its path/spec/grant.
#[derive(Debug, Clone)]
pub(crate) struct NativeContext {
    pub root: PathBuf,
    pub spec: AndroidNativeSpec,
    pub granted: bool,
}

impl NativeContext {
    pub(crate) fn new(root: PathBuf, spec: AndroidNativeSpec, granted: bool) -> Result<Self> {
        validate_native_entry(&root, &spec)?;
        Ok(Self {
            root: root.canonicalize()?,
            spec,
            granted,
        })
    }

    pub(crate) fn available(&self) -> bool {
        self.granted && cfg!(target_os = "android") && executor().is_some()
    }

    pub(crate) fn call(
        &self,
        operation: String,
        params: serde_json::Value,
    ) -> Result<serde_json::Value> {
        self.call_on_platform(operation, params, cfg!(target_os = "android"))
    }

    fn call_on_platform(
        &self,
        operation: String,
        params: serde_json::Value,
        android: bool,
    ) -> Result<serde_json::Value> {
        if !self.granted {
            return Err(LekisError::invalid(
                "Native Android code requires a separate user grant in plugin permissions",
            ));
        }
        if !android {
            return Err(LekisError::unsupported(
                "Native Android plugins are only available on Android",
            ));
        }
        if operation.is_empty() || operation.len() > 256 {
            return Err(LekisError::invalid(
                "Native operation must contain 1–256 bytes",
            ));
        }
        validate_native_entry(&self.root, &self.spec)?;
        let executor = executor().ok_or_else(|| {
            LekisError::unsupported("The Android native plugin executor has not been registered")
        })?;
        executor.call(NativePluginRequest {
            plugin_root: self.root.clone(),
            spec: self.spec.clone(),
            operation,
            params,
        })
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
    use super::*;
    use crate::{Capability, JsRuntime, Permissions, PluginManifest, PluginRuntime};
    use serde_json::json;
    use std::sync::atomic::{AtomicUsize, Ordering};
    static NEXT: AtomicUsize = AtomicUsize::new(0);

    fn fixture() -> (PathBuf, AndroidNativeSpec) {
        let root = std::env::temp_dir().join(format!(
            "lekis-native-host-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::SeqCst)
        ));
        std::fs::create_dir_all(root.join("android")).unwrap();
        std::fs::write(root.join("android/classes.dex"), b"test executor fixture").unwrap();
        (
            root,
            AndroidNativeSpec {
                entry: "android/classes.dex".into(),
                class_name: "dev.example.NativePlugin".into(),
            },
        )
    }

    #[test]
    fn native_entry_rejects_absolute_parent_and_symlink_paths() {
        let (root, spec) = fixture();
        assert!(validate_native_entry(&root, &spec)
            .unwrap()
            .starts_with(root.canonicalize().unwrap()));
        for entry in [
            "",
            "../classes.dex",
            "/tmp/classes.dex",
            "android/../../classes.dex",
            "android\\classes.dex",
        ] {
            assert!(validate_native_entry(
                &root,
                &AndroidNativeSpec {
                    entry: entry.into(),
                    ..spec.clone()
                }
            )
            .is_err());
        }
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(root.join("android/classes.dex"), root.join("linked.dex"))
                .unwrap();
            assert!(validate_native_entry(
                &root,
                &AndroidNativeSpec {
                    entry: "linked.dex".into(),
                    ..spec.clone()
                }
            )
            .is_err());
            std::os::unix::fs::symlink(root.join("android"), root.join("linked-dir")).unwrap();
            assert!(validate_native_entry(
                &root,
                &AndroidNativeSpec {
                    entry: "linked-dir/classes.dex".into(),
                    ..spec.clone()
                }
            )
            .is_err());
        }
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn executor_registration_is_idempotent_and_permission_precedes_execution() {
        struct Executor {
            calls: AtomicUsize,
        }
        impl NativePluginExecutor for Executor {
            fn call(&self, request: NativePluginRequest) -> Result<serde_json::Value> {
                self.calls.fetch_add(1, Ordering::SeqCst);
                assert!(request.plugin_root.is_absolute());
                Ok(
                    json!({"operation":request.operation,"params":request.params,"className":request.spec.class_name}),
                )
            }
        }
        let executor = Arc::new(Executor {
            calls: AtomicUsize::new(0),
        });
        register_native_plugin_executor(executor.clone()).unwrap();
        register_native_plugin_executor(executor.clone()).unwrap();
        assert!(register_native_plugin_executor(Arc::new(Executor {
            calls: AtomicUsize::new(0)
        }))
        .is_err());
        let (root, spec) = fixture();
        let mut context = NativeContext::new(root.clone(), spec, false).unwrap();
        assert!(!context.available());
        assert_eq!(
            context
                .call_on_platform("search".into(), json!({}), true)
                .unwrap_err()
                .code,
            lekis_types::ErrorCode::InvalidArgument
        );
        assert_eq!(executor.calls.load(Ordering::SeqCst), 0);
        context.granted = true;
        assert_eq!(
            context
                .call_on_platform("search".into(), json!({"query":"music"}), true)
                .unwrap()["params"]["query"],
            "music"
        );
        assert_eq!(executor.calls.load(Ordering::SeqCst), 1);
        assert_eq!(
            context
                .call_on_platform("search".into(), json!({}), false)
                .unwrap_err()
                .code,
            lekis_types::ErrorCode::Unsupported
        );
        #[cfg(unix)]
        {
            std::fs::remove_file(root.join("android/classes.dex")).unwrap();
            std::os::unix::fs::symlink("/etc/hosts", root.join("android/classes.dex")).unwrap();
            assert!(context
                .call_on_platform("search".into(), json!({}), true)
                .is_err());
            assert_eq!(executor.calls.load(Ordering::SeqCst), 1);
        }
        std::fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn javascript_cannot_choose_native_path_or_bypass_grant() {
        let (root, _) = fixture();
        let manifest = PluginManifest::parse(r#"{"id":"dev.example.native","name":"Native","version":"1.0.0","apiVersion":"1.2","minAppVersion":"0.1.0","runtime":"js","entry":"index.js","kinds":["source"],"native":{"android":{"entry":"android/classes.dex","className":"dev.example.NativePlugin"}}}"#).unwrap();
        let permissions = Permissions::new(&manifest.permissions, &[]);
        let source = "export async function search() { if(host.native.available) throw Error('must deny'); return await host.native.call('search',{entry:'/etc/hosts'}); }";
        let runtime = JsRuntime::load_with_native(
            manifest.clone(),
            permissions.clone(),
            source,
            root.clone(),
            false,
        )
        .unwrap();
        assert_eq!(
            runtime
                .call(Capability::Search, json!({}))
                .await
                .unwrap_err()
                .code,
            lekis_types::ErrorCode::InvalidArgument
        );
        let unconfigured = JsRuntime::load(manifest, permissions, source).unwrap();
        assert_eq!(
            unconfigured
                .call(Capability::Search, json!({}))
                .await
                .unwrap_err()
                .code,
            lekis_types::ErrorCode::Unsupported
        );
        std::fs::remove_dir_all(root).unwrap();
    }
}
