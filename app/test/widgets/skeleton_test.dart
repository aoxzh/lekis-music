import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/library/widgets/track_tile.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/skeleton.dart';
import 'package:material_ui/material_ui.dart';

Widget _app(Widget child, {bool reduceMotion = false, bool dark = false}) =>
    MaterialApp(
      theme: dark ? lekisDarkTheme() : lekisLightTheme(),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(disableAnimations: reduceMotion),
          child: Scaffold(body: child),
        ),
      ),
    );

int get _transientCallbacks => SchedulerBinding.instance.transientCallbackCount;

void main() {
  testWidgets('one shimmer ticker sweeps all boxes, and stops without boxes', (
    tester,
  ) async {
    final show = ValueNotifier(true);
    await tester.pumpWidget(
      _app(
        LekisShimmer(
          child: ValueListenableBuilder<bool>(
            valueListenable: show,
            builder: (_, visible, _) => visible
                ? Column(
                    children: [
                      for (var i = 0; i < 6; i++) SkeletonTrackTile(index: i),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ),
    );
    expect(tester.hasRunningAnimations, isTrue);
    // Many boxes, one scope → one ticker.
    expect(_transientCallbacks, 1);

    show.value = false;
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('reduced motion: skeleton is static (no ticker running)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const LekisShimmer(
          child: Column(
            children: [
              SkeletonTrackTile(),
              SizedBox(width: 160, child: SkeletonAlbumCard()),
              LekisSkeleton.circle(size: 48),
            ],
          ),
        ),
        reduceMotion: true,
      ),
    );
    expect(find.byType(LekisSkeleton), findsWidgets);
    expect(tester.hasRunningAnimations, isFalse);
    expect(_transientCallbacks, 0);
  });

  testWidgets('skeleton rows keep the real row geometry (light and dark)', (
    tester,
  ) async {
    for (final dark in [false, true]) {
      await tester.pumpWidget(
        _app(
          const LekisShimmer(
            child: Column(
              children: [
                SkeletonTrackTile(key: ValueKey('row')),
                SizedBox(
                  width: 160,
                  child: SkeletonAlbumCard(key: ValueKey('card')),
                ),
              ],
            ),
          ),
          dark: dark,
          reduceMotion: true,
        ),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('row'))).height,
        TrackTile.extent,
      );
      final card = tester.getSize(find.byKey(const ValueKey('card')));
      expect(card.width, 160);
      // Cover + text block, never taller than the real card cell.
      expect(card.height, greaterThan(160));
      expect(card.height, lessThanOrEqualTo(160 + 60));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('fast data never shows the skeleton', (tester) async {
    final loading = ValueNotifier(true);
    await tester.pumpWidget(
      _app(
        ValueListenableBuilder<bool>(
          valueListenable: loading,
          builder: (_, isLoading, _) => LekisLoadingSwitcher(
            loading: isLoading,
            skeleton: const SkeletonTrackTile(),
            child: const Text('content'),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byType(SkeletonTrackTile), findsNothing);
    loading.value = false;
    await tester.pump();
    expect(find.text('content'), findsOneWidget);
    // Shown directly: no cross-fade running.
    expect(tester.hasRunningAnimations, isFalse);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(SkeletonTrackTile), findsNothing);
  });

  testWidgets('slow data: skeleton after the delay, then a cross-fade once', (
    tester,
  ) async {
    final loading = ValueNotifier(true);
    final label = ValueNotifier('content');
    await tester.pumpWidget(
      _app(
        ValueListenableBuilder<bool>(
          valueListenable: loading,
          builder: (_, isLoading, _) => ValueListenableBuilder<String>(
            valueListenable: label,
            builder: (_, text, _) => LekisLoadingSwitcher(
              loading: isLoading,
              skeleton: const SkeletonTrackTile(),
              child: Text(text),
            ),
          ),
        ),
      ),
    );
    await tester.pump(LekisMotion.skeletonDelay);
    await tester.pump();
    expect(find.byType(SkeletonTrackTile), findsOneWidget);
    // Let the skeleton fade in fully and shimmer for a while.
    await tester.pump(const Duration(milliseconds: 600));

    loading.value = false;
    await tester.pump();
    // Both present while cross-fading.
    expect(find.text('content'), findsOneWidget);
    expect(find.byType(SkeletonTrackTile), findsOneWidget);
    // Settles: the fade ends and the shimmer ticker stops with the skeleton.
    await tester.pumpAndSettle();
    expect(find.byType(SkeletonTrackTile), findsNothing);
    expect(tester.hasRunningAnimations, isFalse);

    // A refresh of shown content swaps in place, no fade.
    label.value = 'refreshed';
    await tester.pump();
    expect(find.text('refreshed'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
  });
}
