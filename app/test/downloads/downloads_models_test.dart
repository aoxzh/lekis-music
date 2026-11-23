import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/downloads/downloads_models.dart';
import 'package:lekis/src/rust/api/dto.dart';

OfflineDownloadDto _download({
  required int trackId,
  required OfflineStateDto state,
  int bytes = 0,
  int total = 0,
  String? error,
}) => OfflineDownloadDto(
  trackId: trackId,
  sourceId: 1,
  cachePath: '/data/offline/$trackId.flac',
  bytes: BigInt.from(bytes),
  totalBytes: BigInt.from(total),
  state: state,
  error: error,
  createdAt: 1,
  updatedAt: 2,
);

void main() {
  test('formatBytes uses compact decimal units', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(999), '999 B');
    expect(formatBytes(1000), '1.00 KB');
    expect(formatBytes(12_340), '12.3 KB');
    expect(formatBytes(123_400), '123 KB');
    expect(formatBytes(5_600_000), '5.60 MB');
    expect(formatBytes(2_500_000_000), '2.50 GB');
  });

  test('download rows map state, live progress and status text', () {
    final rows = buildDownloadEntries(
      downloads: [
        _download(
          trackId: 1,
          state: OfflineStateDto.downloading,
          bytes: 100,
          total: 400,
        ),
        _download(
          trackId: 2,
          state: OfflineStateDto.ready,
          bytes: 1_000,
          total: 1_000,
        ),
        _download(
          trackId: 3,
          state: OfflineStateDto.failed,
          bytes: 10,
          total: 100,
          error: 'network down',
        ),
        _download(trackId: 4, state: OfflineStateDto.queued),
      ],
      tracks: const {},
      liveProgress: {1: (downloaded: 300, total: 500)},
    );

    expect(rows, hasLength(4));
    final active = rows[0];
    expect(active.trackId, 1);
    expect(active.isActive, isTrue);
    expect(active.downloadedBytes, 300, reason: '实时进度优先于数据库里的值');
    expect(active.totalBytes, 500);
    expect(active.progress, closeTo(0.6, 1e-9));
    expect(active.statusText, '正在下载 300 B / 500 B');
    expect(active.title, '曲目 #1');

    expect(rows[1].isReady, isTrue);
    expect(rows[1].progress, 1.0);
    expect(rows[1].statusText, '1.00 KB · 可离线播放');

    expect(rows[2].isFailed, isTrue);
    expect(rows[2].statusText, '下载失败，可重试');

    expect(rows[3].isQueued, isTrue);
    expect(rows[3].progress, isNull, reason: '大小未知时进度条应是不确定状态');
    expect(rows[3].statusText, '等待下载');
  });

  test('unknown totals keep a null progress and clamp known values', () {
    final unknown = buildDownloadEntries(
      downloads: [
        _download(trackId: 1, state: OfflineStateDto.downloading, bytes: 50),
      ],
      tracks: const {},
    ).single;
    expect(unknown.progress, isNull);

    final over = buildDownloadEntries(
      downloads: [
        _download(
          trackId: 2,
          state: OfflineStateDto.downloading,
          bytes: 2_000,
          total: 1_000,
        ),
      ],
      tracks: const {},
    ).single;
    expect(over.progress, 1.0);
  });

  test('progress events update one row without touching the rest', () {
    final state = DownloadsState(
      entries: buildDownloadEntries(
        downloads: [
          _download(trackId: 1, state: OfflineStateDto.downloading, total: 100),
          _download(trackId: 2, state: OfflineStateDto.ready, bytes: 100),
        ],
        tracks: const {},
      ),
      readyCount: 1,
      totalBytes: 100,
    );

    final same = state.withProgress(99, 10, null);
    expect(identical(same, state), isTrue, reason: '未知曲目不应制造新状态');

    final updated = state.withProgress(1, 40, 100);
    expect(updated.entries[0].downloadedBytes, 40);
    expect(updated.entries[1].downloadedBytes, 100);
    expect(updated.readyCount, 1);
    expect(updated.totalBytes, 100);
    expect(state.entries[0].downloadedBytes, 0, reason: '原状态保持不可变');
  });

  test('state groups active, failed and completed rows', () {
    final state = DownloadsState(
      entries: buildDownloadEntries(
        downloads: [
          _download(trackId: 1, state: OfflineStateDto.queued),
          _download(trackId: 2, state: OfflineStateDto.downloading, total: 10),
          _download(trackId: 3, state: OfflineStateDto.failed),
          _download(trackId: 4, state: OfflineStateDto.ready, bytes: 10),
        ],
        tracks: const {},
      ),
    );
    expect(state.isEmpty, isFalse);
    expect(state.hasActive, isTrue);
    expect(state.active.map((e) => e.trackId), [1, 2]);
    expect(state.failed.map((e) => e.trackId), [3]);
    expect(state.ready.map((e) => e.trackId), [4]);
    expect(state.entryFor(4)?.isReady, isTrue);
    expect(state.entryFor(9), isNull);
    expect(DownloadsState().isEmpty, isTrue);
  });
}
