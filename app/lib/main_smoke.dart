// Phase 0 冒烟测试入口：不依赖任何页面，只验证"核心启动 → 扫描 → 播放 → 进度事件"整条链路。
//
// 运行：flutter run -t lib/main_smoke.dart --dart-define=MUSIC_DIR=<音乐目录>
// 不传 MUSIC_DIR 时：Android 用 /storage/emulated/0/Music，桌面用 ~/Music。
//
// CI 用：加 `--dart-define=SMOKE_OK_EXIT=true`，播放进度到 1.5 秒后打印 SMOKE_OK 并退出 0；
// 加 `--dart-define=SMOKE_LOG=<文件>` 可把日志写进文件（Windows release 没有控制台）。

import 'dart:async';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:material_ui/material_ui.dart';

import 'package:lekis/src/bridge/core_init.dart';
import 'package:lekis/src/rust/api/core.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/rust/frb_generated.dart';

/// 必须是顶层 const，否则 release 下 `fromEnvironment` 读不到 `--dart-define`。
const bool _smokeOkExit = bool.fromEnvironment('SMOKE_OK_EXIT');
const bool _smokeExclusive = bool.fromEnvironment('SMOKE_EXCLUSIVE');
const String _smokeLogPath = String.fromEnvironment('SMOKE_LOG');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const MaterialApp(home: SmokePage()));
}

String _musicDir() {
  const fromDefine = String.fromEnvironment('MUSIC_DIR');
  if (fromDefine.isNotEmpty) return fromDefine;
  if (Platform.isAndroid) return '/storage/emulated/0/Music';
  final home =
      Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      '.';
  return '$home${Platform.pathSeparator}Music';
}

class SmokePage extends StatefulWidget {
  const SmokePage({super.key});

  @override
  State<SmokePage> createState() => _SmokePageState();
}

class _SmokePageState extends State<SmokePage> {
  final _log = <String>[];
  String _status = '';
  StreamSubscription<CoreEventDto>? _sub;
  Completer<void>? _scanDone;
  int _lastPositionSecond = -1;
  bool _exiting = false;
  bool _loggedOutputMode = false;

  void _add(String line) {
    // ignore: avoid_print
    print('[smoke] $line');
    _writeLog(line);
    setState(() => _log.add(line));
  }

  /// 把冒烟结果同时写进文件：Windows release EXE 没有控制台，CI 只能靠文件读结果。
  static void _writeLog(String line) {
    if (_smokeLogPath.isEmpty) return;
    try {
      File(_smokeLogPath)
          .writeAsStringSync('[smoke] $line\n', mode: FileMode.append);
    } on Object {
      // 日志失败不能影响冒烟流程。
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    final sw = Stopwatch()..start();
    try {
      await initLekisCore();
      _add(
        'core ${coreVersion()} up in ${sw.elapsedMilliseconds} ms, device ${deviceId()}',
      );

      _sub = coreEvents().listen((e) {
        switch (e) {
          case CoreEventDto_PositionTick(:final positionMs):
            final position = positionMs.toInt();
            setState(() => _status = 'position ${position}ms');
            final second = position ~/ 1000;
            if (second != _lastPositionSecond) {
              _lastPositionSecond = second;
              // ignore: avoid_print
              print('[smoke] position ${position}ms');
              _writeLog('position ${position}ms');
            }
            // 可选的 CI 退出：进度真的推进了 1.5 秒才算 Phase 0 冒烟通过。
            if (_smokeOkExit && position >= 1500 && !_exiting) {
              _exiting = true;
              _add('SMOKE_OK position=${position}ms');
              Future<void>.delayed(
                const Duration(milliseconds: 200),
                () => exit(0),
              );
            }
          case CoreEventDto_PlaybackChanged(
            :final state,
            :final trackId,
            :final durationMs,
          ):
            _add('playback $state track=$trackId duration=${durationMs}ms');
            if (state == PlaybackStateDto.playing && !_loggedOutputMode) {
              _loggedOutputMode = true;
              // 独占请求被设备拒绝时，核心会把实际模式降级成 shared；这里记录的必须是实际值。
              final mode = playbackSnapshot().outputMode.name;
              _add('actual output mode=$mode');
            }
          case CoreEventDto_ScanProgress(
            :final phase,
            :final done,
            :final total,
          ):
            setState(() => _status = 'scan $phase $done/${total ?? '?'}');
          case CoreEventDto_ScanFinished(
            :final added,
            :final updated,
            :final removed,
          ):
            _add('scan finished +$added ~$updated -$removed');
            _scanDone?.complete();
          default:
            break;
        }
      });

      final dir = _musicDir();
      if (_smokeExclusive) {
        setOutputMode(mode: OutputModeDto.exclusive);
        _add('requested exclusive output');
      }
      final sources = await listSources();
      PlatformInt64 sourceId;
      final existing = sources.where((s) => s.addresses.contains(dir)).toList();
      if (existing.isEmpty) {
        sourceId = await addSource(
          source: SourceConfigDto(
            kind: SourceKindDto.local,
            name: 'Smoke',
            addresses: [dir],
            rootPath: '',
            options: const {},
            enabled: true,
          ),
        );
        _add('added source $sourceId → $dir');
      } else {
        sourceId = existing.first.id!;
        _add('reusing source $sourceId → $dir');
      }

      sw.reset();
      _scanDone = Completer<void>();
      await startScan(sourceId: sourceId);
      await _scanDone!.future.timeout(const Duration(minutes: 5));
      _add('scan took ${sw.elapsedMilliseconds} ms');

      sw.reset();
      final tracks = await listTracks(
        sort: TrackSortDto.title,
        offset: 0,
        limit: 50,
      );
      _add(
        'listTracks(50) → ${tracks.length} rows in ${sw.elapsedMilliseconds} ms',
      );
      if (tracks.isEmpty) {
        _add('no tracks found in $dir');
        return;
      }
      final first = tracks.first;
      _add(
        'playing "${first.title}" — ${first.artistLine} ${first.qualityBadge ?? ''}',
      );
      playTracks(trackIds: Int64List.fromList([first.id.toInt()]), start: 0);
    } on Object catch (e, st) {
      _add('ERROR $e');
      // ignore: avoid_print
      print(st);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Lekis smoke test')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_status, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Expanded(
              child: ListView(children: [for (final l in _log) Text(l)]),
            ),
            Row(
              children: [
                FilledButton(onPressed: play, child: const Text('Play')),
                const SizedBox(width: 8),
                OutlinedButton(onPressed: pause, child: const Text('Pause')),
                const SizedBox(width: 8),
                OutlinedButton(onPressed: next, child: const Text('Next')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
