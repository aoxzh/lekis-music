// 补全待确认队列的状态与操作。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../bridge/core_events.dart';
import '../../rust/api/core.dart' as core;
import '../../rust/api/dto.dart';
import 'enrich_models.dart';

/// 一次最多拉多少条候选进页面。
const int enrichPageSize = 200;

/// 队列长度（可供导航栏做角标）。初始值来自核心，之后跟随 `EnrichQueueChanged`。
final enrichPendingCountProvider =
    NotifierProvider<EnrichPendingCountNotifier, int?>(
      EnrichPendingCountNotifier.new,
    );

class EnrichPendingCountNotifier extends Notifier<int?> {
  @override
  int? build() {
    ref.listen(coreEventsProvider, (_, next) {
      final event = next.value;
      if (event is CoreEventDto_EnrichQueueChanged) state = event.pending;
    });
    _load();
    return null;
  }

  Future<void> _load() async {
    try {
      final n = await core.pendingCandidateCount();
      if (ref.mounted && state == null) state = n.toInt();
    } catch (_) {
      // 读不到就等下一条事件。
    }
  }
}

/// 待确认的候选列表。
final enrichQueueProvider =
    AsyncNotifierProvider<EnrichQueueNotifier, List<EnrichCandidateDto>>(
      EnrichQueueNotifier.new,
    );

class EnrichQueueNotifier extends AsyncNotifier<List<EnrichCandidateDto>> {
  @override
  Future<List<EnrichCandidateDto>> build() {
    ref.listen(coreEventsProvider, (_, next) {
      if (next.value is CoreEventDto_EnrichQueueChanged) _refreshQuietly();
    });
    return core.pendingCandidates(limit: enrichPageSize);
  }

  Future<void> reload() async {
    state = const AsyncLoading<List<EnrichCandidateDto>>();
    state = await AsyncValue.guard(
      () => core.pendingCandidates(limit: enrichPageSize),
    );
  }

  /// 后台刷新：不闪加载态，失败时保留旧数据。
  Future<void> _refreshQuietly() async {
    try {
      final list = await core.pendingCandidates(limit: enrichPageSize);
      if (ref.mounted) state = AsyncData(list);
    } catch (_) {}
  }

  void _remove(int id) {
    final list = state.value;
    if (list == null) return;
    state = AsyncData([
      for (final c in list)
        if (c.id != id) c,
    ]);
  }

  void _restore(EnrichCandidateDto candidate) {
    final list = state.value;
    if (list == null || list.any((c) => c.id == candidate.id)) return;
    state = AsyncData([candidate, ...list]);
  }

  /// 接受一条。先从列表里拿掉，失败再放回来并抛出。
  Future<void> accept(EnrichCandidateDto candidate) async {
    _remove(candidate.id);
    try {
      await core.acceptCandidate(candidateId: candidate.id);
    } catch (e) {
      _restore(candidate);
      rethrow;
    }
  }

  Future<void> reject(EnrichCandidateDto candidate) async {
    _remove(candidate.id);
    try {
      await core.rejectCandidate(candidateId: candidate.id);
    } catch (e) {
      _restore(candidate);
      rethrow;
    }
  }

  /// 全部接受，返回实际应用的条数。
  Future<int> acceptAll() async {
    final n = await core.acceptAllCandidates();
    await _refreshQuietly();
    return n.toInt();
  }
}

/// 候选对应曲目的“当前”状态，用于和建议并排对比。
@immutable
class CandidateCurrent {
  const CandidateCurrent({this.track, this.artworkFile, this.lyrics});

  final TrackDto? track;

  /// 当前封面缩略图的本地文件路径（没有封面时为 `null`）。
  final String? artworkFile;
  final String? lyrics;
}

/// 封面缩略图宽度（像素），核心会钳到它实际缓存的尺寸范围内。
const int _thumbWidth = 320;

final candidateCurrentProvider = FutureProvider.autoDispose
    .family<CandidateCurrent, EnrichCandidateDto>((ref, candidate) async {
      final trackId = candidate.trackId;
      if (trackId == null) return const CandidateCurrent();
      final track = await core.getTrack(trackId: trackId);
      String? artworkFile;
      String? lyrics;
      switch (parseProposal(candidate)) {
        case ArtworkProposal():
          final art = await core.artwork(trackId: trackId);
          if (art != null) {
            artworkFile = core.artworkPath(
              hash: art.hash,
              width: art.width ?? _thumbWidth,
            );
          }
        case LyricsProposal():
          lyrics = (await core.lyrics(trackId: trackId))?.content;
        default:
          break;
      }
      return CandidateCurrent(
        track: track,
        artworkFile: artworkFile,
        lyrics: lyrics,
      );
    });
