// 离线下载的界面模型。
//
// 这一层不碰桥接 / Riverpod，只做 DTO → 行模型 / 进度 / 字节格式化的纯映射，
// 方便单测（`app/test/downloads/...`）。

import 'package:flutter/foundation.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/dto.dart';

/// 一条下载在界面上的完整信息。
@immutable
class DownloadEntry {
  const DownloadEntry({
    required this.download,
    required this.track,
    required this.downloadedBytes,
    required this.totalBytes,
  });

  /// 核心里的原始记录。
  final OfflineDownloadDto download;

  /// 曲目元数据；曲目被删掉时可能为 `null`（记录通常也会被级联删除）。
  final TrackDto? track;

  /// 已下载字节（优先用实时进度，其次用数据库里的值）。
  final int downloadedBytes;

  /// 源文件大小；0 表示未知。
  final int totalBytes;

  int get trackId => download.trackId;
  OfflineStateDto get state => download.state;

  String get title =>
      track?.title ?? L10n.tr('曲目 #$trackId', 'Track #$trackId');
  String get subtitle => track?.artists.join(' / ') ?? '';

  bool get isActive => state == OfflineStateDto.downloading;
  bool get isQueued => state == OfflineStateDto.queued;
  bool get isReady => state == OfflineStateDto.ready;
  bool get isFailed => state == OfflineStateDto.failed;

  /// Last failure reason reported by the core, if any.
  String? get error => download.error;

  /// 0..1；总大小未知时是 `null`（进度条应显示为不确定状态）。
  double? get progress {
    if (totalBytes <= 0) return null;
    return (downloadedBytes / totalBytes).clamp(0.0, 1.0);
  }

  /// 状态的一句话说明。
  String get statusText {
    return switch (state) {
      OfflineStateDto.queued => L10n.tr('等待下载', 'Queued'),
      OfflineStateDto.downloading =>
        totalBytes > 0
            ? L10n.tr(
                '正在下载 ${formatBytes(downloadedBytes)} / ${formatBytes(totalBytes)}',
                'Downloading ${formatBytes(downloadedBytes)} / ${formatBytes(totalBytes)}',
              )
            : L10n.tr(
                '正在下载 ${formatBytes(downloadedBytes)}',
                'Downloading ${formatBytes(downloadedBytes)}',
              ),
      OfflineStateDto.ready => L10n.tr(
        '${formatBytes(downloadedBytes)} · 可离线播放',
        '${formatBytes(downloadedBytes)} · Available offline',
      ),
      OfflineStateDto.failed => L10n.tr(
        '下载失败，可重试',
        'Download failed, tap to retry',
      ),
    };
  }

  DownloadEntry withProgress(int downloaded, int? total) => DownloadEntry(
    download: download,
    track: track,
    downloadedBytes: downloaded,
    totalBytes: total ?? totalBytes,
  );
}

/// 下载页的完整状态。
@immutable
class DownloadsState {
  const DownloadsState({
    this.entries = const [],
    this.readyCount = 0,
    this.totalBytes = 0,
  });

  final List<DownloadEntry> entries;

  /// 已完成的数量（来自核心的 offline_stats）。
  final int readyCount;

  /// 已完成缓存的总字节数。
  final int totalBytes;

  bool get isEmpty => entries.isEmpty;
  bool get hasActive => entries.any((e) => e.isActive || e.isQueued);

  DownloadEntry? entryFor(int trackId) {
    for (final entry in entries) {
      if (entry.trackId == trackId) return entry;
    }
    return null;
  }

  List<DownloadEntry> get active =>
      entries.where((e) => e.isActive || e.isQueued).toList(growable: false);
  List<DownloadEntry> get failed =>
      entries.where((e) => e.isFailed).toList(growable: false);
  List<DownloadEntry> get ready =>
      entries.where((e) => e.isReady).toList(growable: false);

  /// 下载进度事件只改内存里的字节数，不重新查库。
  DownloadsState withProgress(int trackId, int downloaded, int? total) {
    var changed = false;
    final next = <DownloadEntry>[];
    for (final entry in entries) {
      if (entry.trackId == trackId) {
        changed = true;
        next.add(entry.withProgress(downloaded, total));
      } else {
        next.add(entry);
      }
    }
    return changed ? _copy(entries: next) : this;
  }

  DownloadsState _copy({List<DownloadEntry>? entries}) => DownloadsState(
    entries: entries ?? this.entries,
    readyCount: readyCount,
    totalBytes: totalBytes,
  );
}

/// 把核心记录和曲目元数据映射成界面模型。
///
/// [liveProgress] 是事件流里的实时下载量（`OfflineProgress`），优先于数据库里的
/// `bytes`，这样进度条不用每个 tick 都查库。
List<DownloadEntry> buildDownloadEntries({
  required List<OfflineDownloadDto> downloads,
  required Map<int, TrackDto?> tracks,
  Map<int, ({int downloaded, int? total})> liveProgress = const {},
}) {
  return [
    for (final download in downloads)
      DownloadEntry(
        download: download,
        track: tracks[download.trackId],
        downloadedBytes:
            liveProgress[download.trackId]?.downloaded ??
            download.bytes.toInt(),
        totalBytes:
            liveProgress[download.trackId]?.total ??
            download.totalBytes.toInt(),
      ),
  ];
}

/// 人类可读的字节数（十进制单位，和系统文件管理器的习惯一致）。
String formatBytes(int bytes) {
  if (bytes < 0) bytes = 0;
  if (bytes < 1000) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1000;
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  final digits = value >= 100 ? 0 : (value >= 10 ? 1 : 2);
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}
