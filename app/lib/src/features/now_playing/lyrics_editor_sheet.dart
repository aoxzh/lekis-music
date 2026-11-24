// Manual lyrics editor (ENR-07): paste/import LRC, choose format, tune offset.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/now_playing/now_playing_providers.dart';
import 'package:lekis/src/features/now_playing/lyrics_parser.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/rust/api/error.dart';
import 'package:lekis/src/rust/api/lyric_search.dart' as search;
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
  final _searchTitle = TextEditingController();
  final _searchArtist = TextEditingController();
  List<int> _hits = const [];
  Map<int, search.LyricSearchVersionDto> _recordings = const {};
  bool _searched = false;
  bool _searchExpanded = false;
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
    _prefillQuery();
  }

  Future<void> _prefillQuery() async {
    try {
      final track = await core.getTrack(trackId: widget.trackId);
      if (!mounted ||
          _searchTitle.text.isNotEmpty ||
          _searchArtist.text.isNotEmpty) {
        return;
      }
      setState(() {
        _searchTitle.text = track.title;
        _searchArtist.text = track.artists.firstOrNull ?? '';
      });
    } catch (_) {
      // Query fields remain editable when the track tags are unavailable.
    }
  }

  Future<void> _search() async {
    final title = _searchTitle.text.trim();
    if (title.isEmpty || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
      _notice = null;
      _hits = [];
      _searched = false;
    });
    try {
      final results = await search.searchLyricVersions(
        trackId: widget.trackId,
        title: title,
        artist: _searchArtist.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _searched = true;
        _hits = [for (final hit in results) hit.row.id];
        _recordings = {
          ..._recordings,
          for (final hit in results) hit.row.id: hit,
        };
        final rows = {
          for (final row in _versions) row.id: row,
          for (final hit in results) hit.row.id: hit.row,
        };
        _versions = rows.values.toList();
      });
    } catch (e) {
      if (mounted) setState(() => _error = _lookupError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
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
    try {
      final recordings = await search.storedLyricVersions(
        trackId: widget.trackId,
      );
      final versions = [for (final item in recordings) item.row];
      final active = versions.where((row) => row.isActive).firstOrNull?.lyrics;
      if (!mounted) return;
      setState(() {
        _versions = versions;
        _recordings = {for (final item in recordings) item.row.id: item};
        final hasDraft =
            _content.text != _loadedContent ||
            _format != _loadedFormat ||
            _offset != _loadedOffset;
        _loadedContent = active?.content ?? '';
        _loadedFormat = active?.format ?? LyricsFormatDto.lrc;
        _loadedOffset = active?.offsetMs ?? 0;
        if (!preserveDraft || !hasDraft) {
          _content.text = _loadedContent;
          _format = _loadedFormat;
          _offset = _loadedOffset;
        }
        _error = null;
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
    _searchTitle.dispose();
    _searchArtist.dispose();
    _content.dispose();
    super.dispose();
  }

  String get _offsetLabel => '${_offset >= 0 ? '+' : ''}${_offset}ms';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final stored = _versions.where(
      (v) => !_searchExpanded || !_hits.contains(v.id),
    );
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
                ExpansionTile(
                  key: const ValueKey('lyrics-editor.search'),
                  onExpansionChanged: (open) =>
                      setState(() => _searchExpanded = open),
                  title: Text(
                    context.l10n.pick('按歌名和艺人搜索', 'Search by title and artist'),
                  ),
                  children: [
                    TextField(
                      controller: _searchTitle,
                      enabled: !_saving,
                      maxLength: 512,
                      key: const ValueKey('lyrics-search.title'),
                      decoration: InputDecoration(
                        labelText: context.l10n.pick('歌名', 'Song title'),
                        counterText: '',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    TextField(
                      controller: _searchArtist,
                      enabled: !_saving,
                      maxLength: 512,
                      key: const ValueKey('lyrics-search.artist'),
                      decoration: InputDecoration(
                        labelText: context.l10n.pick(
                          '艺人（可选）',
                          'Artist (optional)',
                        ),
                        counterText: '',
                      ),
                      onSubmitted: (_) => _search(),
                    ),
                    TextButton.icon(
                      key: const ValueKey('lyrics-search.submit'),
                      onPressed: _saving || _searchTitle.text.trim().isEmpty
                          ? null
                          : _search,
                      icon: const Icon(Icons.search),
                      label: Text(context.l10n.pick('搜索版本', 'Search versions')),
                    ),
                    if (_searched && _hits.isEmpty)
                      Text(
                        context.l10n.pick('没有符合条件的版本', 'No matching versions'),
                      ),
                    for (final id in _hits)
                      if (_recordings[id] case final hit?)
                        _versionTile(hit.row, result: true),
                  ],
                ),
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
                if (stored.isNotEmpty) ...[
                  const SizedBox(height: LekisSpacing.xl),
                  _Label(
                    context.l10n.pick('已有版本', 'Existing versions'),
                    theme: theme,
                    colors: colors,
                  ),
                  for (final v in stored) _versionTile(v),
                ],
              ],
            ),
    );
  }

  Widget _versionTile(LyricsRowDto v, {bool result = false}) {
    final colors = context.lekisColors;
    final metadata = _recordings[v.id];
    final duration = metadata?.durationMs;
    final detail = [
      if (metadata?.artists.isNotEmpty ?? false) metadata!.artists.join(' / '),
      if (metadata?.album case final String album) album,
      if (duration != null)
        '${duration ~/ 60000}:${(duration ~/ 1000 % 60).toString().padLeft(2, '0')}',
      context.l10n.lyricsSourceName(v.lyrics.source),
      v.lyrics.format.name,
    ].join(' · ');
    return ListTile(
      key: ValueKey('lyrics-editor.${result ? 'result' : 'version'}.${v.id}'),
      onTap: _saving || v.isActive ? null : () => _activate(v),
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        v.isActive ? Icons.check_circle_rounded : Icons.description_outlined,
        size: LekisSpacing.xl - LekisSpacing.xs,
        color: v.isActive ? colors.accent : colors.onSurfaceVariant,
      ),
      trailing: IconButton(
        key: ValueKey(
          'lyrics-editor.${result ? 'result-preview' : 'preview'}.${v.id}',
        ),
        tooltip: context.l10n.pick('预览歌词', 'Preview lyrics'),
        onPressed: _saving ? null : () => _preview(v),
        icon: const Icon(Icons.visibility_outlined),
      ),
      title: Text(metadata?.title ?? detail),
      subtitle: Text(
        metadata?.title != null
            ? detail
            : context.l10n.pick(
                '${v.lyrics.content.length} 字符',
                '${v.lyrics.content.length} chars',
              ),
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
