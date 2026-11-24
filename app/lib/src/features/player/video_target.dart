import 'dart:convert';

/// A source track identity recovered from the core's stable `uid`
/// (`plugin:<plugin id>:<percent-encoded external id>`).
final class PluginTrackRef {
  const PluginTrackRef(this.pluginId, this.externalId);

  final String pluginId;
  final String externalId;

  static PluginTrackRef? fromUid(String uid) {
    const prefix = 'plugin:';
    if (!uid.startsWith(prefix)) return null;
    final rest = uid.substring(prefix.length);
    final separator = rest.indexOf(':');
    if (separator <= 0 || separator == rest.length - 1) return null;
    final pluginId = rest.substring(0, separator);
    if (pluginId.isEmpty) return null;
    final encoded = rest.substring(separator + 1);
    if (!_isCanonicalExternalId(encoded)) return null;
    try {
      final externalId = Uri.decodeComponent(encoded);
      if (externalId.isEmpty) return null;
      return PluginTrackRef(pluginId, externalId);
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  /// The core percent-encodes external IDs with `NON_ALPHANUMERIC`, so every
  /// byte is either `[A-Za-z0-9]` or an uppercase `%XX` escape. Reject
  /// non-canonical UIDs instead of silently accepting e.g. `%42` for `B`.
  static bool _isCanonicalExternalId(String encoded) {
    try {
      final bytes = utf8.encode(Uri.decodeComponent(encoded));
      final canonical = StringBuffer();
      const digits = '0123456789ABCDEF';
      bool alphanumeric(int byte) =>
          (byte >= 0x30 && byte <= 0x39) ||
          (byte >= 0x41 && byte <= 0x5a) ||
          (byte >= 0x61 && byte <= 0x7a);
      for (final byte in bytes) {
        if (alphanumeric(byte)) {
          canonical.writeCharCode(byte);
        } else {
          canonical
            ..write('%')
            ..write(digits[byte >> 4])
            ..write(digits[byte & 0x0f]);
        }
      }
      return canonical.toString() == encoded;
    } on Object {
      return false;
    }
  }
}

/// An official video page supplied by a source plugin or the built-in
/// Bilibili compatibility mapping.
final class VideoTarget {
  const VideoTarget({required this.url, this.title});

  final String url;
  final String? title;
}
