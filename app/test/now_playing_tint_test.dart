import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/now_playing/now_playing_tint.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';

void main() {
  final scheme = lekisDarkTheme().colorScheme;

  test('bright spotlight swatch on a dark cover stays in light-ink mode', () {
    // Regression for YOASOBI Idol: bright yellow spotlight primary over a
    // dark purple concert backdrop previously flipped the whole page to black
    // text on dark purple.
    final palette = PaletteDto(
      primary: 0xFFFFEB3B,
      secondary: 0xFF6A1B9A,
      onPrimary: 0xFF000000,
      gradient: Uint32List.fromList([
        0xFF3E1C59,
        0xFF512DA8,
        0xFF28123D,
        0xFF4A148C,
      ]),
    );
    final tint = NowPlayingTint.resolve(palette, scheme);

    expect(tint.isLight, isTrue);
    expect(tint.foreground.computeLuminance(), greaterThan(0.8));
    expect(contrastRatio(tint.primary, tint.scene), greaterThanOrEqualTo(4.5));
    expect(
      tint.protectionOpacity,
      inInclusiveRange(
        LekisNowPlaying.protectionOpacity,
        LekisNowPlaying.protectionOpacityMax,
      ),
    );
  });

  test(
    'very bright covers receive stronger dark protection than dark ones',
    () {
      final dark = NowPlayingTint.resolve(
        PaletteDto(
          primary: 0xFF2B1940,
          secondary: 0xFF1A102B,
          onPrimary: 0xFFFFFFFF,
          gradient: Uint32List.fromList([0xFF1E1330, 0xFF2B1940]),
        ),
        scheme,
      );
      final bright = NowPlayingTint.resolve(
        PaletteDto(
          primary: 0xFFF5F5F5,
          secondary: 0xFFEAEAEA,
          onPrimary: 0xFF000000,
          gradient: Uint32List.fromList([0xFFFFFFFF, 0xFFF0F0F0]),
        ),
        scheme,
      );

      expect(bright.isLight, isTrue);
      expect(bright.protectionOpacity, greaterThan(dark.protectionOpacity));
      expect(
        bright.protectionOpacity,
        closeTo(LekisNowPlaying.protectionOpacityMax, 0.05),
      );
    },
  );
}
