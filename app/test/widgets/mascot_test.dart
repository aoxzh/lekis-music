import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/library/widgets/empty_state.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/brand_mark.dart';
import 'package:material_ui/material_ui.dart';

Future<void> _pump(WidgetTester tester, Widget child, ThemeData theme) =>
    tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(body: Center(child: child)),
      ),
    );

void main() {
  test('every pose has a bundled asset', () {
    for (final pose in LekisMascotPose.values) {
      expect(File(pose.asset).existsSync(), isTrue, reason: pose.asset);
    }
  });

  for (final (name, theme) in [
    ('light', lekisLightTheme()),
    ('dark', lekisDarkTheme()),
  ]) {
    testWidgets('renders each pose at the requested size ($name)', (
      tester,
    ) async {
      for (final pose in LekisMascotPose.values) {
        await _pump(tester, LekisMascot(pose: pose, size: 120), theme);
        final image = tester.widget<Image>(find.byType(Image));
        expect((image.image as ResizeImage).imageProvider, isA<AssetImage>());
        expect(
          ((image.image as ResizeImage).imageProvider as AssetImage).assetName,
          pose.asset,
        );
        expect(tester.getSize(find.byType(LekisMascot)), const Size(120, 120));
      }
    });
  }

  testWidgets('decorative by default, labelled on request', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      const LekisMascot(pose: LekisMascotPose.jumping),
      lekisDarkTheme(),
    );
    expect(find.bySemanticsLabel('Lekis'), findsNothing);

    await _pump(
      tester,
      const LekisMascot(
        pose: LekisMascotPose.standing,
        semanticLabel: 'Lekis mascot',
        excludeFromSemantics: false,
      ),
      lekisDarkTheme(),
    );
    expect(find.bySemanticsLabel('Lekis mascot'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('empty state swaps the brand mark for a mascot', (tester) async {
    await _pump(
      tester,
      const LekisEmptyState(title: 'Nothing', mascot: LekisMascotPose.thinking),
      lekisDarkTheme(),
    );
    expect(find.byKey(const ValueKey('empty-state.mascot')), findsOneWidget);
    expect(find.byType(LekisBrandMark), findsNothing);
    expect(
      tester.widget<LekisMascot>(find.byType(LekisMascot)).pose,
      LekisMascotPose.thinking,
    );
  });
}
