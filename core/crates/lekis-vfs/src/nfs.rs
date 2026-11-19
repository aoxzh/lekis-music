//! NFSv3（SRC-08，P1）：基于 `nfs3_client` 的纯 Rust 实现。
//!
//! 覆盖 Linux NAS（群晖的 NFS 导出、TrueNAS、OpenMediaVault……）和各类
//! 内网文件服务器。只做 **NFSv3**：v4 的协议完全不一样（有会话、有 OPEN/CLOSE），
//! 这个 crate 不支持，真遇到 v4-only 的服务器需要另找库。
//!
//! 要点：
//! - **地址**：`nfs://host[:port]/export[/path]`。URL 的整个路径部分就是服务器上的
//!   **导出路径**（NFS 的导出名由服务器定义，客户端无从推断），挂载成功后 VFS 根就是它。
//! - **host 必须是 IP 或可解析的主机名**：`nfs3_client` 内部用 `host.parse::<IpAddr>()`
//!   去连 portmapper，主机名会直接报错。所以这里在建立连接时自己先做一次 DNS 解析。
//! - **端口**：默认走 portmapper（111）问 mountd 和 nfsd 的端口；`?pmport=` /
//!   `?mountport=` / `?nfsport=` 可以手动指定（防火墙只放行固定端口时有用）。
//! - **特权端口**：库默认从 300-1023 的本地端口发起连接（NFS 服务器常要求
//!   `insecure` 或特权端口），Windows 上普通用户绑不了低端口，所以**默认关掉**，
//!   需要时用 `?privileged=1` 打开（Linux/Android 上有 root 才行）。
//! - **认证**：AUTH_NULL（匿名）。NFS 的 AUTH_UNIX 要自己拼 uid/gid 列表，
//!   `nfs3_client` 只暴露 `credential: opaque_auth`，暂不实现（见 `TODO(nfs-auth)`）。
//! - **凭据不进日志**：NFSv3 本身没有密码，tracing 只输出主机和导出路径。
//!
//! 读写实现说明：
//! - `list_dir` 用 `READDIRPLUS`：一次调用就把每个条目的属性带回来，省掉 N 次 `GETATTR`。
//!   服务器不支持时会退化成 `READDIR` + 逐条 `GETATTR`。
//! - `read_range` 按 `NFS_MAXDATA` 上限分块循环读（一次最多几 MB）。
//! - `write_atomic` 是「新建临时文件 → 分块 WRITE → COMMIT → RENAME 覆盖」，
//!   NFSv3 的 `RENAME` 具备 POSIX 语义，目标已存在时会被原子替换。
//! - `create_dir_all` 逐级 `MKDIR`，服务器回 `NFS3ERR_EXIST` 就当成功。

use crate::{DirEntry, EntryKind, FileMeta, Vfs, VfsCapabilities, VfsPath};
use async_trait::async_trait;
use bytes::Bytes;
use lekis_types::{ErrorCode, LekisError, Result, SourceKind};
use nfs3_client::nfs3_types::nfs3;
use nfs3_client::nfs3_types::nfs3::{
    fattr3, filename3, ftype3, nfs_fh3, nfsstat3, stable_how, Nfs3Option,
};
use nfs3_client::nfs3_types::xdr_codec::Opaque;
use nfs3_client::tokio::{TokioConnector, TokioIo};
use nfs3_client::{ConnectError, Nfs3Connection, Nfs3ConnectionBuilder, RpcError};
use std::ops::Range;
use tokio::net::TcpStream;
use tokio::sync::Mutex;

/// portmapper 的默认端口（RFC 1057 里写死的 111）。
const PMAP_PORT: u16 = 111;

/// 单次 `READ` 的最大字节数。NFSv3 服务器一般只接受 32 KiB ~ 1 MiB，
/// 超出会在协议层被截断成一次短读，所以这里取 1 MiB 并靠循环补满。
const READ_CHUNK: usize = 1024 * 1024;

/// 单次 `WRITE` 的最大字节数。和 `READ_CHUNK` 同理，NFS 的 `wtmax` 常见是 64 KiB。
const WRITE_CHUNK: usize = 256 * 1024;

/// `READDIRPLUS` 一次性请求的目录项字节数。太小会需要很多轮，太大会被服务器拒绝。
const READDIR_COUNT: u32 = 64 * 1024;

/// 单个目录最多返回多少个条目（防御性上限，防止服务器 cookie 不前进时死循环）。
const MAX_ENTRIES: usize = 200_000;

/// NFS 源的连接参数。
///
/// 刻意不实现 `Debug`：虽然 NFSv3 没有密码，但导出路径也可能算内部信息，
/// 需要打印时用下面这些明确的字段。
#[derive(Clone, PartialEq, Eq)]
struct NfsTarget {
    /// 主机名或 IP 字面量（不带端口）。
    host: String,
    /// portmapper 端口（默认 111）。
    pmap_port: u16,
    /// mountd 端口（`None` 表示问 portmapper）。
    mount_port: Option<u16>,
    /// nfsd 端口（`None` 表示问 portmapper）。
    nfs_port: Option<u16>,
    /// 服务器上的导出路径，形如 `/volume1/music`。
    export: String,
    /// 是否从特权端口（300-1023）发起连接。
    privileged: bool,
}

/// NFS 文件系统。
pub struct NfsVfs {
    /// 连接参数。
    target: NfsTarget,
    /// 懒惰建立的会话。
    session: Mutex<Option<NfsSession>>,
}

/// 建立好的一对 RPC 连接。
struct NfsSession {
    /// mountd + nfsd 连接，`Deref` 到 `Nfs3Client`。
    conn: Nfs3Connection<TokioIo<TcpStream>>,
    /// 导出根目录的文件句柄。
    root: nfs_fh3,
}

impl NfsVfs {
    /// 连接 `nfs://host[:port]/export[/path]`。
    ///
    /// 可选查询参数：
    /// - `pmport=111`：portmapper 端口；
    /// - `mountport=xxx`、`nfsport=xxx`：跳过 portmapper 直接指定端口；
    /// - `privileged=1`：从特权端口发起连接（需要 root/管理员）。
    ///
    /// 只做参数解析，**不发网络请求**（真正挂载推迟到第一次访问）。
    pub fn connect(url: &str) -> Result<Self> {
        let target = parse_nfs_url(url)?;
        tracing::debug!(
            target: "vfs::nfs",
            host = %target.host,
            export = %target.export,
            pmap_port = target.pmap_port,
            "配置 NFS 源"
        );
        Ok(Self {
            target,
            session: Mutex::new(None),
        })
    }

    /// 取得会话；没有就建立一个。
    ///
    /// 失败不缓存：下次调用会重新挂载，避免一次网络抖动让源永久失效。
    async fn with_session<T, F>(&self, f: F) -> Result<T>
    where
        F: for<'a> FnOnce(
            &'a mut Nfs3Connection<TokioIo<TcpStream>>,
            &'a nfs_fh3,
        ) -> futures_util::future::BoxFuture<'a, Result<T>>,
    {
        let mut guard = self.session.lock().await;
        if guard.is_none() {
            *guard = Some(self.mount().await?);
        }
        let session = match guard.as_mut() {
            Some(s) => s,
            None => {
                return Err(LekisError::internal("NFS 会话在挂载后消失"));
            }
        };
        f(&mut session.conn, &session.root).await
    }

    /// 真正去 mountd 那里挂载导出目录，并记下根文件句柄。
    async fn mount(&self) -> Result<NfsSession> {
        let host = resolve_host(&self.target.host, self.target.pmap_port).await?;

        let mut builder =
            Nfs3ConnectionBuilder::new(TokioConnector, host.as_str(), &self.target.export)
                .portmapper_port(self.target.pmap_port)
                .connect_from_privileged_port(self.target.privileged);
        if let Some(port) = self.target.mount_port {
            builder = builder.mount_port(port);
        }
        if let Some(port) = self.target.nfs_port {
            builder = builder.nfs3_port(port);
        }

        let conn = builder.mount().await.map_err(connect_err)?;
        let root = conn.root_nfs_fh3();
        tracing::debug!(
            target: "vfs::nfs",
            host = %self.target.host,
            export = %self.target.export,
            nfs_port = conn.nfs3_port,
            "NFS 导出挂载成功"
        );
        Ok(NfsSession { conn, root })
    }
}

#[async_trait]
impl Vfs for NfsVfs {
    fn kind(&self) -> SourceKind {
        SourceKind::Nfs
    }

    fn capabilities(&self) -> VfsCapabilities {
        VfsCapabilities {
            writable: true,
            watch: false,
            // NFS 的目录 mtime 由服务器维护，是可靠的。
            reliable_dir_mtime: true,
            // RPC 是「一问一答」的，并发太高只会排在同一对 socket 上。
            suggested_concurrency: 8,
        }
    }

    async fn list_dir(&self, dir: &VfsPath) -> Result<Vec<DirEntry>> {
        let dir = dir.clone();
        self.with_session(move |conn, root| {
            Box::pin(async move {
                let fh = resolve_fh(conn, root, &dir).await?;
                let attrs = getattr(conn, &fh).await?;
                if attrs.type_ != ftype3::NF3DIR {
                    return Err(LekisError::invalid(format!("NFS: {dir} 不是目录")));
                }
                // READDIRPLUS 一次带回属性；服务器不支持时降到 READDIR + GETATTR。
                let mut entries = match readdir_plus(conn, &fh).await {
                    Ok(entries) => entries
                        .into_iter()
                        .map(|(name, meta)| DirEntry {
                            path: dir.join(&name),
                            meta,
                        })
                        .collect::<Vec<_>>(),
                    Err(LekisError {
                        code: ErrorCode::Unsupported,
                        ..
                    }) => {
                        let names = readdir_plain(conn, &fh).await?;
                        let mut out = Vec::with_capacity(names.len());
                        for name in names {
                            // 只对子目录名做 lookup，避免拼出多余前缀。
                            let child_name = name.as_str();
                            let child_fh = lookup(conn, &fh, child_name).await?;
                            let child_attrs = getattr(conn, &child_fh).await?;
                            out.push(DirEntry {
                                path: dir.join(child_name),
                                meta: fattr_meta(&child_attrs),
                            });
                        }
                        out
                    }
                    Err(e) => return Err(e),
                };
                entries.sort_by(|a, b| a.path.cmp(&b.path));
                Ok(entries)
            })
        })
        .await
    }

    async fn stat(&self, path: &VfsPath) -> Result<FileMeta> {
        let path = path.clone();
        self.with_session(move |conn, root| {
            Box::pin(async move {
                let fh = resolve_fh(conn, root, &path).await?;
                let attrs = getattr(conn, &fh).await?;
                Ok(fattr_meta(&attrs))
            })
        })
        .await
    }

    async fn read_range(&self, path: &VfsPath, range: Range<u64>) -> Result<Bytes> {
        if range.end < range.start {
            return Err(LekisError::invalid(format!(
                "NFS: 非法区间 {}..{}",
                range.start, range.end
            )));
        }
        let want = range.end - range.start;
        if want == 0 {
            return Ok(Bytes::new());
        }
        let path = path.clone();
        self.with_session(move |conn, root| {
            Box::pin(async move {
                let fh = resolve_fh(conn, root, &path).await?;
                let mut out = Vec::with_capacity(usize::try_from(want).unwrap_or(0).min(8 << 20));
                let mut pos = range.start;
                let end = range.end;
                while pos < end {
                    let chunk =
                        usize::try_from((end - pos).min(READ_CHUNK as u64)).unwrap_or(READ_CHUNK);
                    let args = nfs3::READ3args {
                        file: fh.clone(),
                        offset: pos,
                        count: u32::try_from(chunk).unwrap_or(u32::MAX),
                    };
                    let res = conn.read(&args).await.map_err(rpc_err)?;
                    let ok = match res {
                        nfs3::Nfs3Result::Ok(ok) => ok,
                        nfs3::Nfs3Result::Err((code, _)) => {
                            // 越界读 NFS 也回 NFS3_OK + eof，所以走到这里一定是真错误。
                            return Err(nfsstat_err(code, "read"));
                        }
                    };
                    let data = ok.data.to_vec();
                    if data.is_empty() {
                        break;
                    }
                    pos += data.len() as u64;
                    out.extend_from_slice(&data);
                    if ok.eof || out.len() as u64 >= want {
                        break;
                    }
                }
                out.truncate(usize::try_from(want).unwrap_or(out.len()));
                Ok(Bytes::from(out))
            })
        })
        .await
    }

    async fn write_atomic(&self, path: &VfsPath, data: Bytes) -> Result<()> {
        let path = path.clone();
        self.with_session(move |conn, root| {
            Box::pin(async move {
                let parent = path.parent().unwrap_or_else(VfsPath::root);
                let name = path
                    .file_name()
                    .ok_or_else(|| LekisError::invalid(format!("NFS: 目标不是文件：{path}")))?;
                let parent_fh = resolve_fh(conn, root, &parent).await?;

                // 1) 在同一个目录里建临时文件（同目录才能保证 rename 是原子的）。
                let tmp_name = format!("{name}.lekis-tmp");
                let create = nfs3::CREATE3args {
                    where_: nfs3::diropargs3 {
                        dir: parent_fh.clone(),
                        name: nfs_name(&tmp_name),
                    },
                    // UNCHECKED：存在就截断，不存在就新建。
                    how: nfs3::createhow3::UNCHECKED(nfs3::sattr3 {
                        size: Nfs3Option::Some(0),
                        ..Default::default()
                    }),
                };
                let created = conn.create(&create).await.map_err(rpc_err)?;
                let file_fh = match created {
                    nfs3::Nfs3Result::Ok(ok) => match ok.obj {
                        Nfs3Option::Some(fh) => fh,
                        Nfs3Option::None => {
                            // 服务器没给句柄（少见），退化成再 lookup 一次。
                            lookup(conn, &parent_fh, &tmp_name).await?
                        }
                    },
                    nfs3::Nfs3Result::Err((code, _)) => return Err(nfsstat_err(code, "create")),
                };

                // 2) 分块写。任何一步失败都要清掉临时文件，别把垃圾留在共享目录里。
                let write_result = write_all(conn, &file_fh, &data).await;
                if let Err(e) = write_result {
                    let _ = remove_file(conn, &parent_fh, &tmp_name).await;
                    return Err(e);
                }
                if let Err(e) = commit(conn, &file_fh, data.len() as u64).await {
                    let _ = remove_file(conn, &parent_fh, &tmp_name).await;
                    return Err(e);
                }

                // 3) RENAME 覆盖目标（NFSv3 的 RENAME 是 POSIX 语义，目标存在会被替换）。
                let rename = nfs3::RENAME3args {
                    from: nfs3::diropargs3 {
                        dir: parent_fh.clone(),
                        name: nfs_name(&tmp_name),
                    },
                    to: nfs3::diropargs3 {
                        dir: parent_fh,
                        name: nfs_name(name),
                    },
                };
                match conn.rename(&rename).await.map_err(rpc_err)? {
                    nfs3::Nfs3Result::Ok(_) => Ok(()),
                    nfs3::Nfs3Result::Err((code, _)) => Err(nfsstat_err(code, "rename")),
                }
            })
        })
        .await
    }

    async fn create_dir_all(&self, dir: &VfsPath) -> Result<()> {
        if dir.is_root() {
            return Ok(());
        }
        let dir = dir.clone();
        self.with_session(move |conn, root| {
            Box::pin(async move {
                let mut current = root.clone();
                for seg in dir.as_str().split('/').filter(|s| !s.is_empty()) {
                    let args = nfs3::MKDIR3args {
                        where_: nfs3::diropargs3 {
                            dir: current.clone(),
                            name: nfs_name(seg),
                        },
                        attributes: nfs3::sattr3::default(),
                    };
                    match conn.mkdir(&args).await.map_err(rpc_err)? {
                        nfs3::Nfs3Result::Ok(ok) => {
                            current = match ok.obj {
                                Nfs3Option::Some(fh) => fh,
                                Nfs3Option::None => lookup(conn, &current, seg).await?,
                            };
                        }
                        // 已存在就是我们要的效果；顺手 lookup 出句柄继续往下走。
                        nfs3::Nfs3Result::Err((nfsstat3::NFS3ERR_EXIST, _)) => {
                            current = lookup(conn, &current, seg).await?;
                        }
                        nfs3::Nfs3Result::Err((code, _)) => {
                            return Err(nfsstat_err(code, "mkdir"));
                        }
                    }
                }
                Ok(())
            })
        })
        .await
    }
}

/// 把主机名解析成 IP 字面量。
///
/// `nfs3_client` 内部 `host.parse::<IpAddr>()`，给它主机名会直接失败，所以先自己解析。
async fn resolve_host(host: &str, port: u16) -> Result<String> {
    if host.parse::<std::net::IpAddr>().is_ok() {
        return Ok(host.to_string());
    }
    if host.starts_with('[') && host.ends_with(']') {
        // 已经是 `[::1]` 形式，去掉方括号就能 parse。
        let bare = &host[1..host.len() - 1];
        if bare.parse::<std::net::IpAddr>().is_ok() {
            return Ok(bare.to_string());
        }
    }
    let addrs: Vec<_> = tokio::net::lookup_host((host, port))
        .await
        .map_err(|e| {
            LekisError::new(
                ErrorCode::Network,
                format!("NFS: 解析主机名 {host} 失败：{e}"),
            )
        })?
        .collect();
    // 优先 IPv4：很多 NFS 服务器只在 v4 上监听，而且 portmapper 的 v6 支持不普遍。
    let picked = addrs
        .iter()
        .find(|a| a.is_ipv4())
        .or_else(|| addrs.first())
        .ok_or_else(|| {
            LekisError::new(
                ErrorCode::Network,
                format!("NFS: 主机名 {host} 没有解析结果"),
            )
        })?;
    Ok(picked.ip().to_string())
}

/// `Nfs3Client` 的别名，纯粹为了让下面的签名短一点。
type Nfs3ClientRef<IO> = nfs3_client::Nfs3Client<IO>;

/// 用 `LOOKUP` 逐段解析路径，返回文件句柄。
///
/// `path` 为空（根）时直接用给定的起点句柄，不做任何 RPC。
async fn resolve_fh<IO>(
    conn: &mut Nfs3ClientRef<IO>,
    root: &nfs_fh3,
    path: &VfsPath,
) -> Result<nfs_fh3>
where
    IO: nfs3_client::io::AsyncRead + nfs3_client::io::AsyncWrite + Send,
{
    let mut current = root.clone();
    for seg in path.as_str().split('/').filter(|s| !s.is_empty()) {
        current = lookup(conn, &current, seg).await?;
    }
    Ok(current)
}

/// 单段 `LOOKUP`。
async fn lookup<IO>(conn: &mut Nfs3ClientRef<IO>, dir: &nfs_fh3, name: &str) -> Result<nfs_fh3>
where
    IO: nfs3_client::io::AsyncRead + nfs3_client::io::AsyncWrite + Send,
{
    let args = nfs3::LOOKUP3args {
        what: nfs3::diropargs3 {
            dir: dir.clone(),
            name: nfs_name(name),
        },
    };
    match conn.lookup(&args).await.map_err(rpc_err)? {
        nfs3::Nfs3Result::Ok(ok) => Ok(ok.object),
        nfs3::Nfs3Result::Err((code, _)) => Err(nfsstat_err(code, "lookup")),
    }
}

/// 取属性。
async fn getattr<IO>(conn: &mut Nfs3ClientRef<IO>, fh: &nfs_fh3) -> Result<fattr3>
where
    IO: nfs3_client::io::AsyncRead + nfs3_client::io::AsyncWrite + Send,
{
    let args = nfs3::GETATTR3args { object: fh.clone() };
    match conn.getattr(&args).await.map_err(rpc_err)? {
        nfs3::Nfs3Result::Ok(ok) => Ok(ok.obj_attributes),
        nfs3::Nfs3Result::Err((code, _)) => Err(nfsstat_err(code, "getattr")),
    }
}

/// `READDIRPLUS`，一次拿全名字 + 属性。
///
/// 返回 `Unsupported` 表示服务器不支持这个 RPC，调用方可以退回 `READDIR`。
async fn readdir_plus<IO>(
    conn: &mut Nfs3ClientRef<IO>,
    dir: &nfs_fh3,
) -> Result<Vec<(String, FileMeta)>>
where
    IO: nfs3_client::io::AsyncRead + nfs3_client::io::AsyncWrite + Send,
{
    let mut out = Vec::new();
    let mut cookie: nfs3::cookie3 = 0;
    let mut cookieverf = nfs3::cookieverf3::default();
    loop {
        let args = nfs3::READDIRPLUS3args {
            dir: dir.clone(),
            cookie,
            cookieverf,
            dircount: READDIR_COUNT,
            maxcount: READDIR_COUNT,
        };
        let res = conn.readdirplus(&args).await.map_err(rpc_err)?;
        let ok = match res {
            nfs3::Nfs3Result::Ok(ok) => ok,
            nfs3::Nfs3Result::Err((nfsstat3::NFS3ERR_NOTSUPP, _)) => {
                return Err(LekisError::new(
                    ErrorCode::Unsupported,
                    "NFS: 服务器不支持 READDIRPLUS",
                ));
            }
            nfs3::Nfs3Result::Err((code, _)) => return Err(nfsstat_err(code, "readdirplus")),
        };
        cookieverf = ok.cookieverf;
        let eof = ok.reply.eof;
        let entries = ok.reply.entries.into_inner();
        if entries.is_empty() {
            if eof {
                break;
            }
            // cookie 没前进又没有条目 —— 服务器有 bug，别死循环。
            return Err(LekisError::new(
                ErrorCode::Decode,
                "NFS: READDIRPLUS 返回空页但未到末尾",
            ));
        }
        for entry in entries {
            cookie = entry.cookie;
            let name = decode_name(&entry.name.0);
            let Some(name) = name.filter(|n| n != "." && n != "..") else {
                continue;
            };
            let meta = match entry.name_attributes {
                Nfs3Option::Some(attrs) => fattr_meta(&attrs),
                Nfs3Option::None => {
                    // 服务器没给属性：拿着句柄单查一次。
                    let attrs = match entry.name_handle {
                        Nfs3Option::Some(fh) => getattr(conn, &fh).await?,
                        Nfs3Option::None => {
                            let fh = lookup(conn, dir, &name).await?;
                            getattr(conn, &fh).await?
                        }
                    };
                    fattr_meta(&attrs)
                }
            };
            out.push((name, meta));
            if out.len() >= MAX_ENTRIES {
                return Ok(out);
            }
        }
        // 页尾判断：`eof` 为真说明这是最后一页；否则用本页最后一个 cookie 继续问。
        if eof {
            break;
        }
    }
    Ok(out)
}

/// `READDIR`，只拿名字（不支持 `READDIRPLUS` 时的退路）。
async fn readdir_plain<IO>(conn: &mut Nfs3ClientRef<IO>, dir: &nfs_fh3) -> Result<Vec<String>>
where
    IO: nfs3_client::io::AsyncRead + nfs3_client::io::AsyncWrite + Send,
{
    let mut out = Vec::new();
    let mut cookie: nfs3::cookie3 = 0;
    let mut cookieverf = nfs3::cookieverf3::default();
    loop {
        let args = nfs3::READDIR3args {
            dir: dir.clone(),
            cookie,
            cookieverf,
            count: READDIR_COUNT,
        };
        let res = conn.readdir(&args).await.map_err(rpc_err)?;
        let ok = match res {
            nfs3::Nfs3Result::Ok(ok) => ok,
            nfs3::Nfs3Result::Err((code, _)) => return Err(nfsstat_err(code, "readdir")),
        };
        cookieverf = ok.cookieverf;
        let eof = ok.reply.eof;
        let entries = ok.reply.entries.into_inner();
        if entries.is_empty() {
            if eof {
                break;
            }
            return Err(LekisError::new(
                ErrorCode::Decode,
                "NFS: READDIR 返回空页但未到末尾",
            ));
        }
        let mut advanced = false;
        for entry in entries {
            cookie = entry.cookie;
            advanced = true;
            if let Some(name) = decode_name(&entry.name.0) {
                if name != "." && name != ".." {
                    out.push(name);
                }
            }
            if out.len() >= MAX_ENTRIES {
                return Ok(out);
            }
        }
        if eof || !advanced {
            break;
        }
    }
    Ok(out)
}

/// 分块写完整数据。
async fn write_all<IO>(conn: &mut Nfs3ClientRef<IO>, fh: &nfs_fh3, data: &[u8]) -> Result<()>
where
    IO: nfs3_client::io::AsyncRead + nfs3_client::io::AsyncWrite + Send,
{
    let mut pos = 0usize;
    while pos < data.len() {
        let end = (pos + WRITE_CHUNK).min(data.len());
        let chunk = &data[pos..end];
        let args = nfs3::WRITE3args {
            file: fh.clone(),
            offset: pos as u64,
            count: u32::try_from(chunk.len()).unwrap_or(u32::MAX),
            // UNSTABLE：先只进缓存，最后统一 COMMIT 一次，比每个块都 FILE_SYNC 快得多。
            stable: stable_how::UNSTABLE,
            data: Opaque::borrowed(chunk),
        };
        match conn.write(&args).await.map_err(rpc_err)? {
            nfs3::Nfs3Result::Ok(ok) => {
                if ok.count as usize != chunk.len() {
                    return Err(LekisError::new(
                        ErrorCode::Io,
                        format!("NFS: 短写 {}/{}", ok.count, chunk.len()),
                    ));
                }
            }
            nfs3::Nfs3Result::Err((code, _)) => return Err(nfsstat_err(code, "write")),
        }
        pos = end;
    }
    Ok(())
}

/// `COMMIT`：把 UNSTABLE 写落盘。
async fn commit<IO>(conn: &mut Nfs3ClientRef<IO>, fh: &nfs_fh3, size: u64) -> Result<()>
where
    IO: nfs3_client::io::AsyncRead + nfs3_client::io::AsyncWrite + Send,
{
    let args = nfs3::COMMIT3args {
        file: fh.clone(),
        offset: 0,
        count: u32::try_from(size).unwrap_or(u32::MAX),
    };
    match conn.commit(&args).await.map_err(rpc_err)? {
        nfs3::Nfs3Result::Ok(_) => Ok(()),
        nfs3::Nfs3Result::Err((code, _)) => Err(nfsstat_err(code, "commit")),
    }
}

/// 删文件（清理临时文件用，失败不覆盖主错误）。
async fn remove_file<IO>(conn: &mut Nfs3ClientRef<IO>, dir: &nfs_fh3, name: &str) -> Result<()>
where
    IO: nfs3_client::io::AsyncRead + nfs3_client::io::AsyncWrite + Send,
{
    let args = nfs3::REMOVE3args {
        object: nfs3::diropargs3 {
            dir: dir.clone(),
            name: nfs_name(name),
        },
    };
    match conn.remove(&args).await.map_err(rpc_err)? {
        nfs3::Nfs3Result::Ok(_) => Ok(()),
        nfs3::Nfs3Result::Err((code, _)) => Err(nfsstat_err(code, "remove")),
    }
}

/// `fattr3` → `FileMeta`。
fn fattr_meta(attrs: &fattr3) -> FileMeta {
    FileMeta {
        kind: match attrs.type_ {
            ftype3::NF3REG => EntryKind::File,
            ftype3::NF3DIR => EntryKind::Dir,
            _ => EntryKind::Other,
        },
        size: attrs.size,
        // nfstime3 是「秒 + 纳秒」，转成毫秒。
        mtime_ms: i64::from(attrs.mtime.seconds) * 1000
            + i64::from(attrs.mtime.nseconds / 1_000_000),
    }
}

/// 把文件名包成 NFS 的 `filename3`。
fn nfs_name(name: &str) -> filename3<'_> {
    filename3(Opaque::borrowed(name.as_bytes()))
}

/// 从 `Opaque` 里取出 UTF-8 文件名；非 UTF-8 返回 `None`（调用方跳过）。
fn decode_name(opaque: &Opaque<'_>) -> Option<String> {
    std::str::from_utf8(opaque.as_ref())
        .ok()
        .map(ToString::to_string)
}

/// `nfsstat3` → `LekisError`。
fn nfsstat_err(code: nfsstat3, what: &str) -> LekisError {
    let error_code = match code {
        nfsstat3::NFS3ERR_NOENT => ErrorCode::NotFound,
        nfsstat3::NFS3ERR_ACCES | nfsstat3::NFS3ERR_PERM | nfsstat3::NFS3ERR_ROFS => {
            ErrorCode::PermissionDenied
        }
        nfsstat3::NFS3ERR_EXIST
        | nfsstat3::NFS3ERR_NOTDIR
        | nfsstat3::NFS3ERR_ISDIR
        | nfsstat3::NFS3ERR_INVAL
        | nfsstat3::NFS3ERR_NAMETOOLONG
        | nfsstat3::NFS3ERR_BADTYPE => ErrorCode::InvalidArgument,
        nfsstat3::NFS3ERR_NOTSUPP => ErrorCode::Unsupported,
        // 句柄失效（服务器重启或导出被卸载）在网络层看起来就是「连不上」。
        nfsstat3::NFS3ERR_STALE | nfsstat3::NFS3ERR_BADHANDLE => ErrorCode::Network,
        nfsstat3::NFS3ERR_NOSPC
        | nfsstat3::NFS3ERR_DQUOT
        | nfsstat3::NFS3ERR_IO
        | nfsstat3::NFS3ERR_NXIO => ErrorCode::Io,
        _ => ErrorCode::Io,
    };
    LekisError::new(error_code, format!("NFS {what} 失败：{code}"))
}

/// `RpcError` → `LekisError`。
fn rpc_err(err: RpcError) -> LekisError {
    match err {
        RpcError::Io(e) => LekisError::from(e),
        RpcError::Xdr(e) => LekisError::new(ErrorCode::Decode, format!("NFS XDR 错误：{e}")),
        RpcError::Auth(stat) => LekisError::new(ErrorCode::Auth, format!("NFS 认证失败：{stat:?}")),
        other => LekisError::new(ErrorCode::Network, format!("NFS RPC 错误：{other}")),
    }
}

/// `ConnectError` → `LekisError`。
fn connect_err(err: ConnectError) -> LekisError {
    match err {
        ConnectError::Io(e) => LekisError::new(ErrorCode::Network, format!("NFS 连接失败：{e}")),
        ConnectError::Portmap(e) => {
            LekisError::new(ErrorCode::Network, format!("NFS portmapper 失败：{e}"))
        }
        ConnectError::Mount(e) => {
            LekisError::new(ErrorCode::NotFound, format!("NFS 挂载导出失败：{e}"))
        }
    }
}

/// 解析 `nfs://host[:port]/export[/path]`。
fn parse_nfs_url(url: &str) -> Result<NfsTarget> {
    let rest = url
        .strip_prefix("nfs://")
        .ok_or_else(|| LekisError::invalid("NFS 地址必须以 nfs:// 开头"))?;

    // 拆出查询串（`?pmport=...`）和片段。
    let (rest, query) = match rest.split_once('?') {
        Some((head, tail)) => (head, tail.split('#').next().unwrap_or("")),
        None => (rest.split('#').next().unwrap_or(rest), ""),
    };

    let (authority, path) = match rest.find('/') {
        Some(idx) => (&rest[..idx], &rest[idx..]),
        None => (rest, ""),
    };

    // 主机 + 可选端口。IPv6 用 `[::1]` 形式。
    let (host, port_part) = if let Some(stripped) = authority.strip_prefix('[') {
        let end = stripped
            .find(']')
            .ok_or_else(|| LekisError::invalid("NFS 地址的 IPv6 主机缺少 `]`"))?;
        let host = &stripped[..end];
        let after = &stripped[end + 1..];
        let port = after.strip_prefix(':');
        if !after.is_empty() && port.is_none() {
            return Err(LekisError::invalid("NFS 地址的 IPv6 主机后面只能是端口"));
        }
        (format!("[{host}]"), port)
    } else {
        match authority.rsplit_once(':') {
            Some((host, port)) => (host.to_string(), Some(port)),
            None => (authority.to_string(), None),
        }
    };

    if host.is_empty() {
        return Err(LekisError::invalid("NFS 地址缺少主机名"));
    }

    let export = percent_decode(path);
    if export.is_empty() || export == "/" {
        return Err(LekisError::invalid(
            "NFS 地址必须带导出路径，例如 nfs://192.168.1.10/volume1/music",
        ));
    }
    if export.contains("..") {
        return Err(LekisError::invalid("NFS 导出路径不允许包含 `..`"));
    }

    let mut target = NfsTarget {
        host,
        // URL 里的端口在 NFS 上没有唯一含义，这里当作 portmapper 端口。
        pmap_port: parse_port(port_part)?.unwrap_or(PMAP_PORT),
        mount_port: None,
        nfs_port: None,
        export,
        privileged: false,
    };

    for pair in query.split('&').filter(|s| !s.is_empty()) {
        let (key, value) = match pair.split_once('=') {
            Some(kv) => kv,
            None => continue,
        };
        match key {
            "pmport" | "portmapper" => {
                if let Some(port) = parse_port(Some(value))? {
                    target.pmap_port = port;
                }
            }
            "mountport" => target.mount_port = parse_port(Some(value))?,
            "nfsport" => target.nfs_port = parse_port(Some(value))?,
            "privileged" => target.privileged = matches!(value, "1" | "true" | "yes"),
            // 未知参数忽略：源配置里可能带着给别的后端用的选项。
            _ => {}
        }
    }

    Ok(target)
}

/// 解析可选端口号。
fn parse_port(raw: Option<&str>) -> Result<Option<u16>> {
    let Some(raw) = raw else { return Ok(None) };
    if raw.is_empty() {
        return Ok(None);
    }
    raw.parse::<u16>()
        .map(Some)
        .map_err(|_| LekisError::invalid(format!("NFS 端口不合法：{raw}")))
}

/// 朴素的 percent 解码（导出路径里可能有中文/空格）。
fn percent_decode(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hex = &input[i + 1..i + 3];
            if let Ok(value) = u8::from_str_radix(hex, 16) {
                out.push(value);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod tests {
    // 测试里允许 unwrap/expect/panic：失败信息比返回 Result 更直观。
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;

    #[test]
    fn parses_minimal_url() {
        let t = parse_nfs_url("nfs://192.168.1.10/volume1/music").expect("应能解析");
        assert_eq!(t.host, "192.168.1.10");
        assert_eq!(t.pmap_port, 111);
        assert_eq!(t.export, "/volume1/music");
        assert!(t.mount_port.is_none());
        assert!(!t.privileged);
    }

    #[test]
    fn parses_port_and_options() {
        let t = parse_nfs_url("nfs://10.0.0.5:1111/data?mountport=20048&nfsport=2049&privileged=1")
            .expect("应能解析");
        assert_eq!(t.pmap_port, 1111);
        assert_eq!(t.mount_port, Some(20048));
        assert_eq!(t.nfs_port, Some(2049));
        assert!(t.privileged);
    }

    #[test]
    fn parses_ipv6_host() {
        let t = parse_nfs_url("nfs://[fe80::1]/export").expect("应能解析");
        assert_eq!(t.host, "[fe80::1]");
        assert_eq!(t.export, "/export");
    }

    #[test]
    fn decodes_chinese_export_path() {
        let t = parse_nfs_url("nfs://nas/%E9%9F%B3%E4%B9%90").expect("应能解析");
        assert_eq!(t.export, "/音乐");
    }

    #[test]
    fn rejects_bad_urls() {
        assert!(parse_nfs_url("http://nas/export").is_err());
        assert!(parse_nfs_url("nfs://nas").is_err(), "缺导出路径");
        assert!(parse_nfs_url("nfs:///export").is_err(), "缺主机");
        assert!(
            parse_nfs_url("nfs://nas/export/../etc").is_err(),
            "不允许 .."
        );
        assert!(parse_nfs_url("nfs://nas/export?nfsport=abc").is_err());
    }

    #[test]
    fn host_without_port_resolves_via_lookup_shape() {
        // 纯逻辑检查：IP 字面量不需要 DNS。
        let t = parse_nfs_url("nfs://127.0.0.1/export").expect("应能解析");
        assert_eq!(t.host, "127.0.0.1");
    }

    #[test]
    fn error_codes_map_from_nfsstat() {
        assert_eq!(
            nfsstat_err(nfsstat3::NFS3ERR_NOENT, "x").code,
            ErrorCode::NotFound
        );
        assert_eq!(
            nfsstat_err(nfsstat3::NFS3ERR_ACCES, "x").code,
            ErrorCode::PermissionDenied
        );
        assert_eq!(
            nfsstat_err(nfsstat3::NFS3ERR_NOTDIR, "x").code,
            ErrorCode::InvalidArgument
        );
        assert_eq!(
            nfsstat_err(nfsstat3::NFS3ERR_NOTSUPP, "x").code,
            ErrorCode::Unsupported
        );
        assert_eq!(
            nfsstat_err(nfsstat3::NFS3ERR_STALE, "x").code,
            ErrorCode::Network
        );
    }

    #[test]
    fn fattr_converts_to_file_meta() {
        let mut attrs = fattr3 {
            type_: ftype3::NF3DIR,
            mode: 0o755,
            nlink: 2,
            uid: 0,
            gid: 0,
            size: 4096,
            used: 4096,
            rdev: Default::default(),
            fsid: 1,
            fileid: 2,
            atime: nfs3::nfstime3::default(),
            mtime: nfs3::nfstime3 {
                seconds: 1_700_000_000,
                nseconds: 500_000_000,
            },
            ctime: nfs3::nfstime3::default(),
        };
        let meta = fattr_meta(&attrs);
        assert_eq!(meta.kind, EntryKind::Dir);
        assert_eq!(meta.size, 4096);
        assert_eq!(meta.mtime_ms, 1_700_000_000_500);
        attrs.type_ = ftype3::NF3REG;
        assert_eq!(fattr_meta(&attrs).kind, EntryKind::File);
        attrs.type_ = ftype3::NF3LNK;
        assert_eq!(fattr_meta(&attrs).kind, EntryKind::Other);
    }

    #[test]
    fn name_roundtrip_and_invalid_utf8() {
        let name = nfs_name("中文.flac");
        assert_eq!(decode_name(&name.0).as_deref(), Some("中文.flac"));
        let bad = Opaque::borrowed(&[0xff, 0xfe]);
        assert!(decode_name(&bad).is_none());
    }
}
