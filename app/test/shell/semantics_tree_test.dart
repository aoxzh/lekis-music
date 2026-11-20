// Every semantics update the framework sends must form a valid tree: each
// serialized node is the root (id 0) or is listed as a child by some node in
// the tree. The Windows / macOS accessibility bridge (ui::AXTree) rejects an
// update that breaks this ("N will not be in the tree and is not the new
// root"), freezes the accessibility tree and can later crash in
// flutter_windows.dll. See https://github.com/flutter/flutter/issues/190357.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/bridge/core_events.dart';
import 'package:lekis/src/features/player/player_bar.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

/// Mirrors what the engine's AccessibilityBridge does with each update.
class _MirrorTree {
  final Map<int, List<int>> children = {};
  final List<String> errors = [];

  void apply(Map<int, List<int>> update) {
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
}

class _FakePosition extends PositionController {
  @override
  int build() => 61000;
}

void main() {
  final binding = _RecordingBinding();

  testWidgets('desktop shell with the player bar sends a valid semantics tree',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final semantics = tester.ensureSemantics();

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

    // Same shape as AppShell: per-tab nested Navigators in an IndexedStack
    // and the desktop PlayerBar as the Scaffold's bottom bar.
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

    // Restoring the saved session enables the seek / volume sliders.
    (container.read(playbackProvider.notifier) as _FakePlayback).restore();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    semantics.dispose();
    expect(tester.takeException(), isNull);
    expect(binding.tree.errors, isEmpty);
  });
}
