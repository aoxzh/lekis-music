import 'package:file_picker/file_picker.dart';
import 'package:lekis/src/features/library/library_actions.dart'
    show describeCoreError;
import 'package:lekis/src/features/library/music_export_destination.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/music_export.dart' as api;
import 'package:material_ui/material_ui.dart';

Future<void> showMusicExport(
  BuildContext context, {
  int? trackId,
  int? albumId,
  List<int>? albumTrackIds,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _ExportDialog(
    trackId: trackId,
    albumId: albumId,
    albumTrackIds: albumTrackIds,
  ),
);

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({this.trackId, this.albumId, this.albumTrackIds});
  final int? trackId;
  final int? albumId;
  final List<int>? albumTrackIds;
  bool get isAlbum => albumId != null || albumTrackIds != null;
  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  late String template = widget.isAlbum ? '{disc}-{track} {title}' : '{title}';
  Uri? directory;
  String? error;
  bool artwork = true;
  bool lyrics = true;
  bool busy = false;
  List<api.MusicExportItemDto>? report;

  Future<void> pickDirectory() async {
    try {
      final selected = await FilePicker.pickDirectory(
        dialogTitle: context.l10n.pick('选择导出目录', 'Choose export folder'),
      );
      if (!mounted || selected == null) return;
      setState(() {
        directory = selected;
        error = null;
      });
    } catch (exception) {
      if (mounted) setState(() => error = describeCoreError(exception));
    }
  }

  Future<void> export() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final rows = await exportToDestination(
        trackId: widget.trackId,
        albumId: widget.albumId,
        albumTrackIds: widget.albumTrackIds,
        destination: directory!,
        nameTemplate: template,
        includeArtwork: artwork,
        includeLyrics: lyrics,
      );
      if (mounted) setState(() => report = rows);
    } catch (exception) {
      if (mounted) setState(() => error = describeCoreError(exception));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pick = context.l10n.pick;
    final rows = report;
    final successful = rows?.where((row) => row.outputPath != null).length ?? 0;
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        title: Text(
          widget.isAlbum
              ? pick('导出整张专辑', 'Export album')
              : pick('导出音乐文件', 'Export music file'),
        ),
        content: SizedBox(
          width: 440,
          height: rows == null
              ? null
              : (56.0 + 88.0 * rows.length).clamp(96.0, 400.0),
          child: rows == null
              ? SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      OutlinedButton.icon(
                        onPressed: busy ? null : pickDirectory,
                        icon: const Icon(Icons.folder_open),
                        label: Text(
                          directory?.toString() ??
                              pick('选择目录…', 'Choose folder…'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        enabled: !busy,
                        initialValue: template,
                        decoration: InputDecoration(
                          labelText: pick('文件名模板', 'Filename template'),
                          helperText:
                              '{title}  {artist}  {album}  {disc}  {track}',
                          helperMaxLines: 2,
                        ),
                        onChanged: (value) => setState(() => template = value),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(pick('嵌入封面', 'Embed artwork')),
                        value: artwork,
                        onChanged: busy
                            ? null
                            : (value) => setState(() => artwork = value!),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(pick('嵌入歌词', 'Embed lyrics')),
                        value: lyrics,
                        onChanged: busy
                            ? null
                            : (value) => setState(() => lyrics = value!),
                      ),
                      Text(
                        pick(
                          '保留原音频格式，同名文件会跳过并列出。',
                          'Keeps the audio format. Existing filenames are skipped and reported.',
                        ),
                      ),
                      if (error != null) SelectableText(error!),
                      if (busy) const LinearProgressIndicator(),
                    ],
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pick(
                        '已导出 $successful / ${rows.length} 首',
                        'Exported $successful of ${rows.length} tracks',
                      ),
                    ),
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: rows.length,
                        itemBuilder: (context, index) {
                          final row = rows[index];
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(row.title),
                            subtitle: SelectableText(
                              row.outputPath ?? row.error ?? '',
                            ),
                            leading: Icon(
                              row.outputPath == null
                                  ? Icons.error_outline
                                  : Icons.check,
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: Text(pick('关闭', 'Close')),
          ),
          if (rows == null)
            FilledButton(
              onPressed: busy || directory == null || template.trim().isEmpty
                  ? null
                  : export,
              child: Text(pick('导出', 'Export')),
            ),
        ],
      ),
    );
  }
}
