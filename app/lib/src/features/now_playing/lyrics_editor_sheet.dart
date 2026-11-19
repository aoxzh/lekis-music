// Manual lyrics editor (ENR-07): paste/import LRC, choose format, tune offset.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/now_playing/now_playing_providers.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

Future<void> showLyricsEditor(
  BuildContext context,
  WidgetRef ref,
  int trackId,
) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _LyricsEditorSheet(trackId: trackId),
  );
  ref.invalidate(lyricsProvider(trackId));
}

class _LyricsEditorSheet extends ConsumerStatefulWidget {
  const _LyricsEditorSheet({required this.trackId});

  final int trackId;

  @override
  ConsumerState<_LyricsEditorSheet> createState() => _LyricsEditorSheetState();
}

class _LyricsEditorSheetState extends ConsumerState<_LyricsEditorSheet> {
  final _content = TextEditingController();
  var _format = LyricsFormatDto.lrc;
  var _offset = 0;
  var _loading = true;
  var _saving = false;
  String? _error;
  List<LyricsRowDto> _versions = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        core.lyrics(trackId: widget.trackId),
        core.lyricsVersions(trackId: widget.trackId),
      ]);
      final current = results[0] as LyricsDto?;
      if (!mounted) return;
      setState(() {
        _versions = results[1] as List<LyricsRowDto>;
        _content.text = current?.content ?? '';
        _format = current?.format ?? LyricsFormatDto.lrc;
        _offset = current?.offsetMs ?? 0;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    final text = _content.text.trim();
    if (text.isEmpty) {
      setState(() => _error = '歌词内容不能为空');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await core.setLyrics(
        trackId: widget.trackId,
        lyrics: LyricsDto(
          format: _format,
          content: text,
          source: 'manual',
          offsetMs: _offset,
          confidence: 1,
        ),
      );
      await core.setLyricsOffset(
        trackId: widget.trackId,
        offsetMs: _offset,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '保存失败：$e';
      });
    }
  }

  @override
  void dispose() {
    _content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        LekisSpacing.lg,
        0,
        LekisSpacing.lg,
        LekisSpacing.lg + bottom,
      ),
      child: _loading
          ? const SizedBox(
              height: 180,
              child: Center(child: CircularProgressIndicator()),
            )
          : SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(Icons.edit_note, color: colors.moon),
                      const SizedBox(width: LekisSpacing.sm),
                      Text('编辑歌词', style: theme.textTheme.titleLarge),
                      const Spacer(),
                      TextButton(
                        onPressed: _saving
                            ? null
                            : () => Navigator.of(context).pop(),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: _saving ? null : _save,
                        child: _saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('保存'),
                      ),
                    ],
                  ),
                  const SizedBox(height: LekisSpacing.sm),
                  Text(
                    '粘贴 LRC / 增强 LRC / TTML，或直接写纯文本。保存后会作为“manual”版本并立即生效。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: LekisSpacing.lg),
                  SegmentedButton<LyricsFormatDto>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: LyricsFormatDto.lrc,
                        label: Text('LRC'),
                      ),
                      ButtonSegment(
                        value: LyricsFormatDto.enhancedLrc,
                        label: Text('逐字'),
                      ),
                      ButtonSegment(
                        value: LyricsFormatDto.ttml,
                        label: Text('TTML'),
                      ),
                      ButtonSegment(
                        value: LyricsFormatDto.plain,
                        label: Text('纯文本'),
                      ),
                    ],
                    selected: {_format},
                    onSelectionChanged: (s) =>
                        setState(() => _format = s.first),
                  ),
                  const SizedBox(height: LekisSpacing.lg),
                  TextField(
                    controller: _content,
                    minLines: 8,
                    maxLines: 16,
                    style: const TextStyle(fontFamily: 'monospace'),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: '歌词内容',
                      hintText: '[00:01.00]第一句\n[00:05.00]第二句',
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: LekisSpacing.lg),
                  Row(
                    children: [
                      const Text('整体偏移'),
                      const SizedBox(width: LekisSpacing.sm),
                      Expanded(
                        child: Slider(
                          value: _offset.toDouble(),
                          min: -5000,
                          max: 5000,
                          divisions: 100,
                          label: '${_offset >= 0 ? '+' : ''}${_offset}ms',
                          onChanged: (v) =>
                              setState(() => _offset = v.round()),
                        ),
                      ),
                      SizedBox(
                        width: 76,
                        child: Text(
                          '${_offset >= 0 ? '+' : ''}${_offset}ms',
                          textAlign: TextAlign.end,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    '正值让歌词提前出现，和 LRC 的 [offset:] 一致。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  if (_versions.isNotEmpty) ...[
                    const SizedBox(height: LekisSpacing.lg),
                    Text('已有版本', style: theme.textTheme.titleSmall),
                    const SizedBox(height: LekisSpacing.xs),
                    for (final v in _versions.take(6))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          v.isActive
                              ? Icons.check_circle
                              : Icons.description_outlined,
                          size: 20,
                          color: v.isActive ? colors.moon : null,
                        ),
                        title: Text(
                          '${v.lyrics.source} · ${v.lyrics.format.name}',
                        ),
                        subtitle: Text('${v.lyrics.content.length} 字符'),
                      ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: LekisSpacing.sm),
                    Text(
                      _error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}
