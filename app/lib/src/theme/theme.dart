// Lekis themes (light / dark / OLED black) built from design tokens.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'tokens.dart';

export 'tokens.dart';

/// Light theme.
ThemeData lekisLightTheme() => _buildTheme(
  brightness: Brightness.light,
  background: LekisPalette.lightBackground,
  surface: LekisPalette.lightSurface,
  onBackground: LekisPalette.lightOnBackground,
  onSurface: LekisPalette.lightOnSurface,
  colors: LekisColors.light,
);

/// Dark theme; [oled] swaps background/surface for pure black.
ThemeData lekisDarkTheme({bool oled = false}) => _buildTheme(
  brightness: Brightness.dark,
  background: oled ? LekisPalette.oledBackground : LekisPalette.darkBackground,
  surface: oled ? LekisPalette.oledSurface : LekisPalette.darkSurface,
  onBackground: LekisPalette.darkOnBackground,
  onSurface: LekisPalette.darkOnSurface,
  colors: oled
      ? LekisColors.dark.copyWith(
          surfaceVariant: LekisPalette.oledSurfaceVariant,
          surfaceElevated: LekisPalette.oledSurfaceElevated,
        )
      : LekisColors.dark,
);

/// Text styles straight from the typography tokens (no color; they inherit
/// from the ambient [DefaultTextStyle]). Prefer `Theme.of(context).textTheme`
/// in widgets; these are for places that need the raw token (e.g. lyrics).
abstract final class LekisText {
  static TextStyle get display => _withFonts(LekisType.display.toStyle());
  static TextStyle get title1 => _withFonts(LekisType.title1.toStyle());
  static TextStyle get title2 => _withFonts(LekisType.title2.toStyle());
  static TextStyle get headline => _withFonts(LekisType.headline.toStyle());
  static TextStyle get body => _withFonts(LekisType.body.toStyle());
  static TextStyle get callout => _withFonts(LekisType.callout.toStyle());
  static TextStyle get caption => _withFonts(LekisType.caption.toStyle());
  static TextStyle get lyricsActive => _withFonts(LekisType.lyrics.toStyle());
  static TextStyle get lyricsInactive => _withFonts(LekisType.lyrics.toStyle());

  /// Tabular figures for times / counters so digits don't jitter.
  static const List<FontFeature> tabularFigures = [
    FontFeature.tabularFigures(),
  ];

  static TextStyle _withFonts(TextStyle style) => style.copyWith(
    fontFamily: _SystemFonts.family,
    fontFamilyFallback: _SystemFonts.fallback,
  );
}

/// System fonts with CJK coverage per platform (no bundled fonts).
abstract final class _SystemFonts {
  static String? get family => switch (defaultTargetPlatform) {
    TargetPlatform.windows => 'Segoe UI Variable Text',
    TargetPlatform.linux => 'Noto Sans',
    TargetPlatform.macOS || TargetPlatform.iOS => '.AppleSystemUIFont',
    // Android: Roboto + system Noto CJK fallback is already correct.
    _ => null,
  };

  static List<String>? get fallback => switch (defaultTargetPlatform) {
    TargetPlatform.windows => const [
      'Segoe UI',
      'Microsoft YaHei UI',
      'Microsoft YaHei',
      'Yu Gothic UI',
      'Malgun Gothic',
      'Segoe UI Emoji',
    ],
    TargetPlatform.linux => const [
      'Noto Sans CJK SC',
      'Noto Sans CJK JP',
      'Noto Sans CJK KR',
      'Source Han Sans SC',
      'WenQuanYi Micro Hei',
      'DejaVu Sans',
      'Noto Color Emoji',
    ],
    TargetPlatform.macOS || TargetPlatform.iOS => const ['PingFang SC'],
    _ => null,
  };
}

TextTheme _textTheme(Color onSurface, Color onSurfaceVariant) {
  TextStyle s(LekisTypeToken t, [Color? color]) =>
      t.toStyle().copyWith(color: color ?? onSurface);
  TextStyle label(LekisTypeToken t) =>
      s(t).copyWith(fontWeight: FontWeight.w600);

  return TextTheme(
    displayLarge: s(LekisType.display),
    displayMedium: s(LekisType.display),
    displaySmall: s(LekisType.display),
    headlineLarge: s(LekisType.display),
    headlineMedium: s(LekisType.title1),
    headlineSmall: s(LekisType.title2),
    titleLarge: s(LekisType.title2),
    titleMedium: s(LekisType.headline),
    titleSmall: label(LekisType.callout),
    bodyLarge: s(LekisType.body),
    bodyMedium: s(LekisType.callout),
    bodySmall: s(LekisType.caption, onSurfaceVariant),
    labelLarge: label(LekisType.callout),
    labelMedium: label(LekisType.caption),
    labelSmall: s(LekisType.caption, onSurfaceVariant),
  ).apply(
    fontFamily: _SystemFonts.family,
    fontFamilyFallback: _SystemFonts.fallback,
  );
}

ThemeData _buildTheme({
  required Brightness brightness,
  required Color background,
  required Color surface,
  required Color onBackground,
  required Color onSurface,
  required LekisColors colors,
}) {
  final isDark = brightness == Brightness.dark;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: colors.accent,
    onPrimary: colors.onAccent,
    primaryContainer: colors.accentSoft,
    onPrimaryContainer: onSurface,
    secondary: colors.aurora,
    onSecondary: isDark ? background : onSurface,
    secondaryContainer: colors.accentSoft,
    onSecondaryContainer: onSurface,
    tertiary: colors.moon,
    onTertiary: colors.onAccent,
    error: colors.danger,
    onError: colors.onAccent,
    surface: surface,
    onSurface: onSurface,
    onSurfaceVariant: colors.onSurfaceVariant,
    surfaceDim: background,
    surfaceBright: colors.surfaceElevated,
    surfaceContainerLowest: background,
    surfaceContainerLow: surface,
    surfaceContainer: surface,
    surfaceContainerHigh: colors.surfaceElevated,
    surfaceContainerHighest: colors.surfaceVariant,
    outline: colors.outline,
    outlineVariant: colors.outline,
    scrim: colors.scrim,
    shadow: colors.scrim,
    inverseSurface: onSurface,
    onInverseSurface: surface,
    inversePrimary: isDark ? LekisPalette.lightAccent : LekisPalette.darkAccent,
    surfaceTint: Colors.transparent,
  );

  final textTheme = _textTheme(onSurface, colors.onSurfaceVariant);
  final overlay = isDark
      ? SystemUiOverlayStyle.light
      : SystemUiOverlayStyle.dark;

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    canvasColor: background,
    textTheme: textTheme,
    fontFamily: _SystemFonts.family,
    fontFamilyFallback: _SystemFonts.fallback,
    extensions: [colors],
    dividerTheme: DividerThemeData(
      color: colors.outline,
      thickness: 1,
      space: 1,
    ),
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      foregroundColor: onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      toolbarHeight: 64,
      titleTextStyle: textTheme.titleLarge,
      systemOverlayStyle: overlay.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: colors.accentSoft,
      elevation: 0,
      height: 68,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => textTheme.labelMedium!.copyWith(
          color: states.contains(WidgetState.selected)
              ? colors.accent
              : colors.onSurfaceVariant,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? colors.accent
              : colors.onSurfaceVariant,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: background,
      indicatorColor: colors.accentSoft,
      selectedIconTheme: IconThemeData(color: colors.accent),
      unselectedIconTheme: IconThemeData(color: colors.onSurfaceVariant),
      selectedLabelTextStyle: textTheme.labelMedium!.copyWith(
        color: colors.accent,
      ),
      unselectedLabelTextStyle: textTheme.labelMedium!.copyWith(
        color: colors.onSurfaceVariant,
      ),
      labelType: NavigationRailLabelType.all,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: colors.onSurfaceVariant,
      textColor: onSurface,
      titleTextStyle: textTheme.bodyLarge,
      subtitleTextStyle: textTheme.bodySmall,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: LekisSpacing.pageGutter,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LekisRadius.md),
      ),
    ),
    cardTheme: CardThemeData(
      color: colors.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LekisRadius.lg),
        side: BorderSide(color: colors.outline),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, LekisSizes.touchTargetMin),
        padding: const EdgeInsets.symmetric(horizontal: LekisSpacing.xl),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: textTheme.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, LekisSizes.touchTargetMin),
        padding: const EdgeInsets.symmetric(horizontal: LekisSpacing.xl),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        side: BorderSide(color: colors.outline),
        textStyle: textTheme.labelLarge,
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        side: WidgetStatePropertyAll(BorderSide(color: colors.outline)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? colors.accentSoft
              : Colors.transparent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? colors.accent
              : colors.onSurfaceVariant,
        ),
        textStyle: WidgetStatePropertyAll(textTheme.labelMedium),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: colors.surfaceVariant,
      selectedColor: colors.accentSoft,
      side: BorderSide.none,
      shape: const StadiumBorder(),
      labelStyle: textTheme.labelMedium,
      padding: const EdgeInsets.symmetric(
        horizontal: LekisSpacing.md,
        vertical: LekisSpacing.xs,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(textStyle: textTheme.labelLarge),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: colors.onSurfaceVariant,
        highlightColor: colors.accentSoft,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surfaceVariant,
      hintStyle: textTheme.bodyLarge!.copyWith(color: colors.onSurfaceVariant),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: LekisSpacing.lg,
        vertical: LekisSpacing.md,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(LekisRadius.md),
        borderSide: BorderSide.none,
      ),
    ),
    searchBarTheme: SearchBarThemeData(
      backgroundColor: WidgetStatePropertyAll(colors.surfaceVariant),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      elevation: const WidgetStatePropertyAll(0),
      shape: const WidgetStatePropertyAll(StadiumBorder()),
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 3,
      activeTrackColor: colors.accent,
      inactiveTrackColor: colors.surfaceVariant,
      thumbColor: colors.accent,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
      overlayColor: colors.accent.withValues(alpha: 0.12),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: colors.accent,
      linearTrackColor: colors.surfaceVariant,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colors.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      modalBarrierColor: colors.scrim,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(LekisRadius.xl),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colors.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      barrierColor: colors.scrim,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LekisRadius.xl),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: onSurface,
      contentTextStyle: textTheme.bodyMedium!.copyWith(color: surface),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LekisRadius.md),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: colors.surfaceElevated,
        borderRadius: BorderRadius.circular(LekisRadius.sm),
        border: Border.all(color: colors.outline),
      ),
      textStyle: textTheme.bodySmall!.copyWith(color: onSurface),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
      },
    ),
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
  );
}
