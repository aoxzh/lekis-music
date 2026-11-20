// The floating mini player must publish exactly the band it occupies.
//
// The shell reserves that band through MediaQuery.padding.bottom so pages can
// clear it (scrollEndPadding, a page's own bottom padding). When the shell
// only reserved the card height, Cover Flow's position line sat underneath the
// player on the Fold5: the card is 56 dp, plus its 8 dp margin, plus the
// gesture inset it keeps clear of.

import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/player/mini_player.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

Widget _host({EdgeInsets padding = EdgeInsets.zero, EdgeInsets gesture = EdgeInsets.zero}) =>
    MediaQuery(
      data: MediaQueryData(
        size: const Size(829, 690),
        devicePixelRatio: 2.625,
        padding: padding,
        systemGestureInsets: gesture,
      ),
      child: Builder(
        builder: (context) => Text(
          '${MiniPlayer.bottomBandHeight(context)}',
          textDirection: TextDirection.ltr,
        ),
      ),
    );

void main() {
  testWidgets('band = card + margin + gesture inset', (tester) async {
    await tester.pumpWidget(_host(gesture: const EdgeInsets.only(bottom: 16)));
    expect(
      tester.widget<Text>(find.byType(Text)).data,
      '${LekisSizes.miniPlayerHeight + LekisSizes.miniPlayerMargin + 16}',
    );
  });

  testWidgets('a larger system padding wins over the gesture inset', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        padding: const EdgeInsets.only(bottom: 34),
        gesture: const EdgeInsets.only(bottom: 16),
      ),
    );
    expect(
      tester.widget<Text>(find.byType(Text)).data,
      '${LekisSizes.miniPlayerHeight + LekisSizes.miniPlayerMargin + 34}',
    );
  });
}
