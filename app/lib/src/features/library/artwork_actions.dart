// "更换封面…"：选一张本地图片当专辑 / 曲目封面（ENR-01 的本地导入）。
//
// 图片交给核心，走和自动补全一样的流水线（缩略图、取色、按内容去重），
// 只写本机缓存和资料库，不改音频文件。

import 'package:file_picker/file_picker.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Int64List;
import 'package:lekis/src/features/library/library_actions.dart'
    show describeCoreError;
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:material_ui/material_ui.dart';

abstract final class ArtworkActionStrings {
  static String get change => L10n.tr('更换封面…', 'Change Artwork…');
  static String get pickTitle => L10n.tr('选择封面图片', 'Choose Artwork Image');
  static String get changed => L10n.tr('封面已更换', 'Artwork changed');
  static String get failed => L10n.tr('更换封面失败', 'Couldn’t change artwork');
  static String get undo => L10n.tr('撤销', 'Undo');
  static String get remove => L10n.tr('移除封面', 'Remove Artwork');
  static String get removed => L10n.tr('已移除封面', 'Artwork removed');
  static String get restored =>
      L10n.tr('已恢复原来的封面', 'Original artwork restored');

  static String failedWith(String detail) =>
      L10n.tr('$failed：$detail', '$failed: $detail');
}

/// 让用户选一张图片，换成 [trackIds]（和 [albumId] 这张专辑）的封面。
Future<void> changeArtworkFlow(
  BuildContext context, {
  required List<int> trackIds,
  int? albumId,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  void say(String text) => messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
  try {
    final file = await FilePicker.pickFile(
      dialogTitle: ArtworkActionStrings.pickTitle,
      type: FileType.image,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    final change = await core.setArtworkFromImage(
      image: bytes,
      trackIds: Int64List.fromList(trackIds),
      albumId: albumId,
    );
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(ArtworkActionStrings.changed),
          action: SnackBarAction(
            label: ArtworkActionStrings.undo,
            onPressed: () async {
              try {
                await core.restoreArtwork(change: change);
                say(ArtworkActionStrings.restored);
              } catch (error) {
                say(ArtworkActionStrings.failedWith(describeCoreError(error)));
              }
            },
          ),
        ),
      );
  } catch (error) {
    say(ArtworkActionStrings.failedWith(describeCoreError(error)));
  }
}

/// 给歌单换封面（[pick] 为 `false` 时移除封面，回到默认图标）。带撤销。
Future<void> changePlaylistCoverFlow(
  BuildContext context, {
  required int playlistId,
  required int? previousArtworkId,
  bool pick = true,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  void say(String text) => messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
  try {
    int? artworkId;
    if (pick) {
      final file = await FilePicker.pickFile(
        dialogTitle: ArtworkActionStrings.pickTitle,
        type: FileType.image,
      );
      if (file == null) return;
      artworkId = (await core.importArtwork(image: await file.readAsBytes()))
          .toInt();
    }
    await core.setPlaylistArtwork(
      playlistId: playlistId,
      artworkId: artworkId,
    );
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            pick ? ArtworkActionStrings.changed : ArtworkActionStrings.removed,
          ),
          action: SnackBarAction(
            label: ArtworkActionStrings.undo,
            onPressed: () async {
              try {
                await core.setPlaylistArtwork(
                  playlistId: playlistId,
                  artworkId: previousArtworkId,
                );
                say(ArtworkActionStrings.restored);
              } catch (error) {
                say(ArtworkActionStrings.failedWith(describeCoreError(error)));
              }
            },
          ),
        ),
      );
  } catch (error) {
    say(ArtworkActionStrings.failedWith(describeCoreError(error)));
  }
}
