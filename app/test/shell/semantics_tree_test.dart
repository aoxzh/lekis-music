// Every semantics update the framework sends must be one the desktop
// accessibility bridge (ui::AXTree) accepts:
// * each serialized node is the root (id 0) or is listed as a child by some
//   node in the tree ("N will not be in the tree and is not the new root",
//   https://github.com/flutter/flutter/issues/190357);
// * a node that moves to a new parent is itself part of the update
//   (otherwise "Nodes left pending by the update").
// Once AXTree rejects one update it rejects all later ones, and on Windows
// flutter_windows.dll then crashes (0xC0000005). Before LekisSlider dropped
// Material's slider semantics, restoring a saved session in the desktop
// player bar moved the seek slider's value-indicator node this way.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/bridge/core_events.dart';
import 'package:lekis/src/features/player/player_bar.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/lekis_slider.dart';
import 'package:material_ui/material_ui.dart';

/// Mirrors what the engine's AccessibilityBridge does with each update.
class _MirrorTree {
  final Map<int, List<int>> children = {};
  final List<String> errors = [];

  void reset() {
    children.clear();
    errors.clear();
  }

  void apply(Map<int, List<int>> update) {
    // ui::AXTree cannot move a node unless the node itself is in the update:
    // the bridge first detaches it from its old parent, which deletes it, and
    // then the new parent lists an id nobody provides ("Nodes left pending by
    // the update"). From then on every update fails.
    final parentOf = <int, int>{
      for (final e in children.entries)
        for (final c in e.value) c: e.key,
    };
    for (final e in update.entries) {
      for (final c in e.value) {
        final oldParent = parentOf[c];
        if (oldParent != null &&
            oldParent != e.key &&
            !update.containsKey(c)) {
          errors.add(
            '$c moved from $oldParent to ${e.key} without an update of its '
            'own (Nodes left pending by the update)',
          );
        }
      }
    }
    children.addAll(update);
    final reachable = <int>{};
    void walk(int id) {
      if (!reachable.add(id)) return;
      for (final c in children[id] ?? const <int>[]) {
        walk(c);
      }
    }

    walk(0);
    for (final id in update.keys) {
      if (!reachable.contains(id)) {
        errors.add('$id will not be in the tree and is not the new root');
      }
    }
    // Nodes no longer reachable are dropped, like AXTree does.
    children.removeWhere((id, _) => !reachable.contains(id));
  }
}

class _RecordingBuilder implements ui.SemanticsUpdateBuilder {
  _RecordingBuilder(this._real, this._tree);

  final ui.SemanticsUpdateBuilder _real;
  final _MirrorTree _tree;
  final Map<int, List<int>> _nodes = {};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final args = invocation.namedArguments;
    if (invocation.memberName == #updateNode) {
      final id = args[#id] as int;
      final kids = args[#childrenInTraversalOrder] as Int32List;
      _nodes[id] = kids.toList();
      return Function.apply(_real.updateNode, const [], args);
    }
    if (invocation.memberName == #updateCustomAction) {
      return Function.apply(_real.updateCustomAction, const [], args);
    }
    if (invocation.memberName == #build) {
      _tree.apply(_nodes);
      return _real.build();
    }
    return super.noSuchMethod(invocation);
  }
}

class _RecordingBinding extends AutomatedTestWidgetsFlutterBinding {
  final _MirrorTree tree = _MirrorTree();

  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() =>
      _RecordingBuilder(super.createSemanticsUpdateBuilder(), tree);
}

class _FakePlayback extends PlaybackController {
  @override
  PlaybackUiState build() => const PlaybackUiState();

  void restore() => state = const PlaybackUiState(
    state: PlaybackStateDto.paused,
    trackId: 1,
    durationMs: 240000,
    queueLength: 3,
    queueIndex: 0,
  );

  void play() => state = state.copyWith(state: PlaybackStateDto.playing);
}

class _FakePosition extends PositionController {
  @override
  int build() => 61000;
}

/// The desktop shell around [PlayerBar]: per-tab nested Navigators in an
/// IndexedStack and the bar as the Scaffold's bottom bar, like AppShell.
Future<ProviderContainer> _pumpDesktopShell(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 820);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [
      coreEventsProvider.overrideWith((ref) => const Stream.empty()),
      playbackProvider.overrideWith(_FakePlayback.new),
      positionProvider.overrideWith(_FakePosition.new),
      currentTrackProvider.overrideWith((ref) async => null),
      currentArtworkProvider.overrideWith((ref) async => null),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: lekisDarkTheme(),
        home: Scaffold(
          body: IndexedStack(
            sizing: StackFit.expand,
            children: [
              for (var i = 0; i < 3; i++)
                Navigator(
                  onGenerateRoute: (settings) => MaterialPageRoute<void>(
                    settings: settings,
                    builder: (_) => Center(child: Text('tab $i')),
                  ),
                ),
            ],
          ),
          bottomNavigationBar: const PlayerBar(),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
  return container;
}

_FakePlayback _playback(ProviderContainer c) =>
    c.read(playbackProvider.notifier) as _FakePlayback;

void main() {
  final binding = _RecordingBinding();
  setUp(binding.tree.reset);

  testWidgets('restoring a saved session in the desktop player bar keeps the '
      'semantics tree valid', (tester) async {
    final semantics = tester.ensureSemantics();
    final container = await _pumpDesktopShell(tester);

    // Restoring the saved session enables the seek / volume sliders.
    _playback(container).restore();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    semantics.dispose();
    expect(tester.takeException(), isNull);
    expect(binding.tree.errors, isEmpty);
  });

  testWidgets('session restore and play / pause while a player bar tooltip '
      'is showing keep the semantics tree valid', (tester) async {
    final semantics = tester.ensureSemantics();
    final container = await _pumpDesktopShell(tester);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byTooltip('播放')));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('播放'), findsWidgets, reason: 'tooltip is showing');

    _playback(container).restore();
    await tester.pump(const Duration(milliseconds: 500));
    _playback(container).play();
    await tester.pump(const Duration(milliseconds: 500));
    await mouse.moveTo(Offset.zero);
    await tester.pump(const Duration(seconds: 1));

    semantics.dispose();
    expect(tester.takeException(), isNull);
    expect(binding.tree.errors, isEmpty);
  });

  testWidgets('LekisSlider is one slider node that can be adjusted', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var value = 0.5;
    final changes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: lekisDarkTheme(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => LekisSlider(
              value: value,
              semanticLabel: 'Volume',
              semanticFormatterCallback: (v) => '${(v * 100).round()}%',
              onChangeStart: (_) => changes.add('start'),
              onChanged: (v) => setState(() => value = v),
              onChangeEnd: (_) => changes.add('end'),
            ),
          ),
        ),
      ),
    );

    expect(
      tester.getSemantics(find.byType(LekisSlider)),
      isSemantics(
        isSlider: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        label: 'Volume',
        value: '50%',
        increasedValue: '55%',
        decreasedValue: '45%',
        hasIncreaseAction: true,
        hasDecreaseAction: true,
      ),
    );
    // Material's own slider node (and its value-indicator portal) is gone.
    expect(find.semantics.byFlag(ui.SemanticsFlag.isSlider), findsOne);

    tester.semantics.increase(find.semantics.byLabel('Volume'));
    await tester.pump();
    expect(value, closeTo(0.55, 1e-9));
    expect(changes, ['start', 'end']);

    semantics.dispose();
    expect(binding.tree.errors, isEmpty);
  });
}
