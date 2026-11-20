//! SMB 2/3（SRC-02）。
//!
//! 基于纯 Rust 的 `smb2` crate（`#![forbid(unsafe_code)]`，不依赖 libsmb2 / Samba 的 C 库），
//! 支持 NTLMv2、SMB3 签名与加密（协商成功时自动加密）、访客会话。
//!
//! 设计要点：
//! - **连接是惰性的**：[`open()`](crate::open) 的签名是同步的，真正握手推迟到第一次
//!   操作。第一次调用如果连不上，错误会被记住并缓存吗？——**不会**，失败就丢弃会话，
//!   下次操作重新连（NAS 重启后无需重启整个音源）。
//! - **`smb2` 的句柄模型**：读文件返回 [`smb2::FileReader`]，它是 `'static` 的预读句柄，
//!   `read_at(offset, len)` 是 pread 语义，且**超过服务器协商的 MaxReadSize 会自动分块**
//!   （`smb2` 内部按 `fundable_chunk(max_read)` 拆包并重组），所以这里不用自己分块。
//! - **路径**：`VfsPath` 用 `/` 分隔，`smb2` 也**只**用 `/` 分隔（`\` 是普通名字字符，
//!   crate 内部映射到 Unicode 私用区），所以两边可以直接对应；share 根的路径是空串。
//! - **凭据**：密码只交给 `smb2` 的 `ClientConfig`，**不出现在日志、错误消息或 URL 里**
//!   （[`SmbTarget`] 保存的地址已经剥掉 userinfo）。

use crate::{DirEntry, EntryKind, FileMeta, Vfs, VfsCapabilities, VfsPath};
use async_trait::async_trait;
use bytes::Bytes;
use lekis_types::{ErrorCode, LekisError, Result, SourceKind};
use std::ops::Range;
use std::time::UNIX_EPOCH;
use tokio::sync::Mutex;

/// 默认 SMB 端口。
const DEFAULT_PORT: u16 = 445;

/// `smb://[user[:pass@]host[:port]/share/path` 解析结果。
///
/// 刻意不实现 `Debug`：里面带密码，避免哪天被 `?target` 打进日志
/// （和 `SftpTarget` / `NfsTarget` 保持一致）。
#[derive(Clone, PartialEq, Eq)]
struct SmbTarget {
    /// `host:port`（已剥掉 userinfo）。
    addr: String,
    /// 用户名（percent 解码后）。
    user: String,
    /// URL userinfo 里的密码（percent 解码后）。
    password: Option<String>,
    /// 共享名（第一段路径）。
    share: String,
    /// 共享内的根路径（`/` 分隔、无首尾 `/`，可能是空串）。
    root: String,
}

/// 已建立的 SMB 会话。
struct SmbSession {
    client: smb2::SmbClient,
    tree: smb2::Tree,
}

/// SMB 文件系统。
pub struct SmbVfs {
    /// 解析后的目标（不含凭据的 URL 部分 + 用户名 + 密码）。
    target: SmbTarget,
    /// 密码（来自 `open()` 参数优先）。
    password: String,
    /// 懒惰建立的会话。
    session: Mutex<Option<SmbSession>>,
}

impl SmbVfs {
    /// 连接 `smb://[user[:pass@]host[:port]/share[/path]`。
    ///
    /// 只做参数解析，不发网络请求（真正连接推迟到第一次读写）。
    pub fn connect(url: &str, password: Option<String>) -> Result<Self> {
        let target = parse_smb_url(url)?;
        let password = password
            .filter(|p| !p.is_empty())
            .or_else(|| target.password.clone())
            .unwrap_or_default();
        tracing::debug!(
            target: "vfs::smb",
            addr = %target.addr,
            share = %target.share,
            root = %target.root,
            user = %target.user,
            "SMB 源已配置（密码不记录）"
        );
        Ok(Self {
            target,
            password,
            session: Mutex::new(None),
        })
    }

    /// 远端绝对路径（share 内、`/` 分隔）。根目录是 `""`。
    fn remote_path(&self, path: &VfsPath) -> Result<String> {
        if self.target.root.is_empty() {
            return Ok(path.as_str().to_string());
        }
        if path.is_root() {
            Ok(self.target.root.clone())
        } else {
            Ok(format!("{}/{}", self.target.root, path.as_str()))
        }
    }

    /// 确保会话已建立，并在锁内执行 `f`。
    ///
    /// 连接失败时不缓存失败状态，下次调用会重连（NAS 重启、Wi-Fi 漫游后自愈）。
    async fn with_session<T, F>(&self, f: F) -> Result<T>
    where
        F: for<'a> FnOnce(
            &'a mut smb2::SmbClient,
            &'a mut smb2::Tree,
        ) -> futures_util::future::BoxFuture<'a, smb2::Result<T>>,
    {
        let mut guard = self.session.lock().await;
        if guard.is_none() {
            tracing::debug!(target: "vfs::smb", addr = %self.target.addr, "建立 SMB 会话");
            // 和 list_shares 走同一套映射：主机不可达是 network，不是 io。
            let mut client = smb2::connect(&self.target.addr, &self.target.user, &self.password)
                .await
                .map_err(smb_auth_err)?;
            let tree = client
                .connect_share(&self.target.share)
                .await
                .map_err(smb_auth_err)?;
            *guard = Some(SmbSession { client, tree });
        }
        let session = guard
            .as_mut()
            .ok_or_else(|| LekisError::internal("smb: 会话初始化失败（内部状态异常）"))?;
        f(&mut session.client, &mut session.tree)
            .await
            .map_err(smb_err)
    }
}

#[async_trait]
impl Vfs for SmbVfs {
    fn kind(&self) -> SourceKind {
        SourceKind::Smb
    }

    fn capabilities(&self) -> VfsCapabilities {
        VfsCapabilities {
            writable: true,
            watch: false,
            // NTFS / Samba 的目录 mtime 在增删条目时会更新，可以用于增量扫描剪枝。
            reliable_dir_mtime: true,
            suggested_concurrency: 8,
        }
    }

    async fn list_dir(&self, dir: &VfsPath) -> Result<Vec<DirEntry>> {
        let remote = self.remote_path(dir)?;
        let entries = self
            .with_session(move |client, tree| {
                Box::pin(async move { client.list_directory(tree, &remote).await })
            })
            .await?;
        let mut out = Vec::with_capacity(entries.len());
        for entry in entries {
            // `.` / `..` 由服务器返回时会话层已过滤；再兜一层。
            if entry.name == "." || entry.name == ".." || entry.name.is_empty() {
                continue;
            }
            out.push(DirEntry {
                path: dir.join(&entry.name),
                meta: FileMeta {
                    kind: if entry.is_directory {
                        EntryKind::Dir
                    } else {
                        EntryKind::File
                    },
                    size: if entry.is_directory { 0 } else { entry.size },
                    mtime_ms: filetime_ms(entry.modified),
                },
            });
        }
        Ok(out)
    }

    async fn stat(&self, path: &VfsPath) -> Result<FileMeta> {
        let remote = self.remote_path(path)?;
        let info = self
            .with_session(move |client, tree| {
                Box::pin(async move { client.stat(tree, &remote).await })
            })
            .await?;
        Ok(FileMeta {
            kind: if info.is_directory {
                EntryKind::Dir
            } else {
                EntryKind::File
            },
            size: if info.is_directory { 0 } else { info.size },
            mtime_ms: filetime_ms(info.modified),
        })
    }

    async fn read_range(&self, path: &VfsPath, range: Range<u64>) -> Result<Bytes> {
        if range.end < range.start {
            return Err(LekisError::invalid("smb: 读取范围 end < start"));
        }
        let want = range.end - range.start;
        if want == 0 {
            return Ok(Bytes::new());
        }
        let remote = self.remote_path(path)?;
        // 只借 `&mut client` 一会儿拿到句柄；`FileReader` 是 'static 的，
        // 之后的分块读在锁外进行，多个并发读共享同一个 SMB 会话。
        let reader = self
            .with_session(move |client, tree| {
                Box::pin(async move { client.open_file_reader(&*tree, &remote).await })
            })
            .await?;
        let result = reader.read_at(range.start, want).await;
        // 尽力关闭句柄，但不让关闭失败盖掉真正的读取错误。
        let closed = reader.close().await;
        let data = result.map_err(smb_err)?;
        if let Err(e) = closed {
            tracing::debug!(target: "vfs::smb", error = %e, "关闭读句柄失败");
        }
        Ok(Bytes::from(data))
    }

    async fn write_atomic(&self, path: &VfsPath, data: Bytes) -> Result<()> {
        if path.is_root() {
            return Err(LekisError::invalid("smb: 不能把文件写到共享根目录"));
        }
        let tmp_path = VfsPath::parse(&format!("{}.lekis-tmp", path.as_str()))
            .ok_or_else(|| LekisError::invalid("smb: 临时文件路径非法"))?;
        let remote = self.remote_path(path)?;
        let tmp_remote = self.remote_path(&tmp_path)?;
        let payload = data.to_vec();

        self.with_session(move |client, tree| {
            Box::pin(async move {
                // 先整块写临时文件（crate 内部按 MaxWriteSize 自动分包），再原子改名覆盖。
                client.write_file(&*tree, &tmp_remote, &payload).await?;
                client
                    .rename_with(
                        &*tree,
                        &tmp_remote,
                        &remote,
                        smb2::RenameOptions::new().replace_if_exists(true),
                    )
                    .await?;
                Ok(())
            })
        })
        .await
    }

    async fn create_dir_all(&self, dir: &VfsPath) -> Result<()> {
        if dir.is_root() {
            return Ok(());
        }
        let mut prefix = VfsPath::root();
        let mut remotes = Vec::new();
        for part in dir.as_str().split('/') {
            prefix = prefix.join(part);
            remotes.push(self.remote_path(&prefix)?);
        }
        self.with_session(move |client, tree| {
            Box::pin(async move {
                for remote in &remotes {
                    match client.create_directory(&*tree, remote).await {
                        Ok(()) => {}
                        // 已存在：MKCOL 语义，当成功。
                        Err(e) if e.kind() == smb2::ErrorKind::AlreadyExists => {}
                        Err(e) => return Err(e),
                    }
                }
                Ok(())
            })
        })
        .await
    }
}

/// `FileTime`（100ns since 1601）→ Unix 毫秒。
fn filetime_ms(time: smb2::pack::FileTime) -> i64 {
    time.to_system_time()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}

/// `smb2::Error` → [`LekisError`]。
///
/// `smb2` 的错误消息只含 `addr`/路径/状态码，不含密码，可以安全带出。
fn smb_err(err: smb2::Error) -> LekisError {
    let code = match err.kind() {
        smb2::ErrorKind::NotFound => ErrorCode::NotFound,
        smb2::ErrorKind::AccessDenied => ErrorCode::PermissionDenied,
        smb2::ErrorKind::AuthRequired
        | smb2::ErrorKind::SigningRequired
        | smb2::ErrorKind::GuestSessionRefused => ErrorCode::Auth,
        smb2::ErrorKind::Unsupported => ErrorCode::Unsupported,
        smb2::ErrorKind::TimedOut | smb2::ErrorKind::ConnectionLost => ErrorCode::Network,
        smb2::ErrorKind::Cancelled => ErrorCode::Cancelled,
        smb2::ErrorKind::AlreadyExists
        | smb2::ErrorKind::IsADirectory
        | smb2::ErrorKind::NotADirectory
        | smb2::ErrorKind::InvalidName
        | smb2::ErrorKind::InvalidData => ErrorCode::InvalidArgument,
        smb2::ErrorKind::TooLarge => ErrorCode::InvalidArgument,
        smb2::ErrorKind::DiskFull | smb2::ErrorKind::SharingViolation => ErrorCode::Io,
        _ => ErrorCode::Io,
    };
    LekisError::new(code, format!("smb: {err}"))
}

/// 连接阶段的错误：`smb2` 把认证失败也报成普通错误，这里按「连接 / 认证」区分。
fn smb_auth_err(err: smb2::Error) -> LekisError {
    let mut mapped = smb_err(err);
    if mapped.code == ErrorCode::Io {
        // 连不上或共享不存在时统一按网络错误处理，便于上层提示「检查地址」。
        mapped.code = ErrorCode::Network;
    }
    mapped
}

/// `smb://[user[:pass@]host[:port][/...]` 里和服务器有关的部分。
/// 同上：带密码，不实现 `Debug`。
#[derive(Clone, PartialEq, Eq)]
struct SmbServer {
    /// `host:port`（已剥掉 userinfo）。
    addr: String,
    /// 用户名（percent 解码后）。
    user: String,
    /// URL userinfo 里的密码（percent 解码后）。
    password: Option<String>,
    /// percent 解码后的路径（去掉首尾 `/`），可能是空串。
    path: String,
}

/// 解析主机 / 端口 / userinfo，不要求带共享名。
fn parse_smb_server(url: &str) -> Result<SmbServer> {
    if !url.starts_with("smb://") {
        return Err(LekisError::invalid("SMB address must start with smb://"));
    }
    let parsed =
        url::Url::parse(url).map_err(|e| LekisError::invalid(format!("SMB 地址不合法: {e}")))?;
    let host = parsed
        .host_str()
        .filter(|h| !h.is_empty())
        .ok_or_else(|| LekisError::invalid("SMB 地址缺少主机名"))?;
    let host = match parsed.host() {
        // IPv6 字面量要带方括号才能拼成 host:port。
        Some(url::Host::Ipv6(v6)) => format!("[{v6}]"),
        _ => host.to_string(),
    };
    let port = parsed.port().unwrap_or(DEFAULT_PORT);

    // `url::Url` 会把 `..` 规范化掉，所以要在**原始字符串**上先拒绝它。
    if raw_path_segments(url).any(|seg| seg == "..") {
        return Err(LekisError::invalid("SMB 地址里的路径包含 ..，已拒绝"));
    }

    // `Url::path()` 返回的是未解码的 path，中文 / 空格要先 percent 解码。
    let path = percent_decode(parsed.path());
    Ok(SmbServer {
        addr: format!("{host}:{port}"),
        user: percent_decode(parsed.username()),
        password: parsed.password().map(percent_decode),
        path: path.trim_matches('/').to_string(),
    })
}

/// 解析 `smb://[user[:pass@]host[:port]/share[/path]`。
///
/// 凭据（userinfo）会被单独摘出来，**不留在地址字符串里**，避免被日志打出去。
fn parse_smb_url(url: &str) -> Result<SmbTarget> {
    let server = parse_smb_server(url)?;
    let (share, root) = match server.path.split_once('/') {
        Some((share, rest)) => (share, rest.trim_matches('/').to_string()),
        None => (server.path.as_str(), String::new()),
    };
    if share.is_empty() {
        return Err(LekisError::invalid(
            "SMB 地址必须带共享名：smb://host/share",
        ));
    }
    // 规范化 root：去掉 `.` 和空段。
    let root = if root.is_empty() {
        String::new()
    } else {
        VfsPath::parse(&root)
            .ok_or_else(|| LekisError::invalid("SMB 地址里的路径不合法"))?
            .as_str()
            .to_string()
    };

    Ok(SmbTarget {
        share: share.to_string(),
        root,
        addr: server.addr,
        user: server.user,
        password: server.password,
    })
}

/// 列出服务器上的磁盘共享（srvsvc `NetShareEnumAll`，经 `IPC$` 命名管道）。
///
/// `url` 只用主机、端口和 userinfo（`smb://nas` 即可）；`password` 优先于 URL 里的密码。
/// 用户名为空时按访客登录。管理共享（`C$`、`IPC$` 这类以 `$` 结尾的）不返回。
pub async fn list_shares(url: &str, password: Option<String>) -> Result<Vec<crate::ShareInfo>> {
    let server = parse_smb_server(url)?;
    let password = password
        .filter(|p| !p.is_empty())
        .or(server.password)
        .unwrap_or_default();
    tracing::debug!(target: "vfs::smb", addr = %server.addr, "枚举 SMB 共享");
    let mut client = smb2::connect(&server.addr, &server.user, &password)
        .await
        .map_err(smb_auth_err)?;
    let shares = client.list_shares().await.map_err(smb_err)?;
    Ok(shares
        .into_iter()
        .filter(|s| !s.name.is_empty() && !s.name.ends_with('$'))
        .map(|s| crate::ShareInfo {
            name: s.name,
            comment: s.comment,
        })
        .collect())
}

/// 取原始 URL 字符串里 path 部分的各段（**不经过 `url::Url` 规范化**）。
///
/// `url::Url` 会把 `a/../b` 折叠成 `b`，这样 `..` 就被吃掉了；这里在原始
/// 字符串上先看一遍，越界路径才能被拒。
fn raw_path_segments(url: &str) -> impl Iterator<Item = &str> {
    let after_scheme = url.split_once("://").map_or(url, |(_, rest)| rest);
    let path = match after_scheme.find('/') {
        Some(idx) => &after_scheme[idx..],
        None => "",
    };
    path.split('/').filter(|seg| !seg.is_empty())
}

/// percent 解码（失败时原样返回，不丢字符）。
fn percent_decode(input: &str) -> String {
    percent_encoding::percent_decode_str(input)
        .decode_utf8()
        .map(|c| c.into_owned())
        .unwrap_or_else(|_| input.to_string())
}

#[cfg(test)]
mod tests {
    // 测试里允许 unwrap/expect/panic：失败信息比返回 Result 更直观。
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;

    #[test]
    fn parses_minimal_url() {
        let target = parse_smb_url("smb://nas/music").expect("应能解析");
        assert_eq!(target.addr, "nas:445");
        assert_eq!(target.share, "music");
        assert_eq!(target.root, "");
        assert_eq!(target.user, "");
        assert!(target.password.is_none());
    }

    #[test]
    fn parses_user_port_and_path() {
        let target =
            parse_smb_url("smb://david:pw@nas.local:1445/music/FLAC/SACD").expect("应能解析");
        assert_eq!(target.addr, "nas.local:1445");
        assert_eq!(target.user, "david");
        assert_eq!(target.password.as_deref(), Some("pw"));
        assert_eq!(target.share, "music");
        assert_eq!(target.root, "FLAC/SACD");
    }

    #[test]
    fn parses_percent_encoded_user_and_path() {
        let target =
            parse_smb_url("smb://a%40b:p%20w@nas/share/%E9%9F%B3%E4%B9%90").expect("应能解析");
        assert_eq!(target.user, "a@b");
        assert_eq!(target.password.as_deref(), Some("p w"));
        assert_eq!(target.root, "音乐");
    }

    #[test]
    fn parses_ipv6_host() {
        let target = parse_smb_url("smb://[fe80::1]:445/share/a").expect("应能解析");
        assert_eq!(target.addr, "[fe80::1]:445");
        assert_eq!(target.share, "share");
        assert_eq!(target.root, "a");
    }

    #[test]
    fn rejects_bad_urls() {
        assert!(parse_smb_url("http://nas/share").is_err());
        assert!(parse_smb_url("smb://nas").is_err(), "缺少共享名要报错");
        assert!(parse_smb_url("smb://nas/").is_err());
        assert!(parse_smb_url("smb:///share").is_err(), "缺少主机名要报错");
        assert!(parse_smb_url("smb://nas/share/../etc").is_err());
    }

    #[test]
    fn server_part_parses_without_share() {
        let server = parse_smb_server("smb://bob@nas.local:1445").expect("应能解析");
        assert_eq!(server.addr, "nas.local:1445");
        assert_eq!(server.user, "bob");
        assert_eq!(server.path, "");
        let server = parse_smb_server("smb://nas/").expect("应能解析");
        assert_eq!(server.addr, "nas:445");
        assert!(parse_smb_server("smb://nas/a/../b").is_err());
        assert!(parse_smb_server("http://nas").is_err());
    }

    #[test]
    fn root_path_is_normalized() {
        let target = parse_smb_url("smb://nas/share//Music/./Rock/").expect("应能解析");
        assert_eq!(target.root, "Music/Rock");
    }

    #[test]
    fn addr_never_contains_credentials() {
        let target = parse_smb_url("smb://bob:hunter2@nas/share").expect("应能解析");
        assert!(!target.addr.contains("bob"));
        assert!(!target.addr.contains("hunter2"));
        // 但用户名/密码确实被解析出来了（供连接使用）。
        assert_eq!(target.user, "bob");
        assert_eq!(target.password.as_deref(), Some("hunter2"));
    }

    /// 构造一个只用来测路径映射的实例（不发网络请求）。
    fn vfs_for(url: &str) -> SmbVfs {
        SmbVfs::connect(url, None).expect("应能构造")
    }

    #[test]
    fn vfs_path_maps_to_share_relative_path() {
        let vfs = vfs_for("smb://nas/music");
        let root = VfsPath::root();
        assert_eq!(vfs.remote_path(&root).expect("应能映射"), "");
        let p = VfsPath::parse("周杰伦/晴天.flac").expect("路径非法");
        assert_eq!(vfs.remote_path(&p).expect("应能映射"), "周杰伦/晴天.flac");
    }

    #[test]
    fn vfs_path_maps_with_sub_root() {
        let vfs = vfs_for("smb://nas/music/FLAC");
        assert_eq!(vfs.remote_path(&VfsPath::root()).expect("应能映射"), "FLAC");
        let p = VfsPath::parse("a/b.mp3").expect("路径非法");
        assert_eq!(vfs.remote_path(&p).expect("应能映射"), "FLAC/a/b.mp3");
    }

    #[test]
    fn roundtrip_vfs_path_through_remote() {
        // 远端路径去掉子根前缀后应当还原成 VfsPath。
        let vfs = vfs_for("smb://nas/music/根");
        let original = VfsPath::parse("专辑/曲目 1.flac").expect("路径非法");
        let remote = vfs.remote_path(&original).expect("应能映射");
        assert_eq!(remote, "根/专辑/曲目 1.flac");
        let back = VfsPath::parse(remote.strip_prefix("根/").unwrap_or(&remote)).expect("还原失败");
        assert_eq!(back, original);
    }

    #[test]
    fn password_argument_overrides_url() {
        let vfs = SmbVfs::connect("smb://nas/share", Some("from_keychain".to_string()))
            .expect("应能构造");
        assert_eq!(vfs.password, "from_keychain");
    }

    #[test]
    fn error_kinds_map_to_project_codes() {
        let not_found = smb_err(smb2::Error::Protocol {
            status: smb2::types::status::NtStatus::OBJECT_NAME_NOT_FOUND,
            command: smb2::types::Command::QueryInfo,
        });
        assert_eq!(not_found.code, ErrorCode::NotFound);
    }
}
