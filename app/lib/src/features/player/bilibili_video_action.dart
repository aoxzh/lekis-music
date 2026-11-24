import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/platform/bilibili_video.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:material_ui/material_ui.dart';

import 'bilibili_video_ref.dart';
import 'player_providers.dart';

bool get supportsBilibiliVideo =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.android);

String watchVideoLabel(BuildContext context) =>
    context.l10n.pick('观看 B 站视频', 'Watch Bilibili video');

Future<void> watchBilibiliTrack(
  BuildContext context, {
  required int trackId,
  BilibiliVideoRef? video,
}) async {
  try {
    final target =
        video ??
        BilibiliVideoRef.fromTrackUid(
          (await core.getTrack(trackId: trackId)).uid,
        );
    if (!context.mounted) return;
    if (target == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.pick(
              '这首曲目没有 B 站视频',
              'No Bilibili video for this track',
            ),
          ),
        ),
      );
      return;
    }
    final page = await target.playbackPage();
    if (!context.mounted) return;
    final container = ProviderScope.containerOf(context, listen: false);
    await openBilibiliVideo(bvid: target.bvid, page: page);
    if (container.read(playbackProvider).isPlaying) {
      container.read(playerActionsProvider).pause();
    }
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          context.l10n.pick(
            '视频暂时无法打开，请稍后重试',
            'Could not open the video. Please try again.',
          ),
        ),
      ),
    );
  }
}
