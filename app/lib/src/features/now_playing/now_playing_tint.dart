// 播放页 / 迷你播放器的封面取色。
//
// 只从封面调色板里取“感觉”，不直接把主色铺满界面：
// * 背景压暗（或提亮）层带一点主色，避免纯黑/纯白让封面显得脏；
// * 文字永远是近黑/近白，按封面的明度选边，保证对比度；
// * 主色只在按钮、进度条这类小面积控件上出现，并先把亮度推到
//   至少 3:1，避免深色封面上的深色进度条看不见。

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:material_ui/material_ui.dart';

export 'package:lekis/src/features/library/widgets/artwork.dart'
    show placeholderGradientColors;

/// 占位封面对应的“调色板”，让背景 / 进度条跟着占位色走，而不是退回品牌紫。
PaletteDto placeholderPalette(int seed, Brightness brightness) {
  final (start, end) = placeholderGradientColors(seed, brightness);
  final mid = Color.lerp(start, end, 0.5)!;
  int rgb(Color c) => c.toARGB32() & 0xFFFFFF;
  return PaletteDto(
    primary: rgb(start),
    secondary: rgb(end),
    onPrimary: brightness == Brightness.dark ? 0xFFFFFF : 0x000000,
    gradient: Uint32List.fromList([rgb(mid), rgb(start), rgb(end), rgb(mid)]),
  );
}

/// 播放页实际使用的调色板：封面自带的调色板优先；当前曲目确实没有封面
/// （界面上画的是占位渐变）时，用占位色推导；封面还在加载或有图但没算出
/// 调色板时返回 null（退回主题色）。参数是主题明暗（占位色随之变化）。
final nowPlayingPaletteProvider = Provider.family<PaletteDto?, Brightness>((
  ref,
  brightness,
) {
  final artwork = ref.watch(currentArtworkProvider);
  final palette = artwork.value?.palette;
  if (palette != null) return palette;
  if (!artwork.hasValue || artwork.value != null) return null;
  final trackId = ref.watch(currentTrackProvider.select((t) => t.value?.id));
  if (trackId == null) return null;
  // Same seed as NowPlayingArtwork / CurrentArtwork.
  return placeholderPalette(trackId.hashCode, brightness);
});

/// WCAG 相对亮度对比度（1..21）。
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// 深色场景里的近白文字；带一点月光的暖调，不是刺眼的纯白。
const Color _lightInk = Color(0xFFF8F5FC);

/// 浅色场景里的近黑文字；带一点靛紫，和品牌色同源。
const Color _darkInk = Color(0xFF15121C);

/// 在 [background] 上可读的文字颜色。[preferred] 的对比度够就用它
/// （通常是封面调色板给出的 `onPrimary`），否则退回近黑/近白。
Color readableOn(Color background, {Color? preferred}) {
  if (preferred != null && contrastRatio(preferred, background) >= 4.5) {
    return preferred;
  }
  return contrastRatio(_lightInk, background) >=
          contrastRatio(_darkInk, background)
      ? _lightInk
      : _darkInk;
}

/// 把 [accent] 的亮度推到在 [scene] 上至少 [minRatio]（默认 3:1）。
/// 只改 HSL 的 lightness，保留封面的色相。
Color readableAccent(Color accent, Color scene, {double minRatio = 3}) {
  if (contrastRatio(accent, scene) >= minRatio) return accent;
  final hsl = HSLColor.fromColor(accent);
  final towardsLight = scene.computeLuminance() < 0.5;
  var lightness = hsl.lightness;
  for (var i = 0; i < 20; i++) {
    lightness = (lightness + (towardsLight ? 0.04 : -0.04)).clamp(0.0, 1.0);
    final candidate = hsl.withLightness(lightness).toColor();
    if (contrastRatio(candidate, scene) >= minRatio) return candidate;
  }
  return towardsLight ? _lightInk : _darkInk;
}

/// 从封面调色板推导出的、已经做过对比度保护的颜色。
@immutable
class NowPlayingTint {
  const NowPlayingTint({
    required this.scene,
    required this.foreground,
    required this.primary,
    required this.secondary,
    required this.onPrimary,
    required this.isLight,
  });

  /// 背景压暗 / 提亮层的底色：近黑或近白，混入一点封面主色。
  /// 往背景上叠这一层，文字就能稳定落在 [foreground] 的对比度里。
  final Color scene;

  /// 正文、图标颜色（近黑或近白）。
  final Color foreground;

  /// 可安全用作按钮 / 进度条的封面主色（对 [scene] ≥ 3:1）。
  final Color primary;

  /// 封面辅色，用于渐变的第二层。
  final Color secondary;

  /// 画在 [primary] 上的图标颜色。
  final Color onPrimary;

  /// [foreground] 是浅色（背景应压暗）还是深色（背景应提亮）。
  final bool isLight;

  /// [palette] 为空时退回主题色。
  factory NowPlayingTint.resolve(PaletteDto? palette, ColorScheme scheme) {
    if (palette == null) {
      final foreground = scheme.onSurface;
      return NowPlayingTint(
        scene: scheme.surface,
        foreground: foreground,
        primary: scheme.primary,
        secondary: scheme.tertiary,
        onPrimary: scheme.onPrimary,
        isLight: foreground.computeLuminance() > 0.5,
      );
    }

    final rawPrimary = Color(0xFF000000 | (palette.primary & 0xFFFFFF));
    final rawSecondary = Color(0xFF000000 | (palette.secondary & 0xFFFFFF));
    // 以封面主色的明度选场景：暗封面配近白文字 + 深色压暗层，
    // 亮封面配近黑文字 + 浅色提亮层。
    final isLight = rawPrimary.computeLuminance() < 0.45;
    final scene = isLight
        ? Color.alphaBlend(const Color(0xE6000000), rawPrimary)
        : Color.alphaBlend(const Color(0xE6FFFFFF), rawPrimary);
    final primary = readableAccent(rawPrimary, scene);
    return NowPlayingTint(
      scene: scene,
      foreground: isLight ? _lightInk : _darkInk,
      primary: primary,
      secondary: readableAccent(rawSecondary, scene),
      onPrimary: readableOn(
        primary,
        preferred: Color(0xFF000000 | (palette.onPrimary & 0xFFFFFF)),
      ),
      isLight: isLight,
    );
  }
}
