import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/library/widgets/alphabet_index_bar.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  Widget wrap(Widget child) {
    return MaterialApp(
      theme: lekisDarkTheme(),
      home: Scaffold(body: Center(child: child)),
    );
  }

  testWidgets('hides when fewer than 2 letters exist', (tester) async {
    await tester.pumpWidget(
      wrap(
        AlphabetIndexBar(
          offsets: const [LetterOffsetDto(letter: 'A', offset: 0)],
          onSelect: (_) {},
        ),
      ),
    );
    expect(find.byKey(AlphabetIndexBar.railKey), findsNothing);
  });

  testWidgets('tap and drag selects target offsets and shows preview bubble', (
    tester,
  ) async {
    final selected = <int>[];
    const offsets = [
      LetterOffsetDto(letter: 'A', offset: 0),
      LetterOffsetDto(letter: 'B', offset: 12),
      LetterOffsetDto(letter: 'Z', offset: 95),
      LetterOffsetDto(letter: '#', offset: 110),
    ];

    await tester.pumpWidget(
      wrap(
        SizedBox(
          height: 300,
          child: AlphabetIndexBar(offsets: offsets, onSelect: selected.add),
        ),
      ),
    );

    final rail = find.byKey(AlphabetIndexBar.railKey);
    expect(rail, findsOneWidget);
    final rect = tester.getRect(rail);

    // 按住顶部选中 A，再拖到底部选中 #，过程中浮出预览气泡。
    final gesture = await tester.startGesture(
      Offset(rect.center.dx, rect.top + 4),
    );
    await tester.pump();
    expect(selected, [0]);
    expect(find.byKey(AlphabetIndexBar.bubbleKey), findsOneWidget);

    await gesture.moveTo(Offset(rect.center.dx, rect.bottom - 4));
    await tester.pump();
    expect(selected.last, 110);

    await gesture.up();
    await tester.pump();
    expect(find.byKey(AlphabetIndexBar.bubbleKey), findsNothing);
  });

  testWidgets('jumpScrollControllerToRow clamps to scroll bounds', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 200,
            child: ListView.builder(
              controller: controller,
              itemExtent: 50,
              itemCount: 20,
              itemBuilder: (_, i) => Text('row $i'),
            ),
          ),
        ),
      ),
    );

    jumpScrollControllerToRow(controller, rowIndex: 5, itemExtent: 50);
    expect(controller.offset, 250);

    jumpScrollControllerToRow(controller, rowIndex: 999, itemExtent: 50);
    expect(controller.offset, controller.position.maxScrollExtent);
  });
}
