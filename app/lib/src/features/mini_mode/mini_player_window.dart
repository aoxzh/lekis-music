// The mini player view and the host that swaps it in for the full UI.
//
// [MiniModeHost] sits in `MaterialApp.builder`, above the Navigator, so open
// pages, dialogs and the Now Playing route all stay alive (just hidden) while
// the window is the mini player, and come back untouched.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_l10n.dart';
import '../../theme/theme.dart';
import '../player/player_providers.dart';
import '../player/sleep_timer.dart';
import '../player/widgets/current_track.dart';
import '../player/widgets/player_controls.dart';
import 'mini_cover_backdrop.dart';
import 'mini_mode_controller.dart';

/// Shows [child] (the app's Navigator) normally, or [MiniPlayerView] while
/// [miniModeProvider] is on.
///
/// The hidden full UI keeps the size it had before the window shrank, so it
/// does not re-layout into the phone layout (and lose state) underneath.
class MiniModeHost extends ConsumerStatefulWidget {
  const MiniModeHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<MiniModeHost> createState() => _MiniModeHostState();
}

class _MiniModeHostState extends ConsumerState<MiniModeHost> {
  Size? _fullSize;

  @override
  Widget build(BuildContext context) {
    final mini = ref.watch(miniModeProvider);
    final mq = MediaQuery.of(context);
    if (!mini) _fullSize = mq.size;
    final frozen = _fullSize ?? mq.size;

    Widget full = widget.child;
    if (mini) {
      full = MediaQuery(
        data: mq.copyWith(size: frozen),
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: frozen.width,
          maxWidth: frozen.width,
          minHeight: frozen.height,
          maxHeight: frozen.height,
          child: full,
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // Same element in both modes (stable key + position), so the
        // Navigator and every open page survive the switch.
        Offstage(
          key: const ValueKey('mini-mode.full'),
          offstage: mini,
          child: ExcludeFocus(
            excluding: mini,
            child: TickerMode(
              enabled: !mini,
              child: ClipRect(child: full),
            ),
          ),
        ),
        if (mini)
          HeroControllerScope.none(
            child: Navigator(
              key: const ValueKey('mini-mode.mini'),
              onGenerateRoute: (_) => PageRouteBuilder<void>(
                pageBuilder: (_, _, _) => const PlayerShortcuts(
                  autofocus: true,
                  child: MiniPlayerView(),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _MiniPanorama extends Notifier<bool> {
  static const setting = 'desktop.mini_player.cover_style';
  bool _edited = false;
  Future<void> _pendingSave = Future.value();

  @override
  bool build() {
    unawaited(_restore(ref.read(miniWindowGatewayProvider)));
    return false;
  }

  Future<void> _restore(MiniWindowGateway gateway) async {
    try {
      final saved = await gateway.getSetting(setting);
      if (ref.mounted && !_edited) state = saved == 'panorama';
    } catch (error) {
      debugPrint('mini mode: reading cover style failed: $error');
    }
  }

  void toggle() {
    _edited = true;
    state = !state;
    final style = state ? 'panorama' : 'square';
    final gateway = ref.read(miniWindowGatewayProvider);
    _pendingSave = _pendingSave.then((_) async {
      try {
        await gateway.setSetting(setting, style);
      } catch (error) {
        debugPrint('mini mode: saving cover style failed: $error');
      }
    });
  }
}

final _miniPanoramaProvider = NotifierProvider<_MiniPanorama, bool>(
  _MiniPanorama.new,
);

/// Compact always-on-top player: cover, title / artist, previous / play /
/// next, a progress line, and a button back to the full window. The whole
/// strip drags the window.
class MiniPlayerView extends ConsumerWidget {
  const MiniPlayerView({super.key});

  static const Key expandKey = ValueKey('mini-player.expand');
  static const Key coverToggleKey = ValueKey('mini-player.cover-toggle');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lekisColors;
    final hasTrack = ref.watch(playbackProvider.select((s) => s.hasTrack));
    final text = Theme.of(context).textTheme;
    final panorama = ref.watch(_miniPanoramaProvider);

    final body = LayoutBuilder(
      builder: (context, bounds) {
        final progressHeight = hasTrack
            ? (bounds.maxHeight < 90
                  ? LekisSpacing.md
                  : LekisSizes.touchTargetMin / 2)
            : LekisSpacing.xxs;
        final bodyHeight = bounds.maxHeight - progressHeight;
        final short = bodyHeight < 78;
        final narrow = bounds.maxWidth < 300;
        final inset = short || narrow ? LekisSpacing.xs : LekisSpacing.sm;
        final thumbnail = math
            .min(
              bodyHeight - 2 * inset,
              bounds.maxWidth * (narrow ? 0.23 : 0.27),
            )
            .clamp(0.0, 100.0);
        final backdropWidth = bounds.maxWidth * (narrow ? 0.43 : 0.53);
        final infoLeft = panorama
            ? backdropWidth * 0.77
            : thumbnail + inset * 2;
        final buttonSize = short ? 26.0 : 32.0;
        final controls = Stack(
          fit: StackFit.expand,
          children: [
            Positioned(
              left: inset,
              bottom: inset,
              child: SizedBox.square(
                dimension: buttonSize,
                child: IconButton.filledTonal(
                  key: coverToggleKey,
                  tooltip: panorama
                      ? context.l10n.pick('切回方形封面', 'Show square cover')
                      : context.l10n.pick('展开封面全景', 'Show panoramic cover'),
                  style: IconButton.styleFrom(
                    backgroundColor: colors.surfaceElevated,
                    foregroundColor: Theme.of(context).colorScheme.onSurface,
                    padding: EdgeInsets.zero,
                    side: BorderSide(color: colors.outline),
                  ),
                  iconSize: 17,
                  onPressed: ref.read(_miniPanoramaProvider.notifier).toggle,
                  icon: Icon(
                    panorama ? Icons.crop_square : Icons.panorama_outlined,
                  ),
                ),
              ),
            ),
            Positioned(
              left: infoLeft,
              right: inset,
              top: short ? 0 : inset,
              bottom: short ? 0 : inset,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, available) => FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: SizedBox(
                                width: available.maxWidth,
                                child: CurrentTrackText(
                                  titleStyle: text.titleSmall,
                                  subtitleStyle: text.bodySmall?.copyWith(
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        SizedBox.square(
                          dimension: buttonSize,
                          child: const SleepTimerButton(
                            key: ValueKey('mini-player.sleep-timer'),
                            compact: true,
                          ),
                        ),
                        SizedBox.square(
                          dimension: buttonSize,
                          child: IconButton(
                            key: expandKey,
                            tooltip: context.l10n.exitMiniPlayer,
                            visualDensity: VisualDensity.compact,
                            iconSize: 18,
                            constraints: const BoxConstraints(
                              minWidth: 32,
                              minHeight: 32,
                            ),
                            padding: EdgeInsets.zero,
                            onPressed: () =>
                                ref.read(miniModeProvider.notifier).exit(),
                            icon: const Icon(Icons.open_in_full_rounded),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    height: short ? bodyHeight * 0.48 : 36,
                    child: IconButtonTheme(
                      data: IconButtonThemeData(
                        style: IconButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          minimumSize: const Size(36, 36),
                          padding: EdgeInsets.zero,
                        ),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Flexible(child: PreviousButton(size: 22)),
                          Flexible(child: PlayPauseButton(size: 26)),
                          Flexible(child: NextButton(size: 22)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
        return Stack(
          children: [
            Positioned.fill(
              bottom: panorama ? 0 : progressHeight,
              child: MiniCoverBackdrop(
                panorama: panorama,
                thumbnail: thumbnail,
                width: backdropWidth,
                inset: inset,
              ),
            ),
            Positioned.fill(
              bottom: progressHeight,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanStart: (_) =>
                    ref.read(miniWindowGatewayProvider).startDragging(),
                child: controls,
              ),
            ),
            if (hasTrack)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                height: progressHeight,
                child: const ThinProgressBar(interactive: true),
              ),
          ],
        );
      },
    );

    // Wheel over the strip adjusts volume; mini mode has no room for a
    // separate slider.
    void onPointerSignal(PointerSignalEvent event) {
      if (event is! PointerScrollEvent) return;
      final dy = event.scrollDelta.dy;
      // Trackpads send horizontal pans as scroll events too; only vertical
      // scrolling should change the volume, otherwise a sideways swipe jumps
      // it up by one step.
      if (dy == 0) return;
      final current = ref.read(playbackProvider).volume;
      final delta = dy > 0 ? -0.04 : 0.04;
      ref
          .read(playerActionsProvider)
          .setVolume((current + delta).clamp(0.0, 1.0));
    }

    return Listener(
      onPointerSignal: onPointerSignal,
      child: Material(
        color: colors.surfaceElevated,
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(border: Border.all(color: colors.outline)),
          child: Semantics(label: context.l10n.miniPlayerMode, child: body),
        ),
      ),
    );
  }
}
