// 手动"补全封面和歌词"：曲目菜单、专辑页、库健康与补全确认页共用。
//
// 支持按需选择补全范围（仅封面 / 仅歌词 / 封面 + 歌词），
// 核心按匹配度处理：把握大的直接应用（只写覆盖层 / 缓存，不动原文件），
// 把握一般的进待确认队列，结果用一条提示告诉用户，有待确认的给个入口。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Int64List;
import 'package:lekis/src/features/library/library_actions.dart'
    show describeCoreError;
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/shell/routes.dart';
import 'package:material_ui/material_ui.dart';

import 'enrich_progress.dart';

const String enrichScopeSettingKey = 'enrich.scope';

/// 补全范围：全部 / 仅封面 / 仅歌词。
enum EnrichScope {
  all('all'),
  artwork('artwork'),
  lyrics('lyrics');

  const EnrichScope(this.storageValue);

  final String storageValue;

  String get label => switch (this) {
    EnrichScope.all => L10n.tr('封面和歌词', 'Artwork & Lyrics'),
    EnrichScope.artwork => L10n.tr('仅补全封面', 'Artwork Only'),
    EnrichScope.lyrics => L10n.tr('仅补全歌词', 'Lyrics Only'),
  };

  String get hint => switch (this) {
    EnrichScope.all => L10n.tr(
      '联网匹配缺失的专辑封面与同步歌词（免 API Key）',
      'Fetch missing album artwork and synced lyrics (no API key needed)',
    ),
    EnrichScope.artwork => L10n.tr(
      '仅从 iTunes(含日区) / Deezer / 网易云 / VocaDB / Cover Art Archive 查找高清封面',
      'Search iTunes (incl. JP), Deezer, NetEase, VocaDB & Cover Art Archive for covers',
    ),
    EnrichScope.lyrics => L10n.tr(
      '仅从 LRCLIB / 网易云 / 酷狗 / Lyrics.ovh 查找歌词',
      'Search LRCLIB, NetEase, KuGou & Lyrics.ovh for lyrics only',
    ),
  };

  IconData get icon => switch (this) {
    EnrichScope.all => Icons.auto_fix_high_outlined,
    EnrichScope.artwork => Icons.image_search_outlined,
    EnrichScope.lyrics => Icons.lyrics_outlined,
  };
}

abstract final class EnrichActionStrings {
  static String get action => L10n.tr('补全封面和歌词', 'Fetch Artwork & Lyrics');
  static String get chooseTitle => L10n.tr('选择补全内容', 'Choose What to Fetch');
  static String get runningAll => L10n.tr('正在查找封面和歌词…', 'Fetching artwork & lyrics…');
  static String get runningArtwork => L10n.tr('正在查找缺失封面…', 'Fetching missing artwork…');
  static String get runningLyrics => L10n.tr('正在查找缺失歌词…', 'Fetching missing lyrics…');
  static String get nothing => L10n.tr('没有找到新的封面或歌词', 'No new artwork or lyrics found');
  static String get review => L10n.tr('去确认', 'Review');
  static String get failed => L10n.tr('补全失败', 'Enrichment failed');
  static String get cancel => L10n.tr('取消', 'Cancel');
  static String get batchNoneMissing =>
      L10n.tr('当前没有缺少对应项的曲目', 'No tracks are missing this item');

  static String runningFor(EnrichScope scope) => switch (scope) {
    EnrichScope.all => runningAll,
    EnrichScope.artwork => runningArtwork,
    EnrichScope.lyrics => runningLyrics,
  };

  static String result(EnrichReportDto r) {
    final parts = [
      if (r.autoApplied > 0)
        L10n.tr('已补全 ${r.autoApplied} 项', 'Applied ${r.autoApplied}'),
      if (r.queued > 0) L10n.tr('${r.queued} 项待确认', '${r.queued} to review'),
    ];
    return parts.isEmpty ? nothing : parts.join(L10n.tr('，', ', '));
  }
}

/// 弹窗让用户选择补全范围（封面 + 歌词 / 仅封面 / 仅歌词）。
Future<EnrichScope?> showEnrichScopeDialog(BuildContext context) {
  return showDialog<EnrichScope>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(EnrichActionStrings.chooseTitle),
      children: [
        for (final scope in EnrichScope.values)
          ListTile(
            leading: Icon(scope.icon),
            title: Text(scope.label),
            subtitle: Text(scope.hint),
            onTap: () => Navigator.of(context).pop(scope),
          ),
      ],
    ),
  );
}

/// 对 [trackIds] 跑一次补全并提示结果（自动驱动 [enrichProgressProvider] 实时进度条）。
///
/// 未显式传入 [scope] 时先弹出范围选择（封面 + 歌词 / 仅封面 / 仅歌词）。
Future<void> enrichTracksFlow(
  BuildContext context,
  List<int> trackIds, {
  EnrichScope? scope,
  List<EnrichTarget>? targets,
  VoidCallback? onCompleted,
}) async {
  final resolvedTargets =
      targets ?? [for (final id in trackIds) EnrichTarget(trackId: id)];
  if (resolvedTargets.isEmpty) return;
  final chosen = scope ?? await showEnrichScopeDialog(context);
  if (chosen == null || !context.mounted) return;

  final messenger = ScaffoldMessenger.maybeOf(context);
  ProviderContainer? container;
  try {
    container = ProviderScope.containerOf(context, listen: false);
  } catch (_) {}

  if (container != null && resolvedTargets.length > 1) {
    final notifier = container.read(enrichProgressProvider.notifier);
    if (container.read(enrichProgressProvider)?.running == true) {
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(EnrichActionStrings.runningFor(chosen))),
        );
      return;
    }
    final done = await notifier.run(
      scope: chosen,
      targets: resolvedTargets,
      onCompleted: onCompleted,
    );
    if (done == null) return;
    final report = EnrichReportDto(
      autoApplied: done.autoApplied,
      queued: done.queued,
      discarded: 0,
    );
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            done.cancelled
                ? L10n.tr(
                    '已取消补全（完成 ${done.completed} / ${done.total}）',
                    'Enrichment cancelled (${done.completed} / ${done.total})',
                  )
                : EnrichActionStrings.result(report),
          ),
          action: report.queued > 0 && context.mounted
              ? SnackBarAction(
                  label: EnrichActionStrings.review,
                  onPressed: () {
                    if (context.mounted) openEnrichReview(context);
                  },
                )
              : null,
        ),
      );
    return;
  }

  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(EnrichActionStrings.runningFor(chosen)),
        duration: const Duration(minutes: 2),
      ),
    );
  SnackBar result;
  try {
    await core.setSetting(
      key: enrichScopeSettingKey,
      value: chosen.storageValue,
    );
    final ids = [for (final t in resolvedTargets) t.trackId];
    final report = ids.length == 1
        ? await core.enrichTrack(trackId: ids.single)
        : await core.enrichTracks(trackIds: Int64List.fromList(ids));
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
    onCompleted?.call();
  } catch (error) {
    result = SnackBar(
      content: Text(
        '${EnrichActionStrings.failed}：${describeCoreError(error)}',
      ),
    );
  } finally {
    try {
      await core.setSetting(key: enrichScopeSettingKey, value: 'all');
    } catch (_) {}
  }
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(result);
}

/// 从资料库中收集缺失封面或歌词的曲目，按所选范围执行补全。
///
/// 会分页读取健康报告直到没有更多缺失项，因此一次点击会处理全部缺失曲目；
/// 进度条显示总数，用户可随时取消。仅补全封面时按专辑去重：同一张缺封面的
/// 专辑只查一首代表曲目，避免重复请求与重复候选。
Future<void> enrichMissingFromLibraryFlow(
  BuildContext context, {
  EnrichScope? scope,
  VoidCallback? onCompleted,
}) async {
  final chosen = scope ?? await showEnrichScopeDialog(context);
  if (chosen == null || !context.mounted) return;

  final targets = <int, EnrichTarget>{};
  final seenAlbums = <int>{};
  Future<void> collect(
    HealthIssueKindDto kind, {
    bool albumDedupe = false,
  }) async {
    const pageSize = 200;
    var offset = 0;
    while (true) {
      final rows = await core.libraryHealthPage(
        kind: kind,
        offset: offset,
        limit: pageSize,
      );
      if (rows.isEmpty) return;
      for (final row in rows) {
        final albumId = row.albumId?.toInt();
        if (albumDedupe &&
            albumId != null &&
            !seenAlbums.add(albumId)) {
          continue;
        }
        targets.putIfAbsent(
          row.trackId,
          () => EnrichTarget(trackId: row.trackId, title: row.title),
        );
      }
      if (rows.length < pageSize) return;
      offset += rows.length;
    }
  }

  try {
    if (chosen == EnrichScope.all || chosen == EnrichScope.artwork) {
      await collect(
        HealthIssueKindDto.missingCover,
        albumDedupe: chosen == EnrichScope.artwork,
      );
    }
    if (chosen == EnrichScope.all || chosen == EnrichScope.lyrics) {
      await collect(HealthIssueKindDto.missingLyrics);
    }
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            '${EnrichActionStrings.failed}：${describeCoreError(error)}',
          ),
        ),
      );
    return;
  }

  if (!context.mounted) return;
  if (targets.isEmpty) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(EnrichActionStrings.batchNoneMissing)),
      );
    return;
  }
  final list = targets.values.toList();
  await enrichTracksFlow(
    context,
    [for (final t in list) t.trackId],
    scope: chosen,
    targets: list,
    onCompleted: onCompleted,
  );
}
