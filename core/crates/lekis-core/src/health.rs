//! 库健康扫描（LIB-11）：按音源分批打开已入库文件，记录打不开 / 读不了的。
//!
//! 只读取每个文件的 1 个字节来确认可读性，不解析标签，也不做频谱分析。
//! 扫描结果写入 `file.scan_state` / `file.scan_error`，由
//! [`crate::LekisCore::library_health_summary`] 的"损坏 / 不可读"计数使用。

use crate::Services;
use lekis_library::HealthScanFile;
use lekis_types::{LekisError, Result};
use lekis_vfs::VfsPath;
use std::sync::Arc;

/// 每批处理的文件数。按源分批，避免一次把十万条路径和结果放进内存。
const HEALTH_SCAN_BATCH: u32 = 500;

/// 一次库健康扫描的结果。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HealthScanReport {
    /// 实际扫描的音源数。
    pub sources: u32,
    /// 检查过的文件数。
    pub files_checked: u64,
    /// 本次检查不可读的文件数（包括之前就已经标记的）。
    pub unreadable: u64,
    /// 从不可读恢复成正常的文件数。
    pub cleared: u64,
    /// 打不开的音源数。
    pub failed_sources: u32,
    /// 音源级别的错误（不包含文件路径，避免把隐私带进日志 / UI）。
    pub errors: Vec<String>,
}

/// 扫描所有有文件行的音源。
pub(crate) async fn scan(s: &Arc<Services>) -> Result<HealthScanReport> {
    let mut report = HealthScanReport::default();
    let sources = s.library.file_sources().await?;
    for source_id in sources {
        let source = match s.library.get_source(source_id).await {
            Ok(source) => source,
            Err(e) => {
                report.failed_sources += 1;
                report
                    .errors
                    .push(format!("source {source_id}: {}", e.message));
                continue;
            }
        };
        // 服务器源没有 `file` 行；插件 / 电台更不会有可读文件。这里只处理文件系统源。
        if !source.kind.is_filesystem() {
            continue;
        }
        let vfs = match s.open_vfs(&source) {
            Ok(vfs) => vfs,
            Err(e) => {
                report.failed_sources += 1;
                report
                    .errors
                    .push(format!("{}: {}", source.name, e.message));
                continue;
            }
        };
        report.sources += 1;
        let mut offset = 0u32;
        loop {
            let files = s
                .library
                .files_for_health_scan(source_id, offset, HEALTH_SCAN_BATCH)
                .await?;
            if files.is_empty() {
                break;
            }
            let count = files.len() as u32;
            let results = check_batch(vfs.as_ref(), &files, &mut report).await;
            let update = s.library.record_file_health(results).await?;
            report.cleared += update.cleared;
            offset += count;
            if count < HEALTH_SCAN_BATCH {
                break;
            }
        }
    }
    s.events.emit(lekis_types::CoreEvent::LibraryChanged {
        scope: lekis_types::LibraryScope::Catalog,
    });
    Ok(report)
}

async fn check_batch(
    vfs: &dyn lekis_vfs::Vfs,
    files: &[HealthScanFile],
    report: &mut HealthScanReport,
) -> Vec<(i64, Option<String>)> {
    let mut results = Vec::with_capacity(files.len());
    for file in files {
        report.files_checked += 1;
        let error = check_one(vfs, file).await;
        if error.is_some() {
            report.unreadable += 1;
        }
        results.push((file.file_id, error));
    }
    results
}

async fn check_one(vfs: &dyn lekis_vfs::Vfs, file: &HealthScanFile) -> Option<String> {
    let Some(path) = VfsPath::parse(&file.path) else {
        return Some("invalid path".to_string());
    };
    match vfs.stat(&path).await {
        Ok(meta) if meta.size == 0 => Some("empty file".to_string()),
        Ok(_) => match vfs.read_range(&path, 0..1).await {
            Ok(_) => None,
            Err(e) => Some(error_text(&e)),
        },
        Err(e) => Some(error_text(&e)),
    }
}

fn error_text(error: &LekisError) -> String {
    // 不把路径塞进来：路径已经由条目本身展示，错误文本只说明原因。
    format!("{}: {}", error.code.as_str(), error.message)
}
