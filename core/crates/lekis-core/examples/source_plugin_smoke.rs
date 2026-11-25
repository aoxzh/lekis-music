//! Manually verify a source plugin using the real QuickJS host and audio decoder.
//! Usage: cargo run -p lekis-core --example source_plugin_smoke -- PLUGIN_DIR QUERY [--allow-process PROGRAM]
//! Uses a temporary library and never plays through the system audio device.
use lekis_core::plugins::PluginManager;
use lekis_library::Library;
use lekis_playback::{open_decoder, MediaLocation, MediaSource};
use lekis_plugin_host::PluginManifest;
use lekis_types::{LekisError, Result};
use std::path::PathBuf;

struct Scratch(PathBuf);
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() != 2 && !(args.len() == 4 && args[2] == "--allow-process") {
        return Err(LekisError::invalid(
            "Usage: source_plugin_smoke PLUGIN_DIR QUERY [--allow-process PROGRAM]",
        ));
    }
    let plugin = PathBuf::from(&args[0]);
    let manifest = PluginManifest::parse(&std::fs::read_to_string(plugin.join("plugin.json"))?)?;
    let scratch = Scratch(std::env::temp_dir().join(format!(
        "lekis-source-smoke-{}-{}",
        std::process::id(),
        lekis_types::now_ms()
    )));
    std::fs::create_dir_all(&scratch.0)?;
    let library = Library::open(&scratch.0.join("library.sqlite"))?;
    let manager = PluginManager::new(&scratch.0, library.clone());
    manager.install(&plugin).await?;
    if args.len() == 4 {
        if !manifest.permissions.process.contains(&args[3]) {
            return Err(LekisError::invalid(
                "Program was not declared by the plugin",
            ));
        }
        library
            .set_setting(
                &format!("plugin.process.{}.{}", manifest.id, args[3]),
                "true",
            )
            .await?;
    }
    let results = manager.search(&manifest.id, &args[1], 3).await?;
    println!("Search: {} track(s)", results.tracks.len());
    let track = results.tracks.first().ok_or_else(|| {
        LekisError::not_found(
            "No tracks returned; try a song URL if the catalog is unavailable in your region",
        )
    })?;
    println!("Track: {} — {}", track.title, track.artist_line);
    let files = library.track_files(track.id).await?;
    let external_id = files
        .first()
        .and_then(|f| f.external_id.as_deref())
        .ok_or_else(|| LekisError::invalid("Missing external ID"))?;
    let stream = manager.stream(&manifest.id, external_id).await?;
    println!(
        "Stream resolved ({} headers; signed URL omitted)",
        stream.headers.len()
    );
    let media = MediaSource {
        track_id: track.id,
        location: MediaLocation::Url {
            url: stream.url,
            headers: stream.headers.into_iter().collect(),
        },
        duration_hint_ms: track.duration_ms,
        gain_db: None,
        range_ms: None,
    };
    let handle = tokio::runtime::Handle::current();
    let (format, samples) = tokio::task::spawn_blocking(move || -> Result<_> {
        let mut decoder = open_decoder(&media, &handle)?;
        let format = decoder.format();
        let target = format.sample_rate as usize * format.channels as usize * 2;
        let mut samples = Vec::new();
        while samples.len() < target && decoder.decode_next(&mut samples)? {}
        if samples.is_empty() || samples.iter().any(|s| !s.is_finite()) {
            return Err(LekisError::invalid(
                "Decoder returned empty or non-finite audio",
            ));
        }
        Ok((format, samples.len()))
    })
    .await
    .map_err(|e| LekisError::internal(e.to_string()))??;
    println!(
        "Decoded {samples} samples at {} Hz / {} channels",
        format.sample_rate, format.channels
    );
    Ok(())
}
