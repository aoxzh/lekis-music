// Shared "liquid glass" backdrop filter: saturate, then blur what is behind.
// Used by the floating tab bar and the floating mini player so both read as
// the same material.

import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';

/// Backdrop filter for glass surfaces: a vibrancy (saturation) boost on what
/// shows through, then a gaussian blur.
ui.ImageFilter lekisGlassFilter(double sigma) {
  const s = LekisTabBarTokens.glassSaturation;
  // Rec. 709 luma weights.
  const r = 0.2126 * (1 - s);
  const g = 0.7152 * (1 - s);
  const b = 0.0722 * (1 - s);
  const saturate = ColorFilter.matrix(<double>[
    r + s, g, b, 0, 0, //
    r, g + s, b, 0, 0, //
    r, g, b + s, 0, 0, //
    0, 0, 0, 1, 0,
  ]);
  return ui.ImageFilter.compose(
    outer: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
    inner: saturate,
  );
}
