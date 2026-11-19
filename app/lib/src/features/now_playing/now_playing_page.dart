import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/now_playing/lyrics_view.dart';
import 'package:lekis/src/features/now_playing/now_playing_artwork.dart';
import 'package:lekis/src/features/now_playing/now_playing_background.dart';
import 'package:lekis/src/features/now_playing/now_playing_providers.dart';
import 'package:lekis/src/features/now_playing/now_playing_route.dart';
import 'package:lekis/src/features/now_playing/now_playing_tint.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/queue_view.dart';
import 'package:lekis/src/features/player/widgets/current_track.dart';
import 'package:lekis/src/features/player/widgets/player_controls.dart';
import 'package:lekis/src/layout/adaptive_two_pane.dart';
import 'package:lekis/src/layout/fold.dart';
import 'package:lekis/src/layout/window_size.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

/// Width from which lyrics get a third column next to cover and controls
/// (common 1024-wide tablets in landscape get the reference
/// cover | controls | lyrics layout).
const double _threePaneMinWidth = 1024;

/// Full-screen Now Playing.
///
/// Layouts (chosen from the window, never the device type):
/// * tabletop (half-open, horizontal hinge): artwork / lyrics above the
///   crease, controls below; nothing on the crease.
/// * landscape-ish, short, or split by a vertical fold / hinge: regions
///   side by side – cover | controls; with lyrics shown, cover + controls |
///   lyrics (or cover | controls | lyrics on very wide windows). The split
///   lands exactly on a vertical fold / hinge when there is one.
/// * portrait: artwork above controls, lyrics as a toggle in place of the
///   artwork.
///
/// Drag down (outside the lyrics list) to push the page back into the mini
/// player; swipe the cover sideways to skip.
class NowPlayingPage extends ConsumerStatefulWidget {
  const NowPlayingPage({super.key});

  @override
  ConsumerState<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends ConsumerState<NowPlayingPage> {
  void _close() => Navigator.of(context).maybePop();

  void _onDragStart(DragStartDetails d) =>
      NowPlayingRoute.of(context)?.beginDrag(MediaQuery.sizeOf(context));

  void _onDragUpdate(DragUpdateDetails d) =>
      NowPlayingRoute.of(context)?.dragBy(d.delta.dy);

  void _onDragEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    final route = NowPlayingRoute.of(context);
    if (route != null) {
      route.endDrag(v);
    } else if (v > LekisNowPlaying.dragCommitVelocity) {
      _close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = ref.watch(
      currentArtworkProvider.select((a) => a.value?.palette),
    );
    final lowPower = MediaQuery.disableAnimationsOf(context);
    final tint = NowPlayingTint.resolve(palette, theme.colorScheme);
    final fg = tint.foreground;
    final fgMuted = fg.withValues(alpha: 0.72);
    final lightForeground = tint.isLight;

    // Re-theme the page for the artwork-driven background. Text stays a
    // contrast-checked near-black / near-white; the cover's primary colour
    // is only used on small controls (play button, seek bar).
    final themed = theme.copyWith(
      colorScheme: theme.colorScheme.copyWith(
        onSurface: fg,
        onSurfaceVariant: fgMuted,
        primary: tint.primary,
        onPrimary: tint.onPrimary,
      ),
      iconTheme: theme.iconTheme.copyWith(color: fg),
      textTheme: theme.textTheme.apply(bodyColor: fg, displayColor: fg),
      sliderTheme: theme.sliderTheme.copyWith(
        activeTrackColor: tint.primary,
        thumbColor: tint.primary,
        inactiveTrackColor: fg.withValues(
          alpha: LekisType.lyricsInactiveOpacity,
        ),
        overlayColor: tint.primary.withValues(alpha: 0.12),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: fg),
      ),
      // Widgets that reach for LekisColors.accent (shuffle / repeat selected)
      // follow the cover too, while staying on the protected scene colour.
      extensions: [
        context.lekisColors.copyWith(
          accent: tint.primary,
          onAccent: tint.onPrimary,
          accentSoft: Color.alphaBlend(
            tint.primary.withValues(alpha: 0.22),
            tint.scene,
          ),
          onSurfaceVariant: fgMuted,
          outline: fg.withValues(alpha: 0.24),
        ),
      ],
    );

    return Theme(
      data: themed,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: lightForeground
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        child: CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
          child: PlayerShortcuts(
            autofocus: true,
            child: GestureDetector(
              onVerticalDragStart: _onDragStart,
              onVerticalDragUpdate: _onDragUpdate,
              onVerticalDragEnd: _onDragEnd,
              child: Semantics(
                namesRoute: true,
                label: '正在播放',
                child: Material(
                  type: MaterialType.transparency,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      NowPlayingBackground(lowPower: lowPower),
                      _NowPlayingLayout(lowPower: lowPower, onClose: _close),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NowPlayingLayout extends ConsumerWidget {
  const _NowPlayingLayout({required this.lowPower, required this.onClose});

  final bool lowPower;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trackId = ref.watch(playbackProvider.select((s) => s.trackId));
    final showLyrics = ref.watch(nowPlayingLyricsVisibleProvider);
    final fold = context.fold;
    final size = MediaQuery.sizeOf(context);
    final short = context.heightClass < WindowHeightClass.medium;
    final verticalFold = fold.hasHinge && fold.hingeAxis == Axis.vertical;
    final landscapeish = size.width >= 600 && size.width >= size.height * 0.95;

    Widget lyrics({bool compact = false}) => trackId == null
        ? const SizedBox.shrink()
        : LyricsView(
            key: ValueKey('lyrics-$trackId'),
            trackId: trackId,
            compact: compact,
            lowPower: lowPower,
          );

    const artwork = Padding(
      padding: EdgeInsets.all(LekisSpacing.xl),
      child: NowPlayingArtwork(),
    );

    Widget switcher({required bool compact}) => AnimatedSwitcher(
      duration: lowPower ? Duration.zero : LekisMotion.normal,
      child: showLyrics
          ? KeyedSubtree(
              key: const ValueKey('lyrics'),
              child: lyrics(compact: compact),
            )
          : const KeyedSubtree(key: ValueKey('art'), child: artwork),
    );

    final topBar = _TopBar(onClose: onClose);

    // Tabletop: top half = artwork / lyrics, bottom half = controls.
    if (fold.isTabletop) {
      return AdaptiveTwoPane(
        primary: SafeArea(
          child: Column(
            children: [
              topBar,
              Expanded(child: switcher(compact: true)),
            ],
          ),
        ),
        secondary: const SafeArea(
          child: Center(
            child: SingleChildScrollView(
              primary: false,
              child: NowPlayingControls(showLyricsToggle: true),
            ),
          ),
        ),
        primaryFraction: 0.5,
      );
    }

    // Regions side by side.
    if (short || landscapeish || verticalFold) {
      const controls = Center(
        child: SingleChildScrollView(
          primary: false,
          padding: EdgeInsets.symmetric(vertical: LekisSpacing.lg),
          child: NowPlayingControls(showLyricsToggle: true),
        ),
      );
      final threePane =
          showLyrics &&
          !short &&
          !verticalFold &&
          size.width >= _threePaneMinWidth;

      final String mode;
      final Widget regions;
      if (!showLyrics) {
        mode = 'cover|controls';
        regions = const _Split(fraction: 0.5, first: artwork, second: controls);
      } else if (threePane) {
        mode = 'cover|controls|lyrics';
        regions = _Split(
          fraction: 0.62,
          first: const _Split(fraction: 0.55, first: artwork, second: controls),
          second: lyrics(),
        );
      } else if (short) {
        // Too short to stack cover and controls: lyrics take the cover's
        // place.
        mode = 'controls|lyrics';
        regions = _Split(
          fraction: 0.5,
          first: controls,
          second: lyrics(compact: true),
        );
      } else {
        mode = 'cover+controls|lyrics';
        regions = _Split(
          fraction: 0.45,
          first: const Column(
            children: [
              Expanded(child: artwork),
              NowPlayingControls(showLyricsToggle: true),
              SizedBox(height: LekisSpacing.xl),
            ],
          ),
          second: lyrics(),
        );
      }

      return SafeArea(
        child: Column(
          children: [
            topBar,
            Expanded(
              child: AnimatedSwitcher(
                duration: lowPower ? Duration.zero : LekisMotion.normal,
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                layoutBuilder: (current, previous) => Stack(
                  fit: StackFit.expand,
                  children: [...previous, ?current],
                ),
                child: KeyedSubtree(key: ValueKey(mode), child: regions),
              ),
            ),
          ],
        ),
      );
    }

    // Portrait.
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          // Portrait tablets: keep the column a comfortable width.
          constraints: const BoxConstraints(
            maxWidth: LekisSizes.desktopSidebarWidth * 2.5,
          ),
          child: Column(
            children: [
              topBar,
              Expanded(child: switcher(compact: true)),
              const NowPlayingControls(showLyricsToggle: true),
              const SizedBox(height: LekisSpacing.lg),
            ],
          ),
        ),
      ),
    );
  }
}

/// Two regions side by side. The split follows a vertical fold or hinge
/// when one crosses this widget (so nothing straddles it), otherwise
/// [fraction] of the width.
class _Split extends StatelessWidget {
  const _Split({
    required this.fraction,
    required this.first,
    required this.second,
  });

  final double fraction;
  final Widget first;
  final Widget second;

  @override
  Widget build(BuildContext context) {
    final fold = context.fold;
    final insetLeft = MediaQuery.paddingOf(context).left;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        var firstWidth = width * fraction;
        var gap = 0.0;
        final hinge = fold.hingeBounds;
        if (hinge != null && fold.hingeAxis == Axis.vertical) {
          // The hinge is in window coordinates and the page fills the
          // window, so only the horizontal safe-area inset shifts it.
          final left = hinge.left - insetLeft;
          if (left > 0 && left + hinge.width < width) {
            firstWidth = left;
            gap = hinge.width;
          }
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: firstWidth, child: first),
            SizedBox(width: gap),
            Expanded(child: second),
          ],
        );
      },
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final fg = Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: LekisSpacing.sm,
        vertical: LekisSpacing.xs,
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: '关闭',
            constraints: const BoxConstraints(
              minWidth: LekisSizes.touchTargetMin,
              minHeight: LekisSizes.touchTargetMin,
            ),
            onPressed: onClose,
            icon: const Icon(Icons.keyboard_arrow_down_rounded),
          ),
          Expanded(
            child: Center(
              // Grabber hint for swipe-down.
              child: Container(
                width: LekisSpacing.xxl + LekisSpacing.xs,
                height: LekisSpacing.xs + LekisSpacing.xxs / 2,
                decoration: BoxDecoration(
                  color: fg.withValues(alpha: LekisType.lyricsInactiveOpacity),
                  borderRadius: BorderRadius.circular(LekisRadius.pill),
                ),
              ),
            ),
          ),
          const SizedBox(width: LekisSizes.touchTargetMin),
        ],
      ),
    );
  }
}

/// Title, seek bar, transport, volume and the lyrics / queue row.
class NowPlayingControls extends ConsumerWidget {
  const NowPlayingControls({super.key, required this.showLyricsToggle});

  final bool showLyricsToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final showLyrics = ref.watch(nowPlayingLyricsVisibleProvider);
    final hasTrack = ref.watch(playbackProvider.select((s) => s.hasTrack));
    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: LekisSizes.desktopSidebarWidth * 2.5,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: LekisSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: CurrentTrackText(
                titleStyle: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
                subtitleStyle: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: LekisSpacing.md),
            const SeekBar(),
            const SizedBox(height: LekisSpacing.sm),
            const FittedBox(child: TransportControls(large: true)),
            if (!platformHasSystemVolume) ...[
              const SizedBox(height: LekisSpacing.sm),
              const VolumeControl(width: LekisSizes.desktopSidebarWidth),
            ],
            const SizedBox(height: LekisSpacing.sm),
            // bottomBarStyle 1 + iconSpacing 2: centred, tightly spaced
            // secondary actions rather than spread to the window edges.
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (showLyricsToggle)
                  IconButton(
                    tooltip: showLyrics ? '显示封面' : '显示歌词',
                    isSelected: showLyrics,
                    constraints: const BoxConstraints(
                      minWidth: LekisSizes.touchTargetMin,
                      minHeight: LekisSizes.touchTargetMin,
                    ),
                    onPressed: hasTrack
                        ? () => ref
                              .read(nowPlayingLyricsVisibleProvider.notifier)
                              .set(!showLyrics)
                        : null,
                    icon: const Icon(Icons.lyrics_outlined),
                    selectedIcon: const Icon(Icons.lyrics_rounded),
                  ),
                const SizedBox(width: LekisSpacing.sm),
                IconButton(
                  tooltip: '播放队列',
                  constraints: const BoxConstraints(
                    minWidth: LekisSizes.touchTargetMin,
                    minHeight: LekisSizes.touchTargetMin,
                  ),
                  onPressed: hasTrack ? () => showQueueSheet(context) : null,
                  icon: const Icon(Icons.queue_music_rounded),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
