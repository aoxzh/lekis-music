//! 桥接层的凭据存储（SRC-15）：按引用保存 SMB / WebDAV 密码、服务器 token。
//!
//! 放在 `api` 模块之外，frb 不会把它导出给 Dart；Dart 只能通过 `set_credential` /
//! `delete_credential` 写，**永远读不回明文**（核心在连接时自己取）。
//!
//! 存储格式：应用数据目录下的 `credentials.json`
//!
//! ```json
//! { "version": 1, "scheme": "dpapi", "entries": { "<ref>": "<base64 密文>" } }
//! ```
//!
//! - Windows：每条用 DPAPI（`CryptProtectData`，当前用户范围 + 固定熵）加密，
//!   只有同一 Windows 用户能解开；文件被拷到别的机器 / 别的账号上无法解密。
//! - Android：用 Android Keystore 里的 AES-256-GCM 密钥加密（密钥不出 Keystore）。
//!   `CredentialCipher.kt` 负责 JNI 调用，IV 和密文一起存进 base64。
//! - Linux：TODO(SRC-15)：改用 libsecret。在那之前退化为 `scheme = "plain"`：值只做
//!   base64（**不是加密**），文件放在应用私有目录，Unix 上权限设为 0600。
//!
//! 主数据库（`library.sqlite`）里只有 `credential_ref`，从不存密码。

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use base64::Engine as _;
use lekis_types::{LekisError, Result};

/// 文件名（放在核心的数据目录里）。
pub(crate) const FILE_NAME: &str = "credentials.json";

#[cfg(windows)]
const SCHEME: &str = "dpapi";
#[cfg(target_os = "android")]
const SCHEME: &str = "android-keystore-aes-gcm-v1";
#[cfg(all(not(windows), not(target_os = "android")))]
const SCHEME: &str = "plain";

#[derive(serde::Serialize, serde::Deserialize, Default)]
struct OnDisk {
    version: u32,
    scheme: String,
    entries: BTreeMap<String, String>,
}

/// 文件存储的凭据。内存里只保存密文（Windows）/ 编码后的值，取用时才解开。
pub(crate) struct FileCredentials {
    path: PathBuf,
    entries: Mutex<BTreeMap<String, String>>,
}

impl FileCredentials {
    /// 打开（不存在就当空的）。文件损坏或方案不匹配时记一条警告并从空开始，不让 App 起不来。
    pub(crate) fn open(dir: &Path) -> Self {
        let path = dir.join(FILE_NAME);
        let entries = match std::fs::read(&path) {
            Ok(bytes) => match serde_json::from_slice::<OnDisk>(&bytes) {
                Ok(disk) if disk.scheme == SCHEME => disk.entries,
                Ok(disk) => {
                    tracing::warn!(target: "bridge", scheme = %disk.scheme, "credential store scheme mismatch, ignoring stored secrets");
                    BTreeMap::new()
                }
                Err(e) => {
                    tracing::warn!(target: "bridge", error = %e, "credential store is corrupt, starting empty");
                    BTreeMap::new()
                }
            },
            Err(_) => BTreeMap::new(),
        };
        Self {
            path,
            entries: Mutex::new(entries),
        }
    }

    fn persist(&self, entries: &BTreeMap<String, String>) -> Result<()> {
        let disk = OnDisk {
            version: 1,
            scheme: SCHEME.to_string(),
            entries: entries.clone(),
        };
        let bytes = serde_json::to_vec_pretty(&disk)
            .map_err(|e| LekisError::internal(format!("serialize credentials: {e}")))?;
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let tmp = self.path.with_extension("json.tmp");
        write_private(&tmp, &bytes)?;
        std::fs::rename(&tmp, &self.path)?;
        Ok(())
    }
}

/// 写文件；Unix 上只给属主读写（0600）。
fn write_private(path: &Path, bytes: &[u8]) -> Result<()> {
    use std::io::Write;
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    Ok(())
}

fn seal(secret: &str) -> Result<String> {
    let sealed = protect(secret.as_bytes())?;
    Ok(base64::engine::general_purpose::STANDARD.encode(sealed))
}

fn open_sealed(stored: &str) -> Result<String> {
    let raw = base64::engine::general_purpose::STANDARD
        .decode(stored)
        .map_err(|e| LekisError::internal(format!("credential is not base64: {e}")))?;
    let plain = unprotect(&raw)?;
    String::from_utf8(plain).map_err(|_| LekisError::internal("credential is not UTF-8"))
}

impl lekis_core::CredentialStore for FileCredentials {
    fn get(&self, key: &str) -> Option<String> {
        let stored = self.entries.lock().ok()?.get(key).cloned()?;
        match open_sealed(&stored) {
            Ok(secret) => Some(secret),
            Err(e) => {
                tracing::warn!(target: "bridge", code = %e.code.as_str(), "cannot unseal credential");
                None
            }
        }
    }

    fn set(&self, key: &str, secret: &str) -> Result<()> {
        let sealed = seal(secret)?;
        let mut entries = self
            .entries
            .lock()
            .map_err(|_| LekisError::internal("credential store poisoned"))?;
        entries.insert(key.to_string(), sealed);
        self.persist(&entries)
    }

    fn delete(&self, key: &str) -> Result<()> {
        let mut entries = self
            .entries
            .lock()
            .map_err(|_| LekisError::internal("credential store poisoned"))?;
        if entries.remove(key).is_some() {
            self.persist(&entries)?;
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// 加密方案
// ---------------------------------------------------------------------------

#[cfg(windows)]
use dpapi::{protect, unprotect};

#[cfg(target_os = "android")]
use android_keystore::{protect, unprotect};

/// TODO(SRC-15)：Linux 改用 libsecret。现在只是原样返回（文件靠目录权限保护）。
#[cfg(all(not(windows), not(target_os = "android")))]
fn protect(data: &[u8]) -> Result<Vec<u8>> {
    Ok(data.to_vec())
}

#[cfg(all(not(windows), not(target_os = "android")))]
fn unprotect(data: &[u8]) -> Result<Vec<u8>> {
    Ok(data.to_vec())
}

/// Android Keystore 加密：真正的密钥在 `CredentialCipher.kt` 里生成并保管，
/// Rust 只通过 JNI 调 `encrypt` / `decrypt`，拿到的都是 IV + 密文。
#[cfg(target_os = "android")]
mod android_keystore {
    use super::{LekisError, Result};
    use jni_sys::{jclass, jvalue, JNIEnv, JavaVM, JNI_EDETACHED, JNI_OK, JNI_VERSION_1_6};
    use std::ffi::c_void;
    use std::ptr;

    const METHOD_ENCRYPT: &[u8] = b"encrypt\0";
    const METHOD_DECRYPT: &[u8] = b"decrypt\0";
    const SIGNATURE: &[u8] = b"([B)[B\0";

    pub(super) fn protect(data: &[u8]) -> Result<Vec<u8>> {
        call(data, true)
    }

    pub(super) fn unprotect(data: &[u8]) -> Result<Vec<u8>> {
        call(data, false)
    }

    fn internal(message: &str) -> LekisError {
        LekisError::internal(format!("android credential cipher: {message}"))
    }

    fn call(data: &[u8], encrypt: bool) -> Result<Vec<u8>> {
        let ctx = ndk_context::android_context();
        let vm = ctx.vm().cast::<JavaVM>();
        if vm.is_null() {
            return Err(internal("JavaVM is not initialized"));
        }
        let class = crate::android_context::credential_cipher_class()
            .ok_or_else(|| internal("CredentialCipher class is not available"))?;

        // SAFETY: vm 来自 MainActivity 登记的 ndk-context，存活到进程结束。
        unsafe {
            let fns = &**vm;
            let get_env = fns
                .GetEnv
                .ok_or_else(|| internal("JNI GetEnv is unavailable"))?;
            let attach = fns
                .AttachCurrentThread
                .ok_or_else(|| internal("JNI AttachCurrentThread is unavailable"))?;
            // GetEnv / AttachCurrentThread 写出的是 `JNIEnv*`（指向函数表指针的
            // 指针），不是函数表指针本身。
            let mut env: *mut JNIEnv = ptr::null_mut();
            let mut attached = false;
            let mut status = get_env(
                vm,
                (&mut env as *mut *mut JNIEnv).cast::<*mut c_void>(),
                JNI_VERSION_1_6,
            );
            if status == JNI_EDETACHED {
                status = attach(
                    vm,
                    (&mut env as *mut *mut JNIEnv).cast::<*mut c_void>(),
                    ptr::null_mut(),
                );
                if status != JNI_OK {
                    return Err(internal("cannot attach the credential thread to the JVM"));
                }
                attached = true;
            } else if status != JNI_OK {
                return Err(internal("cannot get the JNI environment"));
            }
            if env.is_null() {
                return Err(internal("the JVM returned no JNI environment"));
            }

            let result = call_with_env(env, class, data, encrypt);
            if attached {
                if let Some(detach) = fns.DetachCurrentThread {
                    detach(vm);
                }
            }
            result
        }
    }

    /// SAFETY: `env` 必须是已附加到当前线程的 `JNIEnv*`，`class` 是全局类引用。
    unsafe fn call_with_env(
        env: *mut JNIEnv,
        class: jclass,
        data: &[u8],
        encrypt: bool,
    ) -> Result<Vec<u8>> {
        // SAFETY: env 由调用方保证有效。
        let fns = unsafe { &**env };
        let (
            Some(new_byte_array),
            Some(set_region),
            Some(get_region),
            Some(new_array_length),
            Some(get_static_method),
            Some(call_static),
            Some(delete_local_ref),
            Some(exception_check),
            Some(exception_clear),
        ) = (
            fns.NewByteArray,
            fns.SetByteArrayRegion,
            fns.GetByteArrayRegion,
            fns.GetArrayLength,
            fns.GetStaticMethodID,
            fns.CallStaticObjectMethodA,
            fns.DeleteLocalRef,
            fns.ExceptionCheck,
            fns.ExceptionClear,
        )
        else {
            return Err(internal("required JNI functions are unavailable"));
        };

        let len = i32::try_from(data.len())
            .map_err(|_| internal("credential is too large to encrypt"))?;
        // SAFETY: 下面每个 JNI 调用都只在 env 的线程栈内使用局部引用。
        unsafe {
            let input = new_byte_array(env, len);
            if input.is_null() {
                clear_pending(env, exception_check, exception_clear);
                return Err(internal("cannot allocate the JNI byte array"));
            }
            set_region(env, input, 0, len, data.as_ptr().cast());
            if clear_pending(env, exception_check, exception_clear) {
                delete_local_ref(env, input);
                return Err(internal("cannot copy the credential into the JVM"));
            }

            let method = if encrypt {
                get_static_method(
                    env,
                    class,
                    METHOD_ENCRYPT.as_ptr().cast(),
                    SIGNATURE.as_ptr().cast(),
                )
            } else {
                get_static_method(
                    env,
                    class,
                    METHOD_DECRYPT.as_ptr().cast(),
                    SIGNATURE.as_ptr().cast(),
                )
            };
            if method.is_null() || clear_pending(env, exception_check, exception_clear) {
                delete_local_ref(env, input);
                return Err(internal("CredentialCipher method is missing"));
            }

            let args = [jvalue { l: input }];
            let sealed = call_static(env, class, method, args.as_ptr());
            delete_local_ref(env, input);
            if sealed.is_null() {
                clear_pending(env, exception_check, exception_clear);
                return Err(internal("CredentialCipher returned no data"));
            }

            let out_len = new_array_length(env, sealed);
            if out_len < 0 {
                delete_local_ref(env, sealed);
                clear_pending(env, exception_check, exception_clear);
                return Err(internal("CredentialCipher returned an invalid byte array"));
            }
            let mut out = vec![0u8; out_len as usize];
            get_region(env, sealed, 0, out_len, out.as_mut_ptr().cast());
            delete_local_ref(env, sealed);
            if clear_pending(env, exception_check, exception_clear) {
                return Err(internal("cannot copy the sealed credential out of the JVM"));
            }
            Ok(out)
        }
    }

    /// 有挂起的 Java 异常时清掉并返回 `true`；不让它影响后续 JNI 调用。
    unsafe fn clear_pending(
        env: *mut JNIEnv,
        check: unsafe extern "system" fn(*mut JNIEnv) -> u8,
        clear: unsafe extern "system" fn(*mut JNIEnv),
    ) -> bool {
        // SAFETY: env 由调用方保证有效。
        if unsafe { check(env) } == 0 {
            return false;
        }
        // SAFETY: 同上；清掉异常后线程可以继续执行其它 JNI 调用。
        unsafe { clear(env) };
        true
    }
}

#[cfg(windows)]
mod dpapi {
    //! Windows DPAPI（当前用户范围）。

    use super::{LekisError, Result};
    use lekis_types::ErrorCode;
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{
        CryptProtectData, CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
    };

    /// 附加熵：别的程序就算以同一用户身份调用 DPAPI，不知道这个值也解不开。
    const ENTROPY: &[u8] = b"lekis.credentials.v1";

    fn blob(data: &[u8]) -> CRYPT_INTEGER_BLOB {
        CRYPT_INTEGER_BLOB {
            cbData: data.len() as u32,
            pbData: data.as_ptr() as *mut u8,
        }
    }

    /// 把 DPAPI 分配的输出拷出来并释放。
    ///
    /// # Safety
    /// `out` 必须是 DPAPI 成功返回的、由 `LocalAlloc` 分配的缓冲区。
    unsafe fn take(out: CRYPT_INTEGER_BLOB) -> Vec<u8> {
        if out.pbData.is_null() {
            return Vec::new();
        }
        // SAFETY: DPAPI 保证 pbData 指向 cbData 字节的有效内存。
        let v = unsafe { std::slice::from_raw_parts(out.pbData, out.cbData as usize) }.to_vec();
        // SAFETY: 缓冲区由 DPAPI 用 LocalAlloc 分配，按文档必须用 LocalFree 释放。
        unsafe { LocalFree(out.pbData.cast()) };
        v
    }

    fn os_error(what: &str) -> LekisError {
        LekisError::new(
            ErrorCode::Internal,
            format!("{what}: {}", std::io::Error::last_os_error()),
        )
    }

    pub(super) fn protect(data: &[u8]) -> Result<Vec<u8>> {
        let input = blob(data);
        let entropy = blob(ENTROPY);
        let mut out = CRYPT_INTEGER_BLOB {
            cbData: 0,
            pbData: std::ptr::null_mut(),
        };
        // SAFETY: 输入 / 熵指向活着的切片；DPAPI 不会写它们。其余可选参数传空指针。
        let ok = unsafe {
            CryptProtectData(
                &input,
                std::ptr::null(),
                &entropy,
                std::ptr::null(),
                std::ptr::null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut out,
            )
        };
        if ok == 0 {
            return Err(os_error("CryptProtectData"));
        }
        // SAFETY: 调用成功，out 由 DPAPI 分配。
        Ok(unsafe { take(out) })
    }

    pub(super) fn unprotect(data: &[u8]) -> Result<Vec<u8>> {
        let input = blob(data);
        let entropy = blob(ENTROPY);
        let mut out = CRYPT_INTEGER_BLOB {
            cbData: 0,
            pbData: std::ptr::null_mut(),
        };
        // SAFETY: 同上；不要描述字符串（ppszDataDescr 传空）。
        let ok = unsafe {
            CryptUnprotectData(
                &input,
                std::ptr::null_mut(),
                &entropy,
                std::ptr::null(),
                std::ptr::null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut out,
            )
        };
        if ok == 0 {
            return Err(os_error("CryptUnprotectData"));
        }
        // SAFETY: 调用成功，out 由 DPAPI 分配。
        Ok(unsafe { take(out) })
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    use lekis_core::CredentialStore;

    fn temp_dir(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("lekis-bridge-creds-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn roundtrip_persists_across_reopen_without_plaintext() {
        let dir = temp_dir("roundtrip");
        let store = FileCredentials::open(&dir);
        assert_eq!(store.get("smb.nas"), None);
        store.set("smb.nas", "hunter2-秘密").unwrap();
        store.set("plex.token", "abc").unwrap();
        assert_eq!(store.get("smb.nas").as_deref(), Some("hunter2-秘密"));

        let reopened = FileCredentials::open(&dir);
        assert_eq!(reopened.get("smb.nas").as_deref(), Some("hunter2-秘密"));
        assert_eq!(reopened.get("plex.token").as_deref(), Some("abc"));

        let on_disk = std::fs::read_to_string(dir.join(FILE_NAME)).unwrap();
        assert!(on_disk.contains("smb.nas"));
        #[cfg(windows)]
        {
            assert!(
                !on_disk.contains("hunter2"),
                "secret must not be stored in clear text"
            );
            let b64 = base64::engine::general_purpose::STANDARD.encode("hunter2-秘密");
            assert!(
                !on_disk.contains(&b64),
                "secret must be encrypted, not just encoded"
            );
        }

        reopened.delete("smb.nas").unwrap();
        reopened.delete("missing").unwrap();
        let again = FileCredentials::open(&dir);
        assert_eq!(again.get("smb.nas"), None);
        assert_eq!(again.get("plex.token").as_deref(), Some("abc"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn corrupt_file_starts_empty() {
        let dir = temp_dir("corrupt");
        std::fs::write(dir.join(FILE_NAME), b"{ not json").unwrap();
        let store = FileCredentials::open(&dir);
        assert_eq!(store.get("x"), None);
        store.set("x", "y").unwrap();
        assert_eq!(FileCredentials::open(&dir).get("x").as_deref(), Some("y"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
