//! Export library tracks through their configured file sources.
use crate::{artwork_local, enrich, lyrics_local, sidecars, LekisCore, Services};
use lekis_types::{AlbumId, LekisError, Result, Track, TrackId, TrackTagOverrides};
use lekis_vfs::{EntryKind, Vfs, VfsPath};
use std::path::{Path, PathBuf};
use tempfile::NamedTempFile;
use tokio::io::AsyncWriteExt;

/// Catalog item selected for export.
pub enum ExportSelection {
    /// One track.
    Track(TrackId),
    /// Every catalog track in the album.
    Album(AlbumId),
}

/// Destination and metadata choices for one export.
pub struct ExportOptions {
    /// Existing absolute destination directory.
    pub directory: PathBuf,
    /// Filename stem with optional catalog placeholders.
    pub name_template: String,
    /// Keep or embed artwork.
    pub include_artwork: bool,
    /// Keep or embed lyrics.
    pub include_lyrics: bool,
}

/// Publication result for an individual track.
pub struct ExportItem {
    /// Catalog track identifier.
    pub id: TrackId,
    /// Track title for the user-facing report.
    pub title: String,
    /// Published path or the failure that prevented publication.
    pub output: Result<PathBuf>,
}

impl LekisCore {
    /// Write tagged copies and report the outcome of each selected track.
    pub async fn export_music(
        &self,
        selection: ExportSelection,
        mut options: ExportOptions,
    ) -> Result<Vec<ExportItem>> {
        let services = self.services.clone();
        self.run(async move {
            if !options.directory.is_absolute()
                || !tokio::fs::metadata(&options.directory).await?.is_dir()
            {
                return Err(LekisError::invalid("请选择已存在的本地输出目录"));
            }
            options.directory = tokio::fs::canonicalize(&options.directory).await?;
            filename(&options.name_template, &TrackTagOverrides::default(), true)?;
            let tracks = match selection {
                ExportSelection::Track(id) => {
                    vec![(id, services.library.get_track(id).await?.title)]
                }
                ExportSelection::Album(id) => {
                    services.library.get_album(id).await?;
                    let mut tracks = Vec::new();
                    loop {
                        let rows = services
                            .library
                            .album_tracks(id, tracks.len() as u32, 200)
                            .await?;
                        let last = rows.len() < 200;
                        tracks.extend(rows.into_iter().map(|row| (row.id, row.title)));
                        if last {
                            break;
                        }
                    }
                    tracks
                }
            };
            let mut items = Vec::with_capacity(tracks.len());
            for (id, title) in tracks {
                let output = export_track(&services, id, &options).await;
                items.push(ExportItem { id, title, output });
            }
            Ok(items)
        })
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{CoreConfig, PlatformServices};
    use base64::Engine;
    use lekis_library::{ScannedFile, ScannedTags};
    use lekis_scanner::tags::{read_cover_art, read_lyrics, LoftyTagReader, TagReader};
    use lekis_types::{SourceConfig, SourceKind, TrackQuery, TrackSort};
    use lekis_vfs::partial::PartialFile;
    use std::fs;

    const FLAC: &str = concat!(
        "ZkxhQwAAACIBkAGQAADlAADlAfQA8AAAAZCivb5qX62tYkOTeWw2miT8hAAALAwAAABMYXZmNjMuMS4xMDIBAAAA",
        "FAAAAGVuY29kZXI9TGF2ZjYzLjEuMTAy//h0CAABjyROAAAD2wd8CqwNOw8CD+YP2+WZjL3eaWNgqPSOnmHI/s8A",
        "LUoJiJFCklZDEGEMmlCYJgRgIYEYXVMjJ2pKFBYLJZGEdkGEMQwTURJCULSkZNcjEySFiRQlLUxDRhBi8pIoEYC",
        "GBBhaMI5iDFySiLCUCGAgwjJrumJiyJIiRSWXyMuomFihIUCGBBghka2TWUUKIiSKVIYQZO6iwjARgWJYRl6em",
        "vVBMRIJgsJkjCGTutRZEiIoUkxOpyMIMCDAQYCZCwsIxWQxH3ZSQlEUKUIwgYIMQYIGBBggwIDVuA=="
    );

    #[test]
    fn names_stay_in_the_chosen_directory_and_fit_the_filesystem() {
        let mut tags = TrackTagOverrides {
            title: Some("../../bad\\name".into()),
            ..Default::default()
        };
        for bad in ["../{title}", "{title}/x", "{unknown}", "{title", "{title}}"] {
            assert!(filename(bad, &tags, false).is_err());
        }
        assert_eq!(filename("{title}", &tags, false).unwrap(), "_.._bad_name");
        assert_eq!(filename("NUL", &tags, false).unwrap(), "_NUL");
        tags.title = Some("曲".repeat(120));
        assert_eq!(filename("{title}", &tags, false).unwrap(), "曲".repeat(73));
        assert!(filename("{track}", &tags, false).is_err());
    }

    #[tokio::test]
    async fn album_reports_missing_files_and_single_track_keeps_existing_copy() {
        let root = tempfile::tempdir().unwrap();
        let source_dir = root.path().join("source");
        let output_dir = root.path().join("export");
        fs::create_dir(&source_dir).unwrap();
        fs::create_dir(&output_dir).unwrap();
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(FLAC)
            .unwrap();
        fs::write(source_dir.join("a.flac"), &bytes).unwrap();
        let lyric = "[00:00.007]First & second";
        fs::write(source_dir.join("a.lrc"), lyric).unwrap();
        image::RgbImage::new(2, 2)
            .save(source_dir.join("a.png"))
            .unwrap();
        let core = LekisCore::with_runtime(
            CoreConfig::for_tests(root.path()),
            PlatformServices::in_memory(),
            tokio::runtime::Handle::current(),
        )
        .unwrap();
        let library = &core.services.library;
        let source_id = library
            .add_source(SourceConfig {
                id: None,
                kind: SourceKind::Local,
                name: "Fixture".into(),
                addresses: vec![source_dir.display().to_string()],
                root_path: String::new(),
                credential_ref: None,
                options: Default::default(),
                enabled: true,
            })
            .await
            .unwrap();
        let mut batch = Vec::new();
        for (file, title, number) in [("a.flac", "One/Two", 1), ("missing.flac", "Three", 2)] {
            batch.push(ScannedFile {
                source_id,
                path: file.into(),
                size: bytes.len() as u64,
                mtime_ms: 1,
                tags: ScannedTags {
                    title: title.into(),
                    artists: vec!["Artist".into()],
                    album: Some("Album".into()),
                    track_no: Some(number),
                    duration_ms: 50,
                    ..Default::default()
                },
            });
        }
        library.upsert_scanned(batch).await.unwrap();
        let row = &library
            .list_track_rows(TrackQuery {
                sort: TrackSort::Title,
                offset: 0,
                limit: 1,
            })
            .await
            .unwrap()[0];
        let album = library.get_track(row.id).await.unwrap().album_id.unwrap();
        let options = || ExportOptions {
            directory: output_dir.clone(),
            name_template: "{track} {title}".into(),
            include_artwork: true,
            include_lyrics: true,
        };
        let results = core
            .export_music(ExportSelection::Album(album), options())
            .await
            .unwrap();
        assert_eq!(results.len(), 2);
        assert!(results
            .iter()
            .find(|item| item.title == "Three")
            .unwrap()
            .output
            .is_err());
        let path = results
            .iter()
            .find(|item| item.id == row.id)
            .unwrap()
            .output
            .as_ref()
            .unwrap();
        assert_eq!(path.file_name().unwrap(), "01 One_Two.flac");
        let output = fs::read(path).unwrap();
        let data = PartialFile {
            size: output.len() as u64,
            head: output.clone().into(),
            tail: Default::default(),
        };
        let audio_path = VfsPath::parse("export.flac").unwrap();
        let tags = LoftyTagReader.read(&audio_path, &data).unwrap();
        assert_eq!(tags.title, "One/Two");
        assert_eq!(tags.artists, ["Artist"]);
        assert_eq!(tags.album.as_deref(), Some("Album"));
        assert_eq!(tags.track_no, Some(1));
        assert_eq!(
            read_lyrics(&audio_path, &data).unwrap().as_deref(),
            Some(lyric)
        );
        assert_eq!(
            read_cover_art(&audio_path, &data).unwrap().unwrap(),
            fs::read(source_dir.join("a.png")).unwrap()
        );
        let repeated = core
            .export_music(ExportSelection::Track(row.id), options())
            .await
            .unwrap();
        assert!(repeated[0]
            .output
            .as_ref()
            .unwrap_err()
            .message
            .contains("已存在"));
        assert_eq!(fs::read(path).unwrap(), output);
        assert_eq!(fs::read(source_dir.join("a.flac")).unwrap(), bytes);
        assert_eq!(fs::read_dir(output_dir).unwrap().count(), 1);
    }
}

fn forbidden(ch: char) -> bool {
    ch.is_control() || r#"<>:"/\|?*"#.contains(ch)
}

fn filename(template: &str, tags: &TrackTagOverrides, validate_only: bool) -> Result<String> {
    if template.trim().is_empty() || template.len() > 256 || template.contains(forbidden) {
        return Err(LekisError::invalid("文件名模板为空、过长或含非法字符"));
    }
    let track = tags
        .track_no
        .map(|number| format!("{number:02}"))
        .unwrap_or_default();
    let disc = tags
        .disc_no
        .map(|number| number.to_string())
        .unwrap_or_default();
    let mut name = String::new();
    let mut rest = template;
    while let Some(index) = rest.find(['{', '}']) {
        name.push_str(&rest[..index]);
        let (key, tail) = rest[index..]
            .strip_prefix('{')
            .and_then(|s| s.split_once('}'))
            .ok_or_else(|| LekisError::invalid("文件名模板括号不匹配"))?;
        name.push_str(match key {
            "title" => tags.title.as_deref().unwrap_or_default(),
            "artist" => tags.artist.as_deref().unwrap_or_default(),
            "album" => tags.album.as_deref().unwrap_or_default(),
            "track" => &track,
            "disc" => &disc,
            _ => return Err(LekisError::invalid(format!("未知的文件名占位符：{key}"))),
        });
        rest = tail;
    }
    name.push_str(rest);
    let cleaned = name.replace(forbidden, "_");
    let mut result = cleaned.trim_matches([' ', '.']).to_owned();
    if result.len() > 220 {
        let mut end = 220;
        while !result.is_char_boundary(end) {
            end -= 1;
        }
        result.truncate(end);
        result.truncate(result.trim_end_matches([' ', '.']).len());
    }
    if result.is_empty() && !validate_only {
        return Err(LekisError::invalid("展开后的文件名为空"));
    }
    let base = result
        .split('.')
        .next()
        .unwrap_or_default()
        .to_ascii_uppercase();
    if matches!(base.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || ((base.starts_with("COM") || base.starts_with("LPT"))
            && base.len() == 4
            && base.as_bytes()[3].is_ascii_digit())
    {
        result.insert(0, '_');
    }
    Ok(result)
}

async fn export_track(
    services: &Services,
    id: TrackId,
    options: &ExportOptions,
) -> Result<PathBuf> {
    let track = services.library.get_track(id).await?;
    let mut tags = services
        .library
        .track_tag_overrides(id)
        .await?
        .unwrap_or_default();
    if let Some(album_id) = track.album_id {
        let album = services.library.get_album(album_id).await?;
        tags.album_artist = tags.album_artist.or_else(|| nonempty(album.artist_line));
        tags.musicbrainz_album_id = tags.musicbrainz_album_id.or(album.mbid_release);
    }
    fill_catalog_tags(&mut tags, track);
    let stem = filename(&options.name_template, &tags, false)?;
    let mut last_error = LekisError::unsupported("没有可访问的文件系统音频副本");
    for file in services.library.track_files(id).await? {
        if !file.source_kind.is_filesystem() || file.path.is_empty() {
            continue;
        }
        let Some(path) = VfsPath::parse(&file.path) else {
            continue;
        };
        let source = services.library.get_source(file.source_id).await?;
        if !source.enabled {
            continue;
        }
        let ext = path.extension().unwrap_or_default().to_ascii_lowercase();
        if !matches!(
            ext.as_str(),
            "mp3" | "flac" | "m4a" | "mp4" | "aac" | "ogg" | "oga" | "opus"
        ) {
            last_error = LekisError::unsupported(format!("不支持写入该音频格式：.{ext}"));
            continue;
        }
        let target = options.directory.join(format!("{stem}.{ext}"));
        if tokio::fs::try_exists(&target).await? {
            return Err(LekisError::invalid(format!(
                "文件已存在：{}",
                target.display()
            )));
        }
        let vfs = match services
            .vfs_get(file.source_id)
            .map(Ok)
            .unwrap_or_else(|| services.open_vfs(&source))
        {
            Ok(vfs) => vfs,
            Err(error) => {
                last_error = error;
                continue;
            }
        };
        let temp = match copy_audio(vfs.as_ref(), &path, &options.directory, &ext).await {
            Ok(temp) => temp,
            Err(error) => {
                last_error = error;
                continue;
            }
        };
        let lyrics = if options.include_lyrics {
            match services.library.active_lyrics(id).await? {
                Some(lyrics) => Some(lyrics.content),
                None => lyrics_local::read_sidecar(vfs.as_ref(), &path).await,
            }
        } else {
            None
        };
        let cover = if options.include_artwork {
            match services.library.effective_artwork(id).await? {
                Some(art) => {
                    let cached = enrich::artwork_file_path(
                        &services.config,
                        &art.hash,
                        art.width.unwrap_or(1024),
                    );
                    Some(sidecars::webp_to_jpeg(&tokio::fs::read(cached).await?)?)
                }
                None => artwork_local::load_sidecar_cover(vfs.as_ref(), &path).await,
            }
        } else {
            None
        };
        let tags = tags.clone();
        let (art_enabled, lyrics_enabled) = (options.include_artwork, options.include_lyrics);
        let written = tokio::task::spawn_blocking(move || {
            lekis_library::write_export_tags(
                temp.path(),
                &tags,
                art_enabled,
                cover.as_deref(),
                lyrics_enabled,
                lyrics.as_deref(),
            )
            .map(|()| temp)
        })
        .await
        .map_err(|error| LekisError::internal(error.to_string()))?;
        match written {
            Ok(temp) => {
                return tokio::task::spawn_blocking(move || {
                    temp.as_file().sync_all()?;
                    temp.persist_noclobber(&target)
                        .map_err(|error| LekisError::from(error.error))?;
                    Ok(target)
                })
                .await
                .map_err(|error| LekisError::internal(error.to_string()))?;
            }
            Err(error) => last_error = error,
        }
    }
    Err(last_error)
}

fn nonempty(text: String) -> Option<String> {
    (!text.is_empty()).then_some(text)
}

fn fill_catalog_tags(tags: &mut TrackTagOverrides, track: Track) {
    tags.title = Some(track.title);
    tags.artist = tags.artist.take().or_else(|| {
        nonempty(
            track
                .artists
                .into_iter()
                .map(|artist| artist.name)
                .collect::<Vec<_>>()
                .join(" / "),
        )
    });
    tags.album = track.album_title;
    tags.track_no = track.track_no;
    tags.disc_no = track.disc_no;
    tags.year = track.year;
    tags.genre = tags
        .genre
        .take()
        .or_else(|| nonempty(track.genres.join(";")));
    tags.musicbrainz_track_id = tags.musicbrainz_track_id.take().or(track.mbid_recording);
}

async fn copy_audio(vfs: &dyn Vfs, path: &VfsPath, dir: &Path, ext: &str) -> Result<NamedTempFile> {
    let meta = vfs.stat(path).await?;
    if meta.kind != EntryKind::File || meta.size == 0 {
        return Err(LekisError::invalid("音源不是非空普通文件"));
    }
    let temp = tempfile::Builder::new()
        .prefix(".lekis-export-")
        .suffix(&format!(".{ext}"))
        .tempfile_in(dir)?;
    let mut writer = tokio::fs::File::from_std(temp.reopen()?);
    let mut offset = 0;
    while offset < meta.size {
        let end = offset.saturating_add(1024 * 1024).min(meta.size);
        let chunk = vfs.read_range(path, offset..end).await?;
        if chunk.is_empty() || chunk.len() as u64 > end - offset {
            return Err(LekisError::invalid("音源读取不完整"));
        }
        writer.write_all(&chunk).await?;
        offset += chunk.len() as u64;
    }
    writer.flush().await?;
    let after = vfs.stat(path).await?;
    if after.size != meta.size || after.mtime_ms != meta.mtime_ms {
        return Err(LekisError::invalid("复制期间源文件已更改"));
    }
    Ok(temp)
}
