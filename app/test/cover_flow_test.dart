// 封面流：居中的封面最大，两侧旋转；点侧边封面把它换到中间。

import 'dart:ui' show Tristate;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/library/cover_flow_page.dart';
import 'package:lekis/src/features/library/library_page.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

const _total = 40;

AlbumDto _album(int index) => AlbumDto(
  id: index,
  title: '专辑 $index',
  artistLine: '月兔',
  year: 2020,
  trackCount: 10,
);

/// 分页的假资料库；封面为空，测试不需要核心。
ProviderContainer _container() {
  final list = PagedList<AlbumDto>(
    pageSize: 20,
    count: () async => _total,
    fetch: (offset, limit) async {
      final end = (offset + limit).clamp(0, _total);
      return [for (var i = offset; i < end; i++) _album(i)];
    },
  );
  final container = ProviderContainer(
    overrides: [
      albumsListProvider.overrideWith((ref, sort) => list),
      albumArtworkProvider.overrideWith((ref, albumId) async => null),
    ],
  );
  addTearDown(list.dispose);
  addTearDown(container.dispose);
  return container;
}

Widget _app(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(theme: lekisDarkTheme(), home: const CoverFlowPage()),
);

Finder _cover(int index) => find.byKey(ValueKey('cover-flow.cover-$index'));

String _centredTitle(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('cover-flow.title'))).data!;

void main() {
  testWidgets('centres one cover and shows its album', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(_container()));
    await tester.pumpAndSettle();

    expect(find.byType(CoverFlowPage), findsOneWidget);
    expect(_cover(0), findsOneWidget);
    expect(_cover(1), findsOneWidget);
    expect(_centredTitle(tester), '专辑 0');
    expect(find.text('1 / 40'), findsOneWidget);

    // 居中的封面正面朝前：投影后比两侧旋转过的宽。
    final centred = tester.getRect(_cover(0));
    final neighbour = tester.getRect(_cover(1));
    expect(centred.width, greaterThan(neighbour.width));

    // 每张封面都是一个带专辑名的按钮，居中的那张是选中态。
    final centredNode = tester.getSemantics(_cover(0)).getSemanticsData();
    expect(centredNode.label, '专辑 0');
    expect(centredNode.flagsCollection.isButton, isTrue);
    expect(centredNode.flagsCollection.isSelected, Tristate.isTrue);
    final sideNode = tester.getSemantics(_cover(1)).getSemanticsData();
    expect(sideNode.label, '专辑 1');
    expect(sideNode.flagsCollection.isSelected, Tristate.isFalse);

    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a side cover recentres it', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(_container()));
    await tester.pumpAndSettle();

    await tester.tap(_cover(1));
    await tester.pumpAndSettle();

    expect(_centredTitle(tester), '专辑 1');
    expect(find.text('2 / 40'), findsOneWidget);
    expect(
      tester
          .getSemantics(_cover(1))
          .getSemanticsData()
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a slow drag moves one cover and snaps to it', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(_container()));
    await tester.pumpAndSettle();

    // 一格的距离从两张封面的投影中心量出来：拖这么远正好翻一张。
    final start = tester.getCenter(_cover(0));
    final slot = tester.getCenter(_cover(1)).dx - start.dx;
    final gesture = await tester.startGesture(start);
    const steps = 10;
    for (var i = 0; i < steps; i++) {
      await gesture.moveBy(Offset(-slot / steps, 0));
      await tester.pump(const Duration(milliseconds: 150));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(_centredTitle(tester), '专辑 1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the albums header opens the cover flow', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: _container(),
        child: MaterialApp(theme: lekisDarkTheme(), home: const LibraryPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('封面流'));
    await tester.pumpAndSettle();

    expect(find.byType(CoverFlowPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fits a phone and a desktop window without overflow', (
    tester,
  ) async {
    for (final size in const [Size(400, 800), Size(1200, 800)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;

      await tester.pumpWidget(_app(_container()));
      await tester.pumpAndSettle();

      expect(find.byType(CoverFlowPage), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '$size must not overflow');
    }
    addTearDown(tester.view.reset);
  });
}
