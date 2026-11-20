// 标签编辑对话框（LIB-13 / ENR-08）。
//
// 两个动作严格分开：
//   * 仅保存到资料库：只写覆盖层，不碰音频文件；
//   * 写入文件：二次确认后由核心先备份、再临时文件 + 原子替换。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Int64List;
import 'package:lekis/src/features/library/library_actions.dart';
import 'package:lekis/src/features/library/tag_editor_model.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/rust/api/error.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:lekis/src/widgets/adaptive_panel.dart';
import 'package:material_ui/material_ui.dart';

/// 打开单曲标签编辑。
Future<void> showTrackTagEditor(
  BuildContext context, {
  required int trackId,
  String? trackTitle,
}) {
  return showLekisPanel<void>(
    context,
    dismissible: false,
    builder: (_) => TagEditorDialog(trackIds: [trackId], title: trackTitle),
  );
}

/// 打开批量标签编辑。字段留空表示保持每首歌原来的值。
Future<void> showBatchTagEditor(
  BuildContext context, {
  required List<int> trackIds,
}) {
  return showLekisPanel<void>(
    context,
    dismissible: false,
    builder: (_) => TagEditorDialog(trackIds: trackIds),
  );
}

/// 单曲 / 批量共用的标签编辑面板：宽窗口是居中对话框，手机是底部面板。
class TagEditorDialog extends ConsumerStatefulWidget {
  const TagEditorDialog({super.key, required this.trackIds, this.title});

  final List<int> trackIds;
  final String? title;

  @override
  ConsumerState<TagEditorDialog> createState() => _TagEditorDialogState();
}

class _TagEditorDialogState extends ConsumerState<TagEditorDialog> {
  final _title = TextEditingController();
  final _artist = TextEditingController();
  final _album = TextEditingController();
  final _albumArtist = TextEditingController();
  final _trackNo = TextEditingController();
  final _discNo = TextEditingController();
  final _year = TextEditingController();
  final _genre = TextEditingController();
  final _comment = TextEditingController();
  final _composer = TextEditingController();
  final _lyricist = TextEditingController();
  final _musicbrainzTrackId = TextEditingController();
  final _musicbrainzAlbumId = TextEditingController();

  bool _loading = true;
  bool _busy = false;

  /// 这首歌在资料库里有覆盖过的标签（"还原为文件标签"才有意义）。
  bool _hasOverrides = false;
  String? _loadError;
  String? _formError;

  bool get _batch => widget.trackIds.length > 1;
  int get _singleId => widget.trackIds.first;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final controller in [
      _title,
      _artist,
      _album,
      _albumArtist,
      _trackNo,
      _discNo,
      _year,
      _genre,
      _comment,
      _composer,
      _lyricist,
      _musicbrainzTrackId,
      _musicbrainzAlbumId,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    if (_batch) {
      setState(() => _loading = false);
      return;
    }
    try {
      final track = await core.getTrack(trackId: _singleId);
      final overrides = await core.trackTagOverrides(trackId: _singleId);
      _hasOverrides = overrides != null && _anyOverride(overrides);
      TrackTagOverridesDto? fileTags;
      try {
        fileTags = await core.readTrackFileTags(trackId: _singleId);
      } catch (_) {
        // 文件不可读时仍然可以编辑资料库覆盖层。
      }
      final draft = TagEditDraft.forTrack(
        track: track,
        overrides: overrides,
        fileTags: fileTags,
      );
      _applyDraft(draft);
    } catch (error) {
      _loadError = describeCoreError(error);
    }
    if (mounted) setState(() => _loading = false);
  }

  void _applyDraft(TagEditDraft draft) {
    _title.text = draft.title;
    _artist.text = draft.artist;
    _album.text = draft.album;
    _albumArtist.text = draft.albumArtist;
    _trackNo.text = draft.trackNo;
    _discNo.text = draft.discNo;
    _year.text = draft.year;
    _genre.text = draft.genre;
    _comment.text = draft.comment;
    _composer.text = draft.composer;
    _lyricist.text = draft.lyricist;
    _musicbrainzTrackId.text = draft.musicbrainzTrackId;
    _musicbrainzAlbumId.text = draft.musicbrainzAlbumId;
  }

  TagEditDraft _readDraft() => TagEditDraft(
    title: _title.text,
    artist: _artist.text,
    album: _album.text,
    albumArtist: _albumArtist.text,
    trackNo: _trackNo.text,
    discNo: _discNo.text,
    year: _year.text,
    genre: _genre.text,
    comment: _comment.text,
    composer: _composer.text,
    lyricist: _lyricist.text,
    musicbrainzTrackId: _musicbrainzTrackId.text,
    musicbrainzAlbumId: _musicbrainzAlbumId.text,
  );

  Future<void> _saveOnly() async {
    final draft = _readDraft();
    final error = draft.validate();
    if (error != null) {
      setState(() => _formError = error);
      return;
    }
    if (_batch && draft.isEmpty) {
      setState(() => _formError = '批量编辑至少填写一个字段');
      return;
    }
    setState(() {
      _busy = true;
      _formError = null;
    });
    try {
      if (_batch) {
        final failures = await _saveBatchOverrides(draft);
        if (!mounted) return;
        if (failures.isNotEmpty) {
          setState(() => _formError = '有 ${failures.length} 首歌保存失败');
          return;
        }
      } else {
        await core.setTrackTagOverrides(
          trackId: _singleId,
          fields: draft.toOverrides(),
        );
      }
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      final count = widget.trackIds.length;
      Navigator.of(context).pop();
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              count == 1 ? '已保存到资料库（未修改文件）' : '已保存 $count 首歌的标签到资料库（未修改文件）',
            ),
          ),
        );
    } catch (error) {
      if (mounted) setState(() => _formError = describeCoreError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<List<int>> _saveBatchOverrides(TagEditDraft draft) async {
    final failures = <int>[];
    for (final id in widget.trackIds) {
      try {
        final existing = await core.trackTagOverrides(trackId: id);
        final merged = draft.mergeInto(existing);
        await core.setTrackTagOverrides(
          trackId: id,
          fields: merged ?? const TrackTagOverridesDto(),
        );
      } catch (_) {
        failures.add(id);
      }
    }
    return failures;
  }

  static bool _anyOverride(TrackTagOverridesDto o) => [
    o.title,
    o.artist,
    o.album,
    o.albumArtist,
    o.trackNo,
    o.discNo,
    o.year,
    o.genre,
    o.comment,
    o.composer,
    o.lyricist,
    o.musicbrainzTrackId,
    o.musicbrainzAlbumId,
  ].any((v) => v != null);

  /// 丢掉资料库里的修改，回到文件本身的标签（不动文件）。
  Future<void> _clearOverrides() async {
    setState(() {
      _busy = true;
      _formError = null;
    });
    try {
      await core.clearTrackTagOverrides(trackId: _singleId);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('已还原为文件里的标签')));
    } catch (error) {
      if (mounted) setState(() => _formError = describeCoreError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _writeFile() async {
    final draft = _readDraft();
    final error = draft.validate();
    if (error != null) {
      setState(() => _formError = error);
      return;
    }
    if (draft.isEmpty) {
      setState(() => _formError = '请至少填写一个要写入文件的字段');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('写入音频文件？'),
        content: const SingleChildScrollView(
          child: Text(
            '这一步会修改音频文件本身，不是只改资料库。\n\n'
            '写入前会在音频同目录生成 <文件名>.lekis-tags-backup.json 备份原标签；'
            '写入使用临时文件 + 原子替换，失败时会尝试自动恢复。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.save_rounded),
            label: const Text('确认写入'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _busy = true;
      _formError = null;
    });
    try {
      // 先保存覆盖层，核心写文件时读的就是它。
      if (_batch) {
        final failures = await _saveBatchOverrides(draft);
        if (failures.isNotEmpty) {
          if (!mounted) return;
          setState(() => _formError = '有 ${failures.length} 首歌保存覆盖层失败，已停止写入');
          return;
        }
      } else {
        await core.setTrackTagOverrides(
          trackId: _singleId,
          fields: draft.toOverrides(),
        );
      }
      if (!mounted) return;

      late final List<BatchTagWriteItemDto> items;
      if (_batch) {
        items = await core.batchWriteTrackTags(
          trackIds: Int64List.fromList(widget.trackIds),
        );
      } else {
        try {
          final result = await core.writeTrackTags(trackId: _singleId);
          items = [BatchTagWriteItemDto(trackId: _singleId, result: result)];
        } catch (error) {
          items = [
            BatchTagWriteItemDto(
              trackId: _singleId,
              errorKind: error is CoreError ? error.kind : ErrorKind.internal,
              error: error is CoreError ? error.detail : '$error',
            ),
          ];
        }
      }
      if (!mounted) return;
      final navigator = Navigator.of(context);
      navigator.pop();
      await showTagWriteResultDialog(navigator.context, items: items);
    } catch (error) {
      if (mounted) setState(() => _formError = describeCoreError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final close = _busy ? null : () => Navigator.of(context).pop();
    final ready = !_loading && _loadError == null;
    return LekisPanel(
      title: _batch ? '批量编辑标签' : '编辑标签',
      subtitle: _batch
          ? '已选 ${widget.trackIds.length} 首歌曲 · 留空的字段表示不修改'
          : widget.title,
      onClose: close,
      error: _formError,
      actions: [
        TextButton(onPressed: close, child: const Text('取消')),
        if (!_batch && _hasOverrides)
          TextButton.icon(
            key: const ValueKey('tag-editor.clear-overrides'),
            onPressed: _busy || !ready ? null : _clearOverrides,
            icon: const Icon(Icons.restore_rounded),
            label: const Text('还原为文件标签'),
          ),
        OutlinedButton.icon(
          key: const ValueKey('tag-editor.save-library'),
          onPressed: _busy || !ready ? null : _saveOnly,
          icon: const Icon(Icons.library_add_outlined),
          label: const Text('仅保存到资料库'),
        ),
        FilledButton.icon(
          key: const ValueKey('tag-editor.write-file'),
          onPressed: _busy || !ready ? null : _writeFile,
          icon: _busy
              ? const LekisPanelProgress()
              : const Icon(Icons.save_rounded),
          label: const Text('写入文件'),
        ),
      ],
      body: _buildBody(theme, colors),
    );
  }

  Widget _buildBody(ThemeData theme, LekisColors colors) {
    if (_loading) {
      return const SizedBox(
        height: LekisSizes.gridArtworkMin,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_loadError != null) {
      return Text(
        '加载失败：$_loadError',
        style: theme.textTheme.bodyMedium?.copyWith(color: colors.danger),
      );
    }
    Widget section(String label) => Padding(
      padding: const EdgeInsets.only(
        top: LekisSpacing.sm,
        bottom: LekisSpacing.sm,
      ),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: colors.onSurfaceVariant,
        ),
      ),
    );
    const gap = SizedBox(width: LekisSpacing.md);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _batch
              ? '填写要统一修改的字段。留空的字段保持每首歌原来的值。'
              : '“仅保存到资料库”只改显示，不修改文件；留空的字段不会覆盖文件原值。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: LekisSpacing.md),
        section('基本信息'),
        _field(_title, '标题'),
        _field(_artist, '艺人', hint: '多个艺人用 “ / ” 分隔'),
        _field(_album, '专辑'),
        _field(_albumArtist, '专辑艺人'),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _field(_trackNo, '曲目号', number: true)),
            gap,
            Expanded(child: _field(_discNo, '碟片号', number: true)),
            gap,
            Expanded(child: _field(_year, '年份', number: true)),
          ],
        ),
        _field(_genre, '流派', hint: '多个流派用 “;” 分隔'),
        section('创作'),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _field(_composer, '作曲')),
            gap,
            Expanded(child: _field(_lyricist, '作词')),
          ],
        ),
        _field(_comment, '评论', maxLines: 3),
        section('MusicBrainz'),
        _field(_musicbrainzTrackId, '录音 ID'),
        _field(_musicbrainzAlbumId, '专辑 ID'),
        Text(
          '支持 MP3、FLAC、M4A/AAC、OGG/Opus。远程音源与 WAV/APE 等格式不能写回文件。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// Fields use the theme's filled style (same as every other form).
  Widget _field(
    TextEditingController controller,
    String label, {
    String? hint,
    bool number = false,
    int maxLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: LekisPanel.fieldGap),
      child: TextField(
        controller: controller,
        enabled: !_busy,
        maxLines: maxLines,
        keyboardType: number ? TextInputType.number : TextInputType.text,
        decoration: InputDecoration(labelText: label, hintText: hint),
      ),
    );
  }
}

/// 写回 / 恢复结果。失败项提供“从备份恢复”。
Future<void> showTagWriteResultDialog(
  BuildContext context, {
  required List<BatchTagWriteItemDto> items,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _TagWriteResultDialog(items: items),
  );
}

class _TagWriteResultDialog extends StatefulWidget {
  const _TagWriteResultDialog({required this.items});

  final List<BatchTagWriteItemDto> items;

  @override
  State<_TagWriteResultDialog> createState() => _TagWriteResultDialogState();
}

class _TagWriteResultDialogState extends State<_TagWriteResultDialog> {
  final _restoring = <int>{};
  final _restored = <int>{};

  bool get _allSuccess =>
      widget.items.every((item) => item.result != null) &&
      widget.items.every((item) => !_restored.contains(_id(item)));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final success = widget.items.where((item) => item.result != null).length;
    final failed = widget.items.length - success;
    return AlertDialog(
      title: Text(
        failed == 0
            ? '已写入文件'
            : success == 0
            ? '写入失败'
            : '部分写入失败',
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '成功 $success 首，失败 $failed 首。',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: LekisSpacing.md),
              for (final item in widget.items)
                _resultTile(context, item, theme, colors),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_allSuccess ? '关闭' : '稍后处理'),
        ),
      ],
    );
  }

  Widget _resultTile(
    BuildContext context,
    BatchTagWriteItemDto item,
    ThemeData theme,
    LekisColors colors,
  ) {
    final id = _id(item);
    final result = item.result;
    if (result != null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: LekisSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _restored.contains(id) ? '曲目 #$id · 已从备份恢复' : '曲目 #$id · 写入成功',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (!_restored.contains(id)) ...[
              const SizedBox(height: LekisSpacing.xxs),
              SelectableText(
                '文件：${result.filePath}\n备份：${result.backupPath}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              if (result.fields.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: LekisSpacing.xxs),
                  child: Text(
                    '写入字段：${result.fields.map(tagFieldLabel).join('、')}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _restoring.contains(id)
                      ? null
                      : () => _restore(id),
                  icon: _restoring.contains(id)
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.undo_rounded, size: 18),
                  label: const Text('从备份恢复'),
                ),
              ),
            ],
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: LekisSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '曲目 #$id · ${_kindLabel(item.errorKind)}',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.error,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (item.error != null)
            Text(
              item.error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _restored.contains(id) || _restoring.contains(id)
                  ? null
                  : () => _restore(id),
              icon: _restoring.contains(id)
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.restore_rounded, size: 18),
              label: Text(_restored.contains(id) ? '已从备份恢复' : '从备份恢复'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _restore(int trackId) async {
    setState(() => _restoring.add(trackId));
    try {
      final result = await core.restoreTrackTags(trackId: trackId);
      if (!mounted) return;
      setState(() => _restored.add(trackId));
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('已从备份恢复：${result.backupPath}')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('恢复失败：${describeCoreError(error)}')),
        );
    } finally {
      if (mounted) setState(() => _restoring.remove(trackId));
    }
  }

  static int _id(BatchTagWriteItemDto item) => item.trackId;

  static String _kindLabel(ErrorKind? kind) => switch (kind) {
    ErrorKind.unsupported => '格式或音源不支持',
    ErrorKind.permissionDenied => '没有写入权限 / 文件只读或被占用',
    ErrorKind.notFound => '文件或曲目不存在',
    ErrorKind.decode => '标签写入或校验失败',
    ErrorKind.invalidArgument => '参数不合法',
    ErrorKind.io => '文件读写失败',
    ErrorKind.database => '资料库写入失败',
    _ => '写入失败',
  };
}
