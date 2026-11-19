import 'dart:ui' show lerpDouble;

import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

/// Scale applied to artwork under the mouse / finger.
const double _hoverScale = 1.03;
const double _pressScale = 0.97;

/// Hover / press feedback shared by artwork cards: gentle scale + ink.
class ArtworkCardFrame extends StatefulWidget {
  const ArtworkCardFrame({
    super.key,
    required this.onTap,
    required this.artwork,
    required this.title,
    this.subtitle,
    this.selected = false,
    this.semanticLabel,
  });

  final VoidCallback onTap;
  final Widget artwork;
  final String title;
  final String? subtitle;
  final bool selected;
  final String? semanticLabel;

  /// Height of the text block below the artwork (for fixed-height shelves).
  static double textBlockHeight(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scaler = MediaQuery.textScalerOf(context);
    double lineOf(TextStyle? s) {
      final size = s?.fontSize ?? 14;
      return scaler.scale(size) * (s?.height ?? 1.3);
    }

    // The extra 2 px absorb sub-pixel rounding between the computed line boxes
    // and the text layout; without it the shelf overflows by exactly 1 px.
    return LekisSpacing.sm +
        lineOf(t.titleSmall) +
        lineOf(t.bodySmall) +
        LekisSpacing.xxs;
  }

  @override
  State<ArtworkCardFrame> createState() => _ArtworkCardFrameState();
}

class _ArtworkCardFrameState extends State<ArtworkCardFrame> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final scale = _pressed
        ? _pressScale
        : _hovered
        ? _hoverScale
        : 1.0;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.semanticLabel ?? widget.title,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onTap,
          child: FocusableActionDetector(
            actions: {
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  widget.onTap();
                  return null;
                },
              ),
            },
            onShowFocusHighlight: (v) => setState(() => _hovered = v),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedScale(
                  scale: scale,
                  duration: LekisMotion.fast,
                  curve: Curves.easeOutCubic,
                  child: DecoratedBox(
                    position: DecorationPosition.foreground,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(
                        LekisRadius.artworkGrid,
                      ),
                      border: widget.selected
                          ? Border.all(
                              color: colors.accent,
                              width: LekisSpacing.xxs,
                            )
                          : null,
                    ),
                    child: widget.artwork,
                  ),
                ),
                const SizedBox(height: LekisSpacing.sm),
                Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                if (widget.subtitle != null)
                  Text(
                    widget.subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Hero tag for an album cover. [scope] tells apart the places one album
/// can appear on the same page (grid, an artist's shelf, ...), so tags stay
/// unique within a route.
@immutable
class AlbumHeroTag {
  const AlbumHeroTag(this.albumId, this.scope);

  final int albumId;
  final Object scope;

  @override
  bool operator ==(Object other) =>
      other is AlbumHeroTag && other.albumId == albumId && other.scope == scope;

  @override
  int get hashCode => Object.hash(albumId, scope);
}

/// Album cover that flies between a card and the album page.
///
/// During the flight the corner radius and shadow are interpolated between
/// the two ends, and the image is laid out at the destination size and
/// scaled, so the same thumbnail is shown the whole way (no reload flicker).
class AlbumArtHero extends StatelessWidget {
  const AlbumArtHero({
    super.key,
    required this.album,
    required this.tag,
    this.radius,
    this.elevation = 0,
  });

  final AlbumDto album;

  /// `null` → no hero (e.g. the detail pane of a two-pane layout).
  final Object? tag;

  /// Fixed corner radius; `null` → [LekisRadius.artworkFor] the side.
  final double? radius;
  final double elevation;

  double _radiusFor(double side) => radius ?? LekisRadius.artworkFor(side);

  static Widget _frame(
    BuildContext context,
    AlbumDto album,
    double radius,
    double elevation,
  ) => Material(
    type: elevation > 0 ? MaterialType.canvas : MaterialType.transparency,
    color: elevation > 0 ? context.lekisColors.surfaceVariant : null,
    elevation: elevation,
    shadowColor: context.lekisColors.scrim,
    borderRadius: BorderRadius.circular(radius),
    child: AlbumArtwork(album: album, radius: radius),
  );

  static Widget _shuttle(
    BuildContext flightContext,
    Animation<double> animation,
    HeroFlightDirection direction,
    BuildContext fromHeroContext,
    BuildContext toHeroContext,
  ) {
    final fromBox = fromHeroContext.findRenderObject();
    final toBox = toHeroContext.findRenderObject();
    final from = fromHeroContext.findAncestorWidgetOfExactType<AlbumArtHero>();
    final to = toHeroContext.findAncestorWidgetOfExactType<AlbumArtHero>();
    if (from == null ||
        to == null ||
        fromBox is! RenderBox ||
        toBox is! RenderBox) {
      return (toHeroContext.widget as Hero).child;
    }
    // animation runs 0 → 1 towards the pushed page in both directions.
    final push = direction == HeroFlightDirection.push;
    final card = push ? from : to;
    final page = push ? to : from;
    final cardSide = (push ? fromBox : toBox).size.width;
    final pageSide = (push ? toBox : fromBox).size.width;
    final cardRadius = card._radiusFor(cardSide);
    final pageRadius = page._radiusFor(pageSide);
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final t = animation.value;
          final side = constraints.biggest.shortestSide;
          final scale = side <= 0 ? 1.0 : pageSide / side;
          final r = lerpDouble(cardRadius, pageRadius, t)! * scale;
          final e = lerpDouble(card.elevation, page.elevation, t)!;
          return FittedBox(
            child: SizedBox.square(
              dimension: pageSide,
              child: _frame(context, page.album, r, e * scale),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.biggest.shortestSide;
        final content = _frame(context, album, _radiusFor(side), elevation);
        final t = tag;
        if (t == null) return content;
        return Hero(tag: t, flightShuttleBuilder: _shuttle, child: content);
      },
    );
  }
}

class AlbumCard extends StatelessWidget {
  const AlbumCard({
    super.key,
    required this.album,
    required this.onTap,
    this.selected = false,
    this.heroTag,
  });

  final AlbumDto album;
  final VoidCallback onTap;
  final bool selected;

  /// Pass the same tag to `AlbumDetailPage.route` for a cover flight.
  final Object? heroTag;

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      album.artistLine,
      if (album.year != null) '${album.year}',
    ].where((s) => s.isNotEmpty).join(' · ');
    return ArtworkCardFrame(
      onTap: onTap,
      selected: selected,
      artwork: AspectRatio(
        aspectRatio: 1,
        child: AlbumArtHero(
          album: album,
          tag: heroTag,
          radius: LekisRadius.artworkGrid,
        ),
      ),
      title: album.title,
      subtitle: subtitle.isEmpty ? null : subtitle,
    );
  }
}

class AlbumCardPlaceholder extends StatelessWidget {
  const AlbumCardPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surfaceVariant,
              borderRadius: BorderRadius.circular(LekisRadius.artworkGrid),
            ),
          ),
        ),
      ],
    );
  }
}
