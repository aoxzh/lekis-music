// Lekis themes (light / dark / OLED black) built from design tokens.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../platform/ui_profile.dart';
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

/// Coloured desktop text styles ([LekisDesktopType]) for the current theme.
/// Use these for desktop chrome (sidebar, settings panes, cards) so all
/// columns share one scale.
@immutable
class LekisDesktopText {
  LekisDesktopText._(ColorScheme scheme, LekisColors colors)
    : pageTitle = LekisText._withFonts(LekisDesktopType.pageTitle.toStyle())
          .copyWith(color: scheme.onSurface),
      paneTitle = LekisText._withFonts(LekisDesktopType.paneTitle.toStyle())
          .copyWith(
            color: scheme.onSurface.withValues(
              alpha: LekisDesktopType.paneTitleOpacity,
            ),
          ),
      item = LekisText._withFonts(LekisDesktopType.item.toStyle()).copyWith(
        color: scheme.onSurface.withValues(alpha: LekisDesktopType.itemOpacity),
      ),
      itemSelected = LekisText._withFonts(LekisDesktopType.item.toStyle())
          .copyWith(
            color: scheme.onSurface,
            fontWeight: LekisDesktopType.itemSelectedWeight,
          ),
      rowTitle = LekisText._withFonts(LekisDesktopType.item.toStyle())
          .copyWith(color: scheme.onSurface),
      sectionHeader = LekisText._withFonts(
        LekisDesktopType.sectionHeader.toStyle(),
      ).copyWith(color: colors.onSurfaceVariant),
      secondary = LekisText._withFonts(LekisDesktopType.secondary.toStyle())
          .copyWith(color: colors.onSurfaceVariant);

  factory LekisDesktopText.of(BuildContext context) =>
      LekisDesktopText._(Theme.of(context).colorScheme, context.lekisColors);

  final TextStyle pageTitle;
  final TextStyle paneTitle;

  /// Unselected navigation entry.
  final TextStyle item;

  /// Selected navigation entry.
  final TextStyle itemSelected;

  /// Title of a row inside a card (full colour, regular weight).
  final TextStyle rowTitle;
  final TextStyle sectionHeader;
  final TextStyle secondary;
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

/// The on-media variant of the theme, for content laid over artwork (Now
/// Playing, lyrics, cover wall) and everything opened from it.
///
/// Same component vocabulary as the app theme, different materials:
/// translucent [scene]-tinted glass panels, [foreground]-alpha text and
/// controls, and the now-playing tint as the accent (play button, seek bar,
/// badges, primary buttons). Toggles and segmented selections use a
/// foreground-alpha disc instead of the accent so they read as part of the
/// artwork rather than as coloured stickers.
ThemeData lekisOnMediaTheme({
  required Color scene,
  required Color foreground,
  required Color accent,
  required Color onAccent,
}) {
  final lightForeground = foreground.computeLuminance() > 0.5;
  final brightness = lightForeground ? Brightness.dark : Brightness.light;
  Color fg(double alpha) => foreground.withValues(alpha: alpha);
  // The fill of a glass panel before its translucency: a touch of the
  // foreground over the protected scene colour.
  final panelFill = Color.alphaBlend(fg(0.06), scene);
  // Desktop profiles have no glass: the same tinted panels, fully opaque and
  // without backdrop blur.
  final glass = UiProfile.current.supportsGlass;
  // Panels sit on blurred artwork, so they can be fairly translucent. Menus
  // and other surfaces that cannot blur the backdrop get a denser fill: at
  // 0.86 the page's big lyric lines ghosted straight through them.
  final panel = panelFill.withValues(alpha: glass ? 0.92 : 1);
  final palette = lightForeground ? LekisColors.dark : LekisColors.light;
  final colors = palette.copyWith(
    surfaceVariant: fg(0.10),
    surfaceElevated: panelFill.withValues(alpha: glass ? 0.95 : 1),
    onSurfaceVariant: fg(0.70),
    outline: fg(0.16),
    accent: accent,
    onAccent: onAccent,
    accentSoft: fg(0.16),
    scrim: const Color(0x66000000),
  );
  return _buildTheme(
    brightness: brightness,
    background: scene,
    surface: panel,
    onBackground: foreground,
    onSurface: foreground,
    colors: colors,
    inverseText: scene,
    surfaceStyle: LekisSurfaceStyle(
      onMedia: true,
      panel: panel,
      panelBorder: fg(0.14),
      blurSigma: glass ? 24 : 0,
    ),
    // Transport and pane toggles stay full-strength foreground on artwork.
    iconForeground: foreground,
    selectedForeground: foreground,
  );
}

ThemeData _buildTheme({
  required Brightness brightness,
  required Color background,
  required Color surface,
  required Color onBackground,
  required Color onSurface,
  required LekisColors colors,
  Color? inverseText,
  LekisSurfaceStyle surfaceStyle = LekisSurfaceStyle.app,
  Color? iconForeground,
  Color? selectedForeground,
}) {
  final isDark = brightness == Brightness.dark;
  final onMedia = surfaceStyle.onMedia;
  final inverseInk = inverseText ?? surface;
  final selectedFg = selectedForeground ?? colors.accent;
  // 浅色/深色选中胶囊（accentSoft 底色）上的前景色：浅色用品牌靛紫（5.6:1），
  // 深色提亮到柔和薰衣草白（6.7:1），避免纯靛紫落在深紫底上对比度偏低。
  final selectedOnSoftFg = onMedia
      ? selectedFg
      : (isDark ? Color.lerp(selectedFg, onSurface, 0.45)! : selectedFg);
  final scheme = ColorScheme(
    brightness: brightness,
    primary: colors.accent,
    onPrimary: colors.onAccent,
    primaryContainer: colors.accentSoft,
    onPrimaryContainer: onSurface,
    secondary: colors.aurora,
    onSecondary: isDark ? background : onSurface,
    secondaryContainer: colors.accentSoft,
    onSecondaryContainer: onMedia ? onSurface : colors.accent,
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
    onInverseSurface: inverseInk,
    inversePrimary: isDark ? LekisPalette.lightAccent : LekisPalette.darkAccent,
    surfaceTint: Colors.transparent,
  );

  final textTheme = _textTheme(onSurface, colors.onSurfaceVariant);
  final overlay = isDark
      ? SystemUiOverlayStyle.light
      : SystemUiOverlayStyle.dark;

  // ---- Shared shapes ------------------------------------------------------
  final buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(LekisRadius.button),
  );
  final fieldRadius = BorderRadius.circular(LekisRadius.md);
  // Panels separate from the page by a 1 px rim, not by shadow stacks.
  final panelSide = onMedia
      ? BorderSide(color: surfaceStyle.panelBorder)
      : (isDark ? BorderSide(color: colors.outline) : BorderSide.none);
  // Desktop surfaces use the tighter Fluent radii; mobile keeps the soft
  // panel curves.
  final desktop = UiProfile.current.isDesktop;
  final panelRadius = desktop ? LekisRadius.sm : LekisRadius.panel;
  final menuShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(
      desktop ? LekisRadius.sm : LekisRadius.md,
    ),
    side: panelSide,
  );
  const buttonSize = Size(0, LekisSizes.buttonHeight);
  const buttonPadding = EdgeInsets.symmetric(
    horizontal: LekisSpacing.lg + LekisSpacing.xs,
  );
  const buttonIconSize = LekisSpacing.lg + LekisSpacing.xxs;
  final disabledFg = onSurface.withValues(alpha: 0.38);
  final disabledBg = onSurface.withValues(alpha: 0.08);
  WidgetStateProperty<Color?> overlayOn(Color color) =>
      WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.pressed)) {
          return color.withValues(alpha: 0.12);
        }
        if (states.contains(WidgetState.hovered)) {
          return color.withValues(alpha: 0.08);
        }
        if (states.contains(WidgetState.focused)) {
          return color.withValues(alpha: 0.12);
        }
        return null;
      });

  OutlineInputBorder fieldBorder([BorderSide side = BorderSide.none]) =>
      OutlineInputBorder(borderRadius: fieldRadius, borderSide: side);

  // One field style everywhere: filled, no stroke at rest, a 1.5 px ring in
  // the selected colour when focused.
  final inputTheme = InputDecorationTheme(
    filled: true,
    fillColor: colors.surfaceVariant,
    hoverColor: onSurface.withValues(alpha: 0.04),
    labelStyle: textTheme.bodyLarge!.copyWith(color: colors.onSurfaceVariant),
    floatingLabelStyle: WidgetStateTextStyle.resolveWith(
      (states) => textTheme.bodyMedium!.copyWith(
        color: states.contains(WidgetState.error)
            ? colors.danger
            : states.contains(WidgetState.focused)
            ? selectedFg
            : colors.onSurfaceVariant,
      ),
    ),
    hintStyle: textTheme.bodyLarge!.copyWith(
      color: colors.onSurfaceVariant.withValues(
        alpha: colors.onSurfaceVariant.a * (isDark ? 0.78 : 0.90),
      ),
    ),
    helperStyle: textTheme.bodySmall,
    errorStyle: textTheme.bodySmall!.copyWith(color: colors.danger),
    prefixIconColor: colors.onSurfaceVariant,
    suffixIconColor: colors.onSurfaceVariant,
    contentPadding: const EdgeInsets.symmetric(
      horizontal: LekisSpacing.lg,
      vertical: LekisSpacing.md,
    ),
    border: fieldBorder(),
    enabledBorder: fieldBorder(),
    disabledBorder: fieldBorder(),
    focusedBorder: fieldBorder(BorderSide(color: selectedFg, width: 1.5)),
    errorBorder: fieldBorder(BorderSide(color: colors.danger)),
    focusedErrorBorder: fieldBorder(
      BorderSide(color: colors.danger, width: 1.5),
    ),
  );

  final menuStyle = MenuStyle(
    backgroundColor: WidgetStatePropertyAll(colors.surfaceElevated),
    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    shadowColor: WidgetStatePropertyAll(
      onMedia ? Colors.transparent : colors.scrim,
    ),
    elevation: WidgetStatePropertyAll(onMedia ? 0 : 3),
    shape: WidgetStatePropertyAll(menuShape),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(vertical: LekisSpacing.xs),
    ),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: onMedia ? Colors.transparent : background,
    canvasColor: background,
    textTheme: textTheme,
    fontFamily: _SystemFonts.family,
    fontFamilyFallback: _SystemFonts.fallback,
    extensions: [colors, surfaceStyle],
    iconTheme: IconThemeData(color: iconForeground ?? onSurface),
    dividerTheme: DividerThemeData(
      color: colors.outline,
      thickness: 1,
      space: 1,
    ),
    splashFactory: InkSparkle.splashFactory,
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: selectedFg,
      selectionColor: selectedFg.withValues(alpha: 0.28),
      selectionHandleColor: selectedFg,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: onMedia ? Colors.transparent : background,
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
    tabBarTheme: TabBarThemeData(
      labelColor: selectedFg,
      unselectedLabelColor: colors.onSurfaceVariant,
      labelStyle: textTheme.labelLarge,
      unselectedLabelStyle: textTheme.labelLarge,
      indicatorColor: selectedFg,
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: colors.outline,
      overlayColor: overlayOn(onSurface),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: colors.onSurfaceVariant,
      textColor: onSurface,
      selectedColor: selectedFg,
      selectedTileColor: colors.accentSoft,
      titleTextStyle: textTheme.bodyLarge,
      subtitleTextStyle: textTheme.bodySmall,
      leadingAndTrailingTextStyle: textTheme.bodySmall,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: LekisSpacing.pageGutter,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LekisRadius.md),
      ),
    ),
    expansionTileTheme: ExpansionTileThemeData(
      iconColor: colors.onSurfaceVariant,
      collapsedIconColor: colors.onSurfaceVariant,
      textColor: onSurface,
      collapsedTextColor: onSurface,
      shape: const Border(),
      collapsedShape: const Border(),
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
    // ---- Buttons: one height, one corner, one type style. --------------
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: buttonSize,
        padding: buttonPadding,
        shape: buttonShape,
        textStyle: textTheme.labelLarge,
        iconSize: buttonIconSize,
        disabledBackgroundColor: disabledBg,
        disabledForegroundColor: disabledFg,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: buttonSize,
        padding: buttonPadding,
        shape: buttonShape,
        foregroundColor: onSurface,
        disabledForegroundColor: disabledFg,
        side: BorderSide(color: colors.outline),
        textStyle: textTheme.labelLarge,
        iconSize: buttonIconSize,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: buttonSize,
        padding: const EdgeInsets.symmetric(horizontal: LekisSpacing.md),
        shape: buttonShape,
        foregroundColor: selectedFg,
        disabledForegroundColor: disabledFg,
        textStyle: textTheme.labelLarge,
        iconSize: buttonIconSize,
      ),
    ),
    // Icon buttons: plain glyphs; a toggle that is on gets a soft disc
    // (accentSoft) and the selected colour. Same rule in the player bar, on
    // Now Playing and in every page toolbar.
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return null;
          if (states.contains(WidgetState.selected)) return selectedFg;
          return iconForeground;
        }),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? colors.accentSoft : null,
        ),
        overlayColor: overlayOn(onSurface),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: colors.accent,
      foregroundColor: colors.onAccent,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 2,
      highlightElevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LekisRadius.lg),
      ),
      extendedTextStyle: textTheme.labelLarge,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize: const WidgetStatePropertyAll(
          Size(0, LekisSizes.segmentedHeight),
        ),
        side: WidgetStatePropertyAll(BorderSide(color: colors.outline)),
        // One corner for labelled controls (the same 14 as buttons); pills
        // are reserved for chips.
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(LekisRadius.button),
          ),
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? colors.accentSoft
              : Colors.transparent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? selectedOnSoftFg
              : colors.onSurfaceVariant,
        ),
        textStyle: WidgetStatePropertyAll(textTheme.labelLarge),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: colors.surfaceVariant,
      selectedColor: colors.accentSoft,
      secondarySelectedColor: colors.accentSoft,
      disabledColor: disabledBg,
      side: WidgetStateBorderSide.resolveWith(
        (states) => BorderSide(
          color: states.contains(WidgetState.selected)
              ? selectedOnSoftFg.withValues(alpha: isDark ? 0.50 : 0.35)
              : colors.outline,
        ),
      ),
      shape: const StadiumBorder(),
      showCheckmark: false,
      checkmarkColor: selectedOnSoftFg,
      // RawChip 只解析 labelStyle.color（WidgetStateColor），不会解析 WidgetStateTextStyle；
      // 同时显式提供 secondaryLabelStyle 给 ChoiceChip 的选中态，保证浅/深色下文字都清晰可读。
      labelStyle: textTheme.labelMedium!.copyWith(
        color: WidgetStateColor.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return disabledFg;
          if (states.contains(WidgetState.selected)) return selectedOnSoftFg;
          return onSurface;
        }),
      ),
      secondaryLabelStyle: textTheme.labelMedium!.copyWith(
        color: selectedOnSoftFg,
        fontWeight: FontWeight.w600,
      ),
      iconTheme: IconThemeData(
        color: colors.onSurfaceVariant,
        size: LekisSpacing.lg,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: LekisSpacing.sm,
        vertical: LekisSpacing.xs,
      ),
    ),
    // Count badges: small accent pill, never Material's default red.
    badgeTheme: BadgeThemeData(
      backgroundColor: colors.accent,
      textColor: colors.onAccent,
      smallSize: LekisSpacing.sm - LekisSpacing.xxs,
      largeSize: LekisSizes.badgeHeight,
      textStyle: textTheme.labelSmall!.copyWith(
        fontSize: 10,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
        fontFeatures: LekisText.tabularFigures,
      ),
      padding: const EdgeInsets.symmetric(horizontal: LekisSpacing.xs),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? colors.onAccent
            : colors.onSurfaceVariant,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? colors.accent
            : colors.surfaceVariant,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.transparent
            : colors.outline,
      ),
      overlayColor: overlayOn(colors.accent),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? colors.accent : null,
      ),
      checkColor: WidgetStatePropertyAll(colors.onAccent),
      side: BorderSide(color: colors.onSurfaceVariant, width: 1.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LekisRadius.xs),
      ),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? colors.accent
            : colors.onSurfaceVariant,
      ),
    ),
    inputDecorationTheme: inputTheme,
    dropdownMenuTheme: DropdownMenuThemeData(
      textStyle: textTheme.bodyLarge,
      inputDecorationTheme: inputTheme,
      menuStyle: menuStyle,
    ),
    menuTheme: MenuThemeData(style: menuStyle),
    popupMenuTheme: PopupMenuThemeData(
      color: colors.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      shadowColor: onMedia ? Colors.transparent : colors.scrim,
      elevation: onMedia ? 0 : 3,
      shape: menuShape,
      textStyle: textTheme.bodyLarge,
      labelTextStyle: WidgetStatePropertyAll(textTheme.bodyLarge),
      iconColor: colors.onSurfaceVariant,
      menuPadding: const EdgeInsets.symmetric(vertical: LekisSpacing.xs),
    ),
    searchBarTheme: SearchBarThemeData(
      backgroundColor: WidgetStatePropertyAll(colors.surfaceVariant),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      elevation: const WidgetStatePropertyAll(0),
      shape: const WidgetStatePropertyAll(StadiumBorder()),
      textStyle: WidgetStatePropertyAll(textTheme.bodyLarge),
      hintStyle: WidgetStatePropertyAll(inputTheme.hintStyle),
    ),
    // Classic continuous track everywhere: no 2024 gap, stop dot or ticks.
    sliderTheme: SliderThemeData(
      // Pinned: the framework default flips to the 2024 look later.
      // ignore: deprecated_member_use
      year2023: true,
      trackHeight: LekisSpacing.xs,
      activeTrackColor: colors.accent,
      inactiveTrackColor: onMedia
          ? onSurface.withValues(alpha: 0.24)
          : colors.outline,
      disabledActiveTrackColor: disabledFg,
      disabledInactiveTrackColor: disabledBg,
      thumbColor: colors.accent,
      disabledThumbColor: disabledFg,
      tickMarkShape: SliderTickMarkShape.noTickMark,
      thumbShape: const RoundSliderThumbShape(
        enabledThumbRadius: LekisSpacing.xs + LekisSpacing.xxs,
      ),
      overlayShape: const RoundSliderOverlayShape(
        overlayRadius: LekisSpacing.lg,
      ),
      overlayColor: colors.accent.withValues(alpha: 0.12),
      showValueIndicator: ShowValueIndicator.onDrag,
      valueIndicatorColor: onSurface,
      valueIndicatorTextStyle: textTheme.labelMedium!.copyWith(
        color: inverseInk,
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      // ignore: deprecated_member_use
      year2023: true,
      color: colors.accent,
      linearTrackColor: onMedia
          ? onSurface.withValues(alpha: 0.16)
          : colors.surfaceVariant,
      circularTrackColor: Colors.transparent,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colors.surfaceElevated,
      modalBackgroundColor: colors.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      modalBarrierColor: colors.scrim,
      elevation: 0,
      modalElevation: 0,
      showDragHandle: true,
      dragHandleColor: colors.onSurfaceVariant.withValues(
        alpha: colors.onSurfaceVariant.a * 0.5,
      ),
      dragHandleSize: const Size(
        LekisSpacing.xxl + LekisSpacing.xs,
        LekisSpacing.xs,
      ),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        side: panelSide,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(LekisRadius.panel),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colors.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      barrierColor: colors.scrim,
      elevation: onMedia ? 0 : 6,
      shadowColor: onMedia ? Colors.transparent : colors.scrim,
      clipBehavior: Clip.antiAlias,
      titleTextStyle: textTheme.titleLarge,
      contentTextStyle: textTheme.bodyMedium!.copyWith(
        color: colors.onSurfaceVariant,
        height: 1.5,
      ),
      actionsPadding: const EdgeInsets.fromLTRB(
        LekisSpacing.xl,
        0,
        LekisSpacing.xl,
        LekisSpacing.lg,
      ),
      shape: RoundedRectangleBorder(
        side: panelSide,
        borderRadius: BorderRadius.circular(panelRadius),
      ),
    ),
    // On artwork the snack bar is one more dark glass pill, not a white slab
    // across the bottom of the screen.
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: onMedia ? surfaceStyle.panel : onSurface,
      contentTextStyle: textTheme.bodyMedium!.copyWith(
        color: onMedia ? onSurface : inverseInk,
      ),
      actionTextColor: onMedia ? colors.accent : scheme.inversePrimary,
      closeIconColor: onMedia ? colors.onSurfaceVariant : inverseInk,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LekisRadius.md),
        side: onMedia
            ? BorderSide(color: surfaceStyle.panelBorder)
            : BorderSide.none,
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: onMedia ? surfaceStyle.panel : colors.surfaceElevated,
        borderRadius: BorderRadius.circular(LekisRadius.sm),
        border: Border.all(
          color: onMedia ? surfaceStyle.panelBorder : colors.outline,
        ),
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
    // Touch density on mobile, mouse density on desktop.
    visualDensity: UiProfile.current.visualDensity,
    materialTapTargetSize: UiProfile.current.tapTargetSize,
  );
}
