// Manual lyrics editor (ENR-07): paste/import LRC, choose format, tune offset.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/now_playing/now_playing_providers.dart';
import 'package:lekis/src/features/now_playing/lyrics_parser.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/rust/api/error.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:lekis/src/widgets/adaptive_panel.dart';
import 'package:lekis/src/widgets/lekis_slider.dart';
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
  String _loadedContent = '';
  var _loadedFormat = LyricsFormatDto.lrc;
  var _loadedOffset = 0;
  var _loading = true;
  var _saving = false;
  String? _error;
  String? _notice;
  List<LyricsRowDto> _versions = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _lookupError(Object error) {
    if (error is CoreError && error.kind == ErrorKind.rateLimited) {
      return context.l10n.pick(
        '歌词来源暂时限流，请稍后重试。',
        'Lyrics source is busy. Please retry later.',
      );
    }
    return context.l10n.pick(
      '歌词查找失败，请检查网络后重试。',
      'Lyrics lookup failed. Check your connection and retry.',
    );
  }

  Future<void> _load({bool preserveDraft = false}) async {
    LyricsDto? current;
    String? error;
    try {
      current = await core.lyrics(trackId: widget.trackId);
    } catch (e) {
      if (!mounted) return;
      error = _lookupError(e);
    }
    try {
      // Fetch versions after lookup, including new candidates awaiting selection.
      final versions = await core.lyricsVersions(trackId: widget.trackId);
      if (!mounted) return;
      setState(() {
        _versions = versions;
        final hasDraft =
            _content.text != _loadedContent ||
            _format != _loadedFormat ||
            _offset != _loadedOffset;
        _loadedContent = current?.content ?? '';
        _loadedFormat = current?.format ?? LyricsFormatDto.lrc;
        _loadedOffset = current?.offsetMs ?? 0;
        if (!preserveDraft || !hasDraft) {
          _content.text = _loadedContent;
          _format = _loadedFormat;
          _offset = _loadedOffset;
        }
        _error = error;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = context.l10n.pick(
          '无法读取歌词版本，请重试。',
          'Could not load lyrics versions. Please retry.',
        );
        _loading = false;
      });
    }
  }

  Future<void> _preview(LyricsRowDto version) async {
    final parsed = ParsedLyrics.parse(version.lyrics);
    // The parser falls back to raw text for malformed TTML; do not show XML
    // markup as if it were lyrics.
    final lines =
        version.lyrics.format == LyricsFormatDto.ttml && !parsed.synced
        ? <LyricLine>[]
        : parsed.lines;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.pick('歌词预览', 'Lyrics preview')),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: lines.isEmpty
                ? Text(
                    context.l10n.pick(
                      '无法预览此歌词。',
                      'This lyrics version cannot be previewed.',
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final line in lines) ...[
                        Text(line.text),
                        if (line.translation != null) Text(line.translation!),
                      ],
                    ],
                  ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.l10n.pick('关闭', 'Close')),
          ),
        ],
      ),
    );
  }

  Future<void> _activate(LyricsRowDto version) async {
    setState(() {
      _saving = true;
      _error = null;
      _notice = null;
    });
    try {
      await core.activateLyrics(trackId: widget.trackId, lyricsId: version.id);
      ref.invalidate(lyricsProvider(widget.trackId));
      await _load();
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _error = context.l10n.pick(
          '切换歌词失败，请重试。',
          'Could not switch lyrics. Please retry.',
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _retry() async {
    setState(() {
      _saving = true;
      _error = null;
      _notice = null;
    });
    try {
      final result = await core.retryLyrics(trackId: widget.trackId);
      ref.invalidate(lyricsProvider(widget.trackId));
      await _load(preserveDraft: true);
      if (!mounted) return;
      setState(
        () => _notice = result == null
            ? context.l10n.pick(
                '未找到可自动使用的歌词；如有候选，请在下方选择。',
                'No automatic match. Select a candidate below if available.',
              )
            : context.l10n.pick(
                '歌词版本已更新，当前选择已保留。',
                'Lyrics versions refreshed. Your current selection is preserved.',
              ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _lookupError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _save() async {
    final text = _content.text.trim();
    if (text.isEmpty) {
      setState(
        () => _error = context.l10n.pick(
          '歌词内容不能为空',
          'Lyrics content cannot be empty',
        ),
      );
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
      await core.setLyricsOffset(trackId: widget.trackId, offsetMs: _offset);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = context.l10n.pick('保存失败：$e', 'Save failed: $e');
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
      title: context.l10n.pick('编辑歌词', 'Edit Lyrics'),
      subtitle: context.l10n.pick(
        '粘贴 LRC / 增强 LRC / TTML，或直接写纯文本。保存后作为“手动”版本立即生效。',
        'Paste LRC / Enhanced LRC / TTML, or write plain text. Takes effect immediately as the "manual" version.',
      ),
      onClose: close,
      error: _error,
      actions: [
        TextButton.icon(
          key: const ValueKey('lyrics-editor.retry'),
          onPressed: _saving || _loading ? null : _retry,
          icon: const Icon(Icons.refresh_rounded),
          label: Text(context.l10n.pick('重新查找', 'Retry lookup')),
        ),
        TextButton(
          onPressed: close,
          child: Text(context.l10n.pick('取消', 'Cancel')),
        ),
        FilledButton.icon(
          key: const ValueKey('lyrics-editor.save'),
          onPressed: _saving || _loading ? null : _save,
          icon: _saving
              ? const LekisPanelProgress()
              : const Icon(Icons.check_rounded),
          label: Text(context.l10n.pick('保存', 'Save')),
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
                if (_notice != null) ...[
                  Text(
                    _notice!,
                    key: const ValueKey('lyrics-editor.notice'),
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: LekisSpacing.md),
                ],
                _Label(
                  context.l10n.pick('格式', 'Format'),
                  theme: theme,
                  colors: colors,
                ),
                SegmentedButton<LyricsFormatDto>(
                  showSelectedIcon: false,
                  segments: [
                    const ButtonSegment(
                      value: LyricsFormatDto.lrc,
                      label: Text('LRC'),
                    ),
                    ButtonSegment(
                      value: LyricsFormatDto.enhancedLrc,
                      label: Text(context.l10n.pick('逐字', 'Word-by-word')),
                    ),
                    const ButtonSegment(
                      value: LyricsFormatDto.ttml,
                      label: Text('TTML'),
                    ),
                    ButtonSegment(
                      value: LyricsFormatDto.plain,
                      label: Text(context.l10n.pick('纯文本', 'Plain text')),
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
                  decoration: InputDecoration(
                    labelText: context.l10n.pick('歌词内容', 'Lyrics content'),
                    hintText: context.l10n.pick(
                      '[00:01.00]第一句\n[00:05.00]第二句',
                      '[00:01.00]First line\n[00:05.00]Second line',
                    ),
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: LekisSpacing.lg),
                _Label(
                  context.l10n.pick('整体偏移', 'Global offset'),
                  theme: theme,
                  colors: colors,
                ),
                Row(
                  children: [
                    Expanded(
                      child: LekisSlider(
                        value: _offset.toDouble(),
                        min: -5000,
                        max: 5000,
                        divisions: 100,
                        label: _offsetLabel,
                        semanticFormatterCallback: (_) => _offsetLabel,
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
                  context.l10n.pick(
                    '正值让歌词提前出现，和 LRC 的 [offset:] 一致。',
                    'Positive values make lyrics appear earlier, matching LRC [offset:].',
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                if (_versions.isNotEmpty) ...[
                  const SizedBox(height: LekisSpacing.xl),
                  _Label(
                    context.l10n.pick('已有版本', 'Existing versions'),
                    theme: theme,
                    colors: colors,
                  ),
                  for (final v in _versions)
                    ListTile(
                      key: ValueKey('lyrics-editor.version.${v.id}'),
                      onTap: _saving || v.isActive ? null : () => _activate(v),
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
                      trailing: IconButton(
                        key: ValueKey('lyrics-editor.preview.${v.id}'),
                        tooltip: context.l10n.pick('预览歌词', 'Preview lyrics'),
                        onPressed: _saving ? null : () => _preview(v),
                        icon: const Icon(Icons.visibility_outlined),
                      ),
                      title: Text(
                        '${v.lyrics.source} · ${v.lyrics.format.name}',
                      ),
                      subtitle: Text(
                        context.l10n.pick(
                          '${v.lyrics.content.length} 字符',
                          '${v.lyrics.content.length} chars',
                        ),
                      ),
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
