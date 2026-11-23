import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/library/library_page.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

const _english = [
  'Albums',
  'Artists',
  'Songs',
  'Genres',
  'Playlists',
  'Liked',
  'Folders',
];
const _chinese = ['专辑', '艺人', '歌曲', '流派', '歌单', '喜欢', '文件夹'];

Future<ProviderContainer> _mount(
  WidgetTester tester, {
  required double width,
  String language = 'en',
  double scale = 1,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: LekisLocale(
        locale: Locale(language),
        child: MaterialApp(
          theme: lekisLightTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const Scaffold(
            body: Align(alignment: Alignment.topCenter, child: LibraryHeader()),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void _expectFullLabel(WidgetTester tester, String label, double width) {
  final text = find.text(label).last;
  final paragraph = tester.renderObject<RenderParagraph>(text);
  expect(paragraph.didExceedMaxLines, isFalse, reason: label);
  final bounds = tester.getRect(text);
  expect(bounds.left, greaterThanOrEqualTo(0), reason: label);
  expect(bounds.right, lessThanOrEqualTo(width), reason: label);
  expect(bounds.top, greaterThanOrEqualTo(0), reason: label);
  expect(bounds.bottom, lessThanOrEqualTo(800), reason: label);
}

void main() {
  for (final language in ['en', 'zh']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('compact $language at ${scale}x exposes every category', (
        tester,
      ) async {
        final container = await _mount(
          tester,
          width: 320,
          language: language,
          scale: scale,
        );
        final selector = find.byKey(const ValueKey('library-category-select'));
        final tools = tester.getRect(
          find.byKey(const ValueKey('library-header-actions')),
        );
        expect(
          tester.getRect(selector).top,
          greaterThanOrEqualTo(tools.bottom),
        );
        expect(find.byType(SegmentedButton<LibrarySegment>), findsNothing);
        expect(find.byIcon(Icons.sort_rounded), findsOneWidget);
        expect(find.byIcon(Icons.view_carousel_rounded), findsOneWidget);
        await tester.tap(selector);
        await tester.pumpAndSettle();
        final labels = language == 'en' ? _english : _chinese;
        for (final label in labels) {
          _expectFullLabel(tester, label, 320);
        }
        await tester.tap(find.text(labels[3]).last);
        await tester.pumpAndSettle();
        expect(container.read(librarySegmentProvider), LibrarySegment.genres);
        expect(
          tester.widget<DropdownButton<LibrarySegment>>(selector).value,
          LibrarySegment.genres,
        );
        expect(find.byIcon(Icons.sort_rounded), findsNothing);
        expect(find.byIcon(Icons.view_carousel_rounded), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final width in [1440.0, 1920.0]) {
    testWidgets('wide $width keeps full segmented navigation in one row', (
      tester,
    ) async {
      final container = await _mount(tester, width: width);
      final segments = find.byType(SegmentedButton<LibrarySegment>);
      expect(segments, findsOneWidget);
      expect(
        find.byKey(const ValueKey('library-category-select')),
        findsNothing,
      );
      final title = tester.getRect(find.byKey(const ValueKey('library-title')));
      final navigation = tester.getRect(segments);
      final tools = tester.getRect(
        find.byKey(const ValueKey('library-header-actions')),
      );
      expect(title.center.dy, closeTo(navigation.center.dy, 1));
      expect(tools.center.dy, closeTo(navigation.center.dy, 1));
      expect(navigation.right, lessThanOrEqualTo(tools.left));
      for (final label in _english) {
        _expectFullLabel(tester, label, width);
      }
      await tester.tap(find.text('Songs'));
      await tester.pumpAndSettle();
      expect(container.read(librarySegmentProvider), LibrarySegment.songs);
      expect(
        tester.widget<SegmentedButton<LibrarySegment>>(segments).selected,
        {LibrarySegment.songs},
      );
      final sort = tester.widget<PopupMenuButton<TrackSortDto>>(
        find.byType(PopupMenuButton<TrackSortDto>),
      );
      expect(sort.itemBuilder(tester.element(segments)), hasLength(5));
      sort.onSelected!(TrackSortDto.mostPlayed);
      await tester.pumpAndSettle();
      expect(container.read(songSortProvider), TrackSortDto.mostPlayed);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('large text uses the complete menu on a desktop pane', (
    tester,
  ) async {
    await _mount(tester, width: 1200, scale: 2);
    expect(
      find.byKey(const ValueKey('library-category-select')),
      findsOneWidget,
    );
    expect(find.byType(SegmentedButton<LibrarySegment>), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
