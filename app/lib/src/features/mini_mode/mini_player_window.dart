// The mini player view and the host that swaps it in for the full UI.
//
// [MiniModeHost] sits in `MaterialApp.builder`, above the Navigator, so open
// pages, dialogs and the Now Playing route all stay alive (just hidden) while
// the window is the mini player, and come back untouched.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_l10n.dart';
import '../../theme/theme.dart';
import '../player/player_providers.dart';
import '../player/widgets/current_track.dart';
import '../player/widgets/player_controls.dart';
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
          child: TickerMode(
            enabled: !mini,
            child: ClipRect(child: full),
          ),
        ),
        if (mini)
          // Above the Navigator: tooltips need an Overlay of their own.
          Overlay(
            key: const ValueKey('mini-mode.mini'),
            initialEntries: [
              OverlayEntry(
                builder: (_) => const PlayerShortcuts(child: MiniPlayerView()),
              ),
            ],
          ),
      ],
    );
  }
}

/// Compact always-on-top player: cover, title / artist, previous / play /
/// next, a progress line, and a button back to the full window. The whole
/// strip drags the window.
class MiniPlayerView extends ConsumerWidget {
  const MiniPlayerView({super.key});

  static const Key expandKey = ValueKey('mini-player.expand');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lekisColors;
    final hasTrack = ref.watch(playbackProvider.select((s) => s.hasTrack));
    final text = Theme.of(context).textTheme;

    final body = Padding(
      padding: const EdgeInsets.fromLTRB(
        LekisSpacing.sm,
        LekisSpacing.sm,
        LekisSpacing.xs,
        LekisSpacing.xs,
      ),
      child: Row(
        children: [
          const AspectRatio(
            aspectRatio: 1,
            child: CurrentArtwork(radius: LekisRadius.sm),
          ),
          const SizedBox(width: LekisSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: CurrentTrackText(
                        titleStyle: text.titleSmall,
                        subtitleStyle: text.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                    IconButton(
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
                  ],
                ),
                const Spacer(),
                IconButtonTheme(
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
                      PreviousButton(size: 22),
                      PlayPauseButton(size: 26),
                      NextButton(size: 22),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return Material(
      color: colors.surfaceElevated,
      child: DecoratedBox(
        decoration: BoxDecoration(border: Border.all(color: colors.outline)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              // A title-bar double-tap recognizer here delays the first tap
              // on transport/expand buttons while it waits for a second tap.
              // Mini mode cannot maximize; retain only its native pan action.
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanStart: (_) =>
                    ref.read(miniWindowGatewayProvider).startDragging(),
                child: Semantics(
                  label: context.l10n.miniPlayerMode,
                  child: body,
                ),
              ),
            ),
            if (hasTrack)
              const ThinProgressBar()
            else
              const SizedBox(height: 2),
          ],
        ),
      ),
    );
  }
}
