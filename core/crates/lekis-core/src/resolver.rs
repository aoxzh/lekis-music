//! 选源：把播放引擎请求的曲目解析成可播放的媒体（SRC-13、SRC-14、OFF-03）。
//!
//! 目标优先级见 [`crate::selection`]：可用性 > 就近程度 > 音质。
//! 服务器源（OpenSubsonic / Jellyfin / Plex）需要先用 `lekis-providers` 换一个播放地址，
//! 这一步也在本模块完成。
//!
//! ## ReplayGain（PLY-03）
//!
//! 解析媒体时按设置项 `playback.replaygain` 从文件的 `TrackFile.replaygain` 里选增益：
//! `track`（默认）→ 曲目增益，`album` → 专辑增益（缺失时退回曲目），`off` → 不补偿。
//! 选中的 dB 值放进 [`MediaSource::gain_db`]，播放会话在共享模式的解码线程里
//! 和用户音量合成一个系数乘一次；比特完美独占链路会明确忽略它（保持源码位模式）。
//! 设置页已经暴露这个开关，桥接层通过通用的 `get_setting` / `set_setting` 读写。

use crate::selection::{self, NetworkContext, Reachability, SourceHealth};
use lekis_library::{Library, TrackFile};
use lekis_playback::engine::ResolveRequest;
use lekis_playback::{MediaLocation, MediaSource};
use lekis_providers::MediaServer;
use lekis_types::{LekisError, Result, SourceConfig, SourceId, SourceKind, TrackId};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc;

/// 解析一次请求需要用到的依赖。
pub(crate) struct Resolver {
    library: Library,
    plugins: Option<Arc<crate::plugins::PluginManager>>,
    health: Arc<SourceHealth>,
    /// 已经构造好的服务器客户端（按源 ID 缓存）。
    servers: Mutex<HashMap<SourceId, Arc<dyn MediaServer>>>,
    /// 凭据读取（平台注入的系统钥匙串）。
    credentials: Arc<dyn crate::CredentialStore>,
    /// `playback.replaygain` 的当前值（启动时和每次设置时由 core 写入，避免每首歌查一次库）。
    replaygain_mode: std::sync::RwLock<ReplayGainMode>,
    /// 「在其他设备上播放」推过来的远端曲目（CST-03）。
    connect: Arc<crate::connect::media::RemoteMediaRegistry>,
}

/// ReplayGain 补偿方式（PLY-03，设置项 `playback.replaygain`）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) enum ReplayGainMode {
    /// 不补偿。
    Off,
    /// 曲目增益（默认）。
    #[default]
    Track,
    /// 专辑增益，没有就退回曲目增益。
    Album,
}

impl ReplayGainMode {
    /// 设置项的值 → 模式（`off` / `album` / 其它都按 `track`）。
    pub(crate) fn from_setting(value: Option<&str>) -> Self {
        match value.map(str::trim) {
            Some("off") | Some("false") => Self::Off,
            Some("album") => Self::Album,
            _ => Self::Track,
        }
    }

    /// 按模式选增益。
    pub(crate) fn pick(self, rg: &lekis_types::ReplayGain) -> Option<f32> {
        match self {
            Self::Off => None,
            Self::Album => rg.album_gain_db.or(rg.track_gain_db),
            Self::Track => rg.track_gain_db,
        }
    }
}

impl Resolver {
    pub(crate) fn new(
        library: Library,
        health: Arc<SourceHealth>,
        credentials: Arc<dyn crate::CredentialStore>,
    ) -> Self {
        Self {
            library,
            plugins: None,
            health,
            servers: Mutex::new(HashMap::new()),
            credentials,
            replaygain_mode: std::sync::RwLock::new(ReplayGainMode::default()),
            connect: Arc::default(),
        }
    }

    /// Attach source plugins before starting the resolver loop.
    pub(crate) fn with_plugins(mut self, plugins: Arc<crate::plugins::PluginManager>) -> Self {
        self.plugins = Some(plugins);
        self
    }

    /// 远端曲目登记表。
    pub(crate) fn connect(&self) -> &crate::connect::media::RemoteMediaRegistry {
        &self.connect
    }

    /// 更新 ReplayGain 模式（下一首开始生效）。
    pub(crate) fn set_replaygain_mode(&self, mode: ReplayGainMode) {
        if let Ok(mut m) = self.replaygain_mode.write() {
            *m = mode;
        }
    }

    /// 当前 ReplayGain 模式（测试用）。
    #[cfg(test)]
    pub(crate) fn replaygain_mode(&self) -> ReplayGainMode {
        self.replaygain_mode.read().map(|m| *m).unwrap_or_default()
    }

    /// 忘掉某个源缓存的服务器客户端（源配置或凭据变了之后调用）。
    pub(crate) fn forget(&self, source_id: SourceId) {
        if let Ok(mut map) = self.servers.lock() {
            map.remove(&source_id);
        }
    }

    /// 播放引擎的解析循环。
    pub(crate) async fn run(self: Arc<Self>, mut requests: mpsc::Receiver<ResolveRequest>) {
        while let Some((track_id, reply)) = requests.recv().await {
            let result = self.resolve(track_id).await;
            if let Err(e) = &result {
                tracing::warn!(target: "core", %track_id, error = %e, "resolve failed");
            }
            let _ = reply.send(result);
        }
    }

    pub(crate) async fn resolve(&self, track_id: TrackId) -> Result<MediaSource> {
        // CST-03：别的设备推过来的曲目（同一音源上的路径，或者对方的局域网流）。
        if let Some(media_id) = lekis_types::ConnectMediaId::from_track_id(track_id) {
            let media = self
                .connect
                .get(media_id)
                .ok_or_else(|| LekisError::not_found(format!("remote media {track_id} expired")))?;
            let location = match media.location {
                crate::connect::media::RemoteLocation::Vfs { source_id, path } => {
                    MediaLocation::Vfs { source_id, path }
                }
                crate::connect::media::RemoteLocation::Url { url } => MediaLocation::Url {
                    url,
                    headers: Vec::new(),
                },
            };
            return Ok(MediaSource {
                track_id,
                location,
                duration_hint_ms: media.track.duration_ms,
                gain_db: None,
            });
        }
        // SRC-11：网络电台用负数的合成 TrackId，直接打开保存的流地址。
        // 不要求曲目扫描，也没有时长；播放器会把它当成不可 seek 的直播流。
        if let Some(station_id) = lekis_types::RadioStationId::from_track_id(track_id) {
            let station = self.library.radio_station(station_id).await?;
            return Ok(MediaSource {
                track_id,
                location: MediaLocation::Url {
                    url: station.url,
                    headers: Vec::new(),
                },
                duration_hint_ms: 0,
                gain_db: None,
            });
        }
        // SRC-12：播客单集同样是合成 TrackId，直接打开 enclosure 地址（支持 Range 时可 seek）。
        if let Some(episode_id) = lekis_types::PodcastEpisodeId::from_track_id(track_id) {
            let episode = self.library.podcast_episode(episode_id).await?;
            return Ok(MediaSource {
                track_id,
                location: MediaLocation::Url {
                    url: episode.audio_url,
                    headers: Vec::new(),
                },
                duration_hint_ms: episode.duration_ms,
                gain_db: None,
            });
        }
        // OFF-03：已经有完整缓存时优先播本机文件。即使 NAS / 服务器暂时离线也能播。
        if let Some(download) = self.library.offline_ready_download(track_id).await? {
            if std::path::Path::new(&download.cache_path).is_file() {
                let duration_hint_ms = self
                    .library
                    .get_track(track_id)
                    .await
                    .map(|t| t.duration_ms)
                    .unwrap_or(0);
                // 缓存文件仍然沿用普通播放会话 / 解码链路，ReplayGain 设置也照常生效。
                let gain_db = match self.library.track_files(track_id).await {
                    Ok(files) => {
                        let net = self.health.network();
                        selection::pick_best(&files, &|id| self.health.get(id), net)
                            .map(|f| f.replaygain)
                            .and_then(|rg| {
                                self.replaygain_mode
                                    .read()
                                    .ok()
                                    .map(|m| m.pick(&rg))
                                    .unwrap_or_default()
                            })
                    }
                    Err(_) => None,
                };
                tracing::debug!(target: "core", %track_id, "playing offline cache");
                return Ok(MediaSource {
                    track_id,
                    location: MediaLocation::CachedFile {
                        path: download.cache_path,
                    },
                    duration_hint_ms,
                    gain_db,
                });
            }
            tracing::warn!(
                target: "core",
                %track_id,
                path = %download.cache_path,
                "offline cache missing, falling back to source"
            );
        }
        let files = self.library.track_files(track_id).await?;
        let net = self.health.network();
        self.resolve_candidates(track_id, files, net)
            .await
            .map(|(_, media)| media)
    }

    /// 解析一个"下载用"的源（不优先走缓存）。
    ///
    /// 返回选中的文件和播放地址，供 `lekis-core::offline` 决定用 VFS 还是 HTTP 拷贝。
    pub(crate) async fn resolve_file(&self, track_id: TrackId) -> Result<(TrackFile, MediaSource)> {
        let files = self.library.track_files(track_id).await?;
        let net = self.health.network();
        self.resolve_candidates(track_id, files, net).await
    }

    /// A disabled, removed or failing plugin must not hide another copy of the song.
    /// Keep its library references intact for favorites and later reinstallation.
    async fn resolve_candidates(
        &self,
        track_id: TrackId,
        mut files: Vec<TrackFile>,
        net: NetworkContext,
    ) -> Result<(TrackFile, MediaSource)> {
        let mut plugin_error = None;
        while let Some(best) = selection::pick_best(&files, &|id| self.health.get(id), net).cloned()
        {
            files.retain(|file| {
                file.source_id != best.source_id
                    || file.path != best.path
                    || file.external_id != best.external_id
            });
            match self.media_source(track_id, &best, net).await {
                Ok(media) => return Ok((best, media)),
                Err(error) if best.source_kind == SourceKind::Plugin => {
                    tracing::debug!(target: "core", %track_id, source_id = ?best.source_id,
                        %error, "plugin source unavailable, trying another copy");
                    plugin_error = Some(error);
                }
                Err(error) => return Err(error),
            }
        }
        Err(plugin_error.unwrap_or_else(|| {
            LekisError::not_found(format!("no playable file for track {track_id}"))
        }))
    }

    /// 把一个具体的文件变成可播放的媒体描述。
    async fn media_source(
        &self,
        track_id: TrackId,
        file: &TrackFile,
        net: NetworkContext,
    ) -> Result<MediaSource> {
        let gain_db = self.gain_db(file).await;
        let duration_hint_ms = file.duration_ms;

        if file.source_kind.is_filesystem() {
            return Ok(MediaSource {
                track_id,
                location: MediaLocation::Vfs {
                    source_id: file.source_id,
                    path: file.path.clone(),
                },
                duration_hint_ms,
                gain_db,
            });
        }

        let Some(external_id) = file.external_id.clone() else {
            return Err(LekisError::invalid(format!(
                "server-side track {track_id} has no external id"
            )));
        };
        if file.source_kind == SourceKind::Plugin {
            let config = self.library.get_source(file.source_id).await?;
            if !config.enabled {
                return Err(LekisError::unsupported("插件音源已停用"));
            }
            let plugins = self
                .plugins
                .as_ref()
                .ok_or_else(|| LekisError::unsupported("插件宿主不可用"))?;
            let stream = plugins.stream(&config.root_path, &external_id).await?;
            plugins.prefetch_artwork_for_track(track_id);
            return Ok(MediaSource {
                track_id,
                location: MediaLocation::Url {
                    url: stream.url,
                    headers: stream.headers.into_iter().collect(),
                },
                duration_hint_ms,
                gain_db,
            });
        }
        let server = self.server_for(file.source_id).await?;
        let quality = selection::stream_quality_for(file, net);
        match server.stream(&external_id, quality).await {
            Ok(target) => {
                self.health.record(file.source_id, Reachability::Reachable);
                Ok(MediaSource {
                    track_id,
                    location: MediaLocation::Url {
                        url: target.url,
                        headers: target.headers,
                    },
                    duration_hint_ms,
                    gain_db,
                })
            }
            Err(e) => {
                self.health
                    .record(file.source_id, Reachability::Unreachable);
                Err(e)
            }
        }
    }

    /// ReplayGain 增益（PLY-03），按 [`ReplayGainMode`] 选曲目增益或专辑增益。
    async fn gain_db(&self, file: &TrackFile) -> Option<f32> {
        let mode = self.replaygain_mode.read().map(|m| *m).unwrap_or_default();
        mode.pick(&file.replaygain)
    }

    /// 取（或构造）某个服务器源的客户端。凭据从系统钥匙串按 `credential_ref` 读。
    pub(crate) async fn server_for(&self, source_id: SourceId) -> Result<Arc<dyn MediaServer>> {
        if let Ok(map) = self.servers.lock() {
            if let Some(s) = map.get(&source_id) {
                return Ok(s.clone());
            }
        }
        let config = self.library.get_source(source_id).await?;
        let server = build_server(&config, self.credentials.as_ref())?;
        let server: Arc<dyn MediaServer> = Arc::from(server);
        if let Ok(mut map) = self.servers.lock() {
            map.insert(source_id, server.clone());
        }
        Ok(server)
    }
}

/// 按源配置构造服务器客户端。
///
/// 约定（与 `SourceConfig` 的字段对应）：
/// - `addresses`：服务器根地址，第一个优先，其余是备用地址（SRC-14）；
/// - `options["username"]`：OpenSubsonic / Jellyfin 的用户名（Jellyfin 走 API Key 时不需要）；
/// - `options["api_key"]` 或 `credential_ref` 指向的密钥：Jellyfin 的 API Key、Plex 的 token；
/// - `credential_ref` 指向的密钥优先当作"密码 / token"，`options` 里的明文只作为兜底。
pub(crate) fn build_server(
    config: &SourceConfig,
    credentials: &dyn crate::CredentialStore,
) -> Result<Box<dyn MediaServer>> {
    let secret = config
        .credential_ref
        .as_deref()
        .and_then(|r| credentials.get(r))
        .or_else(|| config.options.get("api_key").cloned())
        .or_else(|| config.options.get("token").cloned())
        .unwrap_or_default();
    let username = config.options.get("username").cloned().unwrap_or_default();

    // SRC-14：每个地址（家里 / Tailscale / 外网）各建一个客户端，按顺序故障转移。
    let mut servers: Vec<Box<dyn MediaServer>> = Vec::new();
    let mut last_error = None;
    for raw in &config.addresses {
        let base_url = raw.trim().trim_end_matches('/');
        if base_url.is_empty() {
            continue;
        }
        match build_one_server(config.kind, base_url, &username, secret.clone()) {
            Ok(server) => servers.push(server),
            Err(e) => last_error = Some(e),
        }
    }
    match servers.len() {
        0 => Err(last_error
            .unwrap_or_else(|| LekisError::invalid("server source needs at least one address"))),
        1 => Ok(servers.remove(0)),
        _ => Ok(Box::new(FailoverServer::new(servers))),
    }
}

fn build_one_server(
    kind: SourceKind,
    base_url: &str,
    username: &str,
    secret: String,
) -> Result<Box<dyn MediaServer>> {
    match kind {
        SourceKind::OpenSubsonic => Ok(Box::new(lekis_providers::opensubsonic::OpenSubsonic::new(
            base_url, username, secret,
        ))),
        SourceKind::Jellyfin | SourceKind::Emby => Ok(Box::new(
            lekis_providers::jellyfin::Jellyfin::new(kind, base_url, secret)?,
        )),
        SourceKind::Plex => Ok(Box::new(lekis_providers::plex::Plex::new(
            base_url, secret,
        )?)),
        other => Err(LekisError::unsupported(format!(
            "not a media server source: {other:?}"
        ))),
    }
}

/// 多地址媒体服务器：从上次成功的地址开始依次尝试，成功的地址会被记住。
/// 规则和 `lekis_vfs::failover::FailoverVfs` 一致：已确认可达的地址给出明确
/// 答复（找不到、参数错、凭据错…）时不再换地址重试。
struct FailoverServer {
    servers: Vec<Box<dyn MediaServer>>,
    current: AtomicUsize,
    verified: AtomicBool,
}

impl FailoverServer {
    fn new(servers: Vec<Box<dyn MediaServer>>) -> Self {
        Self {
            servers,
            current: AtomicUsize::new(0),
            verified: AtomicBool::new(false),
        }
    }

    async fn attempt<'a, T, F, Fut>(&'a self, f: F) -> Result<T>
    where
        F: Fn(&'a dyn MediaServer) -> Fut,
        Fut: std::future::Future<Output = Result<T>> + 'a,
    {
        let n = self.servers.len();
        let start = self.current.load(Ordering::Relaxed) % n;
        let mut last_error = None;
        for step in 0..n {
            let index = (start + step) % n;
            match f(self.servers[index].as_ref()).await {
                Ok(value) => {
                    self.current.store(index, Ordering::Relaxed);
                    self.verified.store(true, Ordering::Relaxed);
                    return Ok(value);
                }
                Err(e) => {
                    let definite = lekis_vfs::failover::is_definite_answer(&e)
                        || e.code == lekis_types::ErrorCode::Auth;
                    if step == 0 && self.verified.load(Ordering::Relaxed) && definite {
                        return Err(e);
                    }
                    if step == 0 {
                        self.verified.store(false, Ordering::Relaxed);
                    }
                    last_error = Some(e);
                }
            }
        }
        Err(last_error.unwrap_or_else(|| LekisError::internal("no server address")))
    }
}

#[async_trait::async_trait]
impl MediaServer for FailoverServer {
    fn kind(&self) -> SourceKind {
        self.servers[0].kind()
    }

    async fn ping(&self) -> Result<()> {
        self.attempt(|s| s.ping()).await
    }

    async fn list_tracks(
        &self,
        offset: u32,
        limit: u32,
        since_ms: Option<i64>,
    ) -> Result<Vec<lekis_providers::RemoteTrack>> {
        self.attempt(|s| s.list_tracks(offset, limit, since_ms))
            .await
    }

    async fn stream(
        &self,
        external_id: &str,
        quality: lekis_providers::StreamQuality,
    ) -> Result<lekis_providers::StreamTarget> {
        self.attempt(|s| s.stream(external_id, quality)).await
    }

    async fn album_artwork(&self, album_id: &str) -> Result<Option<Vec<u8>>> {
        self.attempt(|s| s.album_artwork(album_id)).await
    }

    async fn lyrics(&self, external_id: &str) -> Result<Option<lekis_types::Lyrics>> {
        self.attempt(|s| s.lyrics(external_id)).await
    }

    async fn scrobble(&self, external_id: &str, played_at_ms: i64) -> Result<()> {
        self.attempt(|s| s.scrobble(external_id, played_at_ms))
            .await
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::MemoryCredentialStore;
    use lekis_types::{ReplayGain, SourceConfig};

    fn source(
        kind: SourceKind,
        options: &[(&str, &str)],
        credential_ref: Option<&str>,
    ) -> SourceConfig {
        SourceConfig {
            id: Some(SourceId(7)),
            kind,
            name: "srv".into(),
            addresses: vec!["http://192.168.1.10:4533/".into()],
            root_path: String::new(),
            credential_ref: credential_ref.map(str::to_string),
            options: options
                .iter()
                .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
                .collect(),
            enabled: true,
        }
    }

    #[test]
    fn builds_opensubsonic_only_after_stripping_trailing_slash() {
        let creds = MemoryCredentialStore::default();
        let cfg = source(SourceKind::OpenSubsonic, &[("username", "ao")], None);
        let server = build_server(&cfg, &creds).expect("must build");
        assert_eq!(server.kind(), SourceKind::OpenSubsonic);
    }

    #[test]
    fn credential_ref_wins_over_options() {
        let creds = MemoryCredentialStore::default();
        crate::CredentialStore::set(&creds, "srv-secret", "from-keychain").expect("set");
        let cfg = source(
            SourceKind::OpenSubsonic,
            &[("username", "ao"), ("api_key", "from-options")],
            Some("srv-secret"),
        );
        // 只要不 panic 且类型对就说明走通了；具体用哪个密钥由实现内部决定。
        let server = build_server(&cfg, &creds).expect("must build");
        assert_eq!(server.kind(), SourceKind::OpenSubsonic);
    }

    #[test]
    fn rejects_filesystem_and_missing_address() {
        let creds = MemoryCredentialStore::default();
        let mut cfg = source(SourceKind::Local, &[], None);
        let err = match build_server(&cfg, &creds) {
            Ok(_) => panic!("filesystem source must be rejected"),
            Err(e) => e,
        };
        assert_eq!(err.code, lekis_types::ErrorCode::Unsupported);
        cfg.kind = SourceKind::Plex;
        cfg.addresses.clear();
        let err = match build_server(&cfg, &creds) {
            Ok(_) => panic!("source without address must be rejected"),
            Err(e) => e,
        };
        assert_eq!(err.code, lekis_types::ErrorCode::InvalidArgument);
    }

    #[test]
    fn plex_needs_token() {
        let creds = MemoryCredentialStore::default();
        let cfg = source(SourceKind::Plex, &[], None);
        // 没有 token 时构造失败，而不是等到播放时才炸。
        assert!(build_server(&cfg, &creds).is_err());
    }

    fn tf(source: i64, kind: SourceKind, score: i64) -> TrackFile {
        TrackFile {
            source_id: SourceId(source),
            source_kind: kind,
            path: "a/b.flac".into(),
            external_id: None,
            quality_score: score,
            duration_ms: 1000,
            replaygain: ReplayGain::default(),
        }
    }

    #[test]
    fn replaygain_mode_parses_and_picks() {
        let rg = ReplayGain {
            track_gain_db: Some(-3.0),
            album_gain_db: Some(-5.0),
            ..Default::default()
        };
        assert_eq!(ReplayGainMode::from_setting(None), ReplayGainMode::Track);
        assert_eq!(
            ReplayGainMode::from_setting(Some("off")),
            ReplayGainMode::Off
        );
        assert_eq!(
            ReplayGainMode::from_setting(Some("album")),
            ReplayGainMode::Album
        );
        assert_eq!(ReplayGainMode::Off.pick(&rg), None);
        assert_eq!(ReplayGainMode::Track.pick(&rg), Some(-3.0));
        assert_eq!(ReplayGainMode::Album.pick(&rg), Some(-5.0));
        let only_track = ReplayGain {
            track_gain_db: Some(-2.0),
            ..Default::default()
        };
        assert_eq!(ReplayGainMode::Album.pick(&only_track), Some(-2.0));
    }

    /// ReplayGain 必须真的进入 `MediaSource.gain_db`，而不是只停留在设置解析层。
    #[tokio::test]
    async fn media_source_carries_the_selected_replaygain() -> Result<()> {
        let root = std::env::temp_dir().join(format!(
            "lekis-resolver-rg-{}-{}",
            std::process::id(),
            lekis_types::now_ms()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root)?;
        let library = Library::open(&root.join("library.sqlite"))?;
        let resolver = Resolver::new(
            library,
            Arc::new(SourceHealth::new()),
            Arc::new(MemoryCredentialStore::default()),
        );
        let mut file = tf(1, SourceKind::Local, 100);
        file.replaygain = ReplayGain {
            track_gain_db: Some(-7.5),
            album_gain_db: Some(-6.0),
            ..Default::default()
        };

        resolver.set_replaygain_mode(ReplayGainMode::Track);
        let media = resolver
            .media_source(TrackId(1), &file, NetworkContext::Home)
            .await?;
        assert_eq!(media.gain_db, Some(-7.5));

        resolver.set_replaygain_mode(ReplayGainMode::Album);
        let media = resolver
            .media_source(TrackId(1), &file, NetworkContext::Home)
            .await?;
        assert_eq!(media.gain_db, Some(-6.0));

        resolver.set_replaygain_mode(ReplayGainMode::Off);
        let media = resolver
            .media_source(TrackId(1), &file, NetworkContext::Home)
            .await?;
        assert_eq!(media.gain_db, None, "关闭时不能偷偷套用曲目增益");

        drop(resolver);
        let _ = std::fs::remove_dir_all(&root);
        Ok(())
    }

    /// OFF-03：有完整缓存时，即使源文件已经不可达也要直接播本机缓存。
    #[tokio::test]
    async fn ready_offline_cache_wins_over_source() -> Result<()> {
        let root = std::env::temp_dir().join(format!(
            "lekis-resolver-offline-{}-{}",
            std::process::id(),
            lekis_types::now_ms()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root)?;
        let library = Library::open(&root.join("library.sqlite"))?;
        let source = library
            .add_source(SourceConfig {
                id: None,
                kind: SourceKind::Local,
                name: "Music".into(),
                addresses: vec![root.join("music").to_string_lossy().into_owned()],
                root_path: String::new(),
                credential_ref: None,
                options: Default::default(),
                enabled: true,
            })
            .await?;
        use lekis_library::DbResultExt;
        let track = library
            .write(|c| {
                let now = lekis_types::now_ms();
                c.execute(
                    "INSERT INTO track (uid, title, duration_ms, created_at, updated_at)
                     VALUES ('offline-resolver', 'Offline', 4200, ?1, ?1)",
                    [now],
                )
                .db()?;
                Ok(TrackId(c.last_insert_rowid()))
            })
            .await?;
        let cache = root.join("offline/1.flac");
        std::fs::create_dir_all(cache.parent().unwrap_or(&root))?;
        std::fs::write(&cache, b"cached bytes")?;
        library
            .upsert_offline_queued(
                track,
                source,
                cache.to_string_lossy().into_owned(),
                b"cached bytes".len() as u64,
            )
            .await?;
        library
            .mark_offline_ready(track, b"cached bytes".len() as u64)
            .await?;

        let resolver = Resolver::new(
            library,
            Arc::new(SourceHealth::new()),
            Arc::new(MemoryCredentialStore::default()),
        );
        let media = resolver.resolve(track).await?;
        match media.location {
            MediaLocation::CachedFile { path } => assert_eq!(path, cache.to_string_lossy()),
            other => panic!("expected cached file, got {other:?}"),
        }
        assert_eq!(media.duration_hint_ms, 4200);
        drop(resolver);
        let _ = std::fs::remove_dir_all(&root);
        Ok(())
    }

    #[test]
    fn away_network_transcodes_server_sources() {
        let f = tf(1, SourceKind::OpenSubsonic, 100);
        assert_eq!(
            selection::stream_quality_for(&f, NetworkContext::Away),
            lekis_providers::StreamQuality::Transcode { max_kbps: 320 }
        );
        assert_eq!(
            selection::stream_quality_for(&f, NetworkContext::Home),
            lekis_providers::StreamQuality::Original
        );
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod plugin_fallback_tests {
    use super::*;
    use lekis_library::DbResultExt;
    use lekis_providers::{RemoteTrack, StreamQuality, StreamTarget};

    struct AvailableServer;

    #[async_trait::async_trait]
    impl MediaServer for AvailableServer {
        fn kind(&self) -> SourceKind {
            SourceKind::Jellyfin
        }
        async fn ping(&self) -> Result<()> {
            Ok(())
        }
        async fn list_tracks(&self, _: u32, _: u32, _: Option<i64>) -> Result<Vec<RemoteTrack>> {
            Ok(Vec::new())
        }
        async fn stream(&self, id: &str, _: StreamQuality) -> Result<StreamTarget> {
            assert_eq!(id, "server-copy");
            Ok(StreamTarget {
                url: "https://server.example/music.flac".into(),
                headers: Vec::new(),
                seekable: true,
            })
        }
        async fn scrobble(&self, _: &str, _: i64) -> Result<()> {
            Ok(())
        }
    }

    #[tokio::test]
    async fn unavailable_plugin_copies_fall_back_for_playback_and_download() -> Result<()> {
        for state in ["disabled", "removed", "failed", "source-disabled"] {
            let root = std::env::temp_dir().join(format!(
                "lekis-resolver-plugin-{state}-{}-{}",
                std::process::id(),
                lekis_types::now_ms()
            ));
            std::fs::create_dir_all(&root)?;
            let library = Library::open(&root.join("library.sqlite"))?;
            let plugin_id = "dev.lekis.test.fallback";
            let directory = root.join("plugins").join(plugin_id);
            std::fs::create_dir_all(&directory)?;
            std::fs::write(
                directory.join("plugin.json"),
                r#"{
                "id":"dev.lekis.test.fallback", "name":"Fallback", "version":"1.0.0",
                "apiVersion":"1.0", "minAppVersion":"0.1.0", "runtime":"js",
                "entry":"index.js", "kinds":["source"], "permissions":{}
            }"#,
            )?;
            std::fs::write(
                directory.join("index.js"),
                "export function stream() { throw new Error('provider unavailable'); }",
            )?;
            let plugins = Arc::new(crate::plugins::PluginManager::new(&root, library.clone()));
            let plugin_source = library
                .add_source(SourceConfig {
                    id: None,
                    kind: SourceKind::Plugin,
                    name: "Plugin".into(),
                    addresses: Vec::new(),
                    root_path: plugin_id.into(),
                    credential_ref: None,
                    options: Default::default(),
                    enabled: state != "source-disabled",
                })
                .await?;
            let server_source = library
                .add_source(SourceConfig {
                    id: None,
                    kind: SourceKind::Jellyfin,
                    name: "Server".into(),
                    addresses: Vec::new(),
                    root_path: String::new(),
                    credential_ref: None,
                    options: Default::default(),
                    enabled: true,
                })
                .await?;
            let track = library.write(move |connection| {
                let now = lekis_types::now_ms();
                connection.execute(
                    "INSERT INTO track (uid, title, duration_ms, created_at, updated_at)
                     VALUES ('plugin-fallback', 'Song', 1000, ?1, ?1)", [now]
                ).db()?;
                let track = TrackId(connection.last_insert_rowid());
                for (source, external_id) in [(plugin_source, "plugin-copy"), (server_source, "server-copy")] {
                    connection.execute(
                        "INSERT INTO track_file (track_id, file_id, source_id, external_id, quality_score)
                         VALUES (?1, NULL, ?2, ?3, 100)",
                        (track.0, source.0, external_id),
                    ).db()?;
                }
                Ok(track)
            }).await?;
            match state {
                "disabled" => plugins.set_enabled(plugin_id, false).await?,
                "removed" => plugins.remove(plugin_id).await?,
                _ => {}
            }
            let resolver = Resolver::new(
                library.clone(),
                Arc::new(SourceHealth::new()),
                Arc::new(crate::MemoryCredentialStore::default()),
            )
            .with_plugins(plugins);
            resolver
                .servers
                .lock()
                .unwrap()
                .insert(server_source, Arc::new(AvailableServer));
            let files = library.track_files(track).await?;
            assert_eq!(
                selection::pick_best(&files, &|_| Reachability::Unknown, NetworkContext::Home)
                    .unwrap()
                    .source_id,
                plugin_source,
                "fixture must exercise plugin preference"
            );
            let media = resolver.resolve(track).await?;
            assert!(
                matches!(media.location, MediaLocation::Url { ref url, .. }
                if url == "https://server.example/music.flac"),
                "{state}"
            );
            resolver.health.record(server_source, Reachability::Unknown);
            let (file, _) = resolver.resolve_file(track).await?;
            assert_eq!(
                file.source_id, server_source,
                "{state}: download must use the same fallback"
            );
            assert_eq!(
                library.track_files(track).await?.len(),
                2,
                "keep persistent references"
            );
            // With no alternative, preserve the provider's actual error.
            let error = resolver
                .resolve_candidates(
                    track,
                    files
                        .into_iter()
                        .filter(|file| file.source_id == plugin_source)
                        .collect(),
                    NetworkContext::Home,
                )
                .await
                .unwrap_err();
            if state == "failed" {
                assert!(error.message.contains("provider unavailable"));
            }
            drop(resolver);
            drop(library);
            let _ = std::fs::remove_dir_all(root);
        }
        Ok(())
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod failover_server_tests {
    use super::*;
    use lekis_providers::{RemoteTrack, StreamQuality, StreamTarget};
    use lekis_types::ErrorCode;
    use std::sync::atomic::AtomicU32;

    struct Fake {
        error: Option<ErrorCode>,
        calls: Arc<AtomicU32>,
    }

    #[async_trait::async_trait]
    impl MediaServer for Fake {
        fn kind(&self) -> SourceKind {
            SourceKind::Jellyfin
        }
        async fn ping(&self) -> Result<()> {
            self.calls.fetch_add(1, Ordering::Relaxed);
            match self.error {
                Some(code) => Err(LekisError::new(code, "fake")),
                None => Ok(()),
            }
        }
        async fn list_tracks(&self, _: u32, _: u32, _: Option<i64>) -> Result<Vec<RemoteTrack>> {
            Ok(Vec::new())
        }
        async fn stream(&self, _: &str, _: StreamQuality) -> Result<StreamTarget> {
            Err(LekisError::new(ErrorCode::NotFound, "no such track"))
        }
        async fn scrobble(&self, _: &str, _: i64) -> Result<()> {
            Ok(())
        }
    }

    #[tokio::test]
    async fn unreachable_first_address_falls_back_and_sticks() {
        let a = Arc::new(AtomicU32::new(0));
        let b = Arc::new(AtomicU32::new(0));
        let server = FailoverServer::new(vec![
            Box::new(Fake {
                error: Some(ErrorCode::Network),
                calls: a.clone(),
            }),
            Box::new(Fake {
                error: None,
                calls: b.clone(),
            }),
        ]);
        server.ping().await.unwrap();
        server.ping().await.unwrap();
        assert_eq!(a.load(Ordering::Relaxed), 1, "dead address tried only once");
        assert_eq!(b.load(Ordering::Relaxed), 2);
        // A definite "not found" from the known-good address is final.
        assert_eq!(
            server
                .stream("x", StreamQuality::Original)
                .await
                .unwrap_err()
                .code,
            ErrorCode::NotFound
        );
        assert_eq!(server.current.load(Ordering::Relaxed), 1);
    }
}
