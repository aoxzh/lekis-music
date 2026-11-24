import 'package:lekis/src/features/connect/device_picker.dart';

import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/album_detail_page.dart';
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
import 'package:lekis/src/features/now_playing/track_sources_sheet.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/queue_panel.dart';
import 'package:lekis/src/features/player/queue_view.dart';
import 'package:lekis/src/features/player/sleep_timer.dart';
import 'package:lekis/src/features/player/widgets/player_controls.dart';
import 'package:lekis/src/features/settings/equalizer_page.dart';
import 'package:lekis/src/features/settings/settings_providers.dart'
    show playbackOutputProvider, settingProvider, SettingKeys;
import 'package:lekis/src/l10n/app_l10n.dart';
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
    final lightForeground = tint.isLight;

    // One re-theme for the whole page and for everything opened from it:
    // dialogs, sheets and menus capture this theme, so an editor opened over
    // the artwork is the same dark glass as the page instead of a white
    // Material dialog. Text stays a contrast-checked near-black / near-white;
    // the cover's colour only drives the accent (play button, seek bar,
    // badges).
    final themed = lekisOnMediaTheme(
      scene: tint.scene,
      foreground: tint.foreground,
      accent: tint.primary,
      onAccent: tint.onPrimary,
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
                label: context.l10n.pick('正在播放', 'Now Playing'),
                // SnackBars raised from this page (library actions, downloads,
                // add to playlist) must land on the opaque Now Playing route,
                // not on the shell's Scaffold behind it: give the page its own
                // messenger. The Scaffold stays transparent and never resizes
                // for the keyboard, so the layout is unchanged.
                child: ScaffoldMessenger(
                  child: Scaffold(
                    backgroundColor: Colors.transparent,
                    resizeToAvoidBottomInset: false,
                    body: Material(
                      type: MaterialType.transparency,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          NowPlayingBackground(lowPower: lowPower),
                          _NowPlayingLayout(
                            lowPower: lowPower,
                            onClose: _close,
                          ),
                        ],
                      ),
                    ),
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

    final artwork = Padding(
      padding: const EdgeInsets.all(LekisSpacing.xl),
      child: NowPlayingArtwork(showDial: pane == NowPlayingPane.dial),
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
          final roomyQueue = size.width >= 1360;
          regions = Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: roomyQueue
                    ? _Split(fraction: 0.55, first: artwork, second: controls())
                    : const _DesktopArtworkControlsColumn(),
              ),
              SizedBox(width: QueuePanel.width, child: sidePane),
            ],
          );
        } else {
          // 宽屏带歌词采用经典双栏：左侧居中的「封面/黑胶 + 完整宽控制区」，
          // 右侧留出宽裕歌词区，不再挤成三窄栏截断标题。
          mode = 'desktop-cover+controls|lyrics';
          regions = _Split(
            fraction: 0.44,
            first: const _DesktopArtworkControlsColumn(),
            second: Padding(
              padding: const EdgeInsets.only(right: LekisSpacing.xl),
              child: sidePane,
            ),
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

/// 桌面宽屏在展示歌词或较窄队列时的左侧主栏：
/// 封面/黑胶/磁带与完整宽度的控制区上下垂直居中对齐，避免三窄栏挤压标题。
class _DesktopArtworkControlsColumn extends StatelessWidget {
  const _DesktopArtworkControlsColumn();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxArtWidth = math.max(
          180.0,
          math.min(
            constraints.maxWidth - LekisSpacing.xxl * 2,
            nowPlayingControlsMaxWidth - LekisSpacing.xxl,
          ),
        );
        final maxArtHeight = math.max(180.0, constraints.maxHeight - 290.0);
        final artSide = math.min(maxArtWidth, maxArtHeight).clamp(180.0, 380.0);
        return Center(
          child: SingleChildScrollView(
            primary: false,
            padding: const EdgeInsets.symmetric(
              horizontal: LekisSpacing.lg,
              vertical: LekisSpacing.md,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox.square(
                  dimension: artSide,
                  child: const NowPlayingArtwork(),
                ),
                const SizedBox(height: LekisSpacing.lg),
                const NowPlayingControls(),
              ],
            ),
          ),
        );
      },
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

/// Close button (the down chevron doubles as the swipe-down hint). The pane
/// toggles (lyrics, cover wall, queue) are not up here: like Apple Music
/// they sit in a row under the transport, where the thumb / pointer already
/// is.
///
/// No centred grabber pill: it repeated the chevron, and on Samsung
/// foldables / tablets it sat directly under the system's multi-window
/// handle at the top centre of the screen.
class _TopBar extends ConsumerWidget {
  const _TopBar({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dial = ref.watch(nowPlayingPaneProvider) == NowPlayingPane.dial;
    final showDial =
        ref.watch(settingProvider(SettingKeys.lyricsDialButton)).value ==
        'true';
    return Padding(
      padding: const EdgeInsets.all(LekisSpacing.xs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            key: const ValueKey('now-playing.top-bar.close'),
            tooltip: context.l10n.pick('关闭', 'Close'),
            constraints: const BoxConstraints(
              minWidth: LekisSizes.touchTargetMin,
              minHeight: LekisSizes.touchTargetMin,
            ),
            onPressed: onClose,
            icon: const Icon(Icons.keyboard_arrow_down_rounded),
          ),
          if (showDial)
            Flexible(
              child: TextButton.icon(
                key: const ValueKey('now-playing.top-bar.dial'),
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.onSurface,
                ),
                icon: Icon(dial ? Icons.image_outlined : Icons.speed_rounded),
                label: Text(
                  dial
                      ? context.l10n.pick('返回封面', 'Back to artwork')
                      : context.l10n.pick('曲目刻度', 'Track dial'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onPressed: () => ref
                    .read(nowPlayingPaneProvider.notifier)
                    .set(dial ? NowPlayingPane.cover : NowPlayingPane.dial),
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
  static const Key equalizerKey = ValueKey('now-playing.actions.equalizer');

  void _toggle(WidgetRef ref, NowPlayingPane pane) {
    final current = ref.read(nowPlayingPaneProvider);
    ref
        .read(nowPlayingPaneProvider.notifier)
        .set(current == pane ? NowPlayingPane.cover : pane);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
        onPressed: onPressed,
        icon: wrap(icon),
        selectedIcon: wrap(selectedIcon),
      );
    }

    final l10n = context.l10n;
    return Wrap(
      key: const ValueKey('now-playing.actions'),
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        action(
          key: lyricsKey,
          tooltip: pane == NowPlayingPane.lyrics
              ? l10n.hideLyrics
              : l10n.lyrics,
          selected: pane == NowPlayingPane.lyrics,
          icon: Icons.lyrics_outlined,
          selectedIcon: Icons.lyrics_rounded,
          onPressed: hasTrack
              ? () => _toggle(ref, NowPlayingPane.lyrics)
              : null,
        ),
        action(
          key: wallKey,
          tooltip: pane == NowPlayingPane.wall
              ? l10n.pick('隐藏封面墙', 'Hide Cover Wall')
              : l10n.pick('封面墙', 'Cover Wall'),
          selected: pane == NowPlayingPane.wall,
          icon: Icons.grid_view_outlined,
          selectedIcon: Icons.grid_view_rounded,
          onPressed: () => _toggle(ref, NowPlayingPane.wall),
        ),
        action(
          key: queueKey,
          // No count badge: the number on the icon read as a sticker on the
          // artwork. The queue itself shows the count in its header.
          tooltip: queueLength == 0
              ? l10n.queue
              : l10n.pick('播放队列（$queueLength 首）', 'Queue ($queueLength)'),
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
        ),
        // Pick another Lekis device to play on / control.
        action(
          key: equalizerKey,
          tooltip: l10n.pick('均衡器', 'Equalizer'),
          selected: false,
          icon: Icons.graphic_eq_rounded,
          selectedIcon: Icons.graphic_eq_rounded,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const EqualizerPage()),
          ),
        ),
        const SleepTimerButton(key: ValueKey('now-playing.sleep-timer')),
        const ConnectDeviceButton(alwaysShow: true),
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
/// artist block is left-aligned on the seek track's start edge. The seek bar
/// spans the column and the transport sits centred under it, then (desktop) volume,
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
                builder: (context, constraints) => _NowPlayingTitle(
                  compact: context.widthClass == WindowWidthClass.compact,
                  showRating: constraints.maxWidth >= _inlineRatingMinWidth,
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
            LayoutBuilder(
              builder: (context, constraints) => Padding(
                padding: EdgeInsets.symmetric(
                  horizontal:
                      ((constraints.maxWidth - 6 * LekisSizes.touchTargetMin) /
                              2)
                          .clamp(0, _seekTrackInset - LekisSpacing.md),
                ),
                child: const NowPlayingActions(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NowPlayingTitle extends ConsumerWidget {
  const _NowPlayingTitle({required this.compact, required this.showRating});

  final bool compact;
  final bool showRating;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider).value;
    final title = Text(
      track?.title ?? context.l10n.notPlaying,
      key: const ValueKey('now-playing.title'),
      maxLines: compact ? 2 : 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.titleLarge
          ?.copyWith(fontWeight: FontWeight.w700),
    );
    if (track == null) return title;
    final subtitle = _NowPlayingSubtitle(track: track);
    final actions = NowPlayingLibraryActions(showRating: showRating);
    Widget withActions(Widget leading) => Row(
      children: [
        Expanded(child: leading),
        const SizedBox(width: LekisSpacing.sm),
        actions,
      ],
    );
    return compact
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [title, withActions(subtitle)],
          )
        : withActions(
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [title, subtitle],
            ),
          );
  }
}

class _NowPlayingSubtitle extends ConsumerWidget {
  const _NowPlayingSubtitle({required this.track});

  final TrackDto track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final artists = nowPlayingArtistNames(track);
    final artistNames = artists.join(' / ');
    final album = track.albumTitle;
    final albumId = track.albumId;
    final quality = track.qualityBadge;
    final hasArtist = artists.isNotEmpty;
    final hasAlbum = album != null && album.isNotEmpty;
    final hasQuality = quality != null && quality.isNotEmpty;
    final exclusive =
        ref.watch(playbackOutputProvider).mode == OutputModeDto.exclusive;
    final subtitleStyle = theme.textTheme.bodyLarge?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return LayoutBuilder(
      // The artist keeps its natural width (a name cut down to one
      // character is useless as a link) and is capped at 45%; the album
      // takes the rest of the line and ellipsises.
      builder: (context, constraints) => Row(
        key: const ValueKey('now-playing.subtitle'),
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasArtist)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: hasAlbum || hasQuality || exclusive
                    ? constraints.maxWidth * 0.45
                    : constraints.maxWidth,
              ),
              child: _SubtitleLink(
                label: artistNames,
                style: subtitleStyle,
                semanticsLabel: context.l10n.pick(
                  '查看艺人 $artistNames',
                  'View artist $artistNames',
                ),
                onTap: () => openNowPlayingArtist(context, ref, artists),
              ),
            )
          else
            Flexible(
              child: Text(context.l10n.unknownArtist, style: subtitleStyle),
            ),
          if (hasArtist && hasAlbum) Text(' · ', style: subtitleStyle),
          if (hasAlbum)
            Flexible(
              child: albumId == null
                  ? Text(
                      album,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: subtitleStyle,
                    )
                  : _SubtitleLink(
                      label: album,
                      style: subtitleStyle,
                      semanticsLabel: context.l10n.pick(
                        '查看专辑 $album',
                        'View album $album',
                      ),
                      onTap: () =>
                          Navigator.of(context)
                              .push(AlbumDetailPage.route(albumId.toInt())),
                    ),
            ),
          if (hasQuality) ...[
            Text(' · ', style: subtitleStyle),
            Flexible(
              child: _SubtitleLink(
                label: quality,
                style: subtitleStyle?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
                semanticsLabel: context.l10n.pick(
                  '查看曲目来源',
                  'View track sources',
                ),
                onTap: () => showTrackSourcesSheet(
                  context,
                  trackId: track.id.toInt(),
                  title: track.title,
                ),
              ),
            ),
          ],
          if (exclusive) ...[
            Text(' · ', style: subtitleStyle),
            Tooltip(
              message: context.l10n.pick(
                '独占模式：绕过系统混音',
                'Exclusive mode: bypasses the system mixer',
              ),
              child: Icon(
                Icons.high_quality_rounded,
                size: 18,
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A single tappable piece of the artist · album line.
///
/// Understated, the way Spotify and Apple Music do it: no permanent
/// underline (the line must still read as one sentence), the same muted
/// colour as the rest, and the affordance is a pointer plus an underline
/// only while a mouse actually hovers it. Touch platforms get the ripple.
class _SubtitleLink extends StatefulWidget {
  const _SubtitleLink({
    required this.label,
    required this.style,
    required this.onTap,
    required this.semanticsLabel,
  });

  final String label;
  final TextStyle? style;
  final VoidCallback onTap;
  final String semanticsLabel;

  @override
  State<_SubtitleLink> createState() => _SubtitleLinkState();
}

class _SubtitleLinkState extends State<_SubtitleLink> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final color =
        widget.style?.color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Semantics(
      link: true,
      label: widget.semanticsLabel,
      onTap: widget.onTap,
      excludeSemantics: true,
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(LekisRadius.xs),
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.style?.copyWith(
              decoration: _hovered
                  ? TextDecoration.underline
                  : TextDecoration.none,
              decorationColor: color.withValues(alpha: 0.55),
              decorationStyle: TextDecorationStyle.solid,
            ),
          ),
        ),
      ),
    );
  }
}
