// Track-level library actions: loved / rating, with optimistic overrides.
//
// The core emits a `LibraryChanged` event after a successful write, but the
// round-trip through the event stream is fast enough that a row would visibly
// lag behind the tap. These providers keep the pressed state locally and roll
// it back if the bridge call fails.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/error.dart';

class LovedOverridesController extends Notifier<Map<int, bool>> {
  @override
  Map<int, bool> build() => const {};

  /// 先改 UI，桥接调用失败时恢复原值。返回是否成功。
  Future<bool> set(int trackId, bool loved) async {
    final before = Map<int, bool>.of(state);
    state = {...state, trackId: loved};
    try {
      await core.setLoved(trackId: trackId, loved: loved);
      return true;
    } catch (e) {
      state = before;
      debugPrint('setLoved($trackId, $loved) failed: $e');
      return false;
    }
  }
}

final lovedOverridesProvider =
    NotifierProvider<LovedOverridesController, Map<int, bool>>(
      LovedOverridesController.new,
    );

class RatingOverridesController extends Notifier<Map<int, int?>> {
  @override
  Map<int, int?> build() => const {};

  /// 0 / null 表示清除评分。
  Future<bool> set(int trackId, int? rating) async {
    final before = Map<int, int?>.of(state);
    state = {...state, trackId: rating};
    try {
      await core.setRating(trackId: trackId, rating: rating ?? 0);
      return true;
    } catch (e) {
      state = before;
      debugPrint('setRating($trackId, $rating) failed: $e');
      return false;
    }
  }
}

final ratingOverridesProvider =
    NotifierProvider<RatingOverridesController, Map<int, int?>>(
      RatingOverridesController.new,
    );

/// 评分：本地乐观值优先，否则用服务端返回的 `TrackDto.rating`。
int? ratingOf(WidgetRef ref, int trackId, int? serverRating) {
  final overrides = ref.watch(ratingOverridesProvider);
  return overrides.containsKey(trackId) ? overrides[trackId] : serverRating;
}

/// Commands used by row / Now Playing widgets.
class LibraryActions {
  LibraryActions(this._ref);
  final Ref _ref;

  Future<bool> setLoved(int trackId, bool loved) =>
      _ref.read(lovedOverridesProvider.notifier).set(trackId, loved);

  Future<bool> setRating(int trackId, int? rating) =>
      _ref.read(ratingOverridesProvider.notifier).set(trackId, rating);
}

final libraryActionsProvider = Provider<LibraryActions>(LibraryActions.new);

/// 把桥接层的错误转成一句能给用户看的短提示。
String describeCoreError(Object error) {
  if (error is CoreError) return error.detail;
  return '$error';
}
