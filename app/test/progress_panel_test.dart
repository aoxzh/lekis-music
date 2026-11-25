import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/progress_dialog.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  for (final covered in [false, true]) {
    testWidgets(
      'closing progress preserves the current page (covered: $covered)',
      (tester) async {
        final navigator = GlobalKey<NavigatorState>();
        late Future<void> Function() close;
        final count = ValueNotifier(0);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 750);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            theme: lekisDarkTheme(),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  child: const Text('Start'),
                  onPressed: () => close = showProgressPanel(
                    context,
                    progress: count,
                    title: 'Saving',
                    builder: (done) => Text('$done'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Start'));
        if (covered) {
          await tester.pumpAndSettle();
          expect(
            tester.widget<BottomSheet>(find.byType(BottomSheet)).showDragHandle,
            isFalse,
          );
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(find.text('Saving'), findsOneWidget);
          unawaited(
            navigator.currentState!.push(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('Another page')),
              ),
            ),
          );
          await tester.pumpAndSettle();
        }
        final closed = close();
        expect(identical(closed, close()), isTrue);
        await tester.pumpAndSettle();
        await closed;
        if (covered) {
          expect(find.text('Another page'), findsOneWidget);
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
        }
        expect(find.text('Start'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
