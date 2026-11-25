import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/platform/ui_profile.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/action_menu.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  for (final profile in [UiProfile.mobile, UiProfile.desktop]) {
    testWidgets('long action list is reachable on ${profile.formFactor.name}', (
      tester,
    ) async {
      UiProfile.debugOverride = profile;
      addTearDown(() => UiProfile.debugOverride = null);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 480);
      addTearDown(tester.view.reset);
      int? selected;
      await tester.pumpWidget(
        MaterialApp(
          theme: lekisLightTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.5)),
            child: child!,
          ),
          home: Scaffold(
            body: Center(
              child: LekisActionMenuButton<int>(
                title: 'Playlist',
                tooltip: 'Actions',
                actions: () => [
                  for (int i = 0; i < 12; i++)
                    LekisMenuAction(
                      i,
                      Icons.queue_music_rounded,
                      'Action $i',
                      enabled: i > 0,
                      selected: i == 1,
                    ),
                ],
                onSelected: (value) => selected = value,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Actions'));
      await tester.pumpAndSettle();
      expect(
        find.byType(BottomSheet),
        profile.prefersSheets ? findsOneWidget : findsNothing,
      );
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      await tester.tap(find.text('Action 0'));
      await tester.pumpAndSettle();
      expect(selected, isNull);
      await tester.scrollUntilVisible(find.text('Action 11'), 160);
      await tester.tap(find.text('Action 11'));
      await tester.pumpAndSettle();
      expect(selected, 11);
      expect(find.text('Action 0'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
