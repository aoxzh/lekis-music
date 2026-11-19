//! VFS 访问钩子。
//!
//! 播放引擎需要按 Range 读取音频文件，但「哪个 `source_id` 对应哪个 [`Vfs`]」是
//! `lekis-core` 的知识（它负责构造 `Arc<dyn Vfs>`、管理密码和连接）。
//! 依赖方向是 core → playback，playback 不能反过来依赖 core，
//! 所以这里提供一个注册点：core 在打开音源时把 `Arc<dyn Vfs>` 注册进来，
//! 引擎播放时按 `source_id` 取回。
//!
//! 两种注册方式：
//! 1. [`install`]：直接注册一个 `Arc<dyn Vfs>`（最简单，core 打开音源时调用）。
//! 2. [`install_resolver`]：注册一个闭包，播放时**按需**构造（用于懒连接的协议）。
//!
//! 没有注册时，VFS 播放会返回 `not_implemented`，不会 panic —— 这样在没有 core 的
//! 单元测试、CLI 工具里也能安全地只播放本地缓存文件。

use lekis_types::SourceId;
use lekis_vfs::Vfs;
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

type Resolver = Box<dyn Fn(SourceId) -> Option<Arc<dyn Vfs>> + Send + Sync>;

struct Registry {
    /// 已经注册的 VFS 实例。
    vfs: HashMap<SourceId, Arc<dyn Vfs>>,
    /// 按需构造的回调。
    resolver: Option<Resolver>,
}

fn registry() -> &'static Mutex<Registry> {
    static REGISTRY: OnceLock<Mutex<Registry>> = OnceLock::new();
    REGISTRY.get_or_init(|| {
        Mutex::new(Registry {
            vfs: HashMap::new(),
            resolver: None,
        })
    })
}

/// 注册一个已打开的 VFS 实例（`lekis-core` 在打开音源成功后调用）。
pub fn install(source_id: SourceId, vfs: Arc<dyn Vfs>) {
    if let Ok(mut reg) = registry().lock() {
        reg.vfs.insert(source_id, vfs);
    }
}

/// 注销（音源被删除 / 连接断开时调用）。
pub fn uninstall(source_id: SourceId) {
    if let Ok(mut reg) = registry().lock() {
        reg.vfs.remove(&source_id);
    }
}

/// 注册一个「按需构造 VFS」的回调；重复调用会覆盖旧的。
pub fn install_resolver(resolver: Box<dyn Fn(SourceId) -> Option<Arc<dyn Vfs>> + Send + Sync>) {
    if let Ok(mut reg) = registry().lock() {
        reg.resolver = Some(resolver);
    }
}

/// 按 `source_id` 取 VFS；没有注册时返回 `None`。
pub fn resolve(source_id: SourceId) -> Option<Arc<dyn Vfs>> {
    let Ok(reg) = registry().lock() else {
        return None;
    };
    if let Some(vfs) = reg.vfs.get(&source_id) {
        return Some(vfs.clone());
    }
    let resolver = reg.resolver.as_ref()?;
    // 注意：resolver 在持锁状态下调用，所以它不能再去动这个注册表（文档里写清）。
    resolver(source_id)
}

/// 当前是否注册了任何 VFS（测试和诊断用）。
pub fn is_available() -> bool {
    registry()
        .lock()
        .map(|reg| !reg.vfs.is_empty() || reg.resolver.is_some())
        .unwrap_or(false)
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use lekis_vfs::local::LocalVfs;

    #[test]
    fn register_and_resolve() {
        let dir = std::env::temp_dir();
        let vfs: Arc<dyn Vfs> = Arc::new(LocalVfs::new(&dir).expect("absolute path is required"));
        let id = SourceId(424_242);
        install(id, vfs);
        assert!(resolve(id).is_some());
        assert!(resolve(SourceId(999_999)).is_none());
        uninstall(id);
        assert!(resolve(id).is_none());
    }
}
