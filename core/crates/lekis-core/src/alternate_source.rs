//! Per-song source selection. Only stable provider references are saved.

use crate::{LekisCore, Services};
use lekis_library::Library;
use lekis_playback::{EngineCommand, MediaLocation, MediaSource};
use lekis_types::{LekisError, Result, SourceKind, TrackId};
use serde::{Deserialize, Serialize};
use tokio::sync::oneshot;

/// Search result which the source plugin resolved to an allowed stream.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AlternateSource {
    /// Installed source plugin.
    pub plugin_id: String,
    /// Opaque track ID in that plugin.
    pub external_id: String,
    /// Display title.
    pub title: String,
    /// Display artists.
    pub artist: String,
    /// Duration hint in milliseconds.
    pub duration_ms: u64,
}

#[derive(Default)]
pub(crate) struct PreviewState {
    serial: u32,
    active: Option<(u32, TrackId, String, AlternateSource)>,
}

fn key(uid: &str) -> String {
    format!("alternate_source.{uid}")
}

pub(crate) async fn save_binding(
    library: &Library,
    uid: &str,
    candidate: &AlternateSource,
) -> Result<()> {
    let json = serde_json::to_string(candidate)
        .map_err(|error| LekisError::internal(error.to_string()))?;
    library.set_setting(&key(uid), &json).await
}

pub(crate) async fn binding(library: &Library, track: TrackId) -> Result<Option<AlternateSource>> {
    let raw = library.track_alternate_source(track).await?;
    raw.map(|json| serde_json::from_str(&json).map_err(|_| LekisError::invalid("换源绑定无效")))
        .transpose()
}

impl AlternateSource {
    pub(crate) async fn media(
        &self,
        library: &Library,
        plugins: &crate::plugins::PluginManager,
        track: TrackId,
    ) -> Result<MediaSource> {
        let sources = library.list_sources().await?;
        if sources
            .iter()
            .any(|s| s.kind == SourceKind::Plugin && s.root_path == self.plugin_id && !s.enabled)
        {
            return Err(LekisError::unsupported("插件音源已停用"));
        }
        let stream = plugins.stream(&self.plugin_id, &self.external_id).await?;
        Ok(MediaSource {
            track_id: track,
            duration_hint_ms: self.duration_ms,
            gain_db: None,
            location: MediaLocation::Url {
                url: stream.url,
                headers: stream.headers.into_iter().collect(),
            },
        })
    }
}

impl LekisCore {
    /// Search one provider without importing its results into the library.
    pub async fn search_alternate_sources(
        &self,
        track: TrackId,
        plugin: String,
        query: String,
    ) -> Result<Vec<AlternateSource>> {
        let s = self.services.clone();
        self.run(async move {
            if query.trim().is_empty() {
                return Ok(Vec::new());
            }
            let sources = s.library.list_sources().await?;
            let source = sources
                .iter()
                .find(|src| src.kind == SourceKind::Plugin && src.root_path == plugin);
            if source.is_some_and(|src| !src.enabled) {
                return Ok(Vec::new());
            }
            let files = s.library.track_files(track).await?;
            if !files.iter().any(|f| !f.source_kind.is_filesystem()) {
                return Err(LekisError::invalid("只有在线曲目支持换源"));
            }
            let original_ids = files
                .into_iter()
                .filter(|f| Some(f.source_id) == source.and_then(|s| s.id))
                .filter_map(|f| f.external_id)
                .collect::<Vec<_>>();
            s.plugins
                .alternate_candidates(&plugin, &query, &original_ids)
                .await
        })
        .await
    }

    /// Retrieve this song's saved choice.
    pub async fn get_alternate_source(&self, track: TrackId) -> Result<Option<AlternateSource>> {
        let s = self.services.clone();
        self.run(async move { binding(&s.library, track).await })
            .await
    }

    /// Start a reversible audition using the engine's configured audio output.
    pub async fn preview_alternate_source(
        &self,
        track: TrackId,
        candidate: AlternateSource,
    ) -> Result<u32> {
        let s = self.services.clone();
        self.run(async move {
            let mut state = s.alternate_preview.lock().await;
            if s.engine.snapshot().track_id != Some(track) {
                return Err(LekisError::invalid("当前曲目已变化"));
            }
            let uid = s.library.get_track(track).await?.uid;
            let media = candidate.media(&s.library, &s.plugins, track).await?;
            state.serial = state.serial.wrapping_add(1).max(1);
            let id = state.serial;
            let (reply, done) = oneshot::channel();
            s.engine
                .send(EngineCommand::PreviewSource { id, media, reply })?;
            done.await
                .map_err(|_| LekisError::internal("试听已中断"))??;
            state.active = Some((id, track, uid.0, candidate));
            Ok(id)
        })
        .await
    }

    /// Cancel an audition or commit the source for future playback.
    pub async fn finish_alternate_source_preview(&self, id: u32, remember: bool) -> Result<()> {
        let s = self.services.clone();
        self.run(async move {
            let mut state = s.alternate_preview.lock().await;
            let Some((_, track, uid, candidate)) = state.active.take_if(|(token, ..)| *token == id)
            else {
                return if remember {
                    Err(LekisError::invalid("试听已结束"))
                } else {
                    Ok(())
                };
            };
            if remember {
                finish(&s, id, true).await?;
                if let Err(error) = save_binding(&s.library, &uid, &candidate).await {
                    s.engine.send(EngineCommand::ReloadSource(track))?;
                    return Err(error);
                }
            } else {
                // Another transport command may already have cancelled this audition.
                let _ = finish(&s, id, false).await;
            }
            Ok(())
        })
        .await
    }

    /// Return to normal source selection, including offline copies.
    pub async fn reset_alternate_source(&self, track: TrackId) -> Result<()> {
        let s = self.services.clone();
        self.run(async move {
            let _guard = s.alternate_preview.lock().await;
            let uid = s.library.get_track(track).await?.uid;
            s.library.delete_setting(&key(&uid.0)).await?;
            s.engine.send(EngineCommand::ReloadSource(track))
        })
        .await
    }
}

async fn finish(s: &Services, id: u32, keep: bool) -> Result<()> {
    let (reply, done) = oneshot::channel();
    s.engine
        .send(EngineCommand::FinishSourcePreview { id, keep, reply })?;
    done.await.map_err(|_| LekisError::internal("试听已中断"))?
}
