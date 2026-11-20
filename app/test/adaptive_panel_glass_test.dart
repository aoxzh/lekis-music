// 玻璃面板（播放页上的弹窗 / 底部表）的结构：拖拽把手必须画在玻璃里面。
//
// 回归：`showModalBottomSheet(showDragHandle: true)` 的把手是 BottomSheet 自己
// 画的，位于我们自家玻璃的上方。在播放页上玻璃背景是透明的，于是把手下面
// 空出一条没有被玻璃盖住的窄带，歌词糊在上面——看起来像渲染错位。

import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/adaptive_panel.dart';
import 'package:material_ui/material_ui.dart';

ThemeData _mediaTheme() => lekisOnMediaTheme(
  scene: const Color(0xFF201619),
  foreground: const Color(0xFFF8F5FC),
  accent: const Color(0xFFE0A0A0),
  onAccent: const Color(0xFF201619),
);

/// 打开 [open] 触发的那个面板 / 底部表。
Future<void> _pump(
  WidgetTester tester,
  ThemeData theme,
  Future<void> Function(BuildContext) open,
) async {
  tester.view.physicalSize = const Size(420, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () {
                open(context);
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

const _grabber = ValueKey('lekis-sheet.grabber');

void main() {
  testWidgets('播放页上的底部表：把手在玻璃里面', (tester) async {
    await _pump(
      tester,
      _mediaTheme(),
      (context) => showLekisSheet<void>(
        context,
        heightFactor: 0.5,
        builder: (_) => const SizedBox(height: 120),
      ),
    );

    expect(find.byKey(_grabber), findsOneWidget);
    // 把手在 BackdropFilter 内部：它和内容同属一块玻璃，上面没有透明窄带。
    expect(
      find.ancestor(
        of: find.byKey(_grabber),
        matching: find.byType(BackdropFilter),
      ),
      findsOneWidget,
    );
    expect(
      find.ancestor(of: find.byKey(_grabber), matching: find.byType(SafeArea)),
      findsWidgets,
    );
  });

  testWidgets('播放页上的编辑器底部表：同样自己画把手', (tester) async {
    await _pump(
      tester,
      _mediaTheme(),
      (context) => showLekisPanel<void>(
        context,
        dismissible: false,
        builder: (_) =>
            const LekisPanel(title: '编辑歌词', body: SizedBox(height: 40)),
      ),
    );

    expect(find.text('编辑歌词'), findsOneWidget);
    expect(find.byKey(_grabber), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byKey(_grabber),
        matching: find.byType(BackdropFilter),
      ),
      findsOneWidget,
    );
  });

  testWidgets('普通页面上的底部表仍然用框架的把手', (tester) async {
    await _pump(
      tester,
      lekisDarkTheme(),
      (context) => showLekisSheet<void>(
        context,
        heightFactor: 0.5,
        builder: (_) => const SizedBox(height: 120),
      ),
    );

    // 没有玻璃，就没有必要自己画：框架的把手画在不透明表头上，不会露出页面。
    expect(find.byKey(_grabber), findsNothing);
  });
}
