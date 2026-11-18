//! 由平台实现、注入核心的能力（ARCHITECTURE.md 第 2 节第 6 条）。
//!
//! 新增平台能力的步骤：在这里加 trait → 在 lekis-ffi 里加对应的 callback interface 和适配器 →
//! Android（`core/bridge`）和 Windows（`Lekis.Core.Interop`）实现它。

use lekis_types::Result;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

/// 凭据存储（系统钥匙串）。
///
/// - Android：Android Keystore + EncryptedSharedPreferences（或 DataStore + Tink）；
/// - Windows：Credential Manager（`Windows.Security.Credentials.PasswordVault`）；
/// - Linux：libsecret；
/// - lekis-node：加密的本地文件。
pub trait CredentialStore: Send + Sync {
    /// 读取。
    fn get(&self, key: &str) -> Option<String>;
    /// 写入。
    fn set(&self, key: &str, secret: &str) -> Result<()>;
    /// 删除。
    fn delete(&self, key: &str) -> Result<()>;
}

/// 内存实现（测试用）。
#[derive(Default)]
pub struct MemoryCredentialStore(Mutex<HashMap<String, String>>);

impl CredentialStore for MemoryCredentialStore {
    fn get(&self, key: &str) -> Option<String> {
        self.0.lock().ok()?.get(key).cloned()
    }

    fn set(&self, key: &str, secret: &str) -> Result<()> {
        if let Ok(mut m) = self.0.lock() {
            m.insert(key.to_string(), secret.to_string());
        }
        Ok(())
    }

    fn delete(&self, key: &str) -> Result<()> {
        if let Ok(mut m) = self.0.lock() {
            m.remove(key);
        }
        Ok(())
    }
}

/// 平台注入的全部能力。
///
/// TODO：网络状态（是否计费网络、当前 SSID，用于 SRC-14）、电量与充电状态（后台任务调度）。
#[derive(Clone)]
pub struct PlatformServices {
    /// 凭据存储。
    pub credentials: Arc<dyn CredentialStore>,
}

impl PlatformServices {
    /// 全部用内存实现（测试和 lekis-node 早期版本用）。
    pub fn in_memory() -> Self {
        Self {
            credentials: Arc::new(MemoryCredentialStore::default()),
        }
    }
}
