use crate::api::error::CoreError;
use crate::internal::core;
use lekis_core::music_export::{ExportOptions, ExportSelection};
use lekis_types::{AlbumId, LekisError, TrackId};

pub struct MusicExportItemDto {
    pub track_id: i64,
    pub title: String,
    pub output_path: Option<String>,
    pub error: Option<String>,
}

pub async fn export_music(
    track_id: Option<i64>,
    album_id: Option<i64>,
    directory: String,
    name_template: String,
    include_artwork: bool,
    include_lyrics: bool,
) -> Result<Vec<MusicExportItemDto>, CoreError> {
    let selection = match (track_id, album_id) {
        (Some(id), None) if id > 0 => ExportSelection::Track(TrackId(id)),
        (None, Some(id)) if id > 0 => ExportSelection::Album(AlbumId(id)),
        _ => return Err(LekisError::invalid("请选择一首曲目或一张专辑").into()),
    };
    let options = ExportOptions {
        directory: directory.into(),
        name_template,
        include_artwork,
        include_lyrics,
    };
    Ok(core()
        .export_music(selection, options)
        .await?
        .into_iter()
        .map(|item| {
            let (output_path, error) = match item.output {
                Ok(path) => (Some(path.to_string_lossy().into_owned()), None),
                Err(error) => (None, Some(error.message)),
            };
            MusicExportItemDto {
                track_id: item.id.0,
                title: item.title,
                output_path,
                error,
            }
        })
        .collect())
}
