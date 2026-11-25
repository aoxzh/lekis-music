import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/connect/connect_strings.dart';
import 'package:lekis/src/features/settings/connect_settings_section.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

import 'fake_connect_gateway.dart';

void main() {
  testWidgets(
    'a short pairing code stays editable and leading zeroes are preserved',
    (tester) async {
      String? code;
      await tester.pumpWidget(
        MaterialApp(
          theme: lekisDarkTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  code = await showPairingCodeDialog(
                    context,
                    device: fakeDevice(),
                  );
                },
                child: const Text('Pair'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Pair'));
      await tester.pumpAndSettle();
      final input = find.byType(TextField);
      await tester.enterText(input, '001');
      await tester.tap(find.text(ConnectStrings.pairConfirm));
      await tester.pumpAndSettle();
      expect(find.text('请输入 6 位配对码'), findsOneWidget);
      expect(find.text('001'), findsOneWidget);
      await tester.enterText(input, '001234');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(code, '001234');
    },
  );
}
