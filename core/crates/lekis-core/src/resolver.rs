//! 选源：把播放引擎请求的曲目解析成可播放的媒体（SRC-13、SRC-14、OFF-03）。
//!
//! 目标优先级：离线下载 > 播放缓存 > 当前可达的局域网源 > 远程源（服务器 / Tailscale 地址）> 插件。
//! 现在只实现了"取质量最高的文件"。

use lekis_library::Library;
use lekis_playback::engine::ResolveRequest;
use lekis_playback::{MediaLocation, MediaSource};
use lekis_types::{LekisError, Result, TrackId};
use tokio::sync::mpsc;

pub(crate) async fn run(library: Library, mut requests: mpsc::Receiver<ResolveRequest>) {
    while let Some((track_id, reply)) = requests.recv().await {
        let _ = reply.send(resolve(&library, track_id).await);
    }
}

async fn resolve(library: &Library, track_id: TrackId) -> Result<MediaSource> {
    let files = library.track_files(track_id).await?;
    let best = files
        .into_iter()
        .next()
        .ok_or_else(|| LekisError::not_found(format!("no playable file for track {track_id}")))?;
    // TODO(PLY-03)：根据用户设置选择曲目增益 / 专辑增益 / 关闭。
    let gain_db = best.replaygain.track_gain_db;
    Ok(MediaSource {
        track_id,
        location: MediaLocation::Vfs {
            source_id: best.source_id,
            path: best.path,
        },
        duration_hint_ms: best.duration_ms,
        gain_db,
    })
}
