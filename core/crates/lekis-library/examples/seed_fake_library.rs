//! 性能测试用：往一个数据库里灌 N 首假歌（默认 10 万首），用来测列表滚动和查询速度。
//!
//! 用法：cargo run -p lekis-library --example seed_fake_library --release -- <数据目录> [曲目数]
//! 会写入 `<数据目录>/library.sqlite`。文件路径都是假的，只能浏览，不能播放。
//! 应用用 `--dart-define=LEKIS_DATA_DIR=<数据目录>` 指向这个目录。

use std::path::PathBuf;
use std::time::Instant;

use lekis_library::{Library, ScannedFile, ScannedTags};
use lekis_types::{SourceConfig, SourceKind};

const ARTISTS: &[&str] = &[
    "周杰伦",
    "陈奕迅",
    "林俊杰",
    "王菲",
    "孙燕姿",
    "邓紫棋",
    "五月天",
    "李健",
    "Taylor Swift",
    "Radiohead",
    "Daft Punk",
    "宇多田ヒカル",
    "米津玄師",
    "Adele",
    "Coldplay",
    "The Beatles",
];
const WORDS: &[&str] = &[
    "夜", "光", "海", "风", "城市", "月亮", "Blue", "Dream", "Night", "Light", "Love", "雨", "梦",
    "Home", "星", "Road", "Echo", "Silence", "Fire", "季节",
];

#[tokio::main(flavor = "multi_thread")]
async fn main() -> lekis_types::Result<()> {
    let mut args = std::env::args().skip(1);
    let dir = PathBuf::from(args.next().unwrap_or_else(|| "perf-data".into()));
    let count: usize = args.next().and_then(|s| s.parse().ok()).unwrap_or(100_000);
    std::fs::create_dir_all(&dir)?;

    let lib = Library::open(&dir.join("library.sqlite"))?;
    let source = lib
        .add_source(SourceConfig {
            id: None,
            kind: SourceKind::Local,
            name: "Perf (fake)".into(),
            addresses: vec!["/fake".into()],
            root_path: String::new(),
            credential_ref: None,
            options: Default::default(),
            enabled: true,
        })
        .await?;

    let start = Instant::now();
    let mut batch = Vec::with_capacity(1000);
    for i in 0..count {
        let artist_ix = (i * 7919) % (ARTISTS.len() * 200);
        let artist = format!(
            "{} {}",
            ARTISTS[artist_ix % ARTISTS.len()],
            artist_ix / ARTISTS.len()
        );
        let album_ix = i / 12;
        let title = format!(
            "{} {} {}",
            WORDS[i % WORDS.len()],
            WORDS[(i / WORDS.len()) % WORDS.len()],
            i
        );
        batch.push(ScannedFile {
            source_id: source,
            path: format!("fake/{album_ix}/{i}.flac"),
            size: 30_000_000,
            mtime_ms: 1_700_000_000_000,
            tags: ScannedTags {
                title,
                artists: vec![artist.clone()],
                album: Some(format!("{} 专辑 {album_ix}", WORDS[album_ix % WORDS.len()])),
                album_artists: vec![artist],
                track_no: Some((i % 12) as u32 + 1),
                disc_no: Some(1),
                year: Some(1990 + (album_ix % 35) as i32),
                genres: vec![
                    ["Pop", "Rock", "Jazz", "Classical", "Electronic"][album_ix % 5].into(),
                ],
                duration_ms: 150_000 + (i as u64 % 180) * 1000,
                ..Default::default()
            },
        });
        if batch.len() == 1000 {
            lib.upsert_scanned(std::mem::take(&mut batch)).await?;
        }
    }
    if !batch.is_empty() {
        lib.upsert_scanned(batch).await?;
    }
    println!(
        "seeded {count} tracks into {} in {:?}",
        dir.display(),
        start.elapsed()
    );
    Ok(())
}
