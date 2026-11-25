import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/bridge/core_events.dart';
import 'package:lekis/src/features/home/home_page.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/sources/discovery_providers.dart';
import 'package:lekis/src/features/sources/sources_providers.dart';
import 'package:lekis/src/features/sources/strings.dart';
import 'package:lekis/src/features/sources/widgets/add_source.dart';
import 'package:lekis/src/features/sources/widgets/source_list.dart';
import 'package:lekis/src/features/sync/sync_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/shell/app_shell.dart';
import 'package:lekis/src/shell/nav_icon.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class _EmptySources extends SourcesNotifier {
  @override
  Future<List<SourceConfigDto>> build() async => [];
}

class _DisabledSync extends SyncController {
  @override
  Future<SyncUiState> build() async => const SyncUiState();
}

void main() {
  for (final wide in [false, true]) {
    testWidgets('Home opens Add Source on ${wide ? 'desktop' : 'phone'}', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(wide ? 1440 : 400, 900);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            coreEventSourceProvider.overrideWithValue(const Stream.empty()),
            libraryIsEmptyProvider.overrideWith((_) async => true),
            sourcesProvider.overrideWith(_EmptySources.new),
            syncControllerProvider.overrideWith(_DisabledSync.new),
            lanScannerProvider.overrideWithValue(() async => []),
          ],
          child: MaterialApp(theme: lekisDarkTheme(), home: const AppShell()),
        ),
      );
      await tester.pumpAndSettle();

      final homeAdd = find.descendant(
        of: find.byType(HomePage),
        matching: find.text(SourcesStrings.addSource),
      );
      await tester.tap(homeAdd);
      await tester.pumpAndSettle();
      expect(find.byType(SourceKindChooser), findsOneWidget);
      await tester.tap(find.text(SourcesStrings.kindLocal));
      await tester.pumpAndSettle();
      expect(find.byType(SourceForm), findsOneWidget);
      if (wide) {
        await tester.tap(
          find.descendant(
            of: find.byType(SourceForm),
            matching: find.byTooltip(SourcesStrings.back),
          ),
        );
      } else {
        expect(find.byType(BackButton), findsOneWidget);
        await tester.binding.handlePopRoute();
      }
      await tester.pumpAndSettle();
      expect(find.byType(SourceKindChooser), findsOneWidget);
      if (wide) {
        expect(find.byType(AddSourcePage), findsNothing);
        expect(
          tester.getTopLeft(find.byType(AddSourcePane)).dx,
          greaterThanOrEqualTo(tester.getTopRight(find.byType(SourceList)).dx),
        );
        await tester.tap(find.byTooltip(SourcesStrings.cancel));
      } else {
        expect(find.byType(AddSourcePage), findsOneWidget);
        expect(find.byType(SourceList), findsNothing);
        await tester.binding.handlePopRoute();
      }
      await tester.pumpAndSettle();
      expect(find.byType(SourceList), findsOneWidget);
      expect(find.byType(AddSourcePane), findsNothing);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(homeAdd, findsOneWidget);
      await tester.tap(
        find.byWidgetPredicate(
          (widget) =>
              widget is LekisNavIcon &&
              widget.destination == LekisDestination.sources,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SourceList), findsOneWidget);
      expect(find.byType(AddSourcePane), findsNothing);
      await tester.tap(
        find.descendant(
          of: find.byType(SourceList),
          matching: find.text(SourcesStrings.addSource),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SourceKindChooser), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(SourceList), findsOneWidget);
      expect(find.byType(AddSourcePane), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
