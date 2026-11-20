// Manual lyrics editor (ENR-07): paste/import LRC, choose format, tune offset.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/now_playing/now_playing_providers.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:lekis/src/widgets/adaptive_panel.dart';
import 'package:material_ui/material_ui.dart';

/// Opens the lyrics editor: a dialog on wide windows, a bottom sheet on
/// phones (see [showLekisPanel]).
Future<void> showLyricsEditor(
  BuildContext context,
  WidgetRef ref,
  int trackId,
) async {
  await showLekisPanel<void>(
    context,
    dismissible: false,
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

  String get _offsetLabel => '${_offset >= 0 ? '+' : ''}${_offset}ms';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final close = _saving ? null : () => Navigator.of(context).pop();
    return LekisPanel(
      title: '编辑歌词',
      subtitle: '粘贴 LRC / 增强 LRC / TTML，或直接写纯文本。保存后作为“手动”版本立即生效。',
      onClose: close,
      error: _error,
      actions: [
        TextButton(onPressed: close, child: const Text('取消')),
        FilledButton.icon(
          key: const ValueKey('lyrics-editor.save'),
          onPressed: _saving || _loading ? null : _save,
          icon: _saving
              ? const LekisPanelProgress()
              : const Icon(Icons.check_rounded),
          label: const Text('保存'),
        ),
      ],
      body: _loading
          ? const SizedBox(
              height: LekisSizes.gridArtworkMin,
              child: Center(child: CircularProgressIndicator()),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                _Label('格式', theme: theme, colors: colors),
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
                  onSelectionChanged: _saving
                      ? null
                      : (s) => setState(() => _format = s.first),
                ),
                const SizedBox(height: LekisSpacing.lg),
                TextField(
                  key: const ValueKey('lyrics-editor.content'),
                  controller: _content,
                  enabled: !_saving,
                  minLines: 8,
                  maxLines: 16,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFamily: 'monospace',
                  ),
                  decoration: const InputDecoration(
                    labelText: '歌词内容',
                    hintText: '[00:01.00]第一句\n[00:05.00]第二句',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: LekisSpacing.lg),
                _Label('整体偏移', theme: theme, colors: colors),
                Row(
                  children: [
                    Expanded(
                      child: Slider(
                        value: _offset.toDouble(),
                        min: -5000,
                        max: 5000,
                        divisions: 100,
                        label: _offsetLabel,
                        onChanged: _saving
                            ? null
                            : (v) => setState(() => _offset = v.round()),
                      ),
                    ),
                    SizedBox(
                      width: LekisSpacing.xxxl + LekisSpacing.xl,
                      child: Text(
                        _offsetLabel,
                        textAlign: TextAlign.end,
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
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
                  const SizedBox(height: LekisSpacing.xl),
                  _Label('已有版本', theme: theme, colors: colors),
                  for (final v in _versions.take(6))
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        v.isActive
                            ? Icons.check_circle_rounded
                            : Icons.description_outlined,
                        size: LekisSpacing.xl - LekisSpacing.xs,
                        color: v.isActive
                            ? colors.accent
                            : colors.onSurfaceVariant,
                      ),
                      title: Text(
                        '${v.lyrics.source} · ${v.lyrics.format.name}',
                      ),
                      subtitle: Text('${v.lyrics.content.length} 字符'),
                    ),
                ],
              ],
            ),
    );
  }
}

/// Small section label above a control (same as the tag editor's).
class _Label extends StatelessWidget {
  const _Label(this.text, {required this.theme, required this.colors});

  final String text;
  final ThemeData theme;
  final LekisColors colors;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: LekisSpacing.sm),
    child: Text(
      text,
      style: theme.textTheme.labelMedium?.copyWith(
        color: colors.onSurfaceVariant,
      ),
    ),
  );
}
