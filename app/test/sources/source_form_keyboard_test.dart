// The add-source form with the keyboard up.
//
// Regression guard for the Fold5 report "adding a source, tapping the host
// field blanked the whole screen": the shell's Scaffold must not shrink for
// the keyboard (its body already carries the inset, so the page's own
// Scaffold would subtract it twice and collapse to nothing), and the form
// itself has to stay usable — scrollable, with the focused field reachable —
// when only a fraction of the window is left.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/sources/source_kind_info.dart';
import 'package:lekis/src/features/sources/strings.dart';
import 'package:lekis/src/features/sources/widgets/add_source.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

/// Fold5 inner screen, keyboard up: 829 x 690 dp with a 320 dp keyboard.
Widget _page({required double keyboard}) => ProviderScope(
  child: MediaQuery(
    data: MediaQueryData(
      size: const Size(829, 690),
      devicePixelRatio: 2.625,
      viewInsets: EdgeInsets.only(bottom: keyboard),
    ),
    child: MaterialApp(
      theme: lekisDarkTheme(),
      home: const AddSourcePage(),
    ),
  ),
);

void main() {
  testWidgets('host field stays reachable with the keyboard up', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(829, 690);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_page(keyboard: 0));
    await tester.pumpAndSettle();

    // Network group -> SMB.
    await tester.tap(find.text(SourceKindDto.smb.label));
    await tester.pumpAndSettle();
    expect(find.text(SourcesStrings.fieldHost), findsOneWidget);

    // Focus the host field the way the phone does, then raise the keyboard.
    await tester.tap(find.text(SourcesStrings.fieldHost));
    await tester.pumpWidget(_page(keyboard: 320));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // The form is still on screen, not blanked by a double keyboard inset.
    expect(find.text(SourcesStrings.fieldHost), findsOneWidget);
    // And it can still be scrolled to reach the actions at the bottom.
    await tester.drag(find.byType(ListView).first, const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text(SourcesStrings.testAndSave), findsOneWidget);
  });
}
