// User-managed plugin sources.
//
// The app ships one built-in community catalog; users may add more HTTPS
// catalog URLs (community mirrors or their own). The list is persisted in core
// settings and every source is browsed on the Plugins page.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust/api/core.dart' as core;
import 'plugin_download.dart';
import 'plugin_registry.dart';

/// Core setting key holding a JSON array of custom catalog URLs.
const String kPluginSourcesSettingKey = 'plugins.sources';

/// The catalog that ships with the app (see `LEKIS_PLUGIN_REGISTRY_URL`).
String get defaultPluginSourceUrl => pluginRegistryUrl;

/// One browsable catalog: the built-in default or a user-added HTTPS URL.
class PluginSource {
  const PluginSource({required this.url, required this.builtIn});

  final String url;
  final bool builtIn;
}

/// Returns a canonical HTTPS URL, or null when [raw] is not a safe catalog
/// address (plain HTTP, credentials in the URL, or no host).
String? normalizePluginSourceUrl(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri.toString();
}

/// Parses the persisted URL list, dropping malformed entries.
List<String> parsePluginSourceUrls(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    final urls = <String>[];
    for (final value in decoded) {
      if (value is! String) continue;
      final url = normalizePluginSourceUrl(value);
      if (url != null && !urls.contains(url)) urls.add(url);
    }
    return urls;
  } catch (_) {
    return const [];
  }
}

final pluginSourcesProvider =
    AsyncNotifierProvider<PluginSourcesNotifier, List<PluginSource>>(
      PluginSourcesNotifier.new,
    );

/// Catalog entries for one user-added source URL.
final pluginSourceCatalogProvider = FutureProvider.autoDispose
    .family<List<RegistryPlugin>, String>(
      (ref, url) => readPluginResource(
        Uri.parse(url),
        byteLimit: 1024 * 1024,
        read: (uri, chunks) async =>
            parsePluginRegistry(await utf8.decoder.bind(chunks).join(), uri),
      ),
      retry: (_, _) => null,
    );

class PluginSourcesNotifier extends AsyncNotifier<List<PluginSource>> {
  @override
  Future<List<PluginSource>> build() async => _combine(await _loadCustom());

  Future<List<String>> _loadCustom() async {
    try {
      return parsePluginSourceUrls(
        await core.getSetting(key: kPluginSourcesSettingKey),
      );
    } catch (_) {
      // Core may not be available in tests.
      return const [];
    }
  }

  List<PluginSource> _combine(List<String> custom) {
    final seen = <String>{defaultPluginSourceUrl};
    return [
      PluginSource(url: defaultPluginSourceUrl, builtIn: true),
      for (final url in custom)
        if (seen.add(url)) PluginSource(url: url, builtIn: false),
    ];
  }

  /// Adds [raw] and returns false when it is invalid or already present.
  Future<bool> add(String raw) async {
    final url = normalizePluginSourceUrl(raw);
    if (url == null) return false;
    final current = state.value ?? _combine(await _loadCustom());
    if (current.any((source) => source.url == url)) return false;
    final custom = [
      for (final source in current)
        if (!source.builtIn) source.url,
      url,
    ];
    await _save(custom);
    return true;
  }

  /// Removes a user-added source; the built-in source cannot be removed.
  Future<void> remove(String url) async {
    final current = state.value ?? _combine(await _loadCustom());
    final custom = [
      for (final source in current)
        if (!source.builtIn && source.url != url) source.url,
    ];
    await _save(custom);
  }

  Future<void> reload() async =>
      state = AsyncData(_combine(await _loadCustom()));

  Future<void> _save(List<String> custom) async {
    try {
      await core.setSetting(
        key: kPluginSourcesSettingKey,
        value: jsonEncode(custom),
      );
    } catch (_) {
      // Keep the in-memory list usable even when settings are unavailable.
    }
    state = AsyncData(_combine(custom));
  }
}
