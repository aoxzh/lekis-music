import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/sources/widgets/remote_folder_picker.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets(
    'back climbs one folder even during a load, then dismisses at root',
    (tester) async {
      final pending = Completer<SourceListingDto>();
      final visited = <String>[];
      final selected = <String?>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: lekisDarkTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                child: const Text('Browse'),
                onPressed: () async {
                  selected.add(
                    await showRemoteFolderPicker(
                      context,
                      load: (path) async {
                        visited.add(path);
                        if (path == 'A/B') return pending.future;
                        return SourceListingDto(
                          folders: [path.isEmpty ? 'A' : 'B'],
                          audioFiles: 0,
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Browse'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('B'));
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      pending.complete(
        const SourceListingDto(folders: ['stale'], audioFiles: 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('/A'), findsOneWidget);
      expect(find.text('stale'), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(visited, ['', 'A', 'A/B', 'A', '']);
      expect(selected, isEmpty);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(selected, [null]);
      await tester.tap(find.text('Browse'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('A'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('remote-folder-pick')));
      await tester.pumpAndSettle();
      expect(selected, [null, 'A']);
    },
  );
}
