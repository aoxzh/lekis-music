// Paged album-cover wall for Now Playing.
//
// The library can hold 100k+ albums, so the wall never materialises the
// whole list: it reads pages from the same `PagedList` used by the library
// grid and only builds the cells that are on screen (or in the cache
// extent). Scrolling to the end pulls the next page in.

import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

/// Responsive, lazily paged wall of album artwork.
///
/// Tap a cover to play the album (the core expands the album into a queue,
/// so the wall itself never sends thousands of track ids).
class CoverWall extends ConsumerStatefulWidget {
  const CoverWall({super.key, this.onPlayAlbum});

  /// Optional shared-element hook: receives the album and the cover's
  /// window-space rect so the caller can fly it into Now Playing.
  final void Function(AlbumDto album, Rect source)? onPlayAlbum;

  @override
  ConsumerState<CoverWall> createState() => _CoverWallState();
}

class _CoverWallState extends ConsumerState<CoverWall> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Recently added makes the wall feel alive after a scan; the paged list
    // still gives access to the whole library by scrolling.
    final list = ref.watch(albumsListProvider(TrackSortDto.recentlyAdded));
    final colors = context.lekisColors;
    final theme = Theme.of(context);

    return ListenableBuilder(
      listenable: list,
      builder: (context, _) {
        if (list.error != null && list.itemCount == 0) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '封面墙加载失败',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: LekisSpacing.sm),
                TextButton(onPressed: list.retry, child: const Text('重试')),
              ],
            ),
          );
        }
        if (list.isInitialLoading) {
          return const Center(child: CircularProgressIndicator());
        }
        if (list.isEmpty) {
          return Center(
            child: Text(
              '资料库里还没有专辑',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          );
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            const gap = LekisSpacing.md;
            final inset = constraints.maxWidth >= 720
                ? LekisSpacing.xl
                : LekisSpacing.md;
            final usable = math.max(1.0, constraints.maxWidth - inset * 2);
            final columns = math.max(
              2,
              ((usable + gap) / (LekisSizes.coverWallTileMin + gap)).floor(),
            );
            return Scrollbar(
              controller: _scroll,
              interactive: true,
              child: GridView.builder(
                key: const ValueKey('cover-wall.grid'),
                controller: _scroll,
                padding: EdgeInsets.fromLTRB(
                  inset,
                  LekisSpacing.sm,
                  inset,
                  inset,
                ),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: gap,
                  crossAxisSpacing: gap,
                  childAspectRatio: 1,
                ),
                itemCount: list.itemCount,
                itemBuilder: (context, index) {
                  final album = list.itemAt(index);
                  if (album == null) {
                    return const _CoverWallPlaceholder();
                  }
                  return _StaggeredCover(
                    key: ValueKey('cover-wall.entry-${album.id}'),
                    index: index,
                    child: _CoverWallTile(
                      album: album,
                      onTap: (source) {
                        final play = widget.onPlayAlbum;
                        if (play != null) {
                          play(album, source);
                        } else {
                          ref
                              .read(playerActionsProvider)
                              .playAlbum(album.id.toInt());
                        }
                      },
                    ),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}

/// Fade + short rise for cards as they enter the viewport. The delay is
/// capped so a long wall never queues up seconds of animation.
class _StaggeredCover extends StatelessWidget {
  const _StaggeredCover({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final delay = (index % 18) * 20;
    final duration = LekisMotion.normal.inMilliseconds + delay;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: duration),
      curve: Interval(delay / duration, 1, curve: Curves.easeOutCubic),
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, LekisSpacing.md * (1 - t)),
          child: Transform.scale(scale: 0.96 + 0.04 * t, child: child),
        ),
      ),
      child: child,
    );
  }
}

class _CoverWallTile extends StatefulWidget {
  const _CoverWallTile({required this.album, required this.onTap});

  final AlbumDto album;
  final void Function(Rect source) onTap;

  @override
  State<_CoverWallTile> createState() => _CoverWallTileState();
}

class _CoverWallTileState extends State<_CoverWallTile> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  void _activate() {
    final box = context.findRenderObject();
    final source = box is RenderBox && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : Rect.zero;
    widget.onTap(source);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final theme = Theme.of(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final lifted = _hovered || _focused;

    final cover = Stack(
      fit: StackFit.expand,
      children: [
        AlbumArtwork(album: widget.album, radius: LekisRadius.artworkGrid),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(LekisRadius.artworkGrid),
              ),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  colors.scrim.withValues(alpha: 0),
                  colors.scrim.withValues(alpha: 0.82),
                ],
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                LekisSpacing.sm,
                LekisSpacing.xl,
                LekisSpacing.sm,
                LekisSpacing.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.album.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: colors.onAccent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (widget.album.artistLine.isNotEmpty)
                    Text(
                      widget.album.artistLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onAccent.withValues(alpha: 0.76),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (lifted)
          Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.scrim.withValues(alpha: 0.55),
                shape: BoxShape.circle,
              ),
              child: Padding(
                padding: const EdgeInsets.all(LekisSpacing.sm),
                child: Icon(
                  Icons.play_arrow_rounded,
                  color: colors.onAccent,
                  size: LekisSpacing.xl,
                ),
              ),
            ),
          ),
      ],
    );

    return Semantics(
      button: true,
      label: '播放专辑 ${widget.album.title}',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: FocusableActionDetector(
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                _activate();
                return null;
              },
            ),
          },
          onShowFocusHighlight: (value) => setState(() => _focused = value),
          child: GestureDetector(
            key: ValueKey('cover-wall.tile-${widget.album.id}'),
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            onTap: _activate,
            child: AnimatedContainer(
              duration: reduceMotion ? Duration.zero : LekisMotion.fast,
              curve: Curves.easeOutCubic,
              transform: Matrix4.translationValues(
                0,
                lifted ? -LekisSpacing.xs : 0,
                0,
              ),
              transformAlignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(LekisRadius.artworkGrid),
                boxShadow: lifted
                    ? [
                        BoxShadow(
                          color: colors.scrim.withValues(alpha: 0.32),
                          blurRadius: LekisSpacing.xl,
                          offset: const Offset(0, LekisSpacing.sm),
                        ),
                      ]
                    : null,
              ),
              child: AnimatedScale(
                scale: _pressed ? 0.97 : (lifted ? 1.035 : 1),
                duration: reduceMotion ? Duration.zero : LekisMotion.fast,
                curve: Curves.easeOutCubic,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(LekisRadius.artworkGrid),
                  child: cover,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CoverWallPlaceholder extends StatelessWidget {
  const _CoverWallPlaceholder();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.lekisColors.surfaceVariant.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(LekisRadius.artworkGrid),
      ),
    );
  }
}
