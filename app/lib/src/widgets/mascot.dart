// The Lekis moon-rabbit in different poses, for empty, progress and all-good
// states. The launcher-style head-and-shoulders mark stays in brand_mark.dart;
// these are the full-body illustrations from the brand kit, cropped to the
// indigo tile so they read the same in light and dark themes.
import 'package:material_ui/material_ui.dart';

import '../theme/theme.dart';

/// Which mascot illustration to show. Pick by mood, not by page:
enum LekisMascotPose {
  /// Mid-jump, waving. Welcome / first run / "let's get started".
  jumping('jumping'),

  /// Running with motion lines. Work in progress (scan, enrich, download).
  running('running'),

  /// Lounging in a starry armchair (full scene). Calm "nothing here yet":
  /// empty playlists, queue, history.
  sitting('sitting'),

  /// Standing, hands on hips. Confident brand moments (About, splash).
  standing('standing'),

  /// Hand on chin, puzzled. No results, nothing found, errors.
  thinking('thinking'),

  /// Winking thumbs-up. All done / no issues / success.
  thumbsUp('thumbs_up');

  const LekisMascotPose(this.file);

  final String file;

  String get asset => 'assets/brand/mascot/$file.webp';
}

class LekisMascot extends StatelessWidget {
  const LekisMascot({
    super.key,
    required this.pose,
    this.size = 128,
    this.radius,
    this.semanticLabel,
    this.excludeFromSemantics = true,
  });

  final LekisMascotPose pose;

  /// Side of the square tile in logical pixels.
  final double size;

  /// Corner radius; defaults to the launcher-icon ratio (24% of [size]).
  final double? radius;

  /// Read out only when [excludeFromSemantics] is false.
  final String? semanticLabel;

  /// Mascots are decorative next to a title by default.
  final bool excludeFromSemantics;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final r = BorderRadius.circular(radius ?? size * 0.24);
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2;
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        // Hairline so the indigo tile has an edge on dark surfaces too.
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: r,
          border: Border.all(
            color: colors.moon.withValues(alpha: 0.28),
            width: 1,
          ),
        ),
        child: ClipRRect(
          borderRadius: r,
          child: Image.asset(
            pose.asset,
            width: size,
            height: size,
            fit: BoxFit.cover,
            cacheWidth: (size * dpr).round().clamp(1, 512),
            filterQuality: FilterQuality.medium,
            semanticLabel: semanticLabel ?? 'Lekis',
            excludeFromSemantics: excludeFromSemantics,
            errorBuilder: (context, error, stack) => ColoredBox(
              color: colors.accentSoft,
              child: Icon(
                Icons.nightlight_round,
                size: size * 0.4,
                color: colors.moon,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
