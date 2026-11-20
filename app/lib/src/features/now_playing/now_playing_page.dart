import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/now_playing/cover_wall.dart';
import 'package:lekis/src/features/now_playing/lyrics_view.dart';
import 'package:lekis/src/features/now_playing/now_playing_artwork.dart';
import 'package:lekis/src/features/now_playing/now_playing_background.dart';
import 'package:lekis/src/features/now_playing/now_playing_library_actions.dart';
import 'package:lekis/src/features/now_playing/now_playing_layout.dart';
import 'package:lekis/src/features/now_playing/now_playing_providers.dart';
import 'package:lekis/src/features/now_playing/now_playing_route.dart';
import 'package:lekis/src/features/now_playing/now_playing_tint.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/queue_panel.dart';
import 'package:lekis/src/features/player/queue_view.dart';
import 'package:lekis/src/features/player/widgets/player_controls.dart';
import 'package:lekis/src/layout/adaptive_two_pane.dart';
import 'package:lekis/src/layout/fold.dart';
import 'package:lekis/src/layout/window_size.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

/// Full-screen Now Playing.
///
/// Layouts (chosen from the window, never the device type):
/// * tabletop (half-open, horizontal hinge): artwork / wall / lyrics above
///   the crease, controls below; nothing on the crease.
/// * landscape-ish, short, or split by a vertical fold / hinge: regions
///   side by side – cover | controls; with lyrics or queue shown, cover +
///   controls | lyrics/queue (or cover | controls | lyrics/queue on very
///   wide windows). The split lands exactly on a vertical fold / hinge when
///   there is one.
/// * portrait: artwork / wall / lyrics above controls, with the cover wall
///   as a paged grid mode and the queue as a bottom sheet.
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
    final palette = ref.watch(nowPlayingPaletteProvider(theme.brightness));
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
      // Menus and sheets opened from this page inherit the re-themed
      // onSurface, so give them the matching protected scene colour.
      popupMenuTheme: theme.popupMenuTheme.copyWith(color: tint.scene),
      bottomSheetTheme: theme.bottomSheetTheme.copyWith(
        backgroundColor: tint.scene,
        modalBackgroundColor: tint.scene,
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

class _NowPlayingLayout extends ConsumerStatefulWidget {
  const _NowPlayingLayout({required this.lowPower, required this.onClose});

  final bool lowPower;
  final VoidCallback onClose;

  @override
  ConsumerState<_NowPlayingLayout> createState() => _NowPlayingLayoutState();
}

class _NowPlayingLayoutState extends ConsumerState<_NowPlayingLayout>
    with SingleTickerProviderStateMixin {
  late final AnimationController _coverFlight = AnimationController(
    vsync: this,
    duration: LekisMotion.slow,
  );
  OverlayEntry? _coverFlightEntry;
  AlbumDto? _flightAlbum;
  Rect _flightFrom = Rect.zero;
  Rect _flightTo = Rect.zero;

  @override
  void initState() {
    super.initState();
    _coverFlight.addStatusListener((status) {
      if (status == AnimationStatus.completed) _removeCoverFlight();
    });
  }

  @override
  void dispose() {
    _coverFlightEntry?.remove();
    _coverFlight.dispose();
    super.dispose();
  }

  void _removeCoverFlight() {
    _coverFlightEntry?.remove();
    _coverFlightEntry = null;
    _flightAlbum = null;
  }

  /// Cover-wall tap: play the album and fly the tapped cover into the large
  /// Now Playing artwork (shared-element style, no route push involved).
  void _playFromWall(AlbumDto album, Rect source) {
    ref.read(playerActionsProvider).playAlbum(album.id.toInt());
    final desktop = usesNowPlayingSidePanels(context);
    ref.read(nowPlayingPaneProvider.notifier).set(NowPlayingPane.cover);
    if (!desktop ||
        MediaQuery.disableAnimationsOf(context) ||
        source == Rect.zero ||
        _coverFlight.isAnimating) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _flyCover(album, source, _coverDestination());
    });
  }

  /// Where the large cover sits after the wall closes: the left half of a
  /// wide page, centered below the top bar and inside its 24 dp padding.
  Rect _coverDestination() {
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final top = padding.top + LekisSizes.touchTargetMin + LekisSpacing.xs * 2;
    final left = Rect.fromLTRB(
      0,
      top,
      size.width * 0.5,
      size.height - padding.bottom,
    ).deflate(LekisSpacing.xl);
    final side = math.min(left.width, left.height);
    return Rect.fromCenter(center: left.center, width: side, height: side);
  }

  void _flyCover(AlbumDto album, Rect from, Rect to) {
    final overlay = Overlay.of(context, rootOverlay: true);
    _removeCoverFlight();
    _flightAlbum = album;
    _flightFrom = from;
    _flightTo = to;
    final entry = OverlayEntry(
      builder: (context) => IgnorePointer(
        child: AnimatedBuilder(
          animation: _coverFlight,
          builder: (context, _) {
            final t = Curves.easeOutCubic.transform(_coverFlight.value);
            final rect = Rect.lerp(_flightFrom, _flightTo, t)!;
            final radius = lerpDouble(
              LekisRadius.artworkGrid,
              LekisRadius.artworkFor(_flightTo.shortestSide),
              t,
            )!;
            return Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fromRect(
                  rect: rect,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(radius),
                      boxShadow: [
                        BoxShadow(
                          color: context.lekisColors.scrim.withValues(
                            alpha: 0.4 * (1 - t),
                          ),
                          blurRadius: LekisSpacing.xxl * (1 - t),
                          offset: Offset(0, LekisSpacing.md * (1 - t)),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(radius),
                      child: AlbumArtwork(
                        album: _flightAlbum ?? album,
                        radius: 0,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
    _coverFlightEntry = entry;
    overlay.insert(entry);
    _coverFlight.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final trackId = ref.watch(playbackProvider.select((s) => s.trackId));
    final pane = ref.watch(nowPlayingPaneProvider);
    final fold = context.fold;
    final size = MediaQuery.sizeOf(context);
    final short = context.heightClass < WindowHeightClass.medium;
    final verticalFold = fold.hasHinge && fold.hingeAxis == Axis.vertical;
    final landscapeish = size.width >= 600 && size.width >= size.height * 0.95;
    final desktopPanels = usesNowPlayingSidePanels(context);

    // Without a track the view shows its centred empty state instead of a
    // blank pane.
    Widget lyrics({bool compact = false}) => LyricsView(
      key: ValueKey('lyrics-$trackId'),
      trackId: trackId,
      compact: compact,
      lowPower: widget.lowPower,
    );

    const artwork = Padding(
      padding: EdgeInsets.all(LekisSpacing.xl),
      child: NowPlayingArtwork(),
    );

    Widget mainPane({required bool compact}) {
      if (pane == NowPlayingPane.wall) {
        return KeyedSubtree(
          key: const ValueKey('cover-wall'),
          child: CoverWall(onPlayAlbum: _playFromWall),
        );
      }
      if (!desktopPanels && pane == NowPlayingPane.lyrics) {
        return KeyedSubtree(
          key: const ValueKey('lyrics'),
          child: lyrics(compact: compact),
        );
      }
      return KeyedSubtree(key: const ValueKey('art'), child: artwork);
    }

    Widget switcher({required bool compact}) => AnimatedSwitcher(
      duration: widget.lowPower ? Duration.zero : LekisMotion.normal,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (current, previous) =>
          Stack(fit: StackFit.expand, children: [...previous, ?current]),
      child: mainPane(compact: compact),
    );

    // Vertically centred against the artwork next to it; the controls cap
    // their own width so the seek bar never spans a wide window.
    Widget controls() => const Center(
      child: SingleChildScrollView(
        primary: false,
        padding: EdgeInsets.symmetric(vertical: LekisSpacing.lg),
        child: NowPlayingControls(),
      ),
    );

    final topBar = _TopBar(onClose: widget.onClose);

    // Tabletop: top half = artwork / wall / lyrics, bottom half = controls.
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
        secondary: SafeArea(child: controls()),
        primaryFraction: 0.5,
      );
    }

    // Regions side by side.
    if (short || landscapeish || verticalFold) {
      final sidePane = desktopPanels
          ? switch (pane) {
              NowPlayingPane.lyrics => lyrics(),
              NowPlayingPane.queue => _SidePaneEntrance(
                child: QueuePanel(
                  onClose: () => ref
                      .read(nowPlayingPaneProvider.notifier)
                      .set(NowPlayingPane.cover),
                ),
              ),
              _ => null,
            }
          : null;

      final String mode;
      final Widget regions;
      if (sidePane != null) {
        if (pane == NowPlayingPane.queue) {
          mode = 'cover|controls|queue';
          regions = Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _Split(
                  fraction: 0.55,
                  first: artwork,
                  second: controls(),
                ),
              ),
              SizedBox(width: QueuePanel.width, child: sidePane),
            ],
          );
        } else {
          mode = 'cover|controls|lyrics';
          regions = _Split(
            fraction: 0.62,
            first: _Split(fraction: 0.55, first: artwork, second: controls()),
            second: sidePane,
          );
        }
      } else if (pane == NowPlayingPane.wall) {
        mode = 'wall|controls';
        regions = _Split(
          fraction: 0.68,
          first: CoverWall(onPlayAlbum: _playFromWall),
          second: controls(),
        );
      } else if (!desktopPanels && pane == NowPlayingPane.lyrics) {
        if (short) {
          // Too short to stack cover and controls: lyrics take the cover's
          // place.
          mode = 'controls|lyrics';
          regions = _Split(
            fraction: 0.5,
            first: controls(),
            second: lyrics(compact: true),
          );
        } else {
          mode = 'cover+controls|lyrics';
          regions = _Split(
            fraction: 0.45,
            first: Column(
              children: [
                Expanded(child: artwork),
                const NowPlayingControls(),
                const SizedBox(height: LekisSpacing.xl),
              ],
            ),
            second: lyrics(),
          );
        }
      } else {
        mode = 'cover|controls';
        regions = _Split(fraction: 0.5, first: artwork, second: controls());
      }

      return SafeArea(
        child: Column(
          children: [
            topBar,
            Expanded(
              child: AnimatedSwitcher(
                duration: widget.lowPower ? Duration.zero : LekisMotion.normal,
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
              const NowPlayingControls(),
              const SizedBox(height: LekisSpacing.lg),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fade + short slide for the third pane when it opens.
class _SidePaneEntrance extends StatelessWidget {
  const _SidePaneEntrance({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: LekisMotion.normal,
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(LekisSpacing.lg * (1 - t), 0),
          child: child,
        ),
      ),
      child: child,
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

/// Close button and swipe-down grabber. The pane toggles (lyrics, cover
/// wall, queue) are not up here: like Apple Music they sit in a row under
/// the transport, where the thumb / pointer already is.
class _TopBar extends StatelessWidget {
  const _TopBar({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final fg = Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.all(LekisSpacing.xs),
      // The grabber is centred on the full bar width.
      child: Stack(
        alignment: Alignment.center,
        children: [
          IgnorePointer(
            // Grabber hint for swipe-down.
            child: Container(
              key: const ValueKey('now-playing.top-bar.grabber'),
              width: LekisSpacing.xxl + LekisSpacing.xs,
              height: LekisSpacing.xs + LekisSpacing.xxs / 2,
              decoration: BoxDecoration(
                color: fg.withValues(alpha: LekisType.lyricsInactiveOpacity),
                borderRadius: BorderRadius.circular(LekisRadius.pill),
              ),
            ),
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: IconButton(
              tooltip: '关闭',
              constraints: const BoxConstraints(
                minWidth: LekisSizes.touchTargetMin,
                minHeight: LekisSizes.touchTargetMin,
              ),
              onPressed: onClose,
              icon: const Icon(Icons.keyboard_arrow_down_rounded),
            ),
          ),
        ],
      ),
    );
  }
}

/// Apple Music style row under the transport: lyrics, cover wall, queue.
///
/// On wide windows lyrics / queue open the third pane; otherwise lyrics
/// replace the cover and the queue opens as a bottom sheet.
class NowPlayingActions extends ConsumerWidget {
  const NowPlayingActions({super.key});

  static const Key lyricsKey = ValueKey('now-playing.actions.lyrics');
  static const Key wallKey = ValueKey('now-playing.actions.wall');
  static const Key queueKey = ValueKey('now-playing.actions.queue');

  void _toggle(WidgetRef ref, NowPlayingPane pane) {
    final current = ref.read(nowPlayingPaneProvider);
    ref
        .read(nowPlayingPaneProvider.notifier)
        .set(current == pane ? NowPlayingPane.cover : pane);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lekisColors;
    final fg = Theme.of(context).colorScheme.onSurface;
    final desktopPanels = usesNowPlayingSidePanels(context);
    final pane = ref.watch(nowPlayingPaneProvider);
    final hasTrack = ref.watch(playbackProvider.select((s) => s.hasTrack));
    final queueLength = ref.watch(
      playbackProvider.select((s) => s.queueLength),
    );

    Widget action({
      required Key key,
      required String tooltip,
      required bool selected,
      required IconData icon,
      required IconData selectedIcon,
      required VoidCallback? onPressed,
      Widget Function(Widget icon)? decorate,
    }) {
      Widget wrap(IconData data) => decorate?.call(Icon(data)) ?? Icon(data);
      return IconButton(
        key: key,
        tooltip: tooltip,
        isSelected: selected,
        constraints: const BoxConstraints(
          minWidth: LekisSizes.touchTargetMin,
          minHeight: LekisSizes.touchTargetMin,
        ),
        // Selected: a soft filled disc, like Apple Music's lyrics button.
        style: IconButton.styleFrom(
          backgroundColor: selected ? fg.withValues(alpha: 0.16) : null,
        ),
        onPressed: onPressed,
        icon: wrap(icon),
        selectedIcon: wrap(selectedIcon),
      );
    }

    return Row(
      key: const ValueKey('now-playing.actions'),
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        action(
          key: lyricsKey,
          tooltip: pane == NowPlayingPane.lyrics ? '隐藏歌词' : '歌词',
          selected: pane == NowPlayingPane.lyrics,
          icon: Icons.lyrics_outlined,
          selectedIcon: Icons.lyrics_rounded,
          onPressed: hasTrack
              ? () => _toggle(ref, NowPlayingPane.lyrics)
              : null,
        ),
        action(
          key: wallKey,
          tooltip: pane == NowPlayingPane.wall ? '隐藏封面墙' : '封面墙',
          selected: pane == NowPlayingPane.wall,
          icon: Icons.grid_view_outlined,
          selectedIcon: Icons.grid_view_rounded,
          onPressed: () => _toggle(ref, NowPlayingPane.wall),
        ),
        action(
          key: queueKey,
          tooltip: queueLength == 0 ? '播放队列' : '播放队列（$queueLength 首）',
          selected: desktopPanels && pane == NowPlayingPane.queue,
          icon: Icons.queue_music_rounded,
          selectedIcon: Icons.queue_music_rounded,
          onPressed: hasTrack
              ? () {
                  if (desktopPanels) {
                    _toggle(ref, NowPlayingPane.queue);
                  } else {
                    showQueueSheet(context);
                  }
                }
              : null,
          decorate: (icon) => Badge.count(
            count: queueLength,
            isLabelVisible: queueLength > 0,
            backgroundColor: colors.accent,
            textColor: colors.onAccent,
            child: icon,
          ),
        ),
      ],
    );
  }
}

/// Widest the controls column gets: beyond this the seek bar would stretch
/// absurdly across wide windows (480 dp).
const double nowPlayingControlsMaxWidth =
    LekisSizes.desktopQueuePanelWidth * 1.5;

/// Below this column width the rating star moves into the “more” menu so the
/// title keeps enough room.
const double _inlineRatingMinWidth = LekisSizes.desktopQueuePanelWidth * 1.2;

/// Where the seek track (and its time labels) start inside [SeekBar]: the
/// slider's overlay radius. The title block lines up with it.
const double _seekTrackInset = LekisSizes.touchTargetMin / 2;

/// Title block, seek bar, transport and (desktop) volume.
///
/// One alignment for the whole column, Apple Music style: the title /
/// artist block is left-aligned on the seek track's start edge with the
/// library actions trailing it on the same line; the seek bar spans the
/// column and the transport sits centred under it, then (desktop) volume,
/// then the lyrics / wall / queue row at the very bottom.
class NowPlayingControls extends StatelessWidget {
  const NowPlayingControls({super.key});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: nowPlayingControlsMaxWidth),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: LekisSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              // Trailing icons: their 48 dp targets end where the seek track
              // ends, give or take the glyph inset.
              padding: const EdgeInsetsDirectional.only(
                start: _seekTrackInset,
                end: _seekTrackInset - LekisSpacing.md,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) => Row(
                  children: [
                    const Expanded(child: _NowPlayingTitle()),
                    const SizedBox(width: LekisSpacing.sm),
                    NowPlayingLibraryActions(
                      showRating: constraints.maxWidth >= _inlineRatingMinWidth,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: LekisSpacing.sm),
            const SeekBar(),
            const SizedBox(height: LekisSpacing.sm),
            const Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: TransportControls(large: true),
              ),
            ),
            if (!platformHasSystemVolume) ...[
              const SizedBox(height: LekisSpacing.sm),
              const Center(
                child: VolumeControl(width: LekisSizes.desktopSidebarWidth),
              ),
            ],
            const SizedBox(height: LekisSpacing.md),
            const Padding(
              // Outer icons line up with the ends of the seek track.
              padding: EdgeInsets.symmetric(
                horizontal: _seekTrackInset - LekisSpacing.md,
              ),
              child: NowPlayingActions(),
            ),
          ],
        ),
      ),
    );
  }
}

/// Track title over “artist · album”, both single-line with ellipsis.
class _NowPlayingTitle extends ConsumerWidget {
  const _NowPlayingTitle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final track = ref.watch(currentTrackProvider).value;
    final artists = track?.artists.where((a) => a.isNotEmpty).join(' / ');
    final album = track?.albumTitle;
    final subtitle = track == null
        ? null
        : [
            (artists == null || artists.isEmpty) ? '未知艺人' : artists,
            if (album != null && album.isNotEmpty) album,
          ].join(' · ');
    return Column(
      key: const ValueKey('now-playing.title'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          track?.title ?? '未在播放',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        if (subtitle != null)
          Text(
            subtitle,
            key: const ValueKey('now-playing.subtitle'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}
