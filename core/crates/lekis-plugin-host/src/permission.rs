//! 权限检查（PLG-05、PLG-06）。默认零权限，每次宿主 API 调用都要检查。

use crate::manifest::DeclaredPermissions;

/// 一个插件实际拥有的权限（= 清单声明的 ∩ 用户授予的）。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Permissions {
    hosts: Vec<String>,
    processes: Vec<String>,
    /// 是否允许网页登录。
    pub web_sign_in: bool,
    /// 存储配额（字节）。
    pub storage_bytes: u64,
}

impl Permissions {
    /// 由清单声明和用户授予的进程列表生成。网络权限在安装时一次性确认，所以直接取声明值。
    pub fn new(declared: &DeclaredPermissions, user_allowed_processes: &[String]) -> Self {
        Self {
            hosts: declared
                .network
                .iter()
                .map(|h| h.to_ascii_lowercase())
                .collect(),
            processes: declared
                .process
                .iter()
                .filter(|p| user_allowed_processes.contains(p))
                .cloned()
                .collect(),
            web_sign_in: declared.web_sign_in,
            storage_bytes: u64::from(declared.storage_kb.unwrap_or(1024)) * 1024,
        }
    }

    /// 是否允许访问这个 URL。只允许 https（以及 http://localhost 方便调试）。
    pub fn allows_url(&self, url: &str) -> bool {
        let Some(host) = host_of(url) else {
            return false;
        };
        if url.starts_with("http://") && host != "localhost" && host != "127.0.0.1" {
            return false;
        }
        self.hosts
            .iter()
            .any(|pattern| match pattern.strip_prefix("*.") {
                Some(suffix) => host == suffix || host.ends_with(&format!(".{suffix}")),
                None => host == *pattern,
            })
    }

    /// 是否允许启动这个程序（只在桌面端调用）。
    pub fn allows_process(&self, program: &str) -> bool {
        self.processes.iter().any(|p| p == program)
    }
}

/// 从 URL 里取出小写的主机名（不含端口和用户信息）。
fn host_of(url: &str) -> Option<String> {
    let rest = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))?;
    let authority = rest.split(['/', '?', '#']).next()?;
    let host_port = authority.rsplit('@').next()?;
    let host = if let Some(stripped) = host_port.strip_prefix('[') {
        stripped.split(']').next()?
    } else {
        host_port.split(':').next()?
    };
    if host.is_empty() {
        None
    } else {
        Some(host.to_ascii_lowercase())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn perms(hosts: &[&str]) -> Permissions {
        let declared = DeclaredPermissions {
            network: hosts.iter().map(|s| s.to_string()).collect(),
            ..Default::default()
        };
        Permissions::new(&declared, &[])
    }

    #[test]
    fn url_checks() {
        let p = perms(&["lrclib.net", "*.example.com"]);
        assert!(p.allows_url("https://lrclib.net/api/get?x=1"));
        assert!(p.allows_url("https://LRCLIB.net:443/"));
        assert!(p.allows_url("https://cdn.example.com/a.jpg"));
        assert!(p.allows_url("https://example.com/"));
        assert!(!p.allows_url("https://evil-lrclib.net/"));
        assert!(!p.allows_url("https://lrclib.net.evil.com/"));
        assert!(!p.allows_url("http://lrclib.net/")); // 不允许明文 http
        assert!(!p.allows_url("https://user@evil.com/"));
    }
}
