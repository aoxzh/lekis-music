import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../rust/api/music_export.dart' as api;

Future<List<api.MusicExportItemDto>> exportToDestination({
  required Uri destination,
  int? trackId,
  int? albumId,
  required String nameTemplate,
  required bool includeArtwork,
  required bool includeLyrics,
}) async {
  Future<List<api.MusicExportItemDto>> render(String directory) =>
      api.exportMusic(
        trackId: trackId,
        albumId: albumId,
        directory: directory,
        nameTemplate: nameTemplate,
        includeArtwork: includeArtwork,
        includeLyrics: includeLyrics,
      );
  if (destination.scheme != 'content') {
    return render(destination.toFilePath());
  }
  if (!Platform.isAndroid) throw UnsupportedError('Unsupported folder URI');
  final cache = await getTemporaryDirectory();
  final staging = await cache.createTemp('lekis-export-');
  const channel = MethodChannel('dev.lekis/music_export');
  try {
    final rows = await render(staging.path);
    final published = <api.MusicExportItemDto>[];
    for (final row in rows) {
      final output = row.outputPath;
      if (output == null) {
        published.add(row);
        continue;
      }
      try {
        final uri = await channel.invokeMethod<String>('publish', {
          'tree': destination.toString(),
          'file': output,
        });
        if (uri == null) throw StateError('No document URI returned');
        published.add(
          api.MusicExportItemDto(
            trackId: row.trackId,
            title: row.title,
            outputPath: uri,
          ),
        );
      } on PlatformException catch (failure) {
        published.add(
          api.MusicExportItemDto(
            trackId: row.trackId,
            title: row.title,
            error: failure.message ?? failure.code,
          ),
        );
      }
    }
    return published;
  } finally {
    await staging.delete(recursive: true);
  }
}
