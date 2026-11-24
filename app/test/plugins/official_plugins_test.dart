import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/plugins/official_plugins.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/rust/frb_generated.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Api implements RustLibApi {
  String? manifest;
  String? script;
  String? installedPath;
  bool? enabled;

  @override
  Future<List<PluginInfoDto>> crateApiCorePlugins() async => const [];

  @override
  Future<PluginInfoDto> crateApiCoreInstallPluginFromPath({
    required String path,
  }) async {
    installedPath = path;
    manifest = await File('$path${Platform.pathSeparator}plugin.json')
        .readAsString();
    script = await File('$path${Platform.pathSeparator}index.js')
        .readAsString();
    return PluginInfoDto(
      id: officialVideoPluginId,
      name: '视频播放',
      version: '0.1.0',
      apiVersion: '1.2',
      runtime: 'js',
      kinds: const ['video'],
      entry: 'index.js',
      enabled: true,
      nativeAndroidGranted: false,
      directory: officialVideoPluginId,
      permissions: const PluginPermissionsDto(
        network: [],
        process: [],
        requestHeaderHosts: [],
        webSignIn: false,
        nativeAndroid: false,
        storageKb: 1024,
      ),
      settings: const [],
    );
  }

  @override
  Future<void> crateApiCoreSetPluginEnabled({
    required String pluginId,
    required bool enabled,
  }) async {
    this.enabled = enabled;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TemporaryPathProvider extends PathProviderPlatform {
  _TemporaryPathProvider(this.path);
  final String path;

  @override
  Future<String?> getTemporaryPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled official video plugin assets are present', () async {
    final manifest = await rootBundle.loadString(
      'assets/plugins/video-playback/plugin.json',
    );
    expect(manifest, contains('"id": "dev.lekis.video-playback"'));
    expect(manifest, contains('"kinds": ["video"]'));

    final script = await rootBundle.loadString(
      'assets/plugins/video-playback/index.js',
    );
    expect(script, contains('export async function video'));
  });

  test('official video plugin installs once and enables itself', () async {
    final previous = PathProviderPlatform.instance;
    final temp = await Directory.systemTemp.createTemp('lekis-official-test');
    PathProviderPlatform.instance = _TemporaryPathProvider(temp.path);
    addTearDown(() async {
      PathProviderPlatform.instance = previous;
      await temp.delete(recursive: true);
    });

    final api = _Api();
    RustLib.initMock(api: api);
    addTearDown(RustLib.dispose);

    await ensureOfficialPlugins();
    expect(api.installedPath, isNotNull);
    expect(api.manifest, contains('dev.lekis.video-playback'));
    expect(api.script, contains('export async function video'));
    expect(api.enabled, isTrue);
  });
}
