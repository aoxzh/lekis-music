use super::{PluginInfo, PluginManager};
use lekis_enrich::{Candidate, LyricsPayload, TrackHint, AUTO_APPLY_THRESHOLD};
use lekis_plugin_host::Capability;
use lekis_types::{LyricsFormat, Result, SourceKind, TrackId};
use serde::Deserialize;
use serde_json::json;
use std::collections::HashMap;
use std::time::Duration;

#[derive(Deserialize)]
struct PluginLyrics {
    content: String,
    format: LyricsFormat,
    confidence: Option<f32>,
}

impl PluginManager {
    pub(crate) async fn lyric_candidates(
        &self,
        plugins: Vec<PluginInfo>,
        id: TrackId,
        hint: &TrackHint,
    ) -> Result<Vec<Candidate<LyricsPayload>>> {
        let mut origins = HashMap::new();
        for file in self.library.track_files(id).await? {
            if file.source_kind == SourceKind::Plugin {
                if let Some(external) = file.external_id {
                    let source = self.library.get_source(file.source_id).await?;
                    origins.insert(source.root_path, external);
                }
            }
        }
        let track = json!({"title": hint.title, "artists": hint.artists, "album": hint.album, "durationMs": hint.duration_ms, "mbidRecording": hint.mbid_recording});
        let mut candidates = Vec::new();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(8);
        let mut plugins = plugins;
        plugins.sort_by_key(|p| !origins.contains_key(&p.id));
        for plugin in plugins.into_iter().filter(|p| p.enabled) {
            let origin = origins.get(&plugin.id);
            let provides_lyrics = plugin.kinds.iter().any(|k| k == "lyrics");
            let mygo_origin = origin.is_some() && plugin.compatibility.as_deref() == Some("mygo");
            if !(provides_lyrics || mygo_origin)
            {
                continue;
            }
            if tokio::time::Instant::now() >= deadline {
                break;
            }
            let params = json!({"id": origin, "track": track});
            let until = deadline.min(tokio::time::Instant::now() + Duration::from_secs(4));
            let Ok(Ok(value)) =
                tokio::time::timeout_at(until, self.call(&plugin.id, Capability::Lyrics, params))
                    .await
            else {
                continue;
            };
            let Ok(result) = serde_json::from_value::<PluginLyrics>(value) else {
                continue;
            };
            if result.content.trim().is_empty() || result.content.len() > 1024 * 1024 {
                continue;
            }
            // Only a source receiving its own item ID can establish identity directly.
            let maximum = if origin.is_some() {
                1.0
            } else {
                AUTO_APPLY_THRESHOLD - 0.01
            };
            candidates.push(Candidate {
                payload: LyricsPayload {
                    format: result.format,
                    content: result.content,
                },
                source: format!("plugin:{}", plugin.id),
                matched: hint.clone(),
                provider_confidence: result.confidence.unwrap_or(maximum).clamp(0.0, maximum),
            });
        }
        Ok(candidates)
    }
}
