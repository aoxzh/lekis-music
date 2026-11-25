import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/settings/app_updater_provider.dart';
import 'package:lekis/src/features/settings/release_notes_markdown.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('ReleaseNotesMarkdown renders headings, bullets, inline code, links and tables', (
    tester,
  ) async {
    final opened = <String>[];
    const sample = '''
月兔音乐 **0.6.1** 更新，问题请[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 新增

### 封面编辑

- 支持搜索与上传 `cover.jpg` 封面
- **仅限本地与 NAS** 自动补全

---

| 平台 | 文件 |
| --- | --- |
| Android | `lekis-0.6.1-android-arm64.apk` |
''';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ReleaseNotesMarkdown(
              data: sample,
              onOpenLink: (url) async => opened.add(url),
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('新增'), findsOneWidget);
    expect(find.textContaining('封面编辑'), findsOneWidget);
    expect(find.textContaining('cover.jpg'), findsOneWidget);
    expect(find.textContaining('lekis-0.6.1-android-arm64.apk'), findsOneWidget);
    expect(find.byType(Divider), findsOneWidget);
    expect(find.byType(Table), findsOneWidget);
    expect(find.text('## 新增'), findsNothing);
    expect(find.text('### 封面编辑'), findsNothing);
  });

  test('formatUpdateCheckDay formats YYYY-MM-DD with zero padding', () {
    expect(formatUpdateCheckDay(DateTime(2026, 3, 5)), '2026-03-05');
    expect(formatUpdateCheckDay(DateTime(2026, 11, 26)), '2026-11-26');
  });
}
