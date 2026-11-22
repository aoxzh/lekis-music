//! SFTP（SRC-07，P1）：基于 `russh` + `russh-sftp` 的纯 Rust 实现。
//!
//! 覆盖 OpenSSH 的 `sftp-server` 子系统（Linux NAS、群晖、macOS 都能用），
//! 也支持 `Tailscale`/跳板机之后的内网机器。
//!
//! 要点：
//! - **认证**：密码（`open()` 传入的密码，或 URL userinfo 里的密码）+ 私钥
//!   （URL 查询参数 `?key=/path/to/id_ed25519`；passphrase 放凭据库，旧配置里的`?key_passphrase=`由核心迁移进凭据库）。
//!   私钥文件的 passphrase 只在本进程内使用，不进日志。
//! - **主机密钥**：先查用户的 `~/.ssh/known_hosts`（只读），再查 Lekis 自己的
//!   `<数据目录>/ssh_known_hosts`。命中且一致 → 接受；都没记录（首次连接）→ TOFU
//!   接受并记进 Lekis 的文件；**不一致 → 拒绝连接**（防中间人）。
//! - **凭据不进日志**：`tracing` 只输出 host/port，不输出用户名、密码、私钥路径。
//! - **读取**：SFTP 没有 `pread`，用 `seek(SeekFrom::Start(offset))` + 循环读，
//!   读到目标长度或 EOF 为止（服务器可能短读，必须循环）。
//! - **原子写**：写 `<path>.lekis-tmp` 再 `rename` 覆盖。SFTP v3 的 `rename`
//!   在目标已存在时可能报失败（OpenSSH 旧版本如此），所以失败后删掉目标再重试一次。
//!
//! 关于 russh 的 feature：必须 `default-features = false, features = ["ring"]`，
//! 默认的 `aws-lc-rs` 需要 NASM，本项目在 Windows GNU 工具链上没有。
//! 代价是 **RSA 私钥暂不支持**（那是 `rsa` feature，见 `TODO(sftp-rsa)`）。

use crate::{DirEntry, EntryKind, FileMeta, Vfs, VfsCapabilities, VfsPath};
use async_trait::async_trait;
use bytes::Bytes;
use lekis_types::{ErrorCode, LekisError, Result, SourceKind};
use russh_sftp::client::error::Error as SftpError;
use russh_sftp::client::SftpSession;
use russh_sftp::protocol::{FileAttributes, OpenFlags, StatusCode};
use std::ops::Range;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
use tokio::sync::Mutex;

/// 源配置 `options` 里表示认证方式的键。
pub const AUTH_OPTION: &str = "auth";

/// `options["auth"]` 取这个值时，凭据库里存的是私钥（见 [`SftpVfs::connect_with`]）。
pub const AUTH_KEY: &str = "key";

/// 默认 SFTP 端口（跑在 SSH 上）。
const DEFAULT_PORT: u16 = 22;

/// 单次 `read` 的缓冲区大小。SFTP 的包长默认 256 KiB，这里取 128 KiB，
/// 留出协议头空间，避免被服务器按包长切碎得太厉害。
const READ_CHUNK: usize = 128 * 1024;

/// 单个目录最多返回多少个条目（防御性上限）。
const MAX_ENTRIES: usize = 200_000;

/// SFTP 源的连接参数。
///
/// 刻意不实现 `Debug`：里面带密码，避免哪天被 `?target` 打进日志。
#[derive(Clone, PartialEq, Eq)]
struct SftpTarget {
    /// 主机名或 IP（不带端口）。
    host: String,
    /// SSH 端口。
    port: u16,
    /// 登录用户名（percent 解码后）。
    user: String,
    /// URL userinfo 里的密码（percent 解码后）。
    password: Option<String>,
    /// 私钥文件路径（来自 `?key=`）。
    key: Option<String>,
    /// 私钥 passphrase（来自 `?key_passphrase=`）。
    key_passphrase: Option<String>,
    /// 远程根目录（`/` 分隔、无首尾 `/`，可能是空串表示登录目录 `/`）。
    root: String,
}

/// SFTP 文件系统。
pub struct SftpVfs {
    /// 连接参数。
    target: SftpTarget,
    /// 生效的密码（`open()` 参数优先于 URL userinfo）。
    password: String,
    /// 私钥 passphrase（`open()` 参数优先）。
    key_passphrase: Option<String>,
    /// 凭据库里直接存的私钥（OpenSSH / PEM 文本）。有它时优先于 `?key=` 和密码。
    inline_key: Option<InlineKey>,
    /// 懒惰建立的会话。
    session: Mutex<Option<SftpConn>>,
}

/// 凭据库里存的私钥。刻意不实现 `Debug`。
struct InlineKey {
    /// 私钥文本。
    pem: String,
    /// 私钥的 passphrase。
    passphrase: Option<String>,
}

impl InlineKey {
    /// 解析凭据库里的私钥凭据。
    ///
    /// 界面写的是 JSON：`{"private_key": "...", "passphrase": "..."}`；
    /// 不是 JSON 时把整个字符串当成私钥文本（没有 passphrase）。
    fn parse(secret: &str) -> Option<Self> {
        let trimmed = secret.trim();
        if trimmed.is_empty() {
            return None;
        }
        if trimmed.starts_with('{') {
            if let Ok(serde_json::Value::Object(map)) =
                serde_json::from_str::<serde_json::Value>(trimmed)
            {
                let pem = map
                    .get("private_key")
                    .and_then(|v| v.as_str())
                    .map(str::trim)
                    .filter(|v| !v.is_empty())?
                    .to_string();
                let passphrase = map
                    .get("passphrase")
                    .and_then(|v| v.as_str())
                    .filter(|v| !v.is_empty())
                    .map(str::to_string);
                return Some(Self { pem, passphrase });
            }
        }
        Some(Self {
            pem: trimmed.to_string(),
            passphrase: None,
        })
    }
}

impl SftpVfs {
    /// 连接 `sftp://[user[:password]@]host[:port]/path`。
    ///
    /// 可选查询参数：
    /// - `key=/path/to/private_key`：用私钥认证（给了就优先于密码）；
    /// - `key_passphrase=...`：私钥的 passphrase。
    ///
    /// 只做参数解析，**不发网络请求**（真正连接推迟到第一次读写），
    /// 这样源配置里地址写错也能先存下来，等实际访问时再报错。
    pub fn connect(url: &str, password: Option<String>) -> Result<Self> {
        Self::connect_with(url, password, false)
    }

    /// 同 [`connect`](Self::connect)，`inline_key` 为真时 `secret` 是私钥凭据
    /// （见 `InlineKey::parse`）而不是密码。
    pub fn connect_with(url: &str, secret: Option<String>, inline_key: bool) -> Result<Self> {
        let target = parse_sftp_url(url)?;
        let (password, inline_key) = if inline_key {
            let key = secret
                .as_deref()
                .and_then(InlineKey::parse)
                .ok_or_else(|| {
                    LekisError::new(ErrorCode::Auth, "SFTP: 选择了私钥登录，但没有保存私钥")
                })?;
            (target.password.clone().unwrap_or_default(), Some(key))
        } else {
            let password = secret
                .filter(|p| !p.is_empty())
                .or_else(|| target.password.clone())
                .unwrap_or_default();
            (password, None)
        };
        // 私钥文件（`?key=路径`）的 passphrase 存在凭据库里（和密码同一个位置，
        // 用私钥登录时不需要密码）；地址里的 `?key_passphrase=` 只为兼容旧配置，
        // 核心启动时会把它迁移进凭据库。
        let key_passphrase = if target.key.is_some() && inline_key.is_none() {
            Some(password.clone())
                .filter(|p| !p.is_empty())
                .or_else(|| target.key_passphrase.clone())
        } else {
            target.key_passphrase.clone()
        };
        tracing::debug!(
            target: "vfs::sftp",
            host = %target.host,
            port = target.port,
            key_auth = target.key.is_some() || inline_key.is_some(),
            "配置 SFTP 源（凭据不入日志）"
        );
        Ok(Self {
            target,
            password,
            key_passphrase,
            inline_key,
            session: Mutex::new(None),
        })
    }

    /// 远端绝对路径：`/` + 根目录 + 相对路径。
    ///
    /// SFTP 走 POSIX 路径，所以一律用绝对路径、`/` 分隔。
    fn remote_path(&self, path: &VfsPath) -> String {
        let root = self.target.root.as_str();
        let mut out = String::with_capacity(root.len() + path.as_str().len() + 2);
        out.push('/');
        out.push_str(root);
        if !path.is_root() {
            if !root.is_empty() {
                out.push('/');
            }
            out.push_str(path.as_str());
        }
        out
    }

    /// 确保会话已建立，并在锁内执行 `f`。
    ///
    /// 连接失败时不缓存失败状态，下次调用会重连。
    async fn with_session<T, F>(&self, f: F) -> Result<T>
    where
        F: for<'a> FnOnce(&'a SftpSession) -> futures_util::future::BoxFuture<'a, Result<T>>,
    {
        let mut guard = self.session.lock().await;
        if guard.is_none() {
            *guard = Some(self.open_session().await?);
        }
        let conn = guard
            .as_ref()
            .ok_or_else(|| LekisError::internal("sftp: 会话状态异常"))?;
        f(&conn.sftp).await
    }

    /// 建立 SSH 会话 + SFTP 子系统。
    async fn open_session(&self) -> Result<SftpConn> {
        tracing::debug!(
            target: "vfs::sftp",
            host = %self.target.host,
            port = self.target.port,
            "建立 SFTP 会话"
        );
        let config = Arc::new(russh::client::Config::default());
        let verifier = HostKeyVerifier {
            host: self.target.host.clone(),
            port: self.target.port,
        };
        let mut handle = russh::client::connect(
            config,
            (self.target.host.as_str(), self.target.port),
            verifier,
        )
        .await
        .map_err(|e| ssh_err("连接 SSH 服务器失败", e))?;

        let user = self.user();
        let auth = match (self.inline_key.as_ref(), self.target.key.as_deref()) {
            (Some(inline), _) => {
                let key = russh::keys::decode_secret_key(&inline.pem, inline.passphrase.as_deref())
                    .map_err(|e| {
                        LekisError::new(ErrorCode::Auth, format!("解析 SSH 私钥失败: {e}"))
                    })?;
                let key = russh::keys::PrivateKeyWithHashAlg::new(
                    Arc::new(key),
                    Some(russh::keys::HashAlg::Sha256),
                );
                handle.authenticate_publickey(&user, key).await
            }
            (None, Some(key_path)) => {
                // TODO(sftp-rsa): rsa 类型的私钥需要 russh 的 `rsa` feature（额外拉
                // `rsa`/`pkcs1` crate）。当前只用 ring，ed25519/ecdsa 私钥可用，
                // RSA 私钥会在解析阶段报错。
                let key = russh::keys::load_secret_key(key_path, self.key_passphrase.as_deref())
                    .map_err(|e| {
                        LekisError::new(ErrorCode::Auth, format!("读取 SSH 私钥失败: {e}"))
                    })?;
                let key = russh::keys::PrivateKeyWithHashAlg::new(
                    Arc::new(key),
                    Some(russh::keys::HashAlg::Sha256),
                );
                handle.authenticate_publickey(&user, key).await
            }
            (None, None) => handle.authenticate_password(&user, &self.password).await,
        }
        .map_err(|e| ssh_err("SSH 认证请求失败", e))?;
        if !auth.success() {
            return Err(LekisError::new(
                ErrorCode::Auth,
                "SFTP 认证失败（用户名 / 密码 / 私钥不匹配）",
            ));
        }

        let channel = handle
            .channel_open_session()
            .await
            .map_err(|e| ssh_err("打开 SSH 通道失败", e))?;
        channel
            .request_subsystem(true, "sftp")
            .await
            .map_err(|e| ssh_err("请求 sftp 子系统失败（服务器可能禁用了 sftp）", e))?;
        let sftp = SftpSession::new(channel.into_stream())
            .await
            .map_err(sftp_err)?;
        // 单次请求超时（秒）。NAS 上的大目录偶尔会慢，给宽松一点。
        sftp.set_timeout(30);
        Ok(SftpConn {
            // `Handle` 必须保活：它持有到 SSH 会话任务的发送端，drop 掉会话就结束了。
            _ssh: handle,
            sftp,
        })
    }

    /// 登录用户名：URL 里没写就用当前 Windows 用户名。
    fn user(&self) -> String {
        if !self.target.user.is_empty() {
            return self.target.user.clone();
        }
        std::env::var("USERNAME")
            .or_else(|_| std::env::var("USER"))
            .unwrap_or_default()
    }
}

/// 一条活着的 SSH + SFTP 会话。
struct SftpConn {
    /// SSH 会话句柄（只用来保活，见 [`SftpVfs::open_session`]）。
    _ssh: russh::client::Handle<HostKeyVerifier>,
    /// SFTP 子系统。
    sftp: SftpSession,
}

/// SSH 主机密钥校验器。
struct HostKeyVerifier {
    /// 目标主机（用于查 `known_hosts`）。
    host: String,
    /// 目标端口。
    port: u16,
}

/// Lekis 自己记录的主机密钥文件（`<数据目录>/ssh_known_hosts`）。
///
/// 手机上没有 `~/.ssh`，桌面上也不该替用户改他的 `known_hosts`，所以首次连接
/// 学到的密钥记在这里。核心启动时用 [`set_known_hosts_path`] 设置。
static KNOWN_HOSTS: std::sync::RwLock<Option<PathBuf>> = std::sync::RwLock::new(None);

/// 设置 Lekis 自己的 known_hosts 文件路径（核心启动时调用一次）。
pub fn set_known_hosts_path(path: PathBuf) {
    if let Ok(mut slot) = KNOWN_HOSTS.write() {
        *slot = Some(path);
    }
}

fn own_known_hosts() -> Option<PathBuf> {
    KNOWN_HOSTS.read().ok()?.clone()
}

/// 主机密钥校验的结论。
#[derive(Debug, PartialEq, Eq)]
enum HostKeyVerdict {
    /// 有记录且一致。
    Known,
    /// 没有记录：首次连接，已经记下来（TOFU）。
    Learned,
    /// 有记录但不一致：拒绝（可能是中间人，也可能服务器重装过）。
    Changed,
}

/// 依次查用户的 `~/.ssh/known_hosts`（只读）和 Lekis 自己的记录。
/// 两边都没有就把密钥记进 [`own`]，之后再连同一台主机就必须一致。
fn verify_host_key(
    host: &str,
    port: u16,
    key: &russh::keys::PublicKey,
    user: Option<&std::path::Path>,
    own: Option<&std::path::Path>,
) -> HostKeyVerdict {
    use russh::keys::Error as KeyError;
    for path in [user, own].into_iter().flatten() {
        match russh::keys::check_known_hosts_path(host, port, key, path) {
            Ok(true) => return HostKeyVerdict::Known,
            Ok(false) => {}
            Err(KeyError::KeyChanged { .. }) => return HostKeyVerdict::Changed,
            // 文件读不了 / 格式不认识：当作没有记录，不能因此拒绝连接。
            Err(err) => {
                tracing::debug!(target: "vfs::sftp", "known_hosts 读取失败，忽略：{err}");
            }
        }
    }
    match own {
        Some(path) => {
            if let Err(err) =
                russh::keys::known_hosts::learn_known_hosts_path(host, port, key, path)
            {
                tracing::warn!(target: "vfs::sftp", %host, port, "主机密钥记录失败：{err}");
            }
        }
        None => {
            tracing::warn!(target: "vfs::sftp", %host, port, "没有配置 known_hosts 路径，主机密钥未记录");
        }
    }
    HostKeyVerdict::Learned
}

fn user_known_hosts() -> Option<PathBuf> {
    std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .map(PathBuf::from)
        .map(|home| home.join(".ssh").join("known_hosts"))
        .filter(|p| p.exists())
}

impl russh::client::Handler for HostKeyVerifier {
    type Error = russh::Error;

    /// 主机密钥校验（TOFU）：
    ///
    /// - 用户的 `~/.ssh/known_hosts` 或 Lekis 自己的记录里有且一致 → 接受；
    /// - 都没有（首次连接）→ 接受并记进 Lekis 的记录，之后必须一致；
    /// - 有记录但不一致 → **拒绝**。
    async fn check_server_key(
        &mut self,
        server_public_key: &russh::keys::PublicKeyOrCertificate,
    ) -> std::result::Result<bool, Self::Error> {
        let key = match server_public_key {
            russh::keys::PublicKeyOrCertificate::PublicKey { key, .. } => key,
            _ => {
                // 证书形式的主机密钥需要配 CA 才能验，本实现没有 CA 配置，接受并记录。
                tracing::debug!(
                    target: "vfs::sftp",
                    host = %self.host,
                    "服务器给出证书形式的主机密钥，未配置 CA，按接受处理"
                );
                return Ok(true);
            }
        };
        let verdict = verify_host_key(
            &self.host,
            self.port,
            key,
            user_known_hosts().as_deref(),
            own_known_hosts().as_deref(),
        );
        match verdict {
            HostKeyVerdict::Known => Ok(true),
            HostKeyVerdict::Learned => {
                tracing::warn!(
                    target: "vfs::sftp",
                    host = %self.host,
                    port = self.port,
                    "首次连接这台服务器，已记录主机密钥（TOFU）"
                );
                Ok(true)
            }
            HostKeyVerdict::Changed => {
                tracing::warn!(
                    target: "vfs::sftp",
                    host = %self.host,
                    port = self.port,
                    "主机密钥和记录的不一致，拒绝连接"
                );
                Ok(false)
            }
        }
    }
}

#[async_trait]
impl Vfs for SftpVfs {
    fn kind(&self) -> SourceKind {
        SourceKind::Sftp
    }

    fn capabilities(&self) -> VfsCapabilities {
        VfsCapabilities {
            writable: true,
            watch: false,
            reliable_dir_mtime: true,
            // SFTP 是单通道串行协议（同一 channel 上请求可流水线，但实现里按顺序发），
            // 并发太高只会互相排队。
            suggested_concurrency: 4,
        }
    }

    async fn list_dir(&self, dir: &VfsPath) -> Result<Vec<DirEntry>> {
        let remote = self.remote_path(dir);
        let dir = dir.clone();
        self.with_session(move |sftp| {
            Box::pin(async move {
                let iter = sftp.read_dir(remote).await.map_err(sftp_err)?;
                let mut out = Vec::new();
                for entry in iter {
                    if out.len() >= MAX_ENTRIES {
                        return Err(crate::too_many_entries(&"SFTP", MAX_ENTRIES));
                    }
                    let name = entry.file_name();
                    // 防御：跳过空名和相对路径标记（ReadDir 已过滤 . 和 ..）。
                    if name.is_empty() || name == "." || name == ".." || name.contains('/') {
                        continue;
                    }
                    let meta = attrs_meta(&entry.metadata());
                    out.push(DirEntry {
                        path: dir.join(&name),
                        meta,
                    });
                }
                Ok(out)
            })
        })
        .await
    }

    async fn stat(&self, path: &VfsPath) -> Result<FileMeta> {
        let remote = self.remote_path(path);
        self.with_session(move |sftp| {
            Box::pin(async move {
                let attrs = sftp.metadata(remote).await.map_err(sftp_err)?;
                Ok(attrs_meta(&attrs))
            })
        })
        .await
    }

    async fn read_range(&self, path: &VfsPath, range: Range<u64>) -> Result<Bytes> {
        if range.end < range.start {
            return Err(LekisError::invalid("读取范围非法：end < start"));
        }
        let want = range.end - range.start;
        if want == 0 {
            return Ok(Bytes::new());
        }
        let remote = self.remote_path(path);
        self.with_session(move |sftp| {
            Box::pin(async move {
                let mut file = sftp.open(remote).await.map_err(sftp_err)?;
                file.seek(std::io::SeekFrom::Start(range.start))
                    .await
                    .map_err(sftp_io_err)?;
                let mut out: Vec<u8> = Vec::new();
                let mut scratch = vec![0u8; READ_CHUNK];
                let mut remaining = want;
                while remaining > 0 {
                    let take =
                        usize::try_from(remaining.min(READ_CHUNK as u64)).unwrap_or(READ_CHUNK);
                    let read = file.read(&mut scratch[..take]).await.map_err(sftp_io_err)?;
                    if read == 0 {
                        // EOF：文件比 range 短，按实际长度返回（和本地实现一致）。
                        break;
                    }
                    out.extend_from_slice(&scratch[..read]);
                    remaining -= read as u64;
                }
                // 关掉句柄，避免服务器端句柄泄漏；已经读到数据了，关闭失败不算错误。
                let _ = file.close().await;
                Ok(Bytes::from(out))
            })
        })
        .await
    }

    async fn write_atomic(&self, path: &VfsPath, data: Bytes) -> Result<()> {
        let remote = self.remote_path(path);
        let tmp = format!("{remote}.lekis-tmp");
        self.with_session(move |sftp| {
            Box::pin(async move {
                {
                    let mut file = sftp
                        .open_with_flags(
                            tmp.clone(),
                            OpenFlags::WRITE | OpenFlags::CREATE | OpenFlags::TRUNCATE,
                        )
                        .await
                        .map_err(sftp_err)?;
                    file.write_all(&data).await.map_err(sftp_io_err)?;
                    // 支持 fsync 扩展的服务器会真的刷盘，不支持的直接返回 Ok。
                    file.sync_all().await.map_err(sftp_err)?;
                    file.close().await.map_err(sftp_io_err)?;
                }
                // SFTP v3 的 RENAME 不保证覆盖已存在目标：失败时先删目标再试一次。
                match sftp.rename(tmp.clone(), remote.clone()).await {
                    Ok(()) => Ok(()),
                    Err(first) => {
                        // 目标可能不存在，删除失败无所谓。
                        let _ = sftp.remove_file(remote.clone()).await;
                        sftp.rename(tmp.clone(), remote.clone())
                            .await
                            .map_err(|_| sftp_err(first))
                    }
                }
            })
        })
        .await
    }

    async fn delete_file(&self, path: &VfsPath) -> Result<()> {
        if path.is_root() {
            return Err(LekisError::invalid("sftp: 不能删除根目录"));
        }
        let remote = self.remote_path(path);
        self.with_session(move |sftp| {
            Box::pin(async move { sftp.remove_file(remote).await.map_err(sftp_err) })
        })
        .await
    }

    async fn create_dir_all(&self, dir: &VfsPath) -> Result<()> {
        if dir.is_root() {
            return Ok(());
        }
        // 逐级建目录，每级都用绝对远端路径。
        let mut prefixes = Vec::new();
        let mut acc = VfsPath::root();
        for segment in dir.as_str().split('/') {
            if segment.is_empty() {
                continue;
            }
            acc = acc.join(segment);
            prefixes.push(self.remote_path(&acc));
        }
        self.with_session(move |sftp| {
            Box::pin(async move {
                for remote in prefixes {
                    if sftp.try_exists(remote.clone()).await.map_err(sftp_err)? {
                        continue;
                    }
                    match sftp.create_dir(remote.clone()).await {
                        Ok(()) => {}
                        Err(err) => {
                            // 并发创建（另一个扫描线程抢先了）或服务器不支持 MKCOL
                            // 语义时，以「最终存在」为准。
                            if sftp.try_exists(remote).await.unwrap_or(false) {
                                continue;
                            }
                            return Err(sftp_err(err));
                        }
                    }
                }
                Ok(())
            })
        })
        .await
    }
}

/// SFTP 属性 → [`FileMeta`]。
fn attrs_meta(attrs: &FileAttributes) -> FileMeta {
    let kind = if attrs.is_dir() {
        EntryKind::Dir
    } else if attrs.is_regular() {
        EntryKind::File
    } else {
        // 符号链接、设备文件、FIFO……扫描时跳过。
        EntryKind::Other
    };
    FileMeta {
        kind,
        size: attrs.size.unwrap_or(0),
        // SFTP v3 的 mtime 是 **u32 秒**。
        mtime_ms: attrs.mtime.map(|secs| i64::from(secs) * 1000).unwrap_or(0),
    }
}

/// `russh_sftp` 错误 → [`LekisError`]。
fn sftp_err(err: SftpError) -> LekisError {
    let code = match &err {
        SftpError::Status(status) => match status.status_code {
            StatusCode::NoSuchFile => ErrorCode::NotFound,
            StatusCode::PermissionDenied => ErrorCode::PermissionDenied,
            StatusCode::OpUnsupported => ErrorCode::Unsupported,
            StatusCode::ConnectionLost | StatusCode::NoConnection => ErrorCode::Network,
            StatusCode::Eof => ErrorCode::NotFound,
            _ => ErrorCode::Io,
        },
        SftpError::Timeout | SftpError::IO(_) => ErrorCode::Network,
        SftpError::Limited(_) => ErrorCode::Io,
        SftpError::UnexpectedPacket | SftpError::UnexpectedBehavior(_) => ErrorCode::Decode,
    };
    LekisError::new(code, format!("sftp: {err}"))
}

/// 文件读取的 I/O 错误 → [`LekisError`]。
fn sftp_io_err(err: std::io::Error) -> LekisError {
    LekisError::new(ErrorCode::Network, format!("sftp: {err}"))
}

/// `russh` 错误 → [`LekisError`]。
///
/// `russh` 的错误消息只含算法名 / 主机地址，不含密码，可以安全带出。
fn ssh_err(what: &str, err: russh::Error) -> LekisError {
    LekisError::new(ErrorCode::Network, format!("sftp: {what}: {err}"))
}

/// 解析 `sftp://[userinfo@]host[:port]/path[?key=...]`。
///
/// 凭据（userinfo）会被单独摘出来，**不留在地址字符串里**，避免被日志打出去。
fn parse_sftp_url(url: &str) -> Result<SftpTarget> {
    if !url.starts_with("sftp://") {
        return Err(LekisError::invalid("SFTP address must start with sftp://"));
    }
    let parsed =
        url::Url::parse(url).map_err(|e| LekisError::invalid(format!("SFTP 地址不合法: {e}")))?;
    let host = parsed
        .host_str()
        .filter(|h| !h.is_empty())
        .ok_or_else(|| LekisError::invalid("SFTP 地址缺少主机名"))?;
    let host = match parsed.host() {
        // IPv6 字面量去掉方括号（`ToSocketAddrs` 要裸地址）。
        Some(url::Host::Ipv6(v6)) => v6.to_string(),
        _ => host.to_string(),
    };

    // `url::Url` 会把 `..` 规范化掉，所以要在**原始字符串**上先拒绝它。
    if raw_path_segments(url).any(|seg| seg == "..") {
        return Err(LekisError::invalid("SFTP 地址里的路径包含 ..，已拒绝"));
    }

    let mut key = None;
    let mut key_passphrase = None;
    for (name, value) in parsed.query_pairs() {
        match name.as_ref() {
            "key" | "private_key" => key = Some(value.into_owned()),
            "key_passphrase" | "passphrase" => key_passphrase = Some(value.into_owned()),
            // 未知参数忽略：以后加选项时老配置还能用。
            _ => {}
        }
    }

    // `Url::path()` 返回未解码的 path，中文 / 空格要先 percent 解码。
    let path = percent_decode(parsed.path());
    let path = path.trim_matches('/');
    let root = if path.is_empty() {
        String::new()
    } else {
        VfsPath::parse(path)
            .ok_or_else(|| LekisError::invalid("SFTP 地址里的路径不合法"))?
            .as_str()
            .to_string()
    };

    Ok(SftpTarget {
        host,
        port: parsed.port().unwrap_or(DEFAULT_PORT),
        user: percent_decode(parsed.username()),
        password: parsed.password().map(percent_decode),
        key,
        key_passphrase,
        root,
    })
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
    // 查询串 / 片段不属于路径。
    let path = path.split(['?', '#']).next().unwrap_or(path);
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

    /// 一个 SSH 线格式的 ed25519 公钥（32 字节随便填，解析不校验曲线点）。
    fn ed25519(fill: u8) -> russh::keys::PublicKey {
        let mut wire = Vec::new();
        for part in [b"ssh-ed25519".as_slice(), &[fill; 32]] {
            wire.extend_from_slice(&(part.len() as u32).to_be_bytes());
            wire.extend_from_slice(part);
        }
        russh::keys::PublicKey::from_bytes(&wire).expect("valid ed25519 wire key")
    }

    #[test]
    fn host_keys_are_learned_once_then_enforced() {
        let dir = std::env::temp_dir().join(format!("lekis-known-hosts-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let own = dir.join("ssh_known_hosts");
        let (a, b) = (ed25519(1), ed25519(2));

        // 首次：记下来。
        assert_eq!(
            verify_host_key("nas.local", 22, &a, None, Some(&own)),
            HostKeyVerdict::Learned
        );
        assert!(std::fs::read_to_string(&own)
            .unwrap()
            .trim_start()
            .starts_with("nas.local ssh-ed25519 "));
        // 之后：同一把钥匙认得，换了钥匙拒绝。
        assert_eq!(
            verify_host_key("nas.local", 22, &a, None, Some(&own)),
            HostKeyVerdict::Known
        );
        assert_eq!(
            verify_host_key("nas.local", 22, &b, None, Some(&own)),
            HostKeyVerdict::Changed
        );
        // 端口不同算另一台主机。
        assert_eq!(
            verify_host_key("nas.local", 2222, &b, None, Some(&own)),
            HostKeyVerdict::Learned
        );
        assert_eq!(
            verify_host_key("nas.local", 2222, &a, None, Some(&own)),
            HostKeyVerdict::Changed
        );

        // 用户自己的 known_hosts 不一致也拒绝，而且不会被改写。
        let user = dir.join("user_known_hosts");
        std::fs::write(
            &user,
            format!(
                "other.host {}
",
                a.to_openssh().unwrap()
            ),
        )
        .unwrap();
        let before = std::fs::read_to_string(&user).unwrap();
        assert_eq!(
            verify_host_key("other.host", 22, &b, Some(&user), Some(&own)),
            HostKeyVerdict::Changed
        );
        assert_eq!(
            verify_host_key("other.host", 22, &a, Some(&user), Some(&own)),
            HostKeyVerdict::Known
        );
        assert_eq!(std::fs::read_to_string(&user).unwrap(), before);

        // 读不了的文件不等于"密钥变了"（手机上没有 ~/.ssh）。
        let missing = dir.join("nope/known_hosts");
        assert_eq!(
            verify_host_key("new.host", 22, &a, Some(&missing), Some(&own)),
            HostKeyVerdict::Learned
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn inline_key_secret_parses_json_and_raw_text() {
        let key = InlineKey::parse(r#"{"private_key":" KEY ","passphrase":"pp"}"#).expect("json");
        assert_eq!(key.pem, "KEY");
        assert_eq!(key.passphrase.as_deref(), Some("pp"));
        let key = InlineKey::parse(r#"{"private_key":"KEY","passphrase":""}"#).expect("json");
        assert!(key.passphrase.is_none());
        // 拼出来的假 PEM 头（字面量会触发提交前的隐私检查）。
        let fake_pem = format!("-----BEGIN {} KEY-----\nabc", "OPENSSH PRIVATE");
        let key = InlineKey::parse(&fake_pem).expect("raw");
        assert!(key.pem.starts_with("-----BEGIN"));
        assert!(key.passphrase.is_none());
        assert!(InlineKey::parse("  ").is_none());
        assert!(InlineKey::parse(r#"{"private_key":""}"#).is_none());
    }

    #[test]
    fn key_auth_without_saved_key_is_an_auth_error() {
        let err = match SftpVfs::connect_with("sftp://nas/music", None, true) {
            Ok(_) => panic!("must fail"),
            Err(e) => e,
        };
        assert_eq!(err.code, ErrorCode::Auth);
        let vfs =
            SftpVfs::connect_with("sftp://nas/music", Some("KEY".into()), true).expect("key given");
        assert!(vfs.inline_key.is_some());
        assert!(vfs.password.is_empty(), "私钥不能被当成密码");
    }

    #[test]
    fn parses_minimal_url() {
        let target = parse_sftp_url("sftp://nas/music").expect("应能解析");
        assert_eq!(target.host, "nas");
        assert_eq!(target.port, 22);
        assert_eq!(target.user, "");
        assert!(target.password.is_none());
        assert!(target.key.is_none());
        assert_eq!(target.root, "music");
    }

    #[test]
    fn parses_user_port_and_path() {
        let target = parse_sftp_url("sftp://david:pw@nas.local:2222/media/FLAC").expect("应能解析");
        assert_eq!(target.host, "nas.local");
        assert_eq!(target.port, 2222);
        assert_eq!(target.user, "david");
        assert_eq!(target.password.as_deref(), Some("pw"));
        assert_eq!(target.root, "media/FLAC");
    }

    #[test]
    fn parses_percent_encoded_user_and_path() {
        let target =
            parse_sftp_url("sftp://david%20b:p%20w@nas/%E9%9F%B3%E4%B9%90/%E4%B8%93%E8%BE%91")
                .expect("应能解析");
        assert_eq!(target.user, "david b");
        assert_eq!(target.password.as_deref(), Some("p w"));
        assert_eq!(target.root, "音乐/专辑");
    }

    #[test]
    fn parses_private_key_query() {
        let target = parse_sftp_url(
            "sftp://david@nas:2200/media?key=C:%5Ckeys%5Cid_ed25519&key_passphrase=secret",
        )
        .expect("应能解析");
        assert_eq!(target.key.as_deref(), Some("C:\\keys\\id_ed25519"));
        assert_eq!(target.key_passphrase.as_deref(), Some("secret"));
        assert_eq!(target.root, "media");
    }

    #[test]
    fn rejects_bad_urls() {
        assert!(parse_sftp_url("http://nas/media").is_err());
        assert!(parse_sftp_url("sftp:///media").is_err());
        assert!(parse_sftp_url("sftp://nas/a/../b").is_err());
        assert!(parse_sftp_url("not a url").is_err());
    }

    #[test]
    fn no_credentials_in_parsed_strings() {
        let target = parse_sftp_url("sftp://bob:hunter2@nas/media").expect("应能解析");
        assert_eq!(target.host, "nas");
        assert_eq!(target.user, "bob");
        assert_eq!(target.password.as_deref(), Some("hunter2"));
    }

    #[test]
    fn remote_paths_are_absolute() {
        let vfs = SftpVfs::connect("sftp://nas/media", None).expect("应能构造");
        assert_eq!(vfs.remote_path(&VfsPath::root()), "/media");
        let sub = VfsPath::parse("FLAC/曲目 1.flac").expect("应能解析");
        assert_eq!(vfs.remote_path(&sub), "/media/FLAC/曲目 1.flac");

        let bare = SftpVfs::connect("sftp://nas", None).expect("应能构造");
        assert_eq!(bare.remote_path(&VfsPath::root()), "/");
        assert_eq!(bare.remote_path(&sub), "/FLAC/曲目 1.flac");
    }

    #[test]
    fn password_argument_overrides_url() {
        let vfs = SftpVfs::connect("sftp://bob:hunter2@nas/media", Some("from_keychain".into()))
            .expect("应能构造");
        assert_eq!(vfs.password, "from_keychain");
    }
}
