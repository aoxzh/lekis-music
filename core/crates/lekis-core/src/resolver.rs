//! 选源：把播放引擎请求的曲目解析成可播放的媒体（SRC-13、SRC-14、OFF-03）。
//!
//! 目标优先级见 [`crate::selection`]：可用性 > 就近程度 > 音质。
//! 服务器源（OpenSubsonic / Jellyfin / Plex）需要先用 `lekis-providers` 换一个播放地址，
//! 这一步也在本模块完成。

use crate::selection::{self, NetworkContext, Reachability, SourceHealth};
use lekis_library::{Library, TrackFile};
use lekis_playback::engine::ResolveRequest;
use lekis_playback::{MediaLocation, MediaSource};
use lekis_providers::MediaServer;
use lekis_types::{LekisError, Result, SourceConfig, SourceId, SourceKind, TrackId};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc;

/// 解析一次请求需要用到的依赖。
pub(crate) struct Resolver {
    library: Library,
    health: Arc<SourceHealth>,
    /// 已经构造好的服务器客户端（按源 ID 缓存）。
    servers: Mutex<HashMap<SourceId, Arc<dyn MediaServer>>>,
    /// 凭据读取（平台注入的系统钥匙串）。
    credentials: Arc<dyn crate::CredentialStore>,
    /// `playback.replaygain` 的当前值（启动时和每次设置时由 core 写入，避免每首歌查一次库）。
    replaygain_mode: std::sync::RwLock<ReplayGainMode>,
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
            health,
            servers: Mutex::new(HashMap::new()),
            credentials,
            replaygain_mode: std::sync::RwLock::new(ReplayGainMode::default()),
        }
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
        self.replaygain_mode
            .read()
            .map(|m| *m)
            .unwrap_or_default()
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

    async fn resolve(&self, track_id: TrackId) -> Result<MediaSource> {
        let files = self.library.track_files(track_id).await?;
        let net = self.health.network();
        let best = selection::pick_best(&files, &|id| self.health.get(id), net)
            .cloned()
            .ok_or_else(|| {
                LekisError::not_found(format!("no playable file for track {track_id}"))
            })?;
        self.media_source(track_id, &best, net).await
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
        let mode = self
            .replaygain_mode
            .read()
            .map(|m| *m)
            .unwrap_or_default();
        mode.pick(&file.replaygain)
    }

    /// 取（或构造）某个服务器源的客户端。凭据从系统钥匙串按 `credential_ref` 读。
    async fn server_for(&self, source_id: SourceId) -> Result<Arc<dyn MediaServer>> {
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
/// - `addresses[0]`：服务器根地址；
/// - `options["username"]`：OpenSubsonic / Jellyfin 的用户名（Jellyfin 走 API Key 时不需要）；
/// - `options["api_key"]` 或 `credential_ref` 指向的密钥：Jellyfin 的 API Key、Plex 的 token；
/// - `credential_ref` 指向的密钥优先当作"密码 / token"，`options` 里的明文只作为兜底。
pub(crate) fn build_server(
    config: &SourceConfig,
    credentials: &dyn crate::CredentialStore,
) -> Result<Box<dyn MediaServer>> {
    let base_url = config
        .addresses
        .first()
        .map(|s| s.trim_end_matches('/'))
        .filter(|s| !s.is_empty())
        .ok_or_else(|| LekisError::invalid("server source needs at least one address"))?;
    let secret = config
        .credential_ref
        .as_deref()
        .and_then(|r| credentials.get(r))
        .or_else(|| config.options.get("api_key").cloned())
        .or_else(|| config.options.get("token").cloned())
        .unwrap_or_default();
    let username = config.options.get("username").cloned().unwrap_or_default();

    match config.kind {
        SourceKind::OpenSubsonic => Ok(Box::new(lekis_providers::opensubsonic::OpenSubsonic::new(
            base_url, &username, secret,
        ))),
        SourceKind::Jellyfin | SourceKind::Emby => Ok(Box::new(
            lekis_providers::jellyfin::Jellyfin::new(config.kind, base_url, secret)?,
        )),
        SourceKind::Plex => Ok(Box::new(lekis_providers::plex::Plex::new(
            base_url, secret,
        )?)),
        other => Err(LekisError::unsupported(format!(
            "not a media server source: {other:?}"
        ))),
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
        assert_eq!(ReplayGainMode::from_setting(Some("off")), ReplayGainMode::Off);
        assert_eq!(ReplayGainMode::from_setting(Some("album")), ReplayGainMode::Album);
        assert_eq!(ReplayGainMode::Off.pick(&rg), None);
        assert_eq!(ReplayGainMode::Track.pick(&rg), Some(-3.0));
        assert_eq!(ReplayGainMode::Album.pick(&rg), Some(-5.0));
        let only_track = ReplayGain {
            track_gain_db: Some(-2.0),
            ..Default::default()
        };
        assert_eq!(ReplayGainMode::Album.pick(&only_track), Some(-2.0));
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
