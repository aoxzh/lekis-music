//! Seed a clean Lekis profile from the generated demo library.
//!
//! This is a developer tool for promo screenshots: it creates the same SQLite
//! library the app would create after "add folder → scan", so the app can be
//! launched with `--dart-define=LEKIS_DATA_DIR=<dir>` and immediately show the
//! fictional catalogue without touching the real library.
//!
//! Usage:
//!   cargo run -p lekis-core --example seed_demo_library -- \
//!       private/demo-profile private/demo-library

use std::path::PathBuf;
use std::time::{Duration, Instant};

use lekis_core::{CoreConfig, LekisCore, PlatformKind, PlatformServices};
use lekis_types::{LekisError, SourceConfig, SourceKind, TrackSort};

fn main() {
    if let Err(error) = run() {
        eprintln!("seed_demo_library: {error}");
        std::process::exit(1);
    }
}

fn run() -> lekis_types::Result<()> {
    let mut args = std::env::args().skip(1);
    let data_dir = PathBuf::from(args.next().unwrap_or_else(|| {
        eprintln!("usage: seed_demo_library <data-dir> <music-dir>");
        std::process::exit(2);
    }));
    let music_dir = PathBuf::from(args.next().unwrap_or_else(|| {
        eprintln!("usage: seed_demo_library <data-dir> <music-dir>");
        std::process::exit(2);
    }));
    if !music_dir.is_dir() {
        return Err(LekisError::invalid(format!(
            "music folder does not exist: {}",
            music_dir.display()
        )));
    }
    let music_dir = music_dir.canonicalize().map_err(|e| {
        LekisError::invalid(format!(
            "cannot resolve music folder {}: {e}",
            music_dir.display()
        ))
    })?;
    let data_dir = if data_dir.is_absolute() {
        data_dir
    } else {
        std::env::current_dir()
            .map_err(|e| LekisError::internal(format!("current dir: {e}")))?
            .join(data_dir)
    };

    let config = CoreConfig {
        data_dir: data_dir.clone(),
        cache_dir: data_dir.join("cache"),
        device_name: "Lekis Demo".into(),
        platform: PlatformKind::Windows,
        worker_threads: Some(4),
    };
    let core = LekisCore::new(config, PlatformServices::in_memory())?;
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| LekisError::internal(format!("runtime: {e}")))?;

    runtime.block_on(async {
        let source = core
            .add_source(SourceConfig {
                id: None,
                kind: SourceKind::Local,
                name: "Lekis Demo".into(),
                addresses: vec![music_dir.to_string_lossy().into_owned()],
                root_path: String::new(),
                credential_ref: None,
                options: Default::default(),
                enabled: true,
            })
            .await?;
        core.start_scan(source).await?;

        let deadline = Instant::now() + Duration::from_secs(120);
        let mut last = 0;
        let mut last_art = usize::MAX;
        loop {
            let count = core.count_tracks().await?;
            if count != last {
                println!("scanned {count} tracks");
                last = count;
            }
            let albums = core.list_albums(TrackSort::Title, 0, 100).await?;
            let with_art = albums
                .iter()
                .filter(|album| album.artwork_id.is_some() || album.artwork_hash.is_some())
                .count();
            if count >= 18 && with_art != last_art {
                println!("artwork ready for {with_art}/{} albums", albums.len());
                last_art = with_art;
            }
            if count >= 18 && with_art >= albums.len() && !albums.is_empty() {
                break;
            }
            if Instant::now() >= deadline {
                return Err(LekisError::internal("scan timed out"));
            }
            tokio::time::sleep(Duration::from_millis(150)).await;
        }
        Ok(())
    })?;

    println!("demo profile ready: {}", data_dir.display());
    Ok(())
}
