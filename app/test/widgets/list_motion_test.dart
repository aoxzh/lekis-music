import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/widgets/list_motion.dart';
import 'package:lekis/src/widgets/route_entrance.dart';
import 'package:material_ui/material_ui.dart';

class _Host extends StatefulWidget {
  const _Host({required this.items});

  final List<int> items;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with SingleTickerProviderStateMixin {
  late final ListMotion motion = ListMotion(vsync: this);

  @override
  void didUpdateWidget(_Host oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.items;
    final now = widget.items;
    motion.listChanged(
      old: (i) => old[i],
      oldLength: old.length,
      now: (i) => now[i],
      nowLength: now.length,
    );
  }

  @override
  void dispose() {
    motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (var i = 0; i < widget.items.length; i++)
        ListMotionRow(
          key: ValueKey(widget.items[i]),
          motion: motion,
          index: i,
          child: SizedBox(height: 40, child: Text('row ${widget.items[i]}')),
        ),
    ],
  );
}

Widget _app(List<int> items) => MaterialApp(
  home: Scaffold(body: _Host(items: items)),
);

double _dy(WidgetTester tester, int key) {
  final translation = find.ancestor(
    of: find.text('row $key'),
    matching: find.byType(FractionalTranslation),
  );
  if (translation.evaluate().isEmpty) return 0;
  return tester
      .widget<FractionalTranslation>(translation.first)
      .translation
      .dy;
}

double _opacity(WidgetTester tester, int key) {
  final opacity = find.ancestor(
    of: find.text('row $key'),
    matching: find.byType(Opacity),
  );
  if (opacity.evaluate().isEmpty) return 1;
  return tester.widget<Opacity>(opacity.first).opacity;
}

void main() {
  testWidgets('moved rows start at their old place and slide home', (
    tester,
  ) async {
    await tester.pumpWidget(_app([1, 2, 3]));
    await tester.pumpWidget(_app([2, 1, 3]));
    // First frame of the new order: drawn where they were.
    expect(_dy(tester, 2), 1);
    expect(_dy(tester, 1), -1);
    expect(_dy(tester, 3), 0);

    await tester.pump(); // post-frame: motion starts
    await tester.pump(const Duration(milliseconds: 100));
    expect(_dy(tester, 2), inExclusiveRange(0, 1));

    await tester.pumpAndSettle();
    expect(_dy(tester, 2), 0);
    expect(_dy(tester, 1), 0);
  });

  testWidgets('removal closes the gap, insertion fades in', (tester) async {
    await tester.pumpWidget(_app([1, 2, 3]));
    await tester.pumpWidget(_app([1, 3]));
    expect(_dy(tester, 3), 1);
    await tester.pumpAndSettle();

    await tester.pumpWidget(_app([1, 9, 3]));
    expect(_opacity(tester, 9), 0);
    expect(_dy(tester, 3), -1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(_opacity(tester, 9), inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(_opacity(tester, 9), 1);
  });

  test('occurrenceKeys tells repeats apart', () {
    expect(occurrenceKeys([5, 6, 5, 5], (v) => v), [5, 6, '5#1', '5#2']);
  });

  testWidgets('ListRowCollapse folds the row away and back', (tester) async {
    Widget host(bool collapsed) => MaterialApp(
      home: Column(
        children: [
          ListRowCollapse(
            collapsed: collapsed,
            child: const SizedBox(height: 50, child: Text('gone')),
          ),
        ],
      ),
    );
    await tester.pumpWidget(host(false));
    expect(tester.getSize(find.byType(ListRowCollapse)).height, 50);
    await tester.pumpWidget(host(true));
    await tester.pump(ListRowCollapse.duration ~/ 2);
    final mid = tester.getSize(find.byType(ListRowCollapse)).height;
    expect(mid, inExclusiveRange(0, 50));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(ListRowCollapse)).height, 0);
    await tester.pumpWidget(host(false));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(ListRowCollapse)).height, 50);
  });

  group('RouteEntrance', () {
    Future<void> push(WidgetTester tester, {bool reduce = false}) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
            child: child!,
          ),
          home: const SizedBox(),
        ),
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          allowSnapshotting: false,
          builder: (_) => const RouteEntrance(child: Text('title')),
        ),
      );
      await tester.pump();
    }

    double opacity(WidgetTester tester) {
      final fade = find.ancestor(
        of: find.text('title'),
        matching: find.byType(FadeTransition),
      );
      // The nearest FadeTransition is the entrance's own (inside the
      // route's).
      return tester.widget<FadeTransition>(fade.first).opacity.value;
    }

    testWidgets('content rises in after the route starts, then settles', (
      tester,
    ) async {
      await push(tester);
      await tester.pump(const Duration(milliseconds: 60));
      expect(opacity(tester), 0); // still before its interval
      await tester.pump(const Duration(milliseconds: 160));
      expect(opacity(tester), inExclusiveRange(0, 1));
      await tester.pumpAndSettle();
      expect(
        find.ancestor(of: find.text('title'), matching: find.byType(Transform)),
        findsNothing,
      );
    });

    testWidgets('reduced motion shows the content as is', (tester) async {
      await push(tester, reduce: true);
      await tester.pump(const Duration(milliseconds: 60));
      expect(
        find.ancestor(of: find.text('title'), matching: find.byType(Transform)),
        findsNothing,
      );
    });
  });
}
