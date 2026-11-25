import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/settings/widgets/settings_widgets.dart';
import 'package:lekis/src/features/sources/common.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

const _rowKey = ValueKey('row');

Widget _app() => MaterialApp(theme: lekisDarkTheme(), home: const _Root());

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: '设置',
    body: SettingsListView(
      children: [
        SettingsSection(
          title: '播放',
          children: [
            SettingsTile(
              key: _rowKey,
              icon: Icons.storage_outlined,
              title: '音源',
              subtitle: const Text('管理音源'),
              chevron: true,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SettingsScaffold(
                    title: '诊断日志',
                    body: SizedBox.shrink(),
                  ),
                ),
              ),
            ),
            SettingsSwitchTile(
              icon: Icons.linear_scale_rounded,
              title: '无缝播放',
              value: true,
              onChanged: (_) {},
            ),
          ],
        ),
      ],
    ),
  );
}

void main() {
  testWidgets(
    'mobile selector distinguishes dismissing from choosing the system default',
    (tester) async {
      final values = <String?>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: lekisDarkTheme(),
          home: Scaffold(
            body: SettingsSelectField<String?>(
              title: 'Output',
              icon: Icons.speaker,
              value: 'USB',
              choices: const [
                SettingsChoice(null, 'System'),
                SettingsChoice('USB', 'USB'),
              ],
              onChanged: values.add,
            ),
          ),
        ),
      );
      await tester.tap(find.text('USB'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(values, isEmpty);
      await tester.tap(find.text('USB'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('System'));
      await tester.pumpAndSettle();
      expect(values, [null]);
    },
  );

  testWidgets('top-level page: title at the page gutter, no back button', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app());

    expect(find.byType(BackButton), findsNothing);
    expect(find.byType(AppBar), findsNothing);
    final context = tester.element(find.byType(SettingsListView));
    final gutter = pageGutterOf(context);
    expect(tester.getTopLeft(find.text('设置')).dx, gutter);
    // 分组左边缘与标题对齐，小节标题也在同一条线上。
    // Flat rows bleed by their own inset so the row content lands on the
    // gutter while the ripple spans the row.
    expect(
      tester.getTopLeft(find.byType(SettingsGroup)).dx,
      gutter - settingsRowInset,
    );
    expect(tester.getTopLeft(find.text('播放')).dx, gutter);
    expect(
      tester.getSize(find.byKey(_rowKey)).height,
      greaterThanOrEqualTo(LekisSizes.touchTargetMin),
    );
  });

  testWidgets('pushed mobile pages use a compact header with a back button', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app());

    final theme = Theme.of(tester.element(find.text('设置')));
    expect(
      tester.widget<Text>(find.text('设置')).style?.fontSize,
      theme.textTheme.headlineMedium?.fontSize,
    );
    await tester.tap(find.byKey(_rowKey));
    await tester.pumpAndSettle();

    expect(find.byType(BackButton), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
    expect(
      tester.widget<Text>(find.text('诊断日志')).style,
      theme.textTheme.titleLarge,
    );

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('诊断日志'), findsNothing);
  });

  testWidgets('wide windows keep the content column narrow and left aligned', (
    tester,
  ) async {
    const size = Size(2000, 1000);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app());

    final context = tester.element(find.byType(SettingsListView));
    final gutter = pageGutterOf(context);
    final group = tester.getRect(find.byType(SettingsGroup));
    expect(group.left, gutter - settingsRowInset);
    expect(group.width, featureMaxContentWidth + settingsRowInset * 2);
  });

  testWidgets('switch rows toggle from anywhere on the row', (tester) async {
    var value = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: lekisLightTheme(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SettingsSwitchTile(
              icon: Icons.linear_scale_rounded,
              title: '无缝播放',
              value: value,
              onChanged: (v) => setState(() => value = v),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('无缝播放'));
    await tester.pump();
    expect(value, isTrue);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });
}
