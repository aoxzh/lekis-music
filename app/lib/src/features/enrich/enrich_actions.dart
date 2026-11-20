// 手动"补全封面和歌词"：曲目菜单、专辑页共用。
//
// 核心按匹配度处理：把握大的直接应用（只写覆盖层 / 缓存，不动原文件），
// 把握一般的进待确认队列，结果用一条提示告诉用户，有待确认的给个入口。

import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Int64List;
import 'package:lekis/src/features/library/library_actions.dart'
    show describeCoreError;
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/shell/routes.dart';
import 'package:material_ui/material_ui.dart';

abstract final class EnrichActionStrings {
  static const action = '补全封面和歌词';
  static const running = '正在查找封面和歌词…';
  static const nothing = '没有找到新的封面或歌词';
  static const review = '去确认';
  static const failed = '补全失败';

  static String result(EnrichReportDto r) {
    final parts = [
      if (r.autoApplied > 0) '已补全 ${r.autoApplied} 项',
      if (r.queued > 0) '${r.queued} 项待确认',
    ];
    return parts.isEmpty ? nothing : parts.join('，');
  }
}

/// 对 [trackIds] 跑一次补全并提示结果。
Future<void> enrichTracksFlow(BuildContext context, List<int> trackIds) async {
  // 核心的 enrichTracks 收到空列表会补全整个资料库，这里绝不能传空。
  if (trackIds.isEmpty) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      const SnackBar(
        content: Text(EnrichActionStrings.running),
        duration: Duration(minutes: 1),
      ),
    );
  SnackBar result;
  try {
    final report = trackIds.length == 1
        ? await core.enrichTrack(trackId: trackIds.single)
        : await core.enrichTracks(trackIds: Int64List.fromList(trackIds));
    result = SnackBar(
      content: Text(EnrichActionStrings.result(report)),
      action: report.queued > 0 && context.mounted
          ? SnackBarAction(
              label: EnrichActionStrings.review,
              onPressed: () {
                if (context.mounted) openEnrichReview(context);
              },
            )
          : null,
    );
  } catch (error) {
    result = SnackBar(
      content: Text(
        '${EnrichActionStrings.failed}：${describeCoreError(error)}',
      ),
    );
  }
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(result);
}
