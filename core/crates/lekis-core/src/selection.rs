//! 选源（SRC-13、SRC-14、OFF-03）。
//!
//! 一首歌可能有多个可播放文件（同一份拷贝放在 NAS、移动硬盘、手机本地，或者服务器上还有一份）。
//! 播放时按"**可用性 > 就近程度 > 音质**"打分，取分数最高的一个：
//!
//! 1. 可用性：已知不可达的源直接排除；已知可达的源大幅加分；还不知道的源按"可能可达"处理。
//! 2. 就近程度：本机文件 > 局域网共享（SMB/WebDAV/NFS/SFTP）> 服务器源（需要服务端转码/转发）。
//!    不在家时局域网共享降权，服务器源的地址可以走 Tailscale（SRC-14）。
//! 3. 音质：`track_file.quality_score`（无损 > 有损，位深/采样率/码率越高越好）。
//!
//! 这里的函数都是纯函数，方便测试；可达性状态由 [`SourceHealth`] 维护。

use lekis_library::TrackFile;
use lekis_providers::StreamQuality;
use lekis_types::{SourceId, SourceKind};

/// 源可达性。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Reachability {
    /// 还不知道（刚启动、还没探测过）。按"可能可达"处理，但排在已知可达之后。
    #[default]
    Unknown,
    /// 最近一次访问成功。
    Reachable,
    /// 最近一次访问失败（超时 / 拒绝连接 / 认证失败）。
    Unreachable,
}

/// 网络环境（SRC-14）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum NetworkContext {
    /// 在家：局域网共享直连最快。
    #[default]
    Home,
    /// 在外：局域网共享多半不可达，服务器源 / 缓存优先。
    Away,
}

// 权重。可用性是硬条件，数量级必须远大于"就近"和"音质"。
const BONUS_REACHABLE: i64 = 1_000_000;
const BONUS_UNKNOWN: i64 = 500_000;
const PENALTY_LOCAL_NETWORK_AWAY: i64 = 400_000;

const LOCALITY_LOCAL: i64 = 30_000;
const LOCALITY_LAN: i64 = 15_000;
const LOCALITY_SERVER: i64 = 0;
const LOCALITY_UNKNOWN: i64 = 5_000;

/// 音源的就近程度分。
fn locality(kind: SourceKind, net: NetworkContext) -> i64 {
    match kind {
        SourceKind::Local => LOCALITY_LOCAL,
        // 局域网共享：在家最好，在外基本不可达。
        SourceKind::Smb | SourceKind::WebDav | SourceKind::Nfs | SourceKind::Sftp => match net {
            NetworkContext::Home => LOCALITY_LAN,
            NetworkContext::Away => LOCALITY_LAN - PENALTY_LOCAL_NETWORK_AWAY,
        },
        // 服务器源：地址可能是局域网也可能是 Tailscale，两种环境下都能用。
        SourceKind::OpenSubsonic | SourceKind::Jellyfin | SourceKind::Emby | SourceKind::Plex => {
            LOCALITY_SERVER
        }
        // 电台和插件源优先级最低，只在没有别的东西时才会被选到。
        SourceKind::Radio | SourceKind::Plugin => LOCALITY_UNKNOWN,
    }
}

/// 一个候选文件的分项得分（测试和日志用）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Score {
    /// 可用性分。
    pub availability: i64,
    /// 就近程度分。
    pub locality: i64,
    /// 音质分。
    pub quality: i64,
}

impl Score {
    /// 总分。
    pub fn total(&self) -> i64 {
        self.availability + self.locality + self.quality
    }
}

/// 给一个候选文件打分。`reach` 由调用方从 [`SourceHealth`] 查出来。
pub fn score(file: &TrackFile, reach: Reachability, net: NetworkContext) -> Score {
    let availability = match reach {
        Reachability::Reachable => BONUS_REACHABLE,
        Reachability::Unknown => BONUS_UNKNOWN,
        Reachability::Unreachable => i64::MIN / 2, // 排到最后，等同于排除
    };
    Score {
        availability,
        locality: locality(file.source_kind, net),
        quality: file.quality_score,
    }
}

/// 从候选里挑一个最适合播放的。
///
/// `track_files` 已经按音质降序排好（`Library::track_files` 的 ORDER BY），
/// 这里再做一次完整打分，所以**不依赖**输入顺序。分数相同时按原始顺序取第一个，保证结果稳定。
pub fn pick_best<'a>(
    files: &'a [TrackFile],
    health: &dyn Fn(SourceId) -> Reachability,
    net: NetworkContext,
) -> Option<&'a TrackFile> {
    let mut best: Option<(&TrackFile, i64)> = None;
    for f in files {
        if f.path.is_empty() && f.external_id.is_none() {
            // 既没有路径也没有服务器 ID，说明是坏行，跳过。
            continue;
        }
        let s = score(f, health(f.source_id), net).total();
        match best {
            Some((_, best_score)) if best_score >= s => {}
            _ => best = Some((f, s)),
        }
    }
    best.map(|(f, _)| f)
}

/// 各音源最近一次访问的结果（SRC-13/SRC-14）。
///
/// 只是一份内存缓存，掉了也没关系：`Unknown` 会按"可能可达"处理，然后由实际播放去修正。
#[derive(Debug, Default)]
pub struct SourceHealth {
    inner: std::sync::Mutex<std::collections::HashMap<SourceId, Reachability>>,
    net: std::sync::Mutex<NetworkContext>,
}

impl SourceHealth {
    /// 空状态。
    pub fn new() -> Self {
        Self::default()
    }

    /// 查一个源的可达性。
    pub fn get(&self, id: SourceId) -> Reachability {
        self.inner
            .lock()
            .ok()
            .and_then(|m| m.get(&id).copied())
            .unwrap_or_default()
    }

    /// 记录一次访问结果。
    pub fn record(&self, id: SourceId, reach: Reachability) {
        let Ok(mut m) = self.inner.lock() else { return };
        match reach {
            // 失败要记下来；成功也要记；Unknown 等于清除记录。
            Reachability::Unknown => {
                m.remove(&id);
            }
            other => {
                m.insert(id, other);
            }
        }
    }

    /// 当前网络环境。
    pub fn network(&self) -> NetworkContext {
        self.net.lock().map(|n| *n).unwrap_or_default()
    }

    /// 设置网络环境（平台层在切换 Wi-Fi / 断网时调用，SRC-14）。
    pub fn set_network(&self, net: NetworkContext) {
        if let Ok(mut n) = self.net.lock() {
            *n = net;
        }
    }

    /// 按当前状态挑一个文件。
    pub fn pick<'a>(&self, files: &'a [TrackFile]) -> Option<&'a TrackFile> {
        pick_best(files, &|id| self.get(id), self.network())
    }
}

/// 网络环境相关的辅助：在外时对服务器源要求转码以省流量（PLY-08）。
pub fn stream_quality_for(file: &TrackFile, net: NetworkContext) -> StreamQuality {
    match (net, file.source_kind) {
        // 在外用服务器源：默认转码到 320kbps，避免蜂窝流量爆掉。
        (NetworkContext::Away, SourceKind::OpenSubsonic)
        | (NetworkContext::Away, SourceKind::Jellyfin)
        | (NetworkContext::Away, SourceKind::Emby)
        | (NetworkContext::Away, SourceKind::Plex) => StreamQuality::Transcode { max_kbps: 320 },
        // 在家或者文件系统类源：要原文件（PLY-05 比特完美）。
        _ => StreamQuality::Original,
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use lekis_types::{ReplayGain, SourceId};

    fn file(source: i64, kind: SourceKind, quality: i64) -> TrackFile {
        TrackFile {
            source_id: SourceId(source),
            source_kind: kind,
            path: format!("a/{source}.flac"),
            external_id: None,
            quality_score: quality,
            duration_ms: 200_000,
            replaygain: ReplayGain::default(),
        }
    }

    fn none(_: SourceId) -> Reachability {
        Reachability::Unknown
    }

    #[test]
    fn quality_breaks_ties_between_reachable_sources() {
        let files = [
            file(1, SourceKind::Local, 900),
            file(2, SourceKind::Local, 300),
        ];
        let best = pick_best(&files, &none, NetworkContext::Home).expect("must pick");
        assert_eq!(best.source_id, SourceId(1));
    }

    #[test]
    fn reachability_beats_quality() {
        // 高质量的文件在不可达的源上，必须让位给低质量但可达的。
        let files = [
            file(1, SourceKind::Local, 1000),
            file(2, SourceKind::Local, 100),
        ];
        let health = |id: SourceId| {
            if id == SourceId(1) {
                Reachability::Unreachable
            } else {
                Reachability::Reachable
            }
        };
        let best = pick_best(&files, &health, NetworkContext::Home).expect("must pick");
        assert_eq!(best.source_id, SourceId(2));
    }

    #[test]
    fn unknown_source_loses_to_known_reachable() {
        let files = [
            file(1, SourceKind::Local, 1000),
            file(2, SourceKind::Local, 100),
        ];
        let health = |id: SourceId| {
            if id == SourceId(1) {
                Reachability::Unknown
            } else {
                Reachability::Reachable
            }
        };
        let best = pick_best(&files, &health, NetworkContext::Home).expect("must pick");
        assert_eq!(best.source_id, SourceId(2));
    }

    #[test]
    fn local_file_beats_lan_share_of_same_quality_at_home() {
        let files = [
            file(1, SourceKind::Smb, 500),
            file(2, SourceKind::Local, 500),
        ];
        let best = pick_best(&files, &none, NetworkContext::Home).expect("must pick");
        assert_eq!(best.source_id, SourceId(2));
    }

    #[test]
    fn server_beats_lan_share_when_away() {
        // 在外：SMB 不可达的概率很高，服务器源（可走 Tailscale）应当胜出。
        let files = [
            file(1, SourceKind::Smb, 500),
            file(2, SourceKind::OpenSubsonic, 500),
        ];
        let best = pick_best(&files, &none, NetworkContext::Away).expect("must pick");
        assert_eq!(best.source_id, SourceId(2));
    }

    #[test]
    fn skips_broken_rows() {
        let mut bad = file(1, SourceKind::Local, 1000);
        bad.path = String::new();
        bad.external_id = None;
        let files = [bad, file(2, SourceKind::Local, 10)];
        let best = pick_best(&files, &none, NetworkContext::Home).expect("must pick");
        assert_eq!(best.source_id, SourceId(2));
    }

    #[test]
    fn empty_candidates_yield_none() {
        assert!(pick_best(&[], &none, NetworkContext::Home).is_none());
    }
}
