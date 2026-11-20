// 「选择文件夹」：添加 NAS 音源时逐级浏览远端目录，点一下选中子文件夹，
// 不用手打路径。目录内容由调用方给的 `load` 从核心取（`browse_source`）。

import 'package:material_ui/material_ui.dart';

import '../../../rust/api/dto.dart';
import '../../../theme/tokens.dart';
import '../common.dart';
import '../strings.dart';

/// 读一层目录。`path` 相对于音源根目录，`/` 分隔，空串是根。
typedef RemoteFolderLoader = Future<SourceListingDto> Function(String path);

/// 弹出文件夹浏览器。选中时返回相对路径（根目录是空串），取消时返回 `null`。
Future<String?> showRemoteFolderPicker(
  BuildContext context, {
  required RemoteFolderLoader load,
  String initialPath = '',
}) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (context) => FractionallySizedBox(
    heightFactor: 0.85,
    child: RemoteFolderBrowser(
      load: load,
      initialPath: initialPath,
      onPick: (path) => Navigator.of(context).pop(path),
    ),
  ),
);

/// 把用户输入的子路径规范成 `a/b`（去掉首尾斜杠、`.` 和空段）。
String normalizeRemotePath(String raw) => raw
    .split(RegExp(r'[\\/]'))
    .where((s) => s.isNotEmpty && s != '.')
    .join('/');

class RemoteFolderBrowser extends StatefulWidget {
  const RemoteFolderBrowser({
    super.key,
    required this.load,
    required this.onPick,
    this.initialPath = '',
  });

  final RemoteFolderLoader load;
  final ValueChanged<String> onPick;
  final String initialPath;

  @override
  State<RemoteFolderBrowser> createState() => _RemoteFolderBrowserState();
}

class _RemoteFolderBrowserState extends State<RemoteFolderBrowser> {
  late String _path;
  SourceListingDto? _listing;
  Object? _error;
  bool _loading = false;

  /// 每次跳转的序号：快速连点时只认最后一次的结果。
  int _run = 0;

  @override
  void initState() {
    super.initState();
    _path = normalizeRemotePath(widget.initialPath);
    _open(_path);
  }

  Future<void> _open(String path) async {
    final run = ++_run;
    setState(() {
      _path = path;
      _loading = true;
      _error = null;
      _listing = null;
    });
    try {
      final listing = await widget.load(path);
      if (!mounted || run != _run) return;
      setState(() {
        _listing = listing;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || run != _run) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  String get _parent {
    final i = _path.lastIndexOf('/');
    return i < 0 ? '' : _path.substring(0, i);
  }

  String _child(String name) => _path.isEmpty ? name : '$_path/$name';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    final listing = _listing;
    final error = _error;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.featureGutter,
        0,
        context.featureGutter,
        LekisSpacing.lg + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(SourcesStrings.browseTitle, style: theme.textTheme.titleLarge),
          const SizedBox(height: LekisSpacing.sm),
          Row(
            children: [
              IconButton(
                key: const ValueKey('remote-folder-up'),
                tooltip: SourcesStrings.browseUp,
                onPressed: _path.isEmpty || _loading
                    ? null
                    : () => _open(_parent),
                icon: const Icon(Icons.arrow_upward),
              ),
              const SizedBox(width: LekisSpacing.xs),
              Expanded(
                child: Text(
                  _path.isEmpty ? SourcesStrings.browseRoot : '/$_path',
                  key: const ValueKey('remote-folder-path'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          const Divider(),
          Expanded(child: _body(context, listing, error, muted)),
          const SizedBox(height: LekisSpacing.sm),
          if (listing != null)
            Padding(
              padding: const EdgeInsets.only(bottom: LekisSpacing.sm),
              child: Text(
                SourcesStrings.browseAudioCount(listing.audioFiles),
                style: muted,
              ),
            ),
          FilledButton.icon(
            key: const ValueKey('remote-folder-pick'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, LekisSizes.touchTargetMin),
            ),
            onPressed: listing == null ? null : () => widget.onPick(_path),
            icon: const Icon(Icons.check),
            label: const Text(SourcesStrings.browseUseThis),
          ),
        ],
      ),
    );
  }

  Widget _body(
    BuildContext context,
    SourceListingDto? listing,
    Object? error,
    TextStyle? muted,
  ) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${SourcesStrings.browseFailed}：${describeCoreError(error)}',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: context.lekisColors.danger),
            ),
            const SizedBox(height: LekisSpacing.md),
            Wrap(
              spacing: LekisSpacing.sm,
              children: [
                OutlinedButton(
                  onPressed: () => _open(_path),
                  child: const Text(SourcesStrings.retry),
                ),
                if (_path.isNotEmpty)
                  TextButton(
                    onPressed: () => _open(''),
                    child: const Text(SourcesStrings.browseRoot),
                  ),
              ],
            ),
          ],
        ),
      );
    }
    final folders = listing?.folders ?? const <String>[];
    if (folders.isEmpty) {
      return Center(child: Text(SourcesStrings.browseEmpty, style: muted));
    }
    return ListView.builder(
      itemCount: folders.length,
      itemBuilder: (context, i) {
        final name = folders[i];
        return ListTile(
          key: ValueKey('remote-folder:$name'),
          minTileHeight: LekisSizes.touchTargetMin,
          leading: Icon(Icons.folder, color: context.lekisColors.accent),
          title: Text(name),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _open(_child(name)),
        );
      },
    );
  }
}
