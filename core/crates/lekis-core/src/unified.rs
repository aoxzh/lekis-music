//! 统一资料库（SRC-13）：跨音源自动合并与 Chromaprint 音频指纹比对。
//!
//! - 扫描结束后（或用户手动触发），按 `library.unified_auto_merge`（默认开）执行跨音源自动归并；
//! - 元数据模糊匹配在 [`lekis_library::Library::auto_merge_cross_source_tracks`] 中用 `strsim` +
//!   简繁规范化 + 版本词隔离实现；
//! - 音频指纹模式借助纯 Rust 的 `rusty-chromaprint` 对跨源同时长候选曲目解码前 60 秒生成声学指纹，
//!   即使不同音源一个写中文标题、一个写英文标题，也能准确识别并合并为同一首歌，播放时由
//!   [`crate::selection`] 自动挑最佳音源。

use crate::{LekisCore, Services};
use lekis_playback::{open_decoder, MediaLocation, MediaSource};
use lekis_types::{CoreEvent, LekisError, LibraryScope, Result, SourceId, TrackId};
use rusty_chromaprint::{match_fingerprints, Configuration, Fingerprinter};
use std::collections::HashMap;
use tokio::runtime::Handle;

/// 音频指纹分析最多解码前 60 秒（足以稳定区分任意录音，同时保持快速）。
const FINGERPRINT_MAX_SECONDS: u64 = 60;

/// 单次按需指纹扫描最多处理的文件数，避免一次阻塞过久。
const MAX_FINGERPRINT_BATCH: u32 = 120;

/// 统一资料库自动合并报告。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct UnifiedMergeReport {
    /// 本次合并的重复组数量。
    pub merged_groups: u64,
    /// 本次吸收合并掉的冗余曲目数。
    pub merged_tracks: u64,
    /// 本次新计算并落库的音频指纹文件数。
    pub fingerprinted_files: u64,
}

/// 解码一份 [`MediaSource`] 的前 60 秒并生成 Chromaprint 原始指纹（`Vec<u32>`）。
pub(crate) fn compute_fingerprint_blocking(
    media: &MediaSource,
    handle: &Handle,
) -> Result<Vec<u32>> {
    let mut decoder = open_decoder(media, handle)?;
    let fmt = decoder.format();
    let sample_rate = fmt.sample_rate;
    let channels = fmt.channels;
    if sample_rate == 0 || channels == 0 {
        return Err(LekisError::invalid("empty pcm format for fingerprint"));
    }

    let config = Configuration::preset_test2();
    let mut fp = Fingerprinter::new(&config);
    fp.start(sample_rate, u32::from(channels))
        .map_err(|e| LekisError::internal(format!("chromaprint init: {e:?}")))?;

    let max_samples = FINGERPRINT_MAX_SECONDS
        .saturating_mul(u64::from(sample_rate))
        .saturating_mul(u64::from(channels));
    let mut total_samples = 0u64;
    let mut f32_buf = Vec::with_capacity(usize::from(channels) * 4_096);
    let mut i16_buf = Vec::with_capacity(usize::from(channels) * 4_096);

    while total_samples < max_samples {
        f32_buf.clear();
        if !decoder.decode_next(&mut f32_buf)? {
            break;
        }
        if f32_buf.is_empty() {
            continue;
        }
        let take = (max_samples - total_samples).min(f32_buf.len() as u64) as usize;
        i16_buf.clear();
        i16_buf.reserve(take);
        for &s in &f32_buf[..take] {
            let clamped = (s.clamp(-1.0, 1.0) * 32_767.0) as i16;
            i16_buf.push(clamped);
        }
        fp.consume(&i16_buf);
        total_samples += take as u64;
    }
    fp.finish();
    Ok(fp.fingerprint().to_vec())
}

/// 编码指纹为紧凑的十六进制字符串存入 `file.fingerprint`。
pub(crate) fn encode_fingerprint(raw: &[u32]) -> String {
    let mut out = String::with_capacity(raw.len() * 8);
    for &w in raw {
        use std::fmt::Write as _;
        let _ = write!(&mut out, "{w:08x}");
    }
    out
}

/// 解码存储的十六进制指纹。
pub(crate) fn decode_fingerprint(encoded: &str) -> Option<Vec<u32>> {
    if encoded.is_empty() || encoded.len() % 8 != 0 {
        return None;
    }
    let mut out = Vec::with_capacity(encoded.len() / 8);
    for chunk in encoded.as_bytes().chunks_exact(8) {
        let s = std::str::from_utf8(chunk).ok()?;
        let val = u32::from_str_radix(s, 16).ok()?;
        out.push(val);
    }
    Some(out)
}

/// 使用 `rusty-chromaprint` 判定两段音频指纹是否属于同一录音。
pub(crate) fn fingerprints_match(a: &[u32], b: &[u32]) -> bool {
    if a.len() < 16 || b.len() < 16 {
        return false;
    }
    let config = Configuration::preset_test2();
    let Ok(segments) = match_fingerprints(a, b, &config) else {
        return false;
    };
    let min_len = a.len().min(b.len()) as f64;
    let matched_items: usize = segments
        .iter()
        .filter(|seg| seg.score < 10.0)
        .map(|seg| seg.items_count)
        .sum();
    (matched_items as f64) / min_len >= 0.45
}

/// 扫描完成后按设置决定是否自动执行一次跨源统一合并。
pub(crate) async fn run_auto_merge_if_enabled(s: &Services) {
    let enabled = s
        .library
        .get_setting(crate::settings::UNIFIED_AUTO_MERGE)
        .await
        .ok()
        .flatten()
        .map(|v| v.trim() != "false" && v.trim() != "0")
        .unwrap_or(true);
    if !enabled {
        return;
    }
    match s.library.auto_merge_cross_source_tracks().await {
        Ok(stats) if stats.merged_tracks > 0 => {
            tracing::info!(
                target: "core::unified",
                groups = stats.groups,
                merged = stats.merged_tracks,
                "unified library auto-merged cross-source duplicates"
            );
            s.events.emit(CoreEvent::LibraryChanged {
                scope: LibraryScope::Catalog,
            });
        }
        Ok(_) => {}
        Err(e) => {
            tracing::warn!(target: "core::unified", error = %e, "unified auto-merge failed");
        }
    }
}

impl LekisCore {
    /// 立即运行统一资料库跨源自动合并（SRC-13）。
    ///
    /// - `use_fingerprints = false`：快速模式，仅用 MBID + 规范化元数据模糊匹配 + 时长窗口；
    /// - `use_fingerprints = true`：先用 `rusty-chromaprint` 对跨源同时长候选曲目提取声学指纹并合并声学一致的曲目，再跑元数据归并。
    pub async fn auto_merge_unified_library(
        &self,
        use_fingerprints: bool,
    ) -> Result<UnifiedMergeReport> {
        let s = self.services.clone();
        let handle = self.handle.clone();
        self.run(async move {
            let mut report = UnifiedMergeReport::default();

            if use_fingerprints {
                let candidates = s
                    .library
                    .fingerprint_candidates(MAX_FINGERPRINT_BATCH)
                    .await?;
                for cand in candidates {
                    if !cand.source_kind.is_filesystem() {
                        continue;
                    }
                    // 确保 VFS 已打开。
                    if lekis_playback::vfs_access::resolve(cand.source_id).is_none() {
                        if let Ok(src) = s.library.get_source(cand.source_id).await {
                            if let Ok(vfs) = s.open_vfs(&src) {
                                lekis_playback::vfs_access::install(cand.source_id, vfs);
                            }
                        }
                    }
                    let range_ms = (cand.start_ms > 0 || cand.end_ms.is_some())
                        .then_some((cand.start_ms, cand.end_ms));
                    let media = MediaSource {
                        track_id: cand.track_id,
                        location: MediaLocation::Vfs {
                            source_id: cand.source_id,
                            path: cand.path.clone(),
                        },
                        duration_hint_ms: cand.duration_ms,
                        gain_db: None,
                        range_ms,
                    };
                    let h = handle.clone();
                    let fp_res = tokio::task::spawn_blocking(move || {
                        compute_fingerprint_blocking(&media, &h)
                    })
                    .await;
                    if let Ok(Ok(raw)) = fp_res {
                        if raw.len() >= 16 {
                            let encoded = encode_fingerprint(&raw);
                            if s.library
                                .set_file_fingerprint(cand.file_id, encoded)
                                .await
                                .is_ok()
                            {
                                report.fingerprinted_files += 1;
                            }
                        }
                    }
                }

                // 声学指纹跨源比对并合并。
                let all_fps = s.library.track_fingerprints().await?;
                let decoded: Vec<(TrackId, SourceId, i64, Vec<u32>)> = all_fps
                    .into_iter()
                    .filter_map(|(tid, sid, q, enc)| {
                        decode_fingerprint(&enc).map(|v| (tid, sid, q, v))
                    })
                    .collect();

                let mut merged_into: HashMap<TrackId, TrackId> = HashMap::new();
                for i in 0..decoded.len() {
                    let (tid_a, sid_a, q_a, ref fp_a) = decoded[i];
                    if merged_into.contains_key(&tid_a) {
                        continue;
                    }
                    for (tid_b, sid_b, q_b, fp_b) in decoded.iter().skip(i + 1) {
                        if tid_a == *tid_b || sid_a == *sid_b || merged_into.contains_key(tid_b) {
                            continue;
                        }
                        if fingerprints_match(fp_a, fp_b) {
                            let (keep, absorb) = if q_a >= *q_b {
                                (tid_a, *tid_b)
                            } else {
                                (*tid_b, tid_a)
                            };
                            if let Ok(n) = s.library.merge_tracks(keep, vec![absorb]).await {
                                if n > 0 {
                                    merged_into.insert(absorb, keep);
                                    report.merged_groups += 1;
                                    report.merged_tracks += n;
                                }
                            }
                        }
                    }
                }
            }

            let meta_stats = s.library.auto_merge_cross_source_tracks().await?;
            report.merged_groups += meta_stats.groups;
            report.merged_tracks += meta_stats.merged_tracks;

            if report.merged_tracks > 0 {
                s.events.emit(CoreEvent::LibraryChanged {
                    scope: LibraryScope::Catalog,
                });
            }
            Ok(report)
        })
        .await
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    #[test]
    fn fingerprint_hex_roundtrip() {
        let raw = vec![0x0123_4567u32, 0x89ab_cdef, 0, u32::MAX];
        let enc = encode_fingerprint(&raw);
        assert_eq!(decode_fingerprint(&enc), Some(raw));
    }
}
