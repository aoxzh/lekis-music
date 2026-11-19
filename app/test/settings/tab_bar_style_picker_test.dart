import 'dart:ui' show Tristate;

import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/settings/tab_bar_style_picker.dart';
import 'package:lekis/src/shell/tab_bar_style.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class _PickerHarness extends StatefulWidget {
  const _PickerHarness();

  @override
  State<_PickerHarness> createState() => _PickerHarnessState();
}

class _PickerHarnessState extends State<_PickerHarness> {
  TabBarStyle _selected = TabBarStyle.liquid;

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: lekisLightTheme(),
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(LekisSpacing.lg),
        child: TabBarStylePicker(
          selected: _selected,
          onChanged: (style) => setState(() => _selected = style),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('picker shows both choices with selectable semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(const _PickerHarness());

    expect(find.text('液态玻璃'), findsOneWidget);
    expect(find.text('扁平'), findsOneWidget);

    bool selected(TabBarStyle style) =>
        tester
            .getSemantics(find.byKey(TabBarStylePicker.styleKey(style)))
            .flagsCollection
            .isSelected ==
        Tristate.isTrue;

    expect(selected(TabBarStyle.liquid), isTrue);
    expect(selected(TabBarStyle.flat), isFalse);

    await tester.tap(find.byKey(TabBarStylePicker.styleKey(TabBarStyle.flat)));
    await tester.pump();

    expect(selected(TabBarStyle.liquid), isFalse);
    expect(selected(TabBarStyle.flat), isTrue);
    semantics.dispose();
  });
}
