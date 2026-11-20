// The app's one slider.
//
// Every `Slider` in Lekis goes through [LekisSlider] so that:
// * the track is continuous everywhere (the theme pins the 2023 look: no
//   2024 gap, stop dot or tick marks), and only the geometry that genuinely
//   differs per place (track height, thumb size, touch padding) is overridden;
// * the slider is hosted in [SliderOverlayHost]. Material's Slider always
//   wraps itself in an OverlayPortal for its value indicator; when its
//   semantics change after the first snapshot, Flutter <= 3.50 can serialize
//   the portal's semantics node without a parent (flutter#190357), and the
//   desktop accessibility bridge then rejects every update ("N will not be in
//   the tree and is not the new root"), freezing the accessibility tree and
//   later crashing flutter_windows.dll. Hosting the portal in its own overlay
//   keeps the node inside the slider's subtree. Drop the host once the stable
//   SDK contains flutter#193372 (test/shell/semantics_tree_test.dart guards
//   the invariant).

import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';
import 'slider_overlay_host.dart';

/// Continuous slider in the app's style; see the file comment.
class LekisSlider extends StatelessWidget {
  const LekisSlider({
    super.key,
    required this.value,
    this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.label,
    this.semanticLabel,
    this.semanticFormatterCallback,
    this.trackHeight,
    this.thumbRadius,
    this.overlayRadius,
    this.dense = false,
  });

  final double value;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;
  final double min;
  final double max;

  /// Kept for callers that snap (equalizer bands, lyric offset); the theme
  /// hides the tick marks these would otherwise draw.
  final int? divisions;
  final String? label;
  final String? semanticLabel;
  final String Function(double)? semanticFormatterCallback;

  /// Track thickness; `null` keeps the theme's value.
  final double? trackHeight;

  /// Thumb radius; `null` keeps the theme's value.
  final double? thumbRadius;

  /// Touch overlay radius; `null` keeps the theme's value.
  final double? overlayRadius;

  /// `true` in rows that are much shorter than a touch target (the desktop
  /// player bar): the slider then sizes itself from the thumb instead of
  /// reserving 48 dp, so it fits the bar.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final base = SliderTheme.of(context);
    final needsOverride =
        trackHeight != null ||
        thumbRadius != null ||
        overlayRadius != null ||
        dense;
    Widget slider = Slider(
      value: value,
      min: min,
      max: max,
      divisions: divisions,
      label: label,
      semanticFormatterCallback: semanticFormatterCallback,
      onChanged: onChanged,
      onChangeStart: onChangeStart,
      onChangeEnd: onChangeEnd,
    );
    if (needsOverride) {
      slider = SliderTheme(
        data: base.copyWith(
          trackHeight: trackHeight,
          padding: dense ? EdgeInsets.zero : null,
          thumbShape: thumbRadius == null
              ? null
              : RoundSliderThumbShape(enabledThumbRadius: thumbRadius!),
          overlayShape: overlayRadius == null
              ? null
              : RoundSliderOverlayShape(overlayRadius: overlayRadius!),
        ),
        child: slider,
      );
    }
    return SliderOverlayHost(child: slider);
  }
}

/// Shared geometry for the sliders that sit in dense desktop rows.
abstract final class LekisSliderGeometry {
  /// Track thickness everywhere.
  static const double track = LekisSpacing.xs;

  /// Thumb radius at rest.
  static const double thumb = LekisSpacing.xs + LekisSpacing.xxs;

  /// Thumb radius while dragging (grows, like Apple Music's).
  static const double thumbDragging = LekisSpacing.sm;

  /// Touch target radius on phones.
  static const double overlay = LekisSizes.touchTargetMin / 2;

  /// Touch overlay in the desktop player bar (fits inside the bar).
  static const double overlayDense = LekisSpacing.md;
}
