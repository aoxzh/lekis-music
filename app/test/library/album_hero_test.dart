// Album cover flight: card → page, with an empty slot left behind and no
// flight at all under reduced motion.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/library/widgets/album_card.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/page_transitions.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

const _album = AlbumDto(
  id: 7,
  title: '月面',
  artistLine: '月兔',
  year: 2020,
  trackCount: 10,
);
const _tag = AlbumHeroTag(7, 'test');

Widget _app(GlobalKey<NavigatorState> navigator, {bool reduce = false}) =>
    ProviderScope(
      child: MaterialApp(
        navigatorKey: navigator,
        theme: lekisDarkTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
          child: child!,
        ),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox.square(
              dimension: 120,
              child: AlbumArtHero(album: _album, tag: _tag, radius: 8),
            ),
          ),
        ),
      ),
    );

Route<void> _page() => MaterialPageRoute<void>(
  builder: (_) => const Scaffold(
    body: Center(
      child: SizedBox.square(
        dimension: 280,
        child: AlbumArtHero(album: _album, tag: _tag, elevation: 6),
      ),
    ),
  ),
);

void main() {
  testWidgets('cover flies on a straight path, leaving an empty slot', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(_app(navigator));
    navigator.currentState!.push(_page());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    // Mid-flight: one cover in the overlay, two placeholders (grid slot and
    // landing spot) instead of holes.
    final heroes = tester.widgetList<Hero>(find.byType(Hero)).toList();
    expect(heroes, hasLength(2));
    for (final hero in heroes) {
      expect(hero.placeholderBuilder, isNotNull);
      final tween = hero.createRectTween!(
        Rect.zero,
        const Rect.fromLTWH(0, 0, 10, 10),
      );
      expect(tween.runtimeType, RectTween);
    }

    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(AlbumArtHero).last),
      const Size.square(280),
    );
  });

  testWidgets('reduced motion: no cover flight', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(_app(navigator, reduce: true));
    expect(find.byType(Hero), findsNothing);
    navigator.currentState!.push(_page());
    await tester.pumpAndSettle();
    expect(find.byType(Hero), findsNothing);
  });

  test('route motion is quicker than stock fade forwards', () {
    const builder = LekisPageTransitionsBuilder();
    expect(builder.transitionDuration, const Duration(milliseconds: 380));
    expect(
      builder.reverseTransitionDuration,
      const Duration(milliseconds: 320),
    );
    expect(builder.delegatedTransition, isNotNull);
  });
}
