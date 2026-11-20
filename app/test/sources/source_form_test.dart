import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/sources/source_kind_info.dart';
import 'package:lekis/src/features/sources/strings.dart';
import 'package:lekis/src/features/sources/widgets/add_source.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

Widget _form(SourceKindDto kind) => ProviderScope(
  child: MaterialApp(
    theme: lekisDarkTheme(),
    home: Scaffold(
      body: SourceForm(kind: kind, onBack: () {}, onDone: (_) {}),
    ),
  ),
);

void main() {
  test('only remote kinds count as network sources', () {
    expect(SourceKindDto.local.isNetwork, isFalse);
    expect(SourceKindDto.radio.isNetwork, isFalse);
    expect(SourceKindDto.plugin.isNetwork, isFalse);
    for (final k in [
      SourceKindDto.smb,
      SourceKindDto.webDav,
      SourceKindDto.nfs,
      SourceKindDto.sftp,
      SourceKindDto.openSubsonic,
      SourceKindDto.jellyfin,
      SourceKindDto.emby,
      SourceKindDto.plex,
    ]) {
      expect(k.isNetwork, isTrue, reason: k.name);
    }
  });

  testWidgets('local folder form has no test-connection or network fields', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_form(SourceKindDto.local));

    expect(find.byKey(const ValueKey('source-form-test')), findsNothing);
    expect(find.text(SourcesStrings.testConnection), findsNothing);
    expect(find.text(SourcesStrings.moreOptions), findsNothing);
    expect(find.text(SourcesStrings.addAndScan), findsOneWidget);
    expect(find.text(SourcesStrings.pickFolder), findsOneWidget);
  });

  testWidgets('SMB form keeps test-connection and alternate addresses', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_form(SourceKindDto.smb));

    expect(find.byKey(const ValueKey('source-form-test')), findsOneWidget);
    expect(find.text(SourcesStrings.testAndSave), findsOneWidget);
    expect(find.text(SourcesStrings.moreOptions), findsOneWidget);
    // 默认收起，展开后才看到备用地址输入框。
    expect(find.text(SourcesStrings.fieldAlternates), findsNothing);
    await tester.tap(find.text(SourcesStrings.moreOptions));
    await tester.pumpAndSettle();
    expect(find.text(SourcesStrings.fieldAlternates), findsOneWidget);
  });

  testWidgets('chooser puts the local folder first and marks it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: lekisDarkTheme(),
          home: Scaffold(
            body: SourceKindChooser(onChoose: (_) {}, onDiscovered: (_) {}),
          ),
        ),
      ),
    );

    final local = tester.getTopLeft(
      find.byKey(const ValueKey('add-source-local')),
    );
    final smb = tester.getTopLeft(find.text(SourcesStrings.kindSmb));
    expect(local.dy, lessThan(smb.dy));
    expect(find.text(SourcesStrings.recommended), findsOneWidget);
  });
}
