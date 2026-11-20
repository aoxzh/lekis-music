// Lekis design tokens. Source of truth: design/tokens.json — keep in sync.
//
// Everything visual (spacing, radii, sizes, motion, colors) must come from
// here or from the theme built on top of it; no magic numbers in widgets.

import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/physics.dart';
import 'package:material_ui/material_ui.dart';

/// Spacing scale (logical pixels).
abstract final class LekisSpacing {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
  static const double pageGutter = 16;
  static const double pageGutterDesktop = 32;
}

/// Corner radii (logical pixels).
abstract final class LekisRadius {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 18;
  static const double xl = 28;
  static const double artworkList = 6;
  static const double artworkGrid = 12;
  static const double artworkNowPlaying = 18;
  static const double pill = 999;

  /// Floating mini player corners.
  /// Floating mini player: a full capsule (half of its 56 dp height).
  static const double miniPlayer = 28;

  /// Large artwork (Now Playing, detail headers) rounds its corners by this
  /// share of its side, so a cover keeps the same shape at every size.
  static const double artworkFraction = 0.06;

  /// Corner radius for artwork [side] logical pixels wide.
  static double artworkFor(double side) => side * artworkFraction;
}

/// Fixed component sizes (logical pixels).
abstract final class LekisSizes {
  static const double listArtwork = 48;
  static const double gridArtworkMin = 160;
  static const double miniPlayerHeight = 56;

  /// Gap between the floating mini player and the window edges / nav bar.
  static const double miniPlayerMargin = 8;

  /// Widest the floating mini player gets above the glass tab bar.
  static const double floatingMiniPlayerMaxWidth = 560;
  static const double desktopPlayerBarHeight = 92;
  static const double desktopSidebarWidth = 248;

  /// Right-hand playback queue panel on wide windows.
  static const double desktopQueuePanelWidth = 320;

  /// Minimum cover side in the Now Playing cover wall.
  static const double coverWallTileMin = 120;
  static const double touchTargetMin = 48;
}

/// Floating bottom tab bar metrics.
///
/// The bar is a translucent capsule; the selection pill always stays inside
/// it and each destination keeps a full-height touch target.
abstract final class LekisTabBarTokens {
  static const double height = 64;
  static const double iconSize = 24;
  static const double iconGap = 2;
  static const double labelHeight = 15;

  /// Horizontal padding between the capsule edge and the five slots.
  static const double innerInset = 4;

  /// Gap between a slot edge and the selection pill.
  static const double pillInset = 3;

  /// Backdrop blur of the capsule where there is no lens (Skia backends):
  /// frosted glass.
  static const double blurSigma = 22;

  /// Blur under the lens (CYL / Backdrop: 8 dp blur radius ≈ sigma 5).
  static const double lensBlurSigma = 5;

  /// Lens reach in from the rim and how far it bends content (24 / 24 dp).
  static const double refractionHeight = 24;
  static const double refractionAmount = 24;

  /// Widest a slot gets. The capsule hugs its five slots and centres
  /// instead of stretching across wide phones / tablets in portrait.
  static const double maxSlotWidth = 68;

  /// Slot length of the vertical (side) capsule.
  static const double verticalSlot = 60;

  /// Surface tint over the blurred backdrop. Low enough that content
  /// scrolling underneath shows through as colour.
  static const double glassTintDark = 0.40;
  static const double glassTintLight = 0.40;

  /// Saturation boost applied to the backdrop before blurring (vibrancy).
  static const double glassSaturation = 1.5;

  /// Opacity of the film grain laid over the capsule (keeps the gradient
  /// from banding on large soft areas, like Now Playing does).
  static const double noiseOpacity = 0.035;

  /// How much the selection pill stretches while travelling, at most.
  static const double maxPillStretch = 0.18;
}

/// Motion tokens. Springs use mass 1 and are defined by stiffness and
/// damping ratio, like Compose's `spring()`.
abstract final class LekisMotion {
  static final SpringDescription springStandard = _spring(380, 0.86);
  static final SpringDescription springEmphasized = _spring(220, 0.78);
  static final SpringDescription springGentle = _spring(120, 1.0);
  static final SpringDescription springLyricsScroll = _spring(90, 0.92);

  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 250);
  static const Duration slow = Duration(milliseconds: 400);
  static const Duration backgroundCrossfade = Duration(milliseconds: 900);

  /// Squash-and-stretch of a destination icon after it becomes active.
  static const Duration navBounce = Duration(milliseconds: 480);

  /// Flat tab bar selection: short ease, deliberately no spring.
  static const Duration navFlat = Duration(milliseconds: 170);

  static SpringDescription _spring(double stiffness, double dampingRatio) =>
      SpringDescription.withDampingRatio(
        mass: 1,
        stiffness: stiffness,
        ratio: dampingRatio,
      );

  /// Approximate time for [spring] to settle within 1% of its target.
  /// Useful as the `duration` paired with [LekisSpringCurve].
  static Duration settleDuration(SpringDescription spring) {
    final omega = math.sqrt(spring.stiffness / spring.mass);
    final zeta =
        spring.damping / (2 * math.sqrt(spring.stiffness * spring.mass));
    // Envelope e^(-ζωt) reaches 1% at t = ln(100) / (ζω).
    final seconds = math.log(100) / (math.min(zeta, 1.0) * omega);
    return Duration(microseconds: (seconds * 1e6).round());
  }
}

/// A [Curve] that follows a unit spring from 0 to 1, so springs can drive
/// duration-based APIs (route transitions, `AnimatedFoo` widgets).
/// Pair it with [LekisMotion.settleDuration] of the same spring.
class LekisSpringCurve extends Curve {
  LekisSpringCurve(this.spring, {Duration? duration})
    : _seconds =
          (duration ?? LekisMotion.settleDuration(spring)).inMicroseconds / 1e6;

  final SpringDescription spring;
  final double _seconds;

  @override
  double transformInternal(double t) =>
      SpringSimulation(spring, 0, 1, 0).x(t * _seconds);
}

/// Lekis-specific colors not covered by Material's [ColorScheme].
@immutable
class LekisColors extends ThemeExtension<LekisColors> {
  const LekisColors({
    required this.surfaceVariant,
    required this.surfaceElevated,
    required this.onSurfaceVariant,
    required this.outline,
    required this.accent,
    required this.onAccent,
    required this.accentSoft,
    required this.moon,
    required this.aurora,
    required this.danger,
    required this.scrim,
  });

  final Color surfaceVariant;
  final Color surfaceElevated;
  final Color onSurfaceVariant;
  final Color outline;
  final Color accent;
  final Color onAccent;
  final Color accentSoft;
  final Color moon;
  final Color aurora;
  final Color danger;
  final Color scrim;

  static const LekisColors light = LekisColors(
    surfaceVariant: LekisPalette.lightSurfaceVariant,
    surfaceElevated: LekisPalette.lightSurfaceElevated,
    onSurfaceVariant: LekisPalette.lightOnSurfaceVariant,
    outline: LekisPalette.lightOutline,
    accent: LekisPalette.lightAccent,
    onAccent: LekisPalette.lightOnAccent,
    accentSoft: LekisPalette.lightAccentSoft,
    moon: LekisPalette.lightMoon,
    aurora: LekisPalette.lightAurora,
    danger: LekisPalette.lightDanger,
    scrim: LekisPalette.lightScrim,
  );

  static const LekisColors dark = LekisColors(
    surfaceVariant: LekisPalette.darkSurfaceVariant,
    surfaceElevated: LekisPalette.darkSurfaceElevated,
    onSurfaceVariant: LekisPalette.darkOnSurfaceVariant,
    outline: LekisPalette.darkOutline,
    accent: LekisPalette.darkAccent,
    onAccent: LekisPalette.darkOnAccent,
    accentSoft: LekisPalette.darkAccentSoft,
    moon: LekisPalette.darkMoon,
    aurora: LekisPalette.darkAurora,
    danger: LekisPalette.darkDanger,
    scrim: LekisPalette.darkScrim,
  );

  @override
  LekisColors copyWith({
    Color? surfaceVariant,
    Color? surfaceElevated,
    Color? onSurfaceVariant,
    Color? outline,
    Color? accent,
    Color? onAccent,
    Color? accentSoft,
    Color? moon,
    Color? aurora,
    Color? danger,
    Color? scrim,
  }) => LekisColors(
    surfaceVariant: surfaceVariant ?? this.surfaceVariant,
    surfaceElevated: surfaceElevated ?? this.surfaceElevated,
    onSurfaceVariant: onSurfaceVariant ?? this.onSurfaceVariant,
    outline: outline ?? this.outline,
    accent: accent ?? this.accent,
    onAccent: onAccent ?? this.onAccent,
    accentSoft: accentSoft ?? this.accentSoft,
    moon: moon ?? this.moon,
    aurora: aurora ?? this.aurora,
    danger: danger ?? this.danger,
    scrim: scrim ?? this.scrim,
  );

  @override
  LekisColors lerp(covariant ThemeExtension<LekisColors>? other, double t) {
    if (other is! LekisColors) return this;
    return LekisColors(
      surfaceVariant: Color.lerp(surfaceVariant, other.surfaceVariant, t)!,
      surfaceElevated: Color.lerp(surfaceElevated, other.surfaceElevated, t)!,
      onSurfaceVariant: Color.lerp(
        onSurfaceVariant,
        other.onSurfaceVariant,
        t,
      )!,
      outline: Color.lerp(outline, other.outline, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      moon: Color.lerp(moon, other.moon, t)!,
      aurora: Color.lerp(aurora, other.aurora, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      scrim: Color.lerp(scrim, other.scrim, t)!,
    );
  }
}

extension LekisThemeX on BuildContext {
  /// Lekis extension colors of the current theme.
  LekisColors get lekisColors =>
      Theme.of(this).extension<LekisColors>() ??
      (Theme.of(this).brightness == Brightness.dark
          ? LekisColors.dark
          : LekisColors.light);
}

/// Raw palette values from design/tokens.json. Prefer [ColorScheme] or
/// [LekisColors] in widgets; this exists so the theme has one place to read.
abstract final class LekisPalette {
  // Light: cool paper and ink (月夜靛紫 stays the brand accent).
  static const Color lightBackground = Color(0xFFF8F7FC);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceVariant = Color(0xFFEFEDF7);
  static const Color lightSurfaceElevated = Color(0xFFFFFFFF);
  static const Color lightOnBackground = Color(0xFF17151F);
  static const Color lightOnSurface = Color(0xFF17151F);
  static const Color lightOnSurfaceVariant = Color(0xFF615D70);
  static const Color lightOutline = Color(0xFFDEDAE9);
  static const Color lightAccent = Color(0xFF4F46C8);
  static const Color lightOnAccent = Color(0xFFFFFFFF);
  static const Color lightAccentSoft = Color(0xFFE8E5FF);
  static const Color lightMoon = Color(0xFFB9821F);
  static const Color lightAurora = Color(0xFF1F7A6B);
  static const Color lightDanger = Color(0xFFC03A4E);
  static const Color lightScrim = Color(0x66000000);

  // Dark: deep indigo night; moonlight is the rare highlight.
  static const Color darkBackground = Color(0xFF08070F);
  static const Color darkSurface = Color(0xFF0F0E17);
  static const Color darkSurfaceVariant = Color(0xFF181624);
  static const Color darkSurfaceElevated = Color(0xFF14121E);
  static const Color darkOnBackground = Color(0xFFF4F1FA);
  static const Color darkOnSurface = Color(0xFFF4F1FA);
  static const Color darkOnSurfaceVariant = Color(0xFFA5A1B5);
  static const Color darkOutline = Color(0xFF29263A);
  static const Color darkAccent = Color(0xFF6E5BF0);
  static const Color darkOnAccent = Color(0xFFFFFFFF);
  static const Color darkAccentSoft = Color(0xFF221D3F);
  static const Color darkMoon = Color(0xFFF2C46B);
  static const Color darkAurora = Color(0xFF79D6C2);
  static const Color darkDanger = Color(0xFFFF6B81);
  static const Color darkScrim = Color(0xB3000000);

  // OLED black (overrides dark)
  static const Color oledBackground = Color(0xFF000000);
  static const Color oledSurface = Color(0xFF08070D);
  static const Color oledSurfaceVariant = Color(0xFF12101A);
  static const Color oledSurfaceElevated = Color(0xFF0C0A12);
}

/// One typography token: size / weight / line height (logical pixels).
@immutable
class LekisTypeToken {
  const LekisTypeToken(
    this.size,
    this.weight,
    this.lineHeight, {
    this.letterSpacing = 0,
  });

  final double size;
  final FontWeight weight;
  final double lineHeight;

  /// Tracking applied on top of the system font. Negative values tighten
  /// large display text; small positive values open up metadata labels.
  final double letterSpacing;

  TextStyle toStyle() => TextStyle(
    fontSize: size,
    fontWeight: weight,
    height: lineHeight / size,
    letterSpacing: letterSpacing,
    leadingDistribution: TextLeadingDistribution.even,
  );

  /// Interpolates size, weight, line height and tracking; useful for
  /// collapsing headers.
  static LekisTypeToken lerp(LekisTypeToken a, LekisTypeToken b, double t) =>
      LekisTypeToken(
        lerpDouble(a.size, b.size, t)!,
        FontWeight.lerp(a.weight, b.weight, t)!,
        lerpDouble(a.lineHeight, b.lineHeight, t)!,
        letterSpacing: lerpDouble(a.letterSpacing, b.letterSpacing, t)!,
      );
}

/// Typography tokens.
abstract final class LekisType {
  static const display = LekisTypeToken(
    36,
    FontWeight.w700,
    42,
    letterSpacing: -0.6,
  );
  static const title1 = LekisTypeToken(
    28,
    FontWeight.w700,
    34,
    letterSpacing: -0.3,
  );
  static const title2 = LekisTypeToken(
    22,
    FontWeight.w600,
    28,
    letterSpacing: -0.1,
  );
  static const headline = LekisTypeToken(16, FontWeight.w600, 22);
  static const body = LekisTypeToken(15, FontWeight.w400, 21);
  static const callout = LekisTypeToken(13, FontWeight.w400, 18);
  static const caption = LekisTypeToken(
    11,
    FontWeight.w400,
    15,
    letterSpacing: 0.3,
  );
  static const lyrics = LekisTypeToken(
    32,
    FontWeight.w700,
    40,
    letterSpacing: -0.2,
  );

  /// Opacity of inactive lyric lines.
  static const double lyricsInactiveOpacity = 0.35;

  /// Blur radius applied to inactive lyric lines.
  static const double lyricsInactiveBlur = 1.5;
}

/// Now Playing dynamic background tokens.
///
/// Defaults follow Symfonik's `modern` Now Playing style: the artwork itself
/// is the background (blur 160), with no global dimming layer
/// (`backgroundProtection = 0`). Only the top bar gets a protection gradient
/// (`topBarBackgroundProtection = 2`, transparency 60 → 40% at the top).
abstract final class LekisNowPlaying {
  static const int gradientColors = 4;
  static const Duration gradientCycle = Duration(milliseconds: 24000);
  static const double blurRadius = 160;

  /// No full-screen dimming; contrast comes from the adaptive tint and from
  /// the protected top bar. Kept as a token so a future "classic" style can
  /// turn global protection back on.
  static const double protectionOpacity = 0;

  /// Strength of the top-bar scrim (transparency 60 → 40% opacity).
  static const double topBarProtectionOpacity = 0.40;

  /// Share of the window height the top-bar scrim fades across.
  static const double topBarProtectionHeight = 0.22;

  /// Opacity of the palette gradient drifting over the blurred artwork.
  static const double gradientOpacity = 0.55;

  /// Opacity of the overlay-blended grain laid over the soft gradients
  /// (stops banding on large smooth areas).
  static const double noiseOpacity = 0.12;

  /// Share of the travel after which a released drag opens / closes Now
  /// Playing, and the fling speed (logical px/s) that decides regardless.
  static const double dragCommitFraction = 0.35;
  static const double dragCommitVelocity = 700;
}
