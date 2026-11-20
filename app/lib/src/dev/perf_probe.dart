// Dev-only frame-time probe for Now Playing.
//
// Build with `--dart-define=LEKIS_PERF_PROBE=<output file>` (profile mode for
// meaningful numbers). After startup it scripts the scenarios below, records
// every FrameTiming, writes p50 / p90 / worst build and raster times per
// scenario to the file and exits. Without the define this is a pass-through
// and the scripted code is tree-shaken away.
//
//   open-close   open Now Playing (cover pane) and close it, 5 times
//   lyrics       Now Playing with the lyrics pane while playing, 12 s
//
// The lyrics scenario starts playback if a track is loaded and pauses it
// again at the end.

// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../features/now_playing/now_playing_providers.dart';
import '../features/now_playing/now_playing_route.dart';
import '../features/player/player_providers.dart';

const String _probeOut = String.fromEnvironment('LEKIS_PERF_PROBE');

/// Wraps [child]; runs the probe only when built with LEKIS_PERF_PROBE.
class PerfProbe extends ConsumerStatefulWidget {
  const PerfProbe({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<PerfProbe> createState() => _PerfProbeState();
}

class _PerfProbeState extends ConsumerState<PerfProbe> {
  final List<FrameTiming> _frames = [];
  final StringBuffer _report = StringBuffer();

  void _onTimings(List<FrameTiming> t) => _frames.addAll(t);

  @override
  void initState() {
    super.initState();
    if (_probeOut.isEmpty) return;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    unawaited(_run());
  }

  Future<void> _wait(int ms) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  Future<void> _measure(String name, Future<void> Function() body) async {
    await _wait(500);
    _frames.clear();
    await body();
    // Timings are reported in batches; give the last batch time to land.
    await _wait(300);
    _summarise(name, List.of(_frames));
  }

  void _summarise(String name, List<FrameTiming> frames) {
    double ms(Duration d) => d.inMicroseconds / 1000;
    String stats(List<double> v) {
      if (v.isEmpty) return 'n/a';
      v.sort();
      double p(double q) => v[((v.length - 1) * q).round()];
      return 'p50 ${p(0.5).toStringAsFixed(1)}  p90 ${p(0.9).toStringAsFixed(1)}'
          '  max ${v.last.toStringAsFixed(1)}';
    }

    final build = [for (final f in frames) ms(f.buildDuration)];
    final raster = [for (final f in frames) ms(f.rasterDuration)];
    final slow = frames.where((f) => ms(f.totalSpan) > 16.7).length;
    _report
      ..writeln('[$name] frames ${frames.length}, >16.7ms total: $slow')
      ..writeln('  build  ${stats(build)}')
      ..writeln('  raster ${stats(raster)}');
  }

  Future<void> _run() async {
    // Let startup, session restore and first artwork decode settle.
    await _wait(8000);
    final nav = Navigator.of(context, rootNavigator: true);
    final pane = ref.read(nowPlayingPaneProvider.notifier);
    final playback = ref.read(playerActionsProvider);
    // The probe's context sits above every route it pushes and stays
    // mounted, hence the file-level use_build_context_synchronously ignore.

    pane.set(NowPlayingPane.cover);
    await _measure('open-close', () async {
      for (var i = 0; i < 5; i++) {
        unawaited(openNowPlaying(context));
        await _wait(1500);
        nav.pop();
        await _wait(1200);
      }
    });

    final wasPlaying = ref.read(playbackProvider).isPlaying;
    pane.set(NowPlayingPane.lyrics);
    unawaited(openNowPlaying(context));
    await _wait(2000);
    if (!wasPlaying) playback.play();
    await _measure('lyrics', () => _wait(12000));
    if (!wasPlaying) playback.pause();
    nav.pop();

    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    File(_probeOut).writeAsStringSync(_report.toString());
    exit(0);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
