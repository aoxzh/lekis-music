use crate::api::dto::LyricsRowDto;
use crate::api::error::CoreError;
use crate::internal::core;
use lekis_types::TrackId;

/// A stored lyric version and the recording metadata supplied by its provider.
#[derive(Debug, Clone)]
pub struct LyricSearchVersionDto {
    pub row: LyricsRowDto,
    pub title: Option<String>,
    pub artists: Vec<String>,
    pub album: Option<String>,
    pub duration_ms: Option<i64>,
}

impl From<lekis_library::LyricSearchVersion> for LyricSearchVersionDto {
    fn from(value: lekis_library::LyricSearchVersion) -> Self {
        Self {
            row: value.row.into(),
            title: value.title,
            artists: value.artists,
            album: value.album,
            duration_ms: value.duration_ms,
        }
    }
}

pub async fn search_lyric_versions(
    track_id: i64,
    title: String,
    artist: String,
) -> Result<Vec<LyricSearchVersionDto>, CoreError> {
    Ok(core()
        .search_lyric_versions(TrackId(track_id), title, artist)
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

pub async fn stored_lyric_versions(track_id: i64) -> Result<Vec<LyricSearchVersionDto>, CoreError> {
    Ok(core()
        .stored_lyric_versions(TrackId(track_id))
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}
