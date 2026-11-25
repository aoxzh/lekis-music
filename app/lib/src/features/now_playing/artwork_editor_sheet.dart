// 封面补全与编辑面板（正在播放页「更多」菜单入口）。
//
// 仿照歌词编辑器（lyrics_editor_sheet.dart）的交互模式：
//  * 支持按歌名 / 艺人 / 专辑手动在线搜索高清封面并大图预览选用；
//  * 支持上传本地图片（FilePicker）或粘贴在线图片链接；
//  * 支持勾选是否同时应用到整张专辑、移除当前封面，以及操作后一键撤销。

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Int64List;
import 'package:lekis/src/features/library/artwork_actions.dart';
import 'package:lekis/src/features/library/library_actions.dart'
    show describeCoreError;
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/artwork_search.dart' as artwork_search;
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:lekis/src/widgets/adaptive_panel.dart';
import 'package:material_ui/material_ui.dart';

/// 打开封面补全 / 编辑面板（窄屏底部面板，宽屏对话框）。
Future<void> showArtworkEditor(
  BuildContext context,
  WidgetRef ref,
  TrackDto track,
) async {
  await showLekisPanel<void>(
    context,
    dismissible: false,
    builder: (_) => _ArtworkEditorSheet(track: track),
  );
  ref.invalidate(currentArtworkProvider);
  ref.invalidate(currentTrackProvider);
}

class _ArtworkEditorSheet extends ConsumerStatefulWidget {
  const _ArtworkEditorSheet({required this.track});

  final TrackDto track;

  @override
  ConsumerState<_ArtworkEditorSheet> createState() =>
      _ArtworkEditorSheetState();
}

class _ArtworkEditorSheetState extends ConsumerState<_ArtworkEditorSheet> {
  late final TextEditingController _titleController;
  late final TextEditingController _artistController;
  late final TextEditingController _albumController;
  final _urlController = TextEditingController();

  List<artwork_search.ArtworkSearchResultDto> _results = const [];
  artwork_search.ArtworkSearchResultDto? _previewing;
  late bool _applyToAlbum;
  bool _showUrlInput = false;
  bool _searching = false;
  bool _searched = false;
  bool _saving = false;
  String? _error;

  bool get _hasCover => widget.track.artworkId != null;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.track.title);
    _artistController = TextEditingController(
      text: widget.track.artists.firstOrNull ?? '',
    );
    _albumController = TextEditingController(
      text: widget.track.albumTitle ?? '',
    );
    _applyToAlbum = widget.track.albumId != null && !_hasCover;
    // 缺少封面时打开面板自动执行一次在线检索，减少多余点击。
    if (!_hasCover &&
        (_titleController.text.trim().isNotEmpty ||
            _albumController.text.trim().isNotEmpty)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_search());
      });
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _artistController.dispose();
    _albumController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  int? get _targetAlbumId =>
      _applyToAlbum ? widget.track.albumId?.toInt() : null;

  Future<void> _search() async {
    final title = _titleController.text.trim();
    final album = _albumController.text.trim();
    if ((title.isEmpty && album.isEmpty) || _searching || _saving) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final hits = await artwork_search.searchArtworkCandidates(
        trackId: widget.track.id,
        title: title,
        artist: _artistController.text.trim(),
        album: album.isEmpty ? null : album,
      );
      if (!mounted) return;
      setState(() {
        _results = hits;
        _searched = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searched = true;
        _error = context.l10n.pick(
          '封面搜索失败：${describeCoreError(e)}',
          'Artwork search failed: ${describeCoreError(e)}',
        );
      });
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _notifyApplied(ArtworkChangeDto change) {
    final messenger = ScaffoldMessenger.maybeOf(context);
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
                ref.invalidate(currentArtworkProvider);
                ref.invalidate(currentTrackProvider);
                messenger
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    SnackBar(content: Text(ArtworkActionStrings.restored)),
                  );
              } catch (e) {
                messenger
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    SnackBar(
                      content: Text(
                        ArtworkActionStrings.failedWith(describeCoreError(e)),
                      ),
                    ),
                  );
              }
            },
          ),
        ),
      );
  }

  Future<void> _uploadLocalImage() async {
    if (_saving) return;
    try {
      final file = await FilePicker.pickFile(
        dialogTitle: ArtworkActionStrings.pickTitle,
        type: FileType.image,
      );
      if (file == null || !mounted) return;
      setState(() {
        _saving = true;
        _error = null;
      });
      final bytes = await file.readAsBytes();
      final change = await core.setArtworkFromImage(
        image: bytes,
        trackIds: Int64List.fromList([widget.track.id]),
        albumId: _targetAlbumId,
      );
      if (!mounted) return;
      _notifyApplied(change);
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = ArtworkActionStrings.failedWith(describeCoreError(e));
      });
    }
  }

  Future<void> _applyUrl(String rawUrl) async {
    final url = rawUrl.trim();
    if (url.isEmpty || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final change = await artwork_search.setArtworkFromUrl(
        url: url,
        trackIds: Int64List.fromList([widget.track.id]),
        albumId: _targetAlbumId,
      );
      if (!mounted) return;
      _notifyApplied(change);
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = ArtworkActionStrings.failedWith(describeCoreError(e));
      });
    }
  }

  Future<void> _removeCover() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await core.setTrackArtwork(trackId: widget.track.id, artworkId: null);
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(ArtworkActionStrings.removed)));
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = ArtworkActionStrings.failedWith(describeCoreError(e));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _previewing;
    return PopScope<void>(
      canPop: !_saving && preview == null,
      onPopInvokedWithResult: (popped, _) {
        if (!popped && preview != null) {
          setState(() => _previewing = null);
        }
      },
      child: preview == null ? _buildMain(context) : _buildPreview(context, preview),
    );
  }

  Widget _buildPreview(
    BuildContext context,
    artwork_search.ArtworkSearchResultDto candidate,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final meta = [
      _sourceLabel(candidate.source),
      if (candidate.width != null && candidate.height != null)
        '${candidate.width}×${candidate.height}',
      if (candidate.album != null && candidate.album!.isNotEmpty)
        candidate.album!,
      if (candidate.artist != null && candidate.artist!.isNotEmpty)
        candidate.artist!,
    ].join(' · ');
    return LekisPanel(
      step: 'preview',
      title: context.l10n.pick('预览封面', 'Preview Artwork'),
      onClose: _saving ? null : () => setState(() => _previewing = null),
      error: _error,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280, maxHeight: 280),
              child: AspectRatio(
                aspectRatio: 1,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(LekisRadius.md),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                    ),
                    child: Image.network(
                      candidate.url,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const Center(
                        child: Icon(Icons.broken_image_outlined, size: 42),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: LekisSpacing.md),
          if (candidate.title != null && candidate.title!.isNotEmpty)
            Text(
              candidate.title!,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall,
            ),
          if (meta.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              meta,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          if (widget.track.albumId != null) ...[
            const SizedBox(height: LekisSpacing.sm),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _applyToAlbum,
              onChanged: _saving
                  ? null
                  : (v) => setState(() => _applyToAlbum = v ?? false),
              title: Text(
                context.l10n.pick(
                  '同时应用到整张专辑',
                  'Also apply to the entire album',
                ),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => setState(() => _previewing = null),
          child: Text(MaterialLocalizations.of(context).backButtonTooltip),
        ),
        FilledButton.icon(
          key: const ValueKey('artwork-editor.apply-candidate'),
          onPressed: _saving ? null : () => _applyUrl(candidate.url),
          icon: _saving
              ? const LekisPanelProgress()
              : const Icon(Icons.check_rounded),
          label: Text(context.l10n.pick('使用这张封面', 'Use This Cover')),
        ),
      ],
    );
  }

  Widget _buildMain(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final close = _saving ? null : () => Navigator.of(context).pop();
    final l10n = context.l10n;

    return LekisPanel(
      step: 'editor',
      title: _hasCover
          ? l10n.pick('编辑封面', 'Edit Artwork')
          : l10n.pick('补全封面', 'Fetch & Edit Artwork'),
      subtitle: l10n.pick(
        '搜索在线高清封面、上传本地图片或粘贴链接。只写入本机缓存，不改动原音频文件。',
        'Search online covers, upload a local image, or paste an image URL. Saved locally without modifying audio files.',
      ),
      onClose: close,
      error: _error,
      actions: [
        TextButton(
          onPressed: close,
          child: Text(l10n.pick('关闭', 'Close')),
        ),
      ],
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox.square(
                dimension: 64,
                child: TrackArtwork(
                  trackId: widget.track.id,
                  hasArtwork: _hasCover || !widget.track.isLocal,
                  placeholderLabel: widget.track.title,
                  radius: LekisRadius.sm,
                ),
              ),
              const SizedBox(width: LekisSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (widget.track.artists.isNotEmpty)
                          widget.track.artists.join(' / '),
                        if (widget.track.albumTitle != null &&
                            widget.track.albumTitle!.isNotEmpty)
                          widget.track.albumTitle!,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _hasCover
                          ? l10n.pick('当前已有封面', 'Current cover set')
                          : l10n.pick('当前缺少封面', 'No cover yet'),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: _hasCover
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (widget.track.albumId != null) ...[
            const SizedBox(height: LekisSpacing.xs),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: _applyToAlbum,
              onChanged: _saving
                  ? null
                  : (v) => setState(() => _applyToAlbum = v ?? false),
              title: Text(
                l10n.pick('同时应用到整张专辑', 'Also apply to the entire album'),
              ),
            ),
          ],
          const SizedBox(height: LekisSpacing.sm),
          Wrap(
            spacing: LekisSpacing.sm,
            runSpacing: LekisSpacing.xs,
            children: [
              FilledButton.tonalIcon(
                key: const ValueKey('artwork-editor.upload'),
                onPressed: _saving ? null : _uploadLocalImage,
                icon: const Icon(Icons.upload_file_rounded, size: 18),
                label: Text(l10n.pick('上传本地图片', 'Upload Image')),
              ),
              OutlinedButton.icon(
                key: const ValueKey('artwork-editor.url-toggle'),
                onPressed: _saving
                    ? null
                    : () => setState(() => _showUrlInput = !_showUrlInput),
                icon: const Icon(Icons.link_rounded, size: 18),
                label: Text(l10n.pick('图片链接', 'Image URL')),
              ),
              if (_hasCover)
                OutlinedButton.icon(
                  key: const ValueKey('artwork-editor.remove'),
                  onPressed: _saving ? null : _removeCover,
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: Text(ArtworkActionStrings.remove),
                ),
            ],
          ),
          if (_showUrlInput) ...[
            const SizedBox(height: LekisSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('artwork-editor.url-input'),
                    controller: _urlController,
                    enabled: !_saving,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'https://…',
                      labelText: l10n.pick('粘贴图片链接', 'Paste image URL'),
                    ),
                    onSubmitted: _applyUrl,
                  ),
                ),
                const SizedBox(width: LekisSpacing.sm),
                FilledButton(
                  onPressed: _saving
                      ? null
                      : () => _applyUrl(_urlController.text),
                  child: _saving
                      ? const LekisPanelProgress()
                      : Text(l10n.pick('应用', 'Apply')),
                ),
              ],
            ),
          ],
          const Divider(height: LekisSpacing.xl),
          Text(
            l10n.pick('在线搜索封面', 'Search Online Covers'),
            style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary),
          ),
          const SizedBox(height: LekisSpacing.sm),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('artwork-editor.search-title'),
                  controller: _titleController,
                  enabled: !_searching && !_saving,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: l10n.pick('歌曲名', 'Title'),
                  ),
                ),
              ),
              const SizedBox(width: LekisSpacing.sm),
              Expanded(
                child: TextField(
                  key: const ValueKey('artwork-editor.search-artist'),
                  controller: _artistController,
                  enabled: !_searching && !_saving,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: l10n.pick('艺人', 'Artist'),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: LekisSpacing.sm),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('artwork-editor.search-album'),
                  controller: _albumController,
                  enabled: !_searching && !_saving,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: l10n.pick('专辑（可选）', 'Album (optional)'),
                  ),
                ),
              ),
              const SizedBox(width: LekisSpacing.sm),
              FilledButton.icon(
                key: const ValueKey('artwork-editor.search-submit'),
                onPressed: _searching || _saving ? null : _search,
                icon: _searching
                    ? const LekisPanelProgress()
                    : const Icon(Icons.search_rounded, size: 18),
                label: Text(l10n.pick('搜索', 'Search')),
              ),
            ],
          ),
          const SizedBox(height: LekisSpacing.md),
          if (_searching && _results.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: LekisSpacing.xl),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_searched && _results.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: LekisSpacing.lg),
              child: Text(
                l10n.pick(
                  '未找到匹配的在线封面，试试调整关键词或上传本地图片。',
                  'No matching covers found. Try adjusting keywords or upload a local image.',
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else if (_results.isNotEmpty)
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 420 ? 3 : 2;
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _results.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: LekisSpacing.sm,
                    mainAxisSpacing: LekisSpacing.sm,
                    childAspectRatio: 0.78,
                  ),
                  itemBuilder: (context, index) {
                    final item = _results[index];
                    return _ArtworkCandidateTile(
                      item: item,
                      onTap: _saving
                          ? null
                          : () => setState(() {
                              _error = null;
                              _previewing = item;
                            }),
                    );
                  },
                );
              },
            ),
        ],
      ),
    );
  }
}

class _ArtworkCandidateTile extends StatelessWidget {
  const _ArtworkCandidateTile({required this.item, required this.onTap});

  final artwork_search.ArtworkSearchResultDto item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final caption = item.album ?? item.title ?? item.artist ?? '';
    final sizeText = (item.width != null && item.height != null)
        ? '${item.width}×${item.height}'
        : null;
    return InkWell(
      borderRadius: BorderRadius.circular(LekisRadius.sm),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(LekisRadius.sm),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: scheme.surfaceContainerHighest),
                  Image.network(
                    item.url,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const Center(
                      child: Icon(Icons.broken_image_outlined),
                    ),
                  ),
                  Positioned(
                    left: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.65),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        sizeText == null
                            ? _sourceLabel(item.source)
                            : '${_sourceLabel(item.source)} · $sizeText',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            caption.isEmpty ? _sourceLabel(item.source) : caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

String _sourceLabel(String source) => switch (source.toLowerCase()) {
  'itunes' => 'iTunes',
  'deezer' => 'Deezer',
  'netease' => L10n.tr('网易云', 'NetEase'),
  'vocadb' => 'VocaDB',
  'coverartarchive' => 'CAA',
  'musicbrainz' => 'MusicBrainz',
  _ => source,
};
