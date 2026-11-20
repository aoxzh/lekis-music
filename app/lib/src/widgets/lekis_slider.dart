// The app's one slider.
//
// Every `Slider` in Lekis goes through [LekisSlider] so that:
// * the track is continuous everywhere (the theme pins the 2023 look: no
//   2024 gap, stop dot or tick marks), and only the geometry that genuinely
//   differs per place (track height, thumb size, touch padding) is overridden;
// * the slider never puts Material's semantics on the accessibility tree; see
//   [SliderOverlayHost]. Material's Slider always wraps itself in an
//   OverlayPortal, and Flutter <= 3.50 sends the portal child's semantics
//   node in ways the desktop accessibility bridge (ui::AXTree) rejects —
//   as an orphan (flutter#190357) or, when the slider's semantics parent is
//   rebuilt (the player bar's seek bar when a saved session is restored),
//   moved to the new parent without an update of its own. Either way every
//   later update fails and flutter_windows.dll eventually crashes
//   (0xC0000005). LekisSlider therefore excludes the Material slider's
//   semantics and describes itself with one plain slider node: value,
//   increase / decrease and the label, which is everything Material's node
//   carried. test/shell/semantics_tree_test.dart guards the invariant.

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
    final enabled = onChanged != null && max > min;
    final span = max - min;
    final step = divisions != null && divisions! > 0
        ? span / divisions!
        : span * _adjustmentFraction(Theme.of(context).platform);
    double clampValue(double v) => v.clamp(min, max).toDouble();
    String describe(double v) =>
        semanticFormatterCallback?.call(v) ??
        '${(span > 0 ? (v - min) / span * 100 : 0).round()}%';
    void nudge(double delta) {
      final next = clampValue(value + delta);
      onChangeStart?.call(value);
      onChanged?.call(next);
      onChangeEnd?.call(next);
    }

    return Semantics(
      container: true,
      slider: true,
      enabled: enabled,
      focusable: enabled,
      label: semanticLabel ?? label,
      value: describe(clampValue(value)),
      increasedValue: describe(clampValue(value + step)),
      decreasedValue: describe(clampValue(value - step)),
      textDirection: Directionality.maybeOf(context),
      onIncrease: enabled ? () => nudge(step) : null,
      onDecrease: enabled ? () => nudge(-step) : null,
      child: ExcludeSemantics(child: SliderOverlayHost(child: slider)),
    );
  }

  /// Same keyboard / screen-reader step as Material's slider.
  static double _adjustmentFraction(TargetPlatform platform) =>
      switch (platform) {
        TargetPlatform.iOS || TargetPlatform.macOS => 0.1,
        _ => 0.05,
      };
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
