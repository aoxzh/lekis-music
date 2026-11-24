use crate::api::error::CoreError;
use crate::internal::core;
use lekis_core::alternate_source::AlternateSource;
use lekis_types::TrackId;

#[derive(Debug, Clone)]
pub struct AlternateSourceDto {
    pub plugin_id: String,
    pub external_id: String,
    pub title: String,
    pub artist: String,
    pub duration_ms: u64,
}

impl From<AlternateSource> for AlternateSourceDto {
    fn from(value: AlternateSource) -> Self {
        Self {
            plugin_id: value.plugin_id,
            external_id: value.external_id,
            title: value.title,
            artist: value.artist,
            duration_ms: value.duration_ms,
        }
    }
}

impl From<AlternateSourceDto> for AlternateSource {
    fn from(value: AlternateSourceDto) -> Self {
        Self {
            plugin_id: value.plugin_id,
            external_id: value.external_id,
            title: value.title,
            artist: value.artist,
            duration_ms: value.duration_ms,
        }
    }
}

pub async fn search_alternate_sources(
    track_id: i64,
    plugin_id: String,
    query: String,
) -> Result<Vec<AlternateSourceDto>, CoreError> {
    Ok(core()
        .search_alternate_sources(TrackId(track_id), plugin_id, query)
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

pub async fn get_alternate_source(track_id: i64) -> Result<Option<AlternateSourceDto>, CoreError> {
    Ok(core()
        .get_alternate_source(TrackId(track_id))
        .await?
        .map(Into::into))
}

pub async fn preview_alternate_source(
    track_id: i64,
    candidate: AlternateSourceDto,
) -> Result<u32, CoreError> {
    Ok(core()
        .preview_alternate_source(TrackId(track_id), candidate.into())
        .await?)
}

pub async fn finish_alternate_source_preview(
    preview_id: u32,
    remember: bool,
) -> Result<(), CoreError> {
    Ok(core()
        .finish_alternate_source_preview(preview_id, remember)
        .await?)
}

pub async fn reset_alternate_source(track_id: i64) -> Result<(), CoreError> {
    Ok(core().reset_alternate_source(TrackId(track_id)).await?)
}
