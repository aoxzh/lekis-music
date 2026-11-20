import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

/// Shows a pre-sized artwork thumbnail from the core's cache.
///
/// Sizes itself to its constraints (square), requests the smallest thumbnail
/// bucket that covers the physical pixels and decodes at that width only.
class ArtworkImage extends StatelessWidget {
  const ArtworkImage({
    super.key,
    required this.hash,
    this.radius,
    this.placeholderIcon = Icons.music_note_rounded,
    this.placeholderSeed = 0,
    this.placeholderLabel,
  });

  final String? hash;
  final double? radius;
  final IconData placeholderIcon;

  /// Seed for the deterministic gradient used when there is no cover yet.
  final int placeholderSeed;

  /// Optional initial shown in the placeholder (album / artist name).
  final String? placeholderLabel;

  @override
  Widget build(BuildContext context) {
    final r = radius ?? LekisRadius.artworkList;
    return AspectRatio(
      aspectRatio: 1,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        // A hairline rim: white covers need an edge on the light surface,
        // dark covers need one on the dark surface, and on-media panels get
        // the foreground-alpha rim from the theme's outline. Square copies
        // (the blurred background, hero washes) skip it.
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(r),
          border: r > 0
              ? Border.all(color: Theme.of(context).colorScheme.outline)
              : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(r),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final h = hash;
              if (h == null) {
                return ArtworkPlaceholder(
                  icon: placeholderIcon,
                  seed: placeholderSeed,
                  label: placeholderLabel,
                );
              }
              final logical = constraints.biggest.shortestSide.isFinite
                  ? constraints.biggest.shortestSide
                  : LekisSizes.listArtwork;
              final px = logical * MediaQuery.devicePixelRatioOf(context);
              final bucket = artworkBucketFor(px);
              final decodeWidth = px.ceil().clamp(1, bucket);
              Widget placeholder(BuildContext _, Object _, StackTrace? _) =>
                  ArtworkPlaceholder(icon: placeholderIcon);
              return Image.file(
                File(artworkFilePath(h, bucket)),
                key: ValueKey('$h@$bucket'),
                fit: BoxFit.cover,
                cacheWidth: decodeWidth,
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
                frameBuilder: _fadeIn,
                // Smaller buckets may not be generated yet → fall back to the
                // always-present large one, still decoded at small size.
                errorBuilder: bucket == artworkFallbackWidth
                    ? placeholder
                    : (_, _, _) => Image.file(
                        File(artworkFilePath(h, artworkFallbackWidth)),
                        fit: BoxFit.cover,
                        cacheWidth: decodeWidth,
                        gaplessPlayback: true,
                        frameBuilder: _fadeIn,
                        errorBuilder: placeholder,
                      ),
              );
            },
          ),
        ),
      ),
    );
  }

  static Widget _fadeIn(
    BuildContext context,
    Widget child,
    int? frame,
    bool wasSynchronouslyLoaded,
  ) {
    if (wasSynchronouslyLoaded) return child;
    return AnimatedOpacity(
      opacity: frame == null ? 0 : 1,
      duration: LekisMotion.fast,
      curve: Curves.easeOut,
      child: child,
    );
  }
}

/// The two ends of [ArtworkPlaceholder]'s gradient for [seed]. Now Playing
/// derives its background from the same colours when a track has no cover.
(Color, Color) placeholderGradientColors(int seed, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final hue = (seed * 47.0) % 360;
  final start = HSLColor.fromAHSL(
    1,
    hue,
    dark ? 0.46 : 0.36,
    dark ? 0.30 : 0.86,
  ).toColor();
  final end = HSLColor.fromAHSL(
    1,
    (hue + 42) % 360,
    dark ? 0.52 : 0.42,
    dark ? 0.13 : 0.68,
  ).toColor();
  return (start, end);
}

class ArtworkPlaceholder extends StatelessWidget {
  /// Initial letter size as a share of the tile side, and its opacity: a
  /// quiet watermark, not a headline, at any tile size.
  static const double _initialScale = 0.26;
  static const double _initialOpacity = 0.42;

  /// On tiles at least this large, draw the music / album glyph instead of
  /// an initial: a 48 dp character blown up to a grid or hero cover reads as
  /// a poster, not as missing artwork.
  static const double _initialMaxSide = LekisSizes.listArtwork * 2;
  static const double _iconScale = 0.26;

  const ArtworkPlaceholder({
    super.key,
    this.icon = Icons.music_note_rounded,
    this.seed = 0,
    this.label,
  });

  final IconData icon;

  /// Deterministic hue seed so every album / track gets its own colour.
  final int seed;

  /// Optional initial (album, artist) shown instead of the icon.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final (start, end) = placeholderGradientColors(
      seed,
      Theme.of(context).brightness,
    );
    final fg = dark ? Colors.white : Colors.black;
    final initial = label == null || label!.trim().isEmpty
        ? null
        : label!.trim().characters.first.toUpperCase();

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [start, end],
        ),
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          final side = c.biggest.shortestSide.isFinite
              ? c.biggest.shortestSide
              : 48.0;
          return Stack(
            fit: StackFit.expand,
            children: [
              Positioned(
                right: -side * 0.18,
                top: -side * 0.22,
                child: Container(
                  width: side * 0.7,
                  height: side * 0.7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: fg.withValues(alpha: 0.07),
                    border: Border.all(color: fg.withValues(alpha: 0.10)),
                  ),
                ),
              ),
              Center(
                child: initial != null && side < _initialMaxSide
                    ? Text(
                        initial,
                        style: TextStyle(
                          fontSize: side * _initialScale,
                          fontWeight: FontWeight.w600,
                          color: fg.withValues(alpha: _initialOpacity),
                          height: 1,
                        ),
                      )
                    : Icon(
                        icon,
                        size: side * _iconScale,
                        color: fg.withValues(alpha: 0.55),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Artwork of a track (resolved through the core).
class TrackArtwork extends ConsumerWidget {
  const TrackArtwork({
    super.key,
    required this.trackId,
    this.hasArtwork = true,
    this.radius,
    this.placeholderLabel,
  });

  final int trackId;

  /// `false` skips the lookup entirely (row has no artwork id).
  final bool hasArtwork;
  final double? radius;
  final String? placeholderLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hash = hasArtwork
        ? ref.watch(trackArtworkProvider(trackId)).value?.hash
        : null;
    return ArtworkImage(
      hash: hash,
      radius: radius,
      placeholderSeed: trackId,
      placeholderLabel: placeholderLabel,
    );
  }
}

class AlbumArtwork extends ConsumerWidget {
  const AlbumArtwork({super.key, required this.album, this.radius});

  final AlbumDto album;
  final double? radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hash = album.artworkId != null
        ? ref.watch(albumArtworkProvider(album.id)).value?.hash
        : null;
    return ArtworkImage(
      hash: hash,
      radius: radius ?? LekisRadius.artworkGrid,
      placeholderIcon: Icons.album_rounded,
      placeholderSeed: album.id,
      placeholderLabel: album.title,
    );
  }
}

/// Round initial-letter avatar (the core has no artist images yet).
class ArtistAvatar extends StatelessWidget {
  const ArtistAvatar({super.key, required this.name, this.size});

  final String name;
  final double? size;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final s = size ?? LekisSizes.listArtwork;
    final initial = name.trim().isEmpty
        ? '?'
        : name.trim().characters.first.toUpperCase();
    return SizedBox.square(
      dimension: s,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.accentSoft,
          shape: BoxShape.circle,
        ),
        child: Center(
          child: Text(
            initial,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: colors.accent,
              fontSize: s * 0.42,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
