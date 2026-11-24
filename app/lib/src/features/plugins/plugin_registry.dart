import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'plugin_download.dart';

const pluginRegistryUrl = String.fromEnvironment(
  'LEKIS_PLUGIN_REGISTRY_URL',
  defaultValue: 'https://raw.githubusercontent.com/hal-pixel/lekis-plugin-registry/main/catalog.json',
);

final pluginRegistryProvider = FutureProvider.autoDispose<List<RegistryPlugin>>(
  (ref) => readPluginResource(
    Uri.parse(pluginRegistryUrl),
    byteLimit: 1024 * 1024,
    read: (uri, chunks) async =>
        parsePluginRegistry(await utf8.decoder.bind(chunks).join(), uri),
  ),
  retry: (_, _) => null,
);

class RegistryPlugin {
  const RegistryPlugin({
    required this.id,
    required this.name,
    required this.description,
    required this.version,
    required this.package,
    required this.sha256,
  });

  final String id;
  final String name;
  final String description;
  final String version;
  final Uri package;
  final String sha256;

  factory RegistryPlugin.fromJson(Object? entry, Uri catalog) {
    if (entry is! Map<String, dynamic>) {
      throw const FormatException('Expected a plugin entry');
    }
    String field(String key) {
      final value = entry[key];
      if (value is String &&
          (key == 'description' || value.trim().isNotEmpty)) {
        return value.trim();
      }
      throw FormatException('Invalid plugin field: $key');
    }

    final package = pluginPackageUri(
      catalog.resolve(field('package')).toString(),
    );
    if (package == null) {
      throw const FormatException('Expected an HTTPS package URL');
    }
    final hash = field('sha256').toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      throw const FormatException('Invalid plugin SHA-256');
    }
    return RegistryPlugin(
      id: field('id'),
      name: field('name'),
      description: field('description'),
      version: field('version'),
      package: package,
      sha256: hash,
    );
  }
}

List<RegistryPlugin> parsePluginRegistry(String json, Uri catalog) {
  final document = jsonDecode(json);
  if (document case {'version': int version, 'plugins': List entries}
      when version == 1) {
    final ids = <String>{};
    final plugins = <RegistryPlugin>[];
    for (final entry in entries) {
      final plugin = RegistryPlugin.fromJson(entry, catalog);
      if (!ids.add(plugin.id)) {
        throw FormatException('Duplicate plugin ID: ${plugin.id}');
      }
      plugins.add(plugin);
    }
    return plugins;
  }
  throw const FormatException('Unsupported plugin registry');
}
