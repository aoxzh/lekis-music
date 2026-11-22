//! 媒体解析（CST-03）：两台设备的资料库不一样，被控端要从**自己能访问**的地方播放。
//!
//! 被控端按顺序尝试：
//! 1. **同一个音源**：控制端的文件在某个 SMB / WebDAV / NFS / SFTP 共享或媒体服务器上，
//!    被控端也接了同一个（按地址匹配，允许一边接的是另一边的子目录）→ 直接从音源读；
//! 2. **自己资料库里的同一首歌**：跨设备 ID（`TrackUid`）、MusicBrainz 录音 ID；
//! 3. **局域网流**：控制端用自己的核心把文件以 HTTP Range 的方式流过来（一次转移一批随机令牌）。
//!
//! 第 1 步命中但被控端没扫描过那个文件时，用一个合成的曲目 ID（[`ConnectMediaId`]）
//! 记住"从哪个音源的哪个路径读"，元数据只放内存。

use super::protocol::{FileRef, MediaVia, QueueReport, RemoteTrack, TrackRef};
use crate::Services;
use lekis_types::{
    ConnectMediaId, PodcastEpisodeId, RadioStationId, Result, SourceConfig, SourceId, SourceKind,
    TrackId,
};
use std::collections::HashMap;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Mutex;

/// 被控端上一首远端曲目从哪里读。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum RemoteLocation {
    /// 本机某个文件系统类音源里的路径。
    Vfs { source_id: SourceId, path: String },
    /// HTTP 地址（控制端的局域网流、电台 / 播客的原始地址）。
    Url { url: String },
}

/// 一首远端曲目。
#[derive(Debug, Clone)]
pub(crate) struct RemoteMedia {
    pub location: RemoteLocation,
    pub via: MediaVia,
    pub track: TrackRef,
}

/// 被控端：当前远端队列的合成曲目和每首歌的解析方式。
#[derive(Default)]
pub(crate) struct RemoteMediaRegistry {
    next: AtomicI64,
    media: Mutex<HashMap<ConnectMediaId, RemoteMedia>>,
    /// 资料库里的真实曲目是怎么匹配上的（显示"从哪里播"用）。
    vias: Mutex<HashMap<TrackId, MediaVia>>,
    /// 已经从控制端取回的封面。
    artwork: Mutex<HashMap<ConnectMediaId, lekis_types::ArtworkId>>,
}

impl RemoteMediaRegistry {
    pub(crate) fn get(&self, id: ConnectMediaId) -> Option<RemoteMedia> {
        self.media.lock().ok()?.get(&id).cloned()
    }

    pub(crate) fn via(&self, track_id: TrackId) -> Option<MediaVia> {
        if let Some(id) = ConnectMediaId::from_track_id(track_id) {
            return self.get(id).map(|m| m.via);
        }
        self.vias.lock().ok()?.get(&track_id).copied()
    }

    fn insert(&self, media: RemoteMedia) -> TrackId {
        let id = ConnectMediaId(self.next.fetch_add(1, Ordering::Relaxed) + 1);
        if let Ok(mut map) = self.media.lock() {
            map.insert(id, media);
        }
        id.track_id()
    }

    /// 新队列来了：丢掉旧的合成曲目（引擎已经不会再引用它们）。
    fn reset(&self) {
        if let Ok(mut map) = self.media.lock() {
            map.clear();
        }
        if let Ok(mut map) = self.vias.lock() {
            map.clear();
        }
        if let Ok(mut map) = self.artwork.lock() {
            map.clear();
        }
    }

    pub(crate) fn cached_artwork(&self, id: ConnectMediaId) -> Option<lekis_types::ArtworkId> {
        self.artwork.lock().ok()?.get(&id).copied()
    }

    pub(crate) fn remember_artwork(&self, id: ConnectMediaId, artwork: lekis_types::ArtworkId) {
        if let Ok(mut map) = self.artwork.lock() {
            map.insert(id, artwork);
        }
    }

    fn note_via(&self, track_id: TrackId, via: MediaVia) {
        if let Ok(mut map) = self.vias.lock() {
            map.insert(track_id, via);
        }
    }
}

/// 规范化音源地址，用于比较两台设备上的"同一个音源"：
/// 去掉凭据、协议和主机名转小写、`\` 换成 `/`、去掉末尾的 `/`。
pub(crate) fn normalize_address(raw: &str) -> String {
    let raw = raw.trim().replace('\\', "/");
    if let Ok(url) = url::Url::parse(&raw) {
        if url.has_host() {
            let host = url.host_str().unwrap_or_default().to_ascii_lowercase();
            let port = url.port().map(|p| format!(":{p}")).unwrap_or_default();
            let path = percent_decode(url.path());
            return format!("{}://{host}{port}{}", url.scheme(), path)
                .trim_end_matches('/')
                .to_string();
        }
    }
    raw.trim_end_matches('/').to_string()
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(b) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(b);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8(out).unwrap_or_else(|_| s.to_string())
}

/// 去掉地址里的 `user:pass@`（发给别的设备前）。
fn strip_credentials(raw: &str) -> String {
    match url::Url::parse(raw) {
        Ok(mut url) if url.has_host() => {
            let _ = url.set_username("");
            let _ = url.set_password(None);
            url.to_string()
        }
        _ => raw.to_string(),
    }
}

/// 控制端的文件能不能在被控端的某个音源里找到：返回 (音源, 被控端上的相对路径)。
pub(crate) fn match_file(file: &FileRef, sources: &[SourceConfig]) -> Option<(SourceId, String)> {
    // 本地文件夹的路径只在那台机器上有意义。
    if file.kind == SourceKind::Local {
        return None;
    }
    for source in sources {
        let Some(id) = source.id else { continue };
        if !source.enabled || source.kind != file.kind {
            continue;
        }
        for theirs in &file.addresses {
            let theirs = normalize_address(theirs);
            for mine in &source.addresses {
                let mine = normalize_address(mine);
                if file.kind.is_filesystem() {
                    let full = if file.path.is_empty() {
                        theirs.clone()
                    } else {
                        format!("{theirs}/{}", file.path.trim_start_matches('/'))
                    };
                    if let Some(rest) = full.strip_prefix(&format!("{mine}/")) {
                        if !rest.is_empty() {
                            return Some((id, rest.to_string()));
                        }
                    }
                } else if theirs == mine {
                    return Some((id, String::new()));
                }
            }
        }
    }
    None
}

// ---------------------------------------------------------------------------
// 控制端：把本机队列里的一首歌描述出来
// ---------------------------------------------------------------------------

/// 描述一首本机曲目。`stream_url` 由调用方（拿到令牌后）传进来。
pub(crate) async fn describe_track(
    s: &Services,
    sources: &HashMap<SourceId, SourceConfig>,
    id: TrackId,
    stream_url: Option<String>,
) -> Result<TrackRef> {
    if let Some(media) = ConnectMediaId::from_track_id(id).and_then(|m| s.resolver.connect().get(m))
    {
        // 本机正在播别人推来的歌：原样转交（流地址还指向最初的那台设备）。
        return Ok(media.track);
    }
    if let Some(station) = RadioStationId::from_track_id(id) {
        let station = s.library.radio_station(station).await?;
        return Ok(TrackRef {
            uid: format!("radio:{}", station.url),
            title: station.name,
            artist: "网络电台".into(),
            stream_url: Some(station.url),
            ..Default::default()
        });
    }
    if let Some(episode) = PodcastEpisodeId::from_track_id(id) {
        let episode = s.library.podcast_episode(episode).await?;
        return Ok(TrackRef {
            uid: format!("podcast:{}", episode.audio_url),
            title: episode.title,
            artist: episode.podcast_title,
            duration_ms: episode.duration_ms,
            stream_url: Some(episode.audio_url),
            ..Default::default()
        });
    }
    let track = s.library.get_track(id).await?;
    let files = s.library.track_files(id).await.unwrap_or_default();
    let files = files
        .into_iter()
        .filter_map(|f| {
            let source = sources.get(&f.source_id)?;
            Some(FileRef {
                kind: f.source_kind,
                addresses: source
                    .addresses
                    .iter()
                    .map(|a| strip_credentials(a))
                    .collect(),
                path: f.path,
                external_id: f.external_id,
            })
        })
        .collect();
    Ok(TrackRef {
        uid: track.uid.0.clone(),
        mbid: track.mbid_recording.clone(),
        title: track.title.clone(),
        artist: track
            .artists
            .iter()
            .map(|a| a.name.as_str())
            .collect::<Vec<_>>()
            .join(" / "),
        album: track.album_title.clone(),
        duration_ms: track.duration_ms,
        files,
        stream_url,
    })
}

// ---------------------------------------------------------------------------
// 被控端：把收到的描述变成本机可播放的曲目
// ---------------------------------------------------------------------------

/// 解析一首；实在没法播放时返回 `None`。
pub(crate) async fn resolve_ref(
    s: &Services,
    sources: &[SourceConfig],
    r: &TrackRef,
) -> Option<(TrackId, MediaVia)> {
    let registry = s.resolver.connect();
    // 1. 同一个音源。
    for file in &r.files {
        let Some((source_id, path)) = match_file(file, sources) else {
            continue;
        };
        let found = if file.kind.is_filesystem() {
            s.library
                .find_track_by_file(source_id, &path)
                .await
                .ok()
                .flatten()
        } else {
            match &file.external_id {
                Some(ext) => s
                    .library
                    .find_track_by_external(source_id, ext)
                    .await
                    .ok()
                    .flatten(),
                None => None,
            }
        };
        if let Some(id) = found {
            registry.note_via(id, MediaVia::SameSource);
            return Some((id, MediaVia::SameSource));
        }
        if file.kind.is_filesystem() {
            let id = registry.insert(RemoteMedia {
                location: RemoteLocation::Vfs { source_id, path },
                via: MediaVia::SameSource,
                track: r.clone(),
            });
            return Some((id, MediaVia::SameSource));
        }
    }
    // 2. 自己资料库里的同一首歌。
    let mut found = if r.uid.is_empty() {
        None
    } else {
        s.library.find_track_by_uid(&r.uid).await.ok().flatten()
    };
    if found.is_none() {
        if let Some(mbid) = r.mbid.as_deref() {
            found = s.library.find_track_by_mbid(mbid).await.ok().flatten();
        }
    }
    if found.is_none() && !r.title.is_empty() {
        // 两边的 uid 生成方式不同时（一边有 MBID、一边没有），再按元数据算一次。
        let uid = lekis_types::TrackUid::from_metadata(
            &r.artist,
            &r.title,
            r.album.as_deref().unwrap_or_default(),
            r.duration_ms,
        );
        if uid.0 != r.uid {
            found = s.library.find_track_by_uid(&uid.0).await.ok().flatten();
        }
    }
    if let Some(id) = found {
        registry.note_via(id, MediaVia::Library);
        return Some((id, MediaVia::Library));
    }
    // 3. 局域网流（或电台 / 播客的原始地址）。
    let url = r.stream_url.clone()?;
    let id = registry.insert(RemoteMedia {
        location: RemoteLocation::Url { url },
        via: MediaVia::Stream,
        track: r.clone(),
    });
    Some((id, MediaVia::Stream))
}

/// 解析整个队列。`start` 指向的那首解析失败时，从它后面第一首能播的开始。
pub(crate) async fn resolve_queue(
    s: &Services,
    items: &[TrackRef],
    start: u32,
) -> Result<(Vec<TrackId>, usize, QueueReport)> {
    s.resolver.connect().reset();
    let sources = s.library.list_sources().await?;
    let mut report = QueueReport {
        total: items.len() as u32,
        ..Default::default()
    };
    let mut ids = Vec::with_capacity(items.len());
    let mut new_start = None;
    for (i, item) in items.iter().enumerate() {
        match resolve_ref(s, &sources, item).await {
            Some((id, via)) => {
                match via {
                    MediaVia::Library => report.library += 1,
                    MediaVia::SameSource => report.same_source += 1,
                    MediaVia::Stream => report.stream += 1,
                }
                if i as u32 >= start && new_start.is_none() {
                    new_start = Some(ids.len());
                }
                ids.push(id);
            }
            None => report.skipped += 1,
        }
    }
    let start = new_start.unwrap_or(ids.len().saturating_sub(1));
    Ok((ids, start, report))
}

impl RemoteMedia {
    /// 资料库以外的远端曲目，按普通曲目的样子给「正在播放」和队列用。
    pub(crate) fn as_track(&self, id: TrackId) -> lekis_types::Track {
        use lekis_types::{ArtistCredit, ArtistRole, Track, TrackUid};
        Track {
            id,
            uid: TrackUid(self.track.uid.clone()),
            title: self.track.title.clone(),
            sort_title: None,
            artists: self
                .track
                .artist
                .split(" / ")
                .filter(|a| !a.is_empty())
                .map(|name| ArtistCredit {
                    artist_id: None,
                    name: name.to_string(),
                    role: ArtistRole::Main,
                })
                .collect(),
            album_id: None,
            album_title: self.track.album.clone(),
            track_no: None,
            disc_no: None,
            year: None,
            duration_ms: self.track.duration_ms,
            genres: Vec::new(),
            mbid_recording: self.track.mbid.clone(),
            audio: None,
            replaygain: Default::default(),
            artwork_id: None,
            overlay: None,
            is_local: false,
        }
    }

    /// 播放队列里的一行。
    pub(crate) fn as_row(&self, id: TrackId) -> lekis_types::TrackRow {
        lekis_types::TrackRow {
            id,
            title: self.track.title.clone(),
            artist_line: self.track.artist.clone(),
            album_title: self.track.album.clone(),
            duration_ms: self.track.duration_ms,
            artwork_id: None,
            quality_badge: None,
            loved: false,
            is_local: false,
        }
    }
}

/// 远端曲目的封面：第一次从控制端的 `/artwork/<令牌>` 取回并放进本机封面缓存
/// （不挂到任何曲目上），之后直接用缓存。
pub(crate) async fn remote_artwork(
    s: &Services,
    id: TrackId,
) -> Result<Option<lekis_library::ArtworkRow>> {
    let Some(media_id) = ConnectMediaId::from_track_id(id) else {
        return Ok(None);
    };
    let registry = s.resolver.connect();
    if let Some(artwork) = registry.cached_artwork(media_id) {
        return s.library.get_artwork(artwork).await.map(Some);
    }
    let Some(url) = registry
        .get(media_id)
        .and_then(|m| m.track.stream_url)
        .and_then(|u| super::stream::artwork_url_for(&u))
    else {
        return Ok(None);
    };
    let target = crate::enrich::ArtworkTarget {
        track_id: None,
        album_id: None,
        replace_album: false,
    };
    let artwork = match crate::enrich::store_artwork(
        &s.config.cache_dir,
        &s.library,
        target,
        &url,
        "connect",
    )
    .await
    {
        Ok(a) => a,
        Err(e) => {
            tracing::debug!(target: "connect", %id, error = %e, "remote artwork unavailable");
            return Ok(None);
        }
    };
    registry.remember_artwork(media_id, artwork);
    s.library.get_artwork(artwork).await.map(Some)
}

/// 合成 ID 对应的远端曲目（不是远端曲目、或者已经过期时返回 `None`）。
pub(crate) fn remote_media(s: &Services, id: TrackId) -> Option<RemoteMedia> {
    ConnectMediaId::from_track_id(id).and_then(|m| s.resolver.connect().get(m))
}

/// 被控端上一首歌的显示信息。
pub(crate) async fn remote_track(s: &Services, id: TrackId) -> RemoteTrack {
    let via = s.resolver.connect().via(id);
    if let Some(media) = ConnectMediaId::from_track_id(id).and_then(|m| s.resolver.connect().get(m))
    {
        return RemoteTrack {
            id: id.0,
            uid: Some(media.track.uid),
            title: media.track.title,
            artist: media.track.artist,
            album: media.track.album,
            duration_ms: media.track.duration_ms,
            via,
        };
    }
    let track = if let Some(station) = RadioStationId::from_track_id(id) {
        s.library
            .radio_station(station)
            .await
            .ok()
            .map(|st| crate::radio::station_track(&st))
    } else if let Some(episode) = PodcastEpisodeId::from_track_id(id) {
        s.library
            .podcast_episode(episode)
            .await
            .ok()
            .map(|e| crate::podcast::episode_track(&e))
    } else {
        s.library.get_track(id).await.ok()
    };
    match track {
        Some(t) => RemoteTrack {
            id: id.0,
            uid: Some(t.uid.0),
            title: t.title,
            artist: t
                .artists
                .iter()
                .map(|a| a.name.as_str())
                .collect::<Vec<_>>()
                .join(" / "),
            album: t.album_title,
            duration_ms: t.duration_ms,
            via,
        },
        None => RemoteTrack {
            id: id.0,
            via,
            ..Default::default()
        },
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    fn source(id: i64, kind: SourceKind, address: &str) -> SourceConfig {
        SourceConfig {
            id: Some(SourceId(id)),
            kind,
            name: "s".into(),
            addresses: vec![address.into()],
            root_path: String::new(),
            credential_ref: None,
            options: Default::default(),
            enabled: true,
        }
    }

    fn file(kind: SourceKind, address: &str, path: &str) -> FileRef {
        FileRef {
            kind,
            addresses: vec![address.into()],
            path: path.into(),
            external_id: None,
        }
    }

    #[test]
    fn same_share_matches_with_case_and_credentials_ignored() {
        let mine = [source(3, SourceKind::Smb, "smb://NAS.local/Music/")];
        let f = file(
            SourceKind::Smb,
            "smb://user:pw@nas.local/Music",
            "周杰伦/晴天.flac",
        );
        assert_eq!(
            match_file(&f, &mine),
            Some((SourceId(3), "周杰伦/晴天.flac".into()))
        );
    }

    #[test]
    fn subfolder_share_maps_the_remaining_path() {
        // 被控端接的是共享里的子目录，控制端接的是整个共享。
        let mine = [source(5, SourceKind::Smb, "smb://nas/music/华语")];
        let f = file(SourceKind::Smb, "smb://nas/music", "华语/周杰伦/晴天.flac");
        assert_eq!(
            match_file(&f, &mine),
            Some((SourceId(5), "周杰伦/晴天.flac".into()))
        );
        // 反过来：被控端接的是整个共享。
        let mine = [source(6, SourceKind::Smb, "smb://nas/music")];
        let f = file(SourceKind::Smb, "smb://nas/music/华语", "周杰伦/晴天.flac");
        assert_eq!(
            match_file(&f, &mine),
            Some((SourceId(6), "华语/周杰伦/晴天.flac".into()))
        );
    }

    #[test]
    fn different_host_kind_or_local_does_not_match() {
        let mine = [
            source(1, SourceKind::Smb, "smb://other/music"),
            source(2, SourceKind::WebDav, "http://nas/music"),
            source(3, SourceKind::Local, "C:/Music"),
        ];
        assert_eq!(
            match_file(&file(SourceKind::Smb, "smb://nas/music", "a.flac"), &mine),
            None
        );
        assert_eq!(
            match_file(&file(SourceKind::Local, "C:/Music", "a.flac"), &mine),
            None
        );
        // 前缀但不是目录边界。
        let mine = [source(4, SourceKind::Smb, "smb://nas/mus")];
        assert_eq!(
            match_file(&file(SourceKind::Smb, "smb://nas/music", "a.flac"), &mine),
            None
        );
    }

    #[test]
    fn server_sources_match_by_address() {
        let mine = [source(9, SourceKind::Jellyfin, "http://192.168.1.2:8096/")];
        let mut f = file(SourceKind::Jellyfin, "http://192.168.1.2:8096", "");
        f.external_id = Some("abc".into());
        assert_eq!(match_file(&f, &mine), Some((SourceId(9), String::new())));
    }

    #[test]
    fn credentials_are_stripped_before_sending() {
        assert_eq!(
            strip_credentials("smb://bob:secret@nas/music"),
            "smb://nas/music"
        );
        assert_eq!(strip_credentials("D:\\Music"), "D:\\Music");
    }
}
