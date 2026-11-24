import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/plugins/official_plugins.dart';
import 'package:lekis/src/features/plugins/plugins_providers.dart';
import 'package:lekis/src/features/settings/settings_providers.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/platform/external_url.dart';
import 'package:lekis/src/platform/video_player.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:material_ui/material_ui.dart';

import 'bilibili_video_ref.dart';
import 'player_providers.dart';
import 'video_target.dart';

/// Video pages are available everywhere except the web build.
bool get supportsVideo => !kIsWeb;

String watchVideoLabel(BuildContext context) =>
    context.l10n.pick('观看视频', 'Watch video');

String openVideoInBrowserLabel(BuildContext context) =>
    context.l10n.pick('在浏览器打开视频', 'Open video in browser');

bool videoEnabled(WidgetRef ref) =>
    ref.watch(settingProvider(SettingKeys.video)).value != 'false';

/// Whether the source plugin can provide a video page. The bundled official
/// "视频播放" plugin covers sources without a native `video` export; disabling
/// that plugin also disables the built-in Bilibili fallback.
bool pluginSupportsVideo(WidgetRef ref, String? pluginId) {
  if (pluginId == null) return false;
  final all = ref.watch(pluginListProvider).value;
  final enabled = all
      ?.where((plugin) => plugin.enabled && plugin.error == null)
      .toList(growable: false);
  if (enabled != null) {
    if (enabled.any(
      (plugin) => plugin.id == pluginId && plugin.kinds.contains('video'),
    )) {
      return true;
    }
    if (enabled.any(
      (plugin) =>
          plugin.kinds.contains('video') && !plugin.kinds.contains('source'),
    )) {
      return true;
    }
  }
  if (pluginId == BilibiliVideoRef.pluginId) {
    // If the official plugin is installed but disabled, respect the switch;
    // only use the built-in mapping when installation itself was unavailable.
    final installed = all?.any((plugin) => plugin.id == officialVideoPluginId);
    return !(installed ?? false);
  }
  return false;
}

Future<void> watchTrackVideo(
  BuildContext context, {
  required int trackId,
  String? uid,
  String? pluginId,
  String? title,
  List<String>? artists,
  bool external = false,
}) async {
  try {
    final track = uid == null ? await core.getTrack(trackId: trackId) : null;
    if (!context.mounted) return;
    final source = PluginTrackRef.fromUid(uid ?? track!.uid);
    if (source == null) {
      _noVideo(context);
      return;
    }

    final container = ProviderScope.containerOf(context, listen: false);
    List<PluginInfoDto> allPlugins;
    try {
      allPlugins = await container.read(pluginListProvider.future);
    } catch (_) {
      allPlugins = const <PluginInfoDto>[];
    }
    if (!context.mounted) return;
    final plugins = allPlugins
        .where((plugin) => plugin.enabled && plugin.error == null)
        .toList(growable: false);
    final plugin = plugins
        .where((candidate) => candidate.id == source.pluginId)
        .firstOrNull;

    VideoTarget? target;
    if (plugin != null && plugin.kinds.contains('video')) {
      try {
        final dto = await core.pluginVideo(
          pluginId: source.pluginId,
          externalId: source.externalId,
        );
        target = VideoTarget(url: dto.url, title: dto.title);
      } catch (_) {
        // A broken source implementation can still be covered by an optional
        // video-provider plugin or the built-in Bilibili mapping.
      }
    }
    if (target == null) {
      for (final resolver in plugins.where(
        (candidate) =>
            candidate.id != source.pluginId &&
            candidate.kinds.contains('video') &&
            !candidate.kinds.contains('source'),
      )) {
        try {
          final dto = await core.pluginResolveVideo(
            resolverId: resolver.id,
            sourcePluginId: source.pluginId,
            externalId: source.externalId,
            title: title ?? track?.title,
            artists: artists ?? track?.artists ?? const [],
          );
          target = VideoTarget(url: dto.url, title: dto.title);
          break;
        } catch (_) {
          // Try the next provider; an unmappable track is not an error yet.
        }
      }
    }
    final officialInstalled = allPlugins.any(
      (candidate) => candidate.id == officialVideoPluginId,
    );
    final officialEnabled = plugins.any(
      (candidate) => candidate.id == officialVideoPluginId,
    );
    if (target == null &&
        (!officialInstalled || officialEnabled) &&
        source.pluginId == BilibiliVideoRef.pluginId &&
        (pluginId == null || pluginId == BilibiliVideoRef.pluginId)) {
      final video = BilibiliVideoRef.tryParse(
        sourcePluginId: source.pluginId,
        externalId: source.externalId,
      );
      if (video != null) {
        target = video.targetForPage(await video.playbackPage());
      }
    }
    if (!context.mounted) return;
    final video = target;
    if (video == null) {
      _noVideo(context);
      return;
    }

    if (external) {
      if (!await openExternalUrl(video.url)) {
        throw StateError('Could not open the video page');
      }
      if (container.read(playbackProvider).isPlaying) {
        container.read(playerActionsProvider).pause();
      }
      return;
    }

    final result = await openVideoPage(url: video.url, title: video.title);
    if (container.read(playbackProvider).isPlaying) {
      container.read(playerActionsProvider).pause();
    }
    if (result == VideoOpenResult.inApp && context.mounted) {
      final messenger = ScaffoldMessenger.of(context);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.pick('视频已在应用内打开', 'Video opened in the app'),
            ),
            duration: const Duration(seconds: 6),
            action: SnackBarAction(
              label: context.l10n.pick('在浏览器打开', 'Open in browser'),
              onPressed: () => unawaited(openExternalUrl(video.url)),
            ),
          ),
        );
    } else if (result == VideoOpenResult.external && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.pick(
              '应用内播放器不可用，已在浏览器打开',
              'The in-app player is unavailable; opened in your browser',
            ),
          ),
        ),
      );
    }
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          context.l10n.pick(
            '视频暂时无法打开，请稍后再试',
            'Could not open the video. Please try again.',
          ),
        ),
      ),
    );
  }
}

void _noVideo(BuildContext context) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(context.l10n.pick('这首歌没有视频', 'No video for this track')),
    ),
  );
}
