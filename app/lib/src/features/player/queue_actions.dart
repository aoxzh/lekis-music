// "下一首播放" / "加入播放队列"：曲目菜单、批量选择、专辑 / 歌单页共用。
//
// 核心那边是同步调用（只改内存里的队列，队列为空时直接开始播放），
// 改完会推一次播放状态（queueVersion 变化），队列面板自己刷新。

import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Int64List;

import 'package:lekis/src/features/library/library_actions.dart'
    show describeCoreError;
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:material_ui/material_ui.dart';

enum QueuePlacement {
  /// 插到当前曲目之后。
  next,

  /// 追加到队尾。
  end,
}

abstract final class QueueStrings {
  static const playNext = '下一首播放';
  static const addToQueue = '加入播放队列';

  static String done(QueuePlacement where, int count) {
    final what = count == 1 ? '' : ' $count 首';
    return switch (where) {
      QueuePlacement.next => '已设为下一首播放$what',
      QueuePlacement.end => '已加入播放队列$what',
    };
  }

  static const failed = '没能加入播放队列';
}

/// 把 [trackIds] 放进播放队列，并给一个简短提示。
void queueTracks(
  BuildContext context,
  List<int> trackIds, {
  required QueuePlacement where,
}) {
  if (trackIds.isEmpty) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  String message;
  final ids = Int64List.fromList(trackIds);
  try {
    switch (where) {
      case QueuePlacement.next:
        core.playNext(trackIds: ids);
      case QueuePlacement.end:
        core.addToQueue(trackIds: ids);
    }
    message = QueueStrings.done(where, trackIds.length);
  } catch (error) {
    message = '${QueueStrings.failed}：${describeCoreError(error)}';
  }
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
}
