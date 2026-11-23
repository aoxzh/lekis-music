// Manual on-device verification of an independently installed source.
// Copy a trusted plugin ZIP into app-private storage, then run:
// flutter run -t tool/plugin_android_smoke.dart \
//   --dart-define=PLUGIN_ZIP=/data/user/0/dev.lekis.music/files/plugin.zip \
//   --dart-define=PLUGIN_QUERY=<song URL or search words>
// Uses a separate smoke-test library. Signed media URLs are never printed.
import 'dart:async';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Int64List;

import 'package:material_ui/material_ui.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/rust/frb_generated.dart';
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final status = ValueNotifier<String>('Starting Android source check');
  runApp(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: ValueListenableBuilder<String>(
            valueListenable: status,
            builder: (_, value, _) =>
                Padding(padding: const EdgeInsets.all(24), child: Text(value)),
          ),
        ),
      ),
    ),
  );
  void report(String message) {
    status.value = message;
    debugPrint('PLUGIN_SMOKE $message');
  }

  try {
    if (!Platform.isAndroid) throw StateError('Run on Android');
    const zip = String.fromEnvironment('PLUGIN_ZIP');
    const query = String.fromEnvironment('PLUGIN_QUERY');
    if (zip.isEmpty || query.isEmpty) {
      throw StateError('Set PLUGIN_ZIP and PLUGIN_QUERY');
    }
    await RustLib.init();
    final support = await getApplicationSupportDirectory();
    final scratch = await Directory(
      '${support.path}/source-smoke-${DateTime.now().millisecondsSinceEpoch}',
    ).create();
    await core.initCore(
      config: CoreConfigDto(
        dataDir: scratch.path,
        cacheDir: '${scratch.path}/cache',
        deviceName: 'Android plugin smoke',
        platform: PlatformDto.android,
      ),
    );
    final plugin = await core.installPluginFromPath(path: zip);
    final usesNative = plugin.permissions.nativeAndroid;
    if (plugin.nativeAndroidGranted) {
      throw StateError('Native grant must default off');
    }
    report('Installed ${plugin.id}; native extension: $usesNative; grant off');
    if (usesNative) {
      await core.setPluginNativeAndroidAllowed(
        pluginId: plugin.id,
        allowed: true,
      );
      final granted = (await core.plugins()).singleWhere(
        (p) => p.id == plugin.id,
      );
      if (!granted.nativeAndroidGranted) {
        throw StateError('Native grant not persisted');
      }
    }
    final results = await core.searchPlugin(
      pluginId: plugin.id,
      query: query,
      limit: 3,
    );
    if (results.tracks.isEmpty) throw StateError('No tracks returned');
    final track = results.tracks.first;
    report('Search returned ${results.tracks.length} tracks: ${track.title}');
    core.setVolume(volume: 0.05);
    core.playTracks(trackIds: Int64List.fromList([track.id]), start: 0);
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    var played = false;
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final snapshot = core.playbackSnapshot();
      if (snapshot.state == PlaybackStateDto.playing &&
          snapshot.positionMs >= BigInt.from(2500)) {
        report(
          'PASS: Android native search → resolve → playback (${snapshot.positionMs} ms)',
        );
        played = true;
        break;
      }
    }
    core.pause();
    if (!played) {
      throw StateError(
        'Playback did not advance: ${core.playbackSnapshot().state}',
      );
    }
    if (usesNative) {
      await core.setPluginNativeAndroidAllowed(
        pluginId: plugin.id,
        allowed: false,
      );
      final revoked = (await core.plugins()).singleWhere(
        (p) => p.id == plugin.id,
      );
      if (revoked.nativeAndroidGranted) {
        throw StateError('Native grant not revoked');
      }
    }
    report(
      'PASS: Android source playback${usesNative ? " and native permission revocation" : ""}',
    );
  } catch (error, stack) {
    // Redact URLs: network errors can contain signed media URLs.
    final detail = error.toString().replaceAll(
      RegExp(r'https?://[^\s]+'),
      '<URL>',
    );
    report('FAIL: ${error.runtimeType}: $detail');
    debugPrintStack(stackTrace: stack);
  }
}
