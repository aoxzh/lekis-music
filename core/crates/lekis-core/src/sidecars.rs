//! 把补全到的封面 / 歌词写回音源目录，避免重新添加资料库后还要再补一遍。
//!
//! 只处理文件系统音源（本地磁盘、SMB、WebDAV、SFTP、NFS），媒体服务器源没有可写的
//! 目录。所有写入都是 best-effort：只读共享、权限不足或网络错误只记日志，不影响补全
//! 本身。可以在设置里用 `enrich.write_sidecars=false` 关掉。
//!
//! 命名规则和扫描器保持一致：
//! - 专辑封面：目录里的 `cover.jpg`（已有 `cover.*` / `folder.*` / `front.*` 时跳过）；
//! - 单曲封面：`<歌曲名>.jpg`（同一目录每首歌封面不同时使用）；
//! - 歌词：与音频同名的 `.lrc` / `.ttml` / `.txt`。

use crate::artwork_local::{SIDECAR_NAMES, TRACK_COVER_EXTS};
use crate::enrich::tier_for;
use crate::lyrics_local::{vfs_for, LYRICS_EXTS};
use crate::Services;
use bytes::Bytes;
use lekis_library::{cache_relative_path, EnrichCandidateRow};
use lekis_types::{
    ErrorCode, LekisError, Lyrics, LyricsFormat, Result, TrackId, TrackQuery, TrackSort,
};
use lekis_vfs::{EntryKind, Vfs, VfsPath};
use std::collections::HashSet;
use std::sync::Arc;

/// 关闭侧车写入的设置键；缺省为开启。
pub(crate) const WRITE_SIDECARS_SETTING: &str = "enrich.write_sidecars";

/// 旧版本补全结果迁移到侧车文件的一次性标记。
const SIDECAR_BACKFILL_SETTING: &str = "enrich.sidecars_backfill";

/// 把一首歌的生效封面 / 歌词写到它所有文件系统副本旁边。
///
/// `overwrite = false` 时保留现有侧车文件（补全 / 迁移用）；用户手动改封面或歌词时传
/// `true`，让源目录跟着更新。
pub(crate) async fn persist_for_track(
    services: &Arc<Services>,
    track_id: TrackId,
    overwrite: bool,
) -> Result<()> {
    if !sidecars_enabled(services).await? {
        return Ok(());
    }
    let files = services.library.track_files(track_id).await?;
    if files.is_empty() {
        return Ok(());
    }
    let track = services.library.get_track(track_id).await?;
    let album_art = match track.album_id {
        Some(album_id) => services.library.album_own_artwork(album_id).await?,
        None => None,
    };
    let artwork = services.library.effective_artwork(track_id).await?;
    let lyrics = services.library.active_lyrics(track_id).await?;
    let need_lyrics = lyrics
        .as_ref()
        .is_some_and(|lyrics| !matches!(lyrics.source.as_str(), "sidecar" | "embedded"));
    let need_cover = artwork
        .as_ref()
        .is_some_and(|artwork| !matches!(artwork.source.as_str(), "sidecar" | "embedded"));
    if !need_lyrics && !need_cover {
        return Ok(());
    }
    let mut written_album_dirs = HashSet::new();

    for file in files {
        if !file.source_kind.is_filesystem() || file.path.is_empty() {
            continue;
        }
        let Some(path) = VfsPath::parse(&file.path) else {
            continue;
        };
        let Some(dir) = path.parent() else {
            continue;
        };
        let Some(vfs) = vfs_for(services, file.source_id).await else {
            continue;
        };
        if !vfs.capabilities().writable {
            continue;
        }
        // 一个目录只列一次；用文件名判断侧车是否已存在，比逐个 stat 省很多 NAS 请求。
        let entries = match vfs.list_dir(&dir).await {
            Ok(entries) => entries,
            Err(_) => continue,
        };
        let names: HashSet<String> = entries
            .iter()
            .filter(|entry| matches!(entry.meta.kind, EntryKind::File))
            .filter_map(|entry| entry.path.file_name().map(str::to_string))
            .collect();

        if need_lyrics {
            if let Some(lyrics) = &lyrics {
                if let Err(error) =
                    persist_lyrics(vfs.as_ref(), &path, lyrics, &names, overwrite).await
                {
                    tracing::debug!(
                        target: "core::sidecars",
                        path = %path,
                        code = %error.code.as_str(),
                        "writing lyrics sidecar failed"
                    );
                }
            }
        }
        if need_cover {
            if let Some(artwork) = &artwork {
                let album_level = album_art == Some(artwork.id);
                if album_level && !written_album_dirs.insert(dir.as_str().to_string()) {
                    continue;
                }
                if let Err(error) = persist_cover(
                    services,
                    vfs.as_ref(),
                    &dir,
                    &path,
                    artwork,
                    album_level,
                    &names,
                    overwrite,
                )
                .await
                {
                    tracing::debug!(
                        target: "core::sidecars",
                        path = %path,
                        code = %error.code.as_str(),
                        "writing cover sidecar failed"
                    );
                }
            }
        }
    }
    Ok(())
}

/// 一张专辑的所有曲目都尝试写一遍（多碟目录需要每个目录各有一张封面）。
pub(crate) async fn persist_for_album(
    services: &Arc<Services>,
    album_id: lekis_types::AlbumId,
    overwrite: bool,
) -> Result<()> {
    let mut offset = 0u32;
    loop {
        let tracks = services.library.album_tracks(album_id, offset, 200).await?;
        if tracks.is_empty() {
            return Ok(());
        }
        for track in &tracks {
            if let Err(error) = persist_for_track(services, track.id, overwrite).await {
                tracing::debug!(
                    target: "core::sidecars",
                    track = track.id.0,
                    code = %error.code.as_str(),
                    "writing album sidecar failed"
                );
            }
        }
        if tracks.len() < 200 {
            return Ok(());
        }
        offset += tracks.len() as u32;
    }
}

/// 用户接受一条补全候选后，把结果写到候选涉及的曲目 / 专辑旁边。
pub(crate) async fn persist_for_candidate(
    services: &Arc<Services>,
    row: &EnrichCandidateRow,
) -> Result<()> {
    if let Some(track_id) = row.track_id {
        return persist_for_track(services, track_id, false).await;
    }
    let Some(album_id) = row.album_id else {
        return Ok(());
    };
    persist_for_album(services, album_id, false).await
}

/// 升级到带侧车写回的新版本后，把旧版本已经补全到缓存里的封面 / 歌词一次性写回源目录。
///
/// 这是后台任务：不阻塞启动，失败只记日志；完成后写一个 marker，之后不再扫描。
pub(crate) async fn backfill_if_needed(services: &Arc<Services>) -> Result<()> {
    // Unit tests spin up short-lived cores and delete their temp libraries; a
    // background writer racing them makes assertions non-deterministic.
    if cfg!(test) {
        return Ok(());
    }
    // Give the app time to finish startup and let a first play start before a
    // big migration saturates a NAS connection.
    tokio::time::sleep(std::time::Duration::from_secs(20)).await;
    if services
        .library
        .get_setting(SIDECAR_BACKFILL_SETTING)
        .await?
        .as_deref()
        == Some("done")
    {
        return Ok(());
    }
    if !sidecars_enabled(services).await? {
        return Ok(());
    }
    const PAGE: u32 = 500;
    let mut offset = 0u32;
    let mut checked = 0u64;
    loop {
        let tracks = services
            .library
            .list_track_rows(TrackQuery {
                sort: TrackSort::Title,
                offset,
                limit: PAGE,
            })
            .await?;
        if tracks.is_empty() {
            break;
        }
        for track in &tracks {
            if let Err(error) = persist_for_track(services, track.id, false).await {
                tracing::debug!(
                    target: "core::sidecars",
                    track = track.id.0,
                    code = %error.code.as_str(),
                    "backfilling sidecar failed"
                );
            }
            checked += 1;
        }
        if tracks.len() < PAGE as usize {
            break;
        }
        offset += tracks.len() as u32;
    }
    services
        .library
        .set_setting(SIDECAR_BACKFILL_SETTING, "done")
        .await?;
    tracing::info!(target: "core::sidecars", checked, "sidecar backfill complete");
    Ok(())
}

async fn sidecars_enabled(services: &Arc<Services>) -> Result<bool> {
    let value = services.library.get_setting(WRITE_SIDECARS_SETTING).await?;
    Ok(value.as_deref() != Some("false"))
}

async fn persist_lyrics(
    vfs: &dyn Vfs,
    audio: &VfsPath,
    lyrics: &Lyrics,
    names: &HashSet<String>,
    overwrite: bool,
) -> Result<()> {
    if matches!(lyrics.source.as_str(), "sidecar" | "embedded") {
        return Ok(());
    }
    if lyrics.content.trim().is_empty() {
        return Ok(());
    }
    let Some(stem) = audio.as_str().rsplit_once('.').map(|(stem, _)| stem) else {
        return Ok(());
    };
    let base = stem.rsplit_once('/').map(|(_, name)| name).unwrap_or(stem);
    let ext = match lyrics.format {
        LyricsFormat::Plain => "txt",
        LyricsFormat::Lrc | LyricsFormat::EnhancedLrc => "lrc",
        LyricsFormat::Ttml => "ttml",
    };
    if !overwrite
        && LYRICS_EXTS
            .iter()
            .any(|candidate| names.contains(&format!("{base}.{candidate}")))
    {
        return Ok(());
    }
    let Some(target) = VfsPath::parse(&format!("{stem}.{ext}")) else {
        return Ok(());
    };
    vfs.write_atomic(&target, Bytes::from(lyrics.content.clone().into_bytes()))
        .await
}

#[allow(clippy::too_many_arguments)]
async fn persist_cover(
    services: &Arc<Services>,
    vfs: &dyn Vfs,
    dir: &VfsPath,
    audio: &VfsPath,
    artwork: &lekis_library::ArtworkRow,
    album_level: bool,
    names: &HashSet<String>,
    overwrite: bool,
) -> Result<()> {
    let Some(stem) = audio.as_str().rsplit_once('.').map(|(stem, _)| stem) else {
        return Ok(());
    };
    let file_name = stem.rsplit_once('/').map(|(_, name)| name).unwrap_or(stem);
    let target = if album_level {
        if !overwrite && SIDECAR_NAMES.iter().any(|name| names.contains(*name)) {
            return Ok(());
        }
        dir.join("cover.jpg")
    } else {
        if !overwrite
            && TRACK_COVER_EXTS
                .iter()
                .any(|ext| names.contains(&format!("{file_name}.{ext}")))
        {
            return Ok(());
        }
        let Some(target) = VfsPath::parse(&format!("{stem}.jpg")) else {
            return Ok(());
        };
        target
    };
    if !overwrite && names.contains(target.file_name().unwrap_or_default()) {
        return Ok(());
    }
    let width = tier_for(artwork.width.unwrap_or(1024));
    let cache_path = services
        .config
        .cache_dir
        .join(cache_relative_path(&artwork.hash, width));
    let bytes = match tokio::fs::read(&cache_path).await {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(LekisError::new(
                ErrorCode::Io,
                format!("读取封面缓存失败：{error}"),
            ));
        }
    };
    let jpeg = tokio::task::spawn_blocking(move || webp_to_jpeg(&bytes))
        .await
        .map_err(|error| LekisError::internal(format!("封面转码任务失败：{error}")))??;
    vfs.write_atomic(&target, Bytes::from(jpeg)).await
}

/// 缓存里的是 WebP；侧车统一写 JPEG，兼容不认 WebP 的播放器 / 扫描器。
fn webp_to_jpeg(bytes: &[u8]) -> Result<Vec<u8>> {
    let image = image::load_from_memory_with_format(bytes, image::ImageFormat::WebP)
        .map_err(|error| LekisError::new(ErrorCode::Decode, format!("封面解码失败：{error}")))?;
    let mut output = Vec::new();
    image
        .write_to(
            &mut std::io::Cursor::new(&mut output),
            image::ImageFormat::Jpeg,
        )
        .map_err(|error| LekisError::new(ErrorCode::Decode, format!("封面编码失败：{error}")))?;
    Ok(output)
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn existing_vtt_blocks_automatic_lyrics_writeback() {
        let root = std::env::temp_dir().join(format!("lekis-vtt-write-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let audio = VfsPath::parse("song.flac").unwrap();
        let vfs = lekis_vfs::local::LocalVfs::new(&root).unwrap();
        let lyrics = Lyrics {
            format: LyricsFormat::Lrc,
            content: "[00:01.00]new".into(),
            source: "manual".into(),
            offset_ms: 0,
            confidence: 1.0,
        };
        for name in ["song.vtt", "song.VTT"] {
            std::fs::write(root.join(name), "original").unwrap();
            let names = HashSet::from([name.to_owned()]);
            persist_lyrics(&vfs, &audio, &lyrics, &names, false)
                .await
                .unwrap();
            assert!(!root.join("song.lrc").exists());
            persist_lyrics(&vfs, &audio, &lyrics, &names, true)
                .await
                .unwrap();
            assert_eq!(
                std::fs::read_to_string(root.join("song.lrc")).unwrap(),
                lyrics.content
            );
            assert_eq!(
                std::fs::read_to_string(root.join(name)).unwrap(),
                "original"
            );
            std::fs::remove_file(root.join("song.lrc")).unwrap();
            std::fs::remove_file(root.join(name)).unwrap();
        }
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn jpeg_sidecar_round_trips_a_webp_image() {
        let source =
            image::RgbImage::from_fn(8, 8, |x, y| image::Rgb([x as u8 * 16, y as u8 * 16, 128]));
        let mut webp = Vec::new();
        image::DynamicImage::ImageRgb8(source)
            .write_to(
                &mut std::io::Cursor::new(&mut webp),
                image::ImageFormat::WebP,
            )
            .unwrap();
        let jpeg = webp_to_jpeg(&webp).unwrap();
        assert!(jpeg.starts_with(&[0xFF, 0xD8, 0xFF]));
        let decoded = image::load_from_memory_with_format(&jpeg, image::ImageFormat::Jpeg).unwrap();
        assert_eq!(decoded.width(), 8);
        assert_eq!(decoded.height(), 8);
    }
}
