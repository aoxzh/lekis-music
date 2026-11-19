// M3U / M3U8 导入导出（PL-03）。
//
// 核心负责解析和匹配，这里只做三件事：把导出文本交给剪贴板 / 文件选择器、
// 让用户选择文件或粘贴文本、把 `PlaylistImportReportDto` 映射成好读的摘要。
// 纯计算部分保持无副作用，方便单元测试（见 `test/playlist_m3u_test.dart`）。

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_actions.dart';
import 'package:lekis/src/features/playlists/playlist_actions.dart';
import 'package:lekis/src/features/playlists/playlist_detail_page.dart';
import 'package:lekis/src/features/playlists/playlist_providers.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

/// 导入结果的可读摘要（由生成的 DTO 映射而来）。
class PlaylistImportOutcome {
  const PlaylistImportOutcome({
    required this.playlistId,
    required this.matched,
    required this.total,
    required this.missing,
  });

  factory PlaylistImportOutcome.fromReport(PlaylistImportReportDto report) {
    return PlaylistImportOutcome(
      playlistId: report.playlistId,
      matched: report.matched,
      total: report.total,
      missing: List<String>.unmodifiable(report.missing),
    );
  }

  /// 新建歌单的 ID。
  final int playlistId;

  /// 成功匹配的条目数。
  final int matched;

  /// 解析到的条目总数（含未匹配）。
  final int total;

  /// 没匹配到曲目的原始路径。
  final List<String> missing;

  bool get hasMissing => missing.isNotEmpty;

  int get unmatched => missing.length;

  String get summary {
    if (total == 0) return '文件里没有条目，已创建空歌单。';
    if (missing.isEmpty) return '已导入 $matched 首歌曲（共 $total 条）。';
    return '已导入 $matched 首歌曲，${missing.length} 个路径未匹配（共 $total 条）。';
  }
}

/// 导出文件名：去掉 Windows / Android 不允许的字符，保留中文，默认 `.m3u8`。
String playlistM3uFileName(String name) {
  final cleaned = name
      .trim()
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
      .replaceAll(RegExp(r'^[.\s]+|[.\s]+$'), '');
  final base = cleaned.isEmpty ? 'lekis-playlist' : cleaned;
  return '$base.m3u8';
}

/// XSPF 导出文件名，规则和 M3U 一样，扩展名不同。
String playlistXspfFileName(String name) {
  final base = playlistM3uFileName(name);
  return '${base.substring(0, base.length - '.m3u8'.length)}.xspf';
}

/// 导入时按内容判断格式，避免用户为了选错扩展名被拒绝。
bool looksLikeXspf(String content) {
  final text = content.trimLeft().toLowerCase();
  return text.startsWith('<?xml') || text.startsWith('<playlist');
}

/// XSPF 里真正的 `<track>` 数量。
int countXspfTracks(String content) =>
    RegExp(r'<track(?:\s|>)', caseSensitive: false).allMatches(content).length;

/// 从文件名猜一个歌单名（`通勤.m3u8` → `通勤`）。
String playlistNameFromM3uFile(String fileName) {
  final dot = fileName.lastIndexOf('.');
  final stem = dot > 0 ? fileName.substring(0, dot) : fileName;
  final trimmed = stem.trim();
  return trimmed.isEmpty ? '导入的歌单' : trimmed;
}

/// 数一下 M3U 文本里有多少个真正的路径条目（忽略 `#` 开头的扩展标签）。
int countM3uEntries(String content) {
  var count = 0;
  final text = content.startsWith('\u{feff}') ? content.substring(1) : content;
  for (final raw in text.replaceAll('\r', '\n').split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    count++;
  }
  return count;
}

enum _PlaylistExportFormat { m3u, xspf }

enum _M3uExportAction { copy, save }

/// 导出普通歌单：先选格式（M3U / XSPF），再选“复制”或“保存文件”。
Future<void> exportPlaylistM3uFlow(
  BuildContext context,
  PlaylistDto playlist,
) async {
  if (playlist.kind != PlaylistKindDto.static_) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('智能歌单没有固定条目，不能导出')));
    return;
  }

  final format = await showDialog<_PlaylistExportFormat>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('导出歌单'),
      children: [
        SimpleDialogOption(
          onPressed: () =>
              Navigator.of(context).pop(_PlaylistExportFormat.m3u),
          child: const ListTile(
            leading: Icon(Icons.playlist_play_rounded),
            title: Text('M3U8'),
            subtitle: Text('兼容大多数播放器、车载和 NAS'),
          ),
        ),
        SimpleDialogOption(
          onPressed: () =>
              Navigator.of(context).pop(_PlaylistExportFormat.xspf),
          child: const ListTile(
            leading: Icon(Icons.code_rounded),
            title: Text('XSPF'),
            subtitle: Text('XML 格式，保留艺人和标题元数据'),
          ),
        ),
      ],
    ),
  );
  if (format == null || !context.mounted) return;

  final String text;
  try {
    text = switch (format) {
      _PlaylistExportFormat.m3u => await core.exportPlaylistM3U(
        playlistId: playlist.id,
      ),
      _PlaylistExportFormat.xspf => await core.exportPlaylistXspf(
        playlistId: playlist.id,
      ),
    };
  } catch (e) {
    if (context.mounted) showPlaylistError(context, e);
    return;
  }
  if (!context.mounted) return;

  final isM3u = format == _PlaylistExportFormat.m3u;
  final count = isM3u ? countM3uEntries(text) : countXspfTracks(text);
  final formatName = isM3u ? 'M3U8' : 'XSPF';
  final action = await showDialog<_M3uExportAction>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('导出 $formatName'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('“${playlist.name}”共 $count 个条目。'),
          const SizedBox(height: LekisSpacing.sm),
          Text(
            isM3u
                ? '文件是 UTF-8 编码的 .m3u8，可以复制后粘贴到别处，或直接保存到设备。'
                : '文件是 UTF-8 编码的 .xspf（XML），适合保留艺人/标题并导入其他播放器。',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: context.lekisColors.onSurfaceVariant),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        OutlinedButton.icon(
          onPressed: () => Navigator.of(context).pop(_M3uExportAction.copy),
          icon: const Icon(Icons.copy_rounded),
          label: const Text('复制'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.of(context).pop(_M3uExportAction.save),
          icon: const Icon(Icons.save_alt_rounded),
          label: const Text('保存文件'),
        ),
      ],
    ),
  );
  if (action == null) return;

  if (action == _M3uExportAction.copy) {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      _snack(context, '已复制 $formatName 文本（$count 个条目）');
    }
    return;
  }

  final fileName = isM3u
      ? playlistM3uFileName(playlist.name)
      : playlistXspfFileName(playlist.name);
  try {
    final saved = await FilePicker.saveFile(
      dialogTitle: '导出 $formatName',
      fileName: fileName,
      bytes: Uint8List.fromList(utf8.encode(text)),
      mimeType: isM3u ? 'audio/x-mpegurl' : 'application/xspf+xml',
    );
    if (saved != null && context.mounted) _snack(context, '已保存 $fileName');
  } catch (e) {
    if (context.mounted) _snack(context, '保存失败：$e');
  }
}

/// 导入对话框：可以选 .m3u / .m3u8 文件，也可以直接粘贴文本。
class PlaylistM3uImportDialog extends StatefulWidget {
  const PlaylistM3uImportDialog({super.key});

  @override
  State<PlaylistM3uImportDialog> createState() =>
      _PlaylistM3uImportDialogState();
}

class _PlaylistM3uImportDialogState extends State<PlaylistM3uImportDialog> {
  static const _defaultName = '导入的歌单';
  final _name = TextEditingController(text: _defaultName);
  final _content = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _content.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    try {
      final file = await FilePicker.pickFile(
        dialogTitle: '选择播放列表',
        type: FileType.custom,
        allowedExtensions: const ['m3u', 'm3u8', 'xspf'],
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final text = utf8.decode(bytes, allowMalformed: true);
      if (!mounted) return;
      setState(() {
        _content.text = text;
        final current = _name.text.trim();
        if (current.isEmpty || current == _defaultName) {
          _name.text = playlistNameFromM3uFile(file.name);
        }
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '读取文件失败：$e');
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty || !mounted) return;
    setState(() {
      _content.text = text;
      _error = null;
    });
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final content = _content.text;
    if (name.isEmpty) {
      setState(() => _error = '歌单名称不能为空');
      return;
    }
    if (content.trim().isEmpty) {
      setState(() => _error = '请选择歌单文件或粘贴内容');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final report = looksLikeXspf(content)
          ? await core.importPlaylistXspf(name: name, content: content)
          : await core.importPlaylistM3U(name: name, content: content);
      if (!mounted) return;
      Navigator.of(context).pop(PlaylistImportOutcome.fromReport(report));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = describeCoreError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('导入歌单'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: '歌单名称',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: LekisSpacing.md),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _pickFile,
                    icon: const Icon(Icons.folder_open_rounded),
                    label: const Text('选择文件'),
                  ),
                  const SizedBox(width: LekisSpacing.sm),
                  TextButton.icon(
                    onPressed: _busy ? null : _paste,
                    icon: const Icon(Icons.content_paste_rounded),
                    label: const Text('从剪贴板粘贴'),
                  ),
                ],
              ),
              const SizedBox(height: LekisSpacing.sm),
              TextField(
                controller: _content,
                enabled: !_busy,
                minLines: 6,
                maxLines: 10,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  hintText: '把 .m3u / .m3u8 / .xspf 的内容粘贴到这里，或者点上面的“选择文件”',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: LekisSpacing.sm),
                Text(
                  _error!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _submit,
          icon: _busy
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.playlist_add_check_rounded),
          label: Text(_busy ? '导入中…' : '导入'),
        ),
      ],
    );
  }
}

/// 显示导入结果；返回用户是否选择打开新歌单。
Future<bool?> showM3uImportReportDialog(
  BuildContext context,
  PlaylistImportOutcome outcome,
) {
  return showDialog<bool>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      final colors = context.lekisColors;
      return AlertDialog(
        title: const Text('导入完成'),
        content: SizedBox(
          width: 480,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(outcome.summary),
                  const SizedBox(height: LekisSpacing.xs),
                  Text(
                    '匹配 ${outcome.matched} 首 · 未匹配 ${outcome.unmatched} 个',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  if (outcome.hasMissing) ...[
                    const SizedBox(height: LekisSpacing.md),
                    Text(
                      '未匹配的路径',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: LekisSpacing.xs),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(LekisSpacing.sm),
                      decoration: BoxDecoration(
                        color: colors.surfaceVariant.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(LekisRadius.sm),
                      ),
                      child: SelectableText(
                        outcome.missing.join('\n'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('打开歌单'),
          ),
        ],
      );
    },
  );
}

/// 导入流程：选择/粘贴 → 导入 → 显示匹配报告 → 可选打开新歌单。
Future<void> importPlaylistM3uFlow(BuildContext context, WidgetRef ref) async {
  final outcome = await showDialog<PlaylistImportOutcome>(
    context: context,
    builder: (_) => const PlaylistM3uImportDialog(),
  );
  if (outcome == null || !context.mounted) return;

  ref.invalidate(playlistsProvider);
  final open = await showM3uImportReportDialog(context, outcome);
  if (open == true && context.mounted) {
    await Navigator.of(context)
        .push(PlaylistDetailPage.route(outcome.playlistId));
  }
}

void _snack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
