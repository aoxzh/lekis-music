// “添加音源”流程：先选类型，再填一个尽量短的表单，连接并保存后立即开始扫描。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../rust/api/dto.dart';
import '../../../theme/tokens.dart';
import '../../plugins/plugins_page.dart';
import '../../plugins/strings.dart';
import '../common.dart';
import '../discovery_providers.dart';
import '../local_folder_access.dart';
import '../source_draft.dart';
import '../source_kind_info.dart';
import '../sources_providers.dart';
import '../strings.dart';
import 'lan_discovery.dart';
import 'remote_folder_picker.dart';
import 'source_status.dart';

/// 添加音源的整个流程（可以嵌进双栏右侧，也可以包成独立页面）。
class AddSourcePane extends ConsumerStatefulWidget {
  const AddSourcePane({super.key, required this.onDone, this.onCancel});

  /// 保存成功后回调新音源的 ID。
  final ValueChanged<int> onDone;
  final VoidCallback? onCancel;

  @override
  ConsumerState<AddSourcePane> createState() => _AddSourcePaneState();
}

class _AddSourcePaneState extends ConsumerState<AddSourcePane> {
  SourceKindDto? _kind;
  SourceDraft? _prefill;

  void _chooseKind(SourceKindDto kind) {
    setState(() {
      _kind = kind;
      _prefill = null;
    });
  }

  void _chooseDiscovered(DiscoveredServiceDto service) {
    final draft = SourceDraft.fromDiscovered(service);
    setState(() {
      _kind = draft.kind;
      _prefill = draft;
    });
  }

  void _backToChooser() {
    setState(() {
      _kind = null;
      _prefill = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    // 进表单再返回时保留发现结果，不用每次重扫一遍。
    ref.watch(lanDiscoveryProvider.select((s) => s.hasScanned));
    final kind = _kind;
    return AnimatedSwitcher(
      duration: LekisMotion.normal,
      child: kind == null
          ? SourceKindChooser(
              key: const ValueKey('chooser'),
              onChoose: _chooseKind,
              onDiscovered: _chooseDiscovered,
            )
          : SourceForm(
              key: ValueKey(kind),
              kind: kind,
              initial: _prefill,
              onBack: _backToChooser,
              onDone: widget.onDone,
            ),
    );
  }
}

/// 窄窗口里用的独立页面。
class AddSourcePage extends StatelessWidget {
  const AddSourcePage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(SourcesStrings.addSource)),
    body: AddSourcePane(onDone: (id) => Navigator.of(context).pop(id)),
  );
}

/// 编辑已保存音源的独立页面。保存成功时返回 `true`。
class EditSourcePage extends StatelessWidget {
  const EditSourcePage({super.key, required this.source});

  final SourceConfigDto source;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(SourcesStrings.editSource)),
    body: SourceForm(
      kind: source.kind,
      existing: source,
      onBack: () => Navigator.of(context).pop(false),
      onDone: (_) => Navigator.of(context).pop(true),
    ),
  );
}

class SourceKindChooser extends StatelessWidget {
  const SourceKindChooser({
    super.key,
    required this.onChoose,
    required this.onDiscovered,
  });

  final ValueChanged<SourceKindDto> onChoose;

  /// 点了一条局域网发现结果：直接带着地址进入对应表单。
  final ValueChanged<DiscoveredServiceDto> onDiscovered;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: context.lekisColors.onSurfaceVariant,
    );
    Widget group(String title, List<SourceKindDto> kinds) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            top: LekisSpacing.xl,
            bottom: LekisSpacing.sm,
          ),
          child: Text(
            title,
            style: theme.textTheme.labelLarge?.copyWith(
              color: context.lekisColors.onSurfaceVariant,
            ),
          ),
        ),
        for (final k in kinds) _KindOption(kind: k, onTap: () => onChoose(k)),
      ],
    );

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: featureMaxContentWidth),
        child: ListView(
          padding: featureScrollPadding(context),
          children: [
            Text(
              SourcesStrings.chooseKind,
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: LekisSpacing.sm),
            Text(SourcesStrings.chooseKindBody, style: muted),
            const SizedBox(height: LekisSpacing.xl),
            // 本地文件夹是绝大多数人的第一步：单独放大、放在最前面。
            _FeaturedLocalOption(onTap: () => onChoose(SourceKindDto.local)),
            ListTile(
              leading: const Icon(Icons.extension_outlined),
              title: Text(PluginStrings.importSource),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const PluginsPage()),
              ),
            ),
            const SizedBox(height: LekisSpacing.xl),
            // 打开就自动扫局域网，找到的 NAS 紧跟在本地文件夹后面，点一下就能预填。
            LanDiscoverySection(onPick: onDiscovered),
            const SizedBox(height: LekisSpacing.xxl),
            Text(
              SourcesStrings.groupNetwork,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: LekisSpacing.xs),
            Text(SourcesStrings.groupNetworkBody, style: muted),
            group(SourcesStrings.groupNetworkShare, const [
              SourceKindDto.smb,
              SourceKindDto.webDav,
              SourceKindDto.nfs,
              SourceKindDto.sftp,
            ]),
            group(SourcesStrings.groupMediaServer, const [
              SourceKindDto.openSubsonic,
              SourceKindDto.jellyfin,
              SourceKindDto.plex,
            ]),
          ],
        ),
      ),
    );
  }
}

/// “本地文件夹”的大号入口：强调色底 + “推荐”标签。
class _FeaturedLocalOption extends StatelessWidget {
  const _FeaturedLocalOption({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final theme = Theme.of(context);
    return Card(
      key: const ValueKey('add-source-local'),
      elevation: 0,
      margin: EdgeInsets.zero,
      color: colors.accentSoft,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LekisRadius.md),
        side: BorderSide(color: colors.accent.withValues(alpha: 0.5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(LekisSpacing.lg),
          child: Row(
            children: [
              SourceKindBadge(icon: SourceKindDto.local.icon),
              const SizedBox(width: LekisSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: LekisSpacing.sm,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          SourcesStrings.kindLocal,
                          style: theme.textTheme.titleMedium,
                        ),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors.accent,
                            borderRadius: BorderRadius.circular(LekisRadius.sm),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: LekisSpacing.sm,
                              vertical: LekisSpacing.xxs,
                            ),
                            child: Text(
                              SourcesStrings.recommended,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: colors.onAccent,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: LekisSpacing.xs),
                    Text(
                      SourcesStrings.kindLocalFeaturedHint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: LekisSpacing.sm),
              Icon(Icons.chevron_right, color: colors.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _KindOption extends StatelessWidget {
  const _KindOption({required this.kind, required this.onTap});

  final SourceKindDto kind;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hint = kind.hint;
    return Card(
      elevation: 0,
      color: context.lekisColors.surfaceVariant,
      margin: const EdgeInsets.only(bottom: LekisSpacing.sm),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LekisRadius.md),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        minTileHeight: LekisSizes.touchTargetMin + LekisSpacing.lg,
        leading: SourceKindBadge(icon: kind.icon),
        title: Text(kind.label),
        subtitle: hint == null ? null : Text(hint),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

/// 某一种音源的表单。
class SourceForm extends ConsumerStatefulWidget {
  const SourceForm({
    super.key,
    required this.kind,
    required this.onBack,
    required this.onDone,
    this.initial,
    this.existing,
  });

  final SourceKindDto kind;
  final VoidCallback onBack;
  final ValueChanged<int> onDone;

  /// 从局域网发现结果带进来的预填值。
  final SourceDraft? initial;

  /// 编辑时传入已保存的配置；`null` 表示新建。
  final SourceConfigDto? existing;

  @override
  ConsumerState<SourceForm> createState() => _SourceFormState();
}

class _SourceFormState extends ConsumerState<SourceForm> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _host = TextEditingController();
  final _share = TextEditingController();
  final _path = TextEditingController();
  final _url = TextEditingController();
  final _username = TextEditingController();
  final _secret = TextEditingController();
  final _alternates = TextEditingController();
  final _port = TextEditingController();
  final _passphrase = TextEditingController();

  bool _guest = false;

  /// SFTP 用私钥登录。
  bool _useKey = false;

  /// 编辑时已保存的 SFTP 认证方式；切换方式后必须重新输入凭据。
  bool _savedUseKey = false;

  /// 「列出共享 / 导出」的结果；`null` 表示还没列过。
  List<ShareDto>? _shares;
  bool _loadingShares = false;
  String? _sharesError;
  bool _obscure = true;
  bool _busy = false;
  bool _testing = false;
  bool _picking = false;
  bool _credentialSaved = false;
  bool _replaceSecret = true;
  String? _localPath;
  String? _error;

  SourceKindDto get _kind => widget.kind;
  SourceConfigDto? get _existing => widget.existing;
  bool get _isEdit => _existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    final initial = existing == null
        ? widget.initial
        : SourceDraft.fromConfig(existing);
    final credentialRef = existing?.credentialRef?.trim() ?? '';
    _credentialSaved =
        credentialRef.isNotEmpty &&
        ref.read(sourceActionsProvider).hasCredential(credentialRef);
    _replaceSecret = !_credentialSaved;
    if (initial == null) return;
    _name.text = initial.name;
    _host.text = initial.host;
    _share.text = initial.share;
    _path.text = initial.path;
    _url.text = initial.url;
    _username.text = initial.username;
    _guest = initial.guest;
    _port.text = initial.port;
    _useKey = initial.useKey;
    _savedUseKey = initial.useKey;
    _alternates.text = initial.alternateAddresses.join('\n');
    _localPath = initial.kind == SourceKindDto.local && initial.path.isNotEmpty
        ? initial.path
        : null;
  }

  @override
  void dispose() {
    _secret.clear();
    _passphrase.clear();
    for (final c in [
      _port,
      _passphrase,
      _name,
      _host,
      _share,
      _path,
      _url,
      _username,
      _secret,
      _alternates,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickFolder() async {
    setState(() {
      _picking = true;
      _error = null;
    });
    final result = await pickMusicFolder();
    if (!mounted) return;
    setState(() {
      _picking = false;
      switch (result) {
        case FolderPicked(:final path):
          _localPath = path;
        case FolderPickFailed(:final message):
          _error = message;
        case FolderPickCancelled():
          break;
      }
    });
  }

  bool get _canSubmit =>
      !_busy &&
      !_testing &&
      (_kind != SourceKindDto.local || _localPath != null);

  /// 编辑时密码已经保存在核心：没点“替换密码”就不带任何 secret。
  /// SFTP 换了认证方式（密码 ↔ 私钥）时旧凭据没法用，必须重新输入。
  bool get _useTypedSecret =>
      !_guest && (!_credentialSaved || _replaceSecret || _authModeChanged);

  bool get _authModeChanged =>
      _isEdit && _kind == SourceKindDto.sftp && _useKey != _savedUseKey;

  bool get _usesSecret => switch (_kind) {
    SourceKindDto.local || SourceKindDto.nfs => false,
    SourceKindDto.smb => !_guest,
    _ => true,
  };

  bool get _secretRequired => switch (_kind) {
    SourceKindDto.smb => !_guest,
    SourceKindDto.sftp ||
    SourceKindDto.openSubsonic ||
    SourceKindDto.jellyfin ||
    SourceKindDto.emby ||
    SourceKindDto.plex => true,
    _ => false,
  };

  SourceDraft _draft() => SourceDraft(
    kind: _kind,
    name: _name.text,
    host: _host.text,
    share: _share.text,
    path: _kind == SourceKindDto.local ? (_localPath ?? '') : _path.text,
    url: _url.text,
    username: _guest ? '' : _username.text,
    secret: _useTypedSecret ? _secret.text : '',
    guest: _guest,
    port: _port.text,
    useKey: _kind == SourceKindDto.sftp && _useKey,
    keyPassphrase: _useTypedSecret && _useKey ? _passphrase.text : '',
    // 备用地址只对网络音源有意义；本地文件夹永远只有一个路径。
    alternateAddresses: _isNetwork
        ? _alternates.text
              .split('\n')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList(growable: false)
        : const [],
  );

  /// 只有网络音源才有“测试连接”、凭据和备用地址。
  bool get _isNetwork => _kind.isNetwork;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final draft = _draft();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_isEdit) {
        final existing = _existing!;
        await ref.read(sourceActionsProvider).update(existing, draft);
        _secret.clear();
        _passphrase.clear();
        if (!mounted) return;
        showFeatureSnack(context, SourcesStrings.savedChanges);
        widget.onDone(existing.id?.toInt() ?? 0);
        return;
      }
      final result = await ref.read(sourceActionsProvider).add(draft);
      _secret.clear();
      _passphrase.clear();
      if (!mounted) return;
      final scanError = result.scanError;
      showFeatureSnack(
        context,
        scanError == null
            ? SourcesStrings.saved
            : '${SourcesStrings.savedButScanFailed}：${describeCoreError(scanError)}',
      );
      widget.onDone(result.sourceId);
    } catch (e) {
      if (mounted) setState(() => _error = describeCoreError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _test() async {
    if (!_isNetwork || !_canSubmit) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final draft = _draft();
    setState(() {
      _testing = true;
      _error = null;
    });
    try {
      await ref
          .read(sourceActionsProvider)
          .testDraft(draft, existing: _existing);
      if (mounted) showFeatureSnack(context, SourcesStrings.testSuccess);
    } catch (e) {
      if (mounted) setState(() => _error = describeCoreError(e));
    } finally {
      draft.forgetSecret();
      if (mounted) setState(() => _testing = false);
    }
  }

  /// 列出主机上的 SMB 共享 / NFS 导出，结果显示成可点的标签。
  Future<void> _listShares() async {
    final hostError = SourceValidators.host(_host.text);
    final userError = _kind == SourceKindDto.smb && !_guest
        ? SourceValidators.username(_username.text)
        : null;
    if (hostError != null || userError != null) {
      setState(() => _sharesError = hostError ?? userError);
      return;
    }
    final draft = _draft()
      ..share = ''
      ..path = '';
    setState(() {
      _loadingShares = true;
      _sharesError = null;
    });
    try {
      final shares = await ref
          .read(sourceActionsProvider)
          .listShares(draft, existing: _existing);
      if (!mounted) return;
      setState(() {
        _shares = shares;
        // 只有一个共享时直接选上，少点一下。
        if (shares.length == 1 && _share.text.trim().isEmpty) {
          _share.text = shares.single.name;
        }
      });
    } catch (e) {
      if (mounted) {
        setState(
          () => _sharesError =
              '${SourcesStrings.sharesFailed}：${describeCoreError(e)}',
        );
      }
    } finally {
      draft.forgetSecret();
      if (mounted) setState(() => _loadingShares = false);
    }
  }

  void _pickShare(String name) {
    setState(() {
      if (_share.text.trim() != name) _path.clear();
      _share.text = name;
    });
  }

  /// 浏览前要先有的字段；缺了就返回提示。
  String? _browsePrerequisite() {
    switch (_kind) {
      case SourceKindDto.webDav:
        return SourceValidators.httpUrl(_url.text) == null
            ? null
            : SourcesStrings.browseNeedsUrl;
      case SourceKindDto.smb:
        if (SourceValidators.host(_host.text) != null) {
          return SourcesStrings.browseNeedsHost;
        }
        return _share.text.trim().isEmpty
            ? SourcesStrings.browseNeedsShare
            : null;
      case SourceKindDto.nfs:
        if (SourceValidators.host(_host.text) != null) {
          return SourcesStrings.browseNeedsHost;
        }
        return SourceValidators.nfsExport(_share.text) == null
            ? null
            : SourcesStrings.browseNeedsExport;
      default:
        return SourceValidators.host(_host.text) == null
            ? null
            : SourcesStrings.browseNeedsHost;
    }
  }

  /// 弹出远端文件夹浏览器。SMB / NFS / SFTP 选的是子目录；WebDAV 直接拼进地址。
  Future<void> _browse() async {
    final missing = _browsePrerequisite();
    if (missing != null) {
      setState(() => _error = missing);
      return;
    }
    final webDav = _kind == SourceKindDto.webDav;
    final base = _draft();
    if (!webDav) base.path = '';
    setState(() => _error = null);
    final actions = ref.read(sourceActionsProvider);
    final existing = _existing;
    try {
      // 一次准备好配置，浏览器里点多少层都只用这一份临时凭据。
      final picked = await actions.withPreparedConfig(
        base,
        existing: existing,
        (config) => showRemoteFolderPicker(
          context,
          initialPath: webDav ? '' : _path.text,
          load: (path) => actions.browseConfig(config, path),
        ),
      );
      if (picked == null || !mounted) return;
      setState(() {
        if (webDav) {
          if (picked.isNotEmpty) {
            final encoded = picked
                .split('/')
                .map(Uri.encodeComponent)
                .join('/');
            _url.text = '${normalizeHttpUrl(_url.text)}/$encoded';
          }
        } else {
          _path.text = picked;
        }
      });
    } finally {
      base.forgetSecret();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final error = _error;

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: featureMaxContentWidth),
        child: Form(
          key: _formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: AutofillGroup(
            child: ListView(
              padding: featureScrollPadding(context),
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: SourcesStrings.back,
                      onPressed: _busy || _testing ? null : widget.onBack,
                      icon: const Icon(Icons.arrow_back),
                    ),
                    const SizedBox(width: LekisSpacing.sm),
                    SourceKindBadge(icon: _kind.icon),
                    const SizedBox(width: LekisSpacing.md),
                    Expanded(
                      child: Text(
                        _kind.label,
                        style: theme.textTheme.headlineSmall,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: LekisSpacing.xl),
                ..._fields(context),
                _gap,
                _text(
                  controller: _name,
                  label: SourcesStrings.fieldName,
                  hint: SourcesStrings.fieldNameHint,
                  action: TextInputAction.done,
                ),
                if (_isNetwork) ...[_gap, _moreOptions(context)],
                if (_usesSecret && _useTypedSecret) ...[
                  const SizedBox(height: LekisSpacing.md),
                  Row(
                    children: [
                      Icon(
                        Icons.lock_outline,
                        size: LekisSpacing.lg,
                        color: colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: LekisSpacing.sm),
                      Expanded(
                        child: Text(
                          SourcesStrings.credentialNotice,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                if (error != null) ...[
                  const SizedBox(height: LekisSpacing.lg),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      error,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.danger,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: LekisSpacing.xl),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: LekisSpacing.sm,
                  runSpacing: LekisSpacing.sm,
                  children: [
                    TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, LekisSizes.touchTargetMin),
                      ),
                      onPressed: _busy || _testing ? null : widget.onBack,
                      child: Text(SourcesStrings.cancel),
                    ),
                    // 本地文件夹没有“连接”可测，选好文件夹直接添加即可。
                    if (_isNetwork)
                      OutlinedButton.icon(
                        key: const ValueKey('source-form-test'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, LekisSizes.touchTargetMin),
                        ),
                        onPressed: _canSubmit ? _test : null,
                        icon: _testing
                            ? const SizedBox.square(
                                dimension: LekisSpacing.lg,
                                child: CircularProgressIndicator(
                                  strokeWidth: LekisSpacing.xxs,
                                ),
                              )
                            : const Icon(Icons.wifi_tethering),
                        label: Text(
                          _testing
                              ? SourcesStrings.testing
                              : SourcesStrings.testConnection,
                        ),
                      ),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, LekisSizes.touchTargetMin),
                      ),
                      onPressed: _canSubmit ? _submit : null,
                      icon: _busy
                          ? const SizedBox.square(
                              dimension: LekisSpacing.lg,
                              child: CircularProgressIndicator(
                                strokeWidth: LekisSpacing.xxs,
                              ),
                            )
                          : const Icon(Icons.check),
                      label: Text(_submitLabel),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static const _gap = SizedBox(height: LekisSpacing.md);

  String get _submitLabel {
    if (_isEdit) {
      return _busy ? SourcesStrings.savingChanges : SourcesStrings.saveChanges;
    }
    if (!_isNetwork) {
      return _busy ? SourcesStrings.adding : SourcesStrings.addAndScan;
    }
    return _busy ? SourcesStrings.saving : SourcesStrings.testAndSave;
  }

  /// 网络音源的进阶字段（备用地址）。默认收起，已有备用地址时展开。
  Widget _moreOptions(BuildContext context) {
    final hostBased =
        _kind == SourceKindDto.smb ||
        _kind == SourceKindDto.nfs ||
        _kind == SourceKindDto.sftp;
    return Theme(
      // 去掉 ExpansionTile 展开时上下出现的分隔线。
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: const ValueKey('source-more-options'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: LekisSpacing.sm),
        initiallyExpanded: _alternates.text.trim().isNotEmpty,
        title: Text(SourcesStrings.moreOptions),
        subtitle: Text(SourcesStrings.moreOptionsHint),
        children: [
          TextFormField(
            controller: _alternates,
            enabled: !_busy && !_testing,
            keyboardType: TextInputType.multiline,
            minLines: 2,
            maxLines: 5,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: SourcesStrings.fieldAlternates,
              hintText: hostBased
                  ? '${SourcesStrings.fieldAlternatesHint}\n${_alternateExample()}'
                  : '${SourcesStrings.fieldAlternatesHint}\nhttps://music.example.com',
              helperText: SourcesStrings.fieldAlternatesHelper,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
    );
  }

  String _alternateExample() => switch (_kind) {
    SourceKindDto.nfs => 'nfs://100.64.0.2/volume1/music',
    SourceKindDto.sftp => 'sftp://100.64.0.2:22/volume1/music',
    _ => '100.64.0.2/music',
  };

  List<Widget> _fields(BuildContext context) => switch (_kind) {
    SourceKindDto.local => _localFields(context),
    SourceKindDto.smb => _smbFields(),
    SourceKindDto.nfs => _nfsFields(context),
    SourceKindDto.sftp => _sftpFields(),
    SourceKindDto.webDav => [
      _text(
        controller: _url,
        label: SourcesStrings.fieldUrl,
        hint: SourcesStrings.fieldWebDavUrlHint,
        keyboard: TextInputType.url,
        validator: SourceValidators.httpUrl,
        autofocus: true,
        suffix: _browseButton(),
      ),
      _gap,
      // WebDAV 允许匿名访问，账号密码都是可选的。
      _text(
        controller: _username,
        label: SourcesStrings.fieldUsername,
        autofill: const [AutofillHints.username],
      ),
      ..._credentialFields(
        label: SourcesStrings.fieldPassword,
        validator: SourceValidators.password,
      ),
    ],
    SourceKindDto.openSubsonic => [
      _text(
        controller: _url,
        label: SourcesStrings.fieldUrl,
        hint: SourcesStrings.fieldServerUrlHint,
        keyboard: TextInputType.url,
        validator: SourceValidators.httpUrl,
        autofocus: true,
      ),
      _gap,
      _text(
        controller: _username,
        label: SourcesStrings.fieldUsername,
        validator: SourceValidators.username,
        autofill: const [AutofillHints.username],
      ),
      ..._credentialFields(
        label: SourcesStrings.fieldPassword,
        validator: SourceValidators.password,
      ),
    ],
    SourceKindDto.jellyfin || SourceKindDto.emby => [
      _text(
        controller: _url,
        label: SourcesStrings.fieldUrl,
        hint: SourcesStrings.fieldServerUrlHint,
        keyboard: TextInputType.url,
        validator: SourceValidators.httpUrl,
        autofocus: true,
      ),
      ..._credentialFields(
        label: SourcesStrings.fieldApiKey,
        validator: SourceValidators.apiKey,
        hint: SourcesStrings.fieldApiKeyHint,
      ),
    ],
    SourceKindDto.plex => [
      _text(
        controller: _url,
        label: SourcesStrings.fieldUrl,
        hint: SourcesStrings.fieldServerUrlHint,
        keyboard: TextInputType.url,
        validator: SourceValidators.httpUrl,
        autofocus: true,
      ),
      ..._credentialFields(
        label: SourcesStrings.fieldPlexToken,
        validator: SourceValidators.token,
        hint: SourcesStrings.fieldPlexTokenHint,
      ),
    ],
    _ => const [],
  };

  /// 凭据字段：已保存且没点“替换密码”时只显示状态，不显示输入框，
  /// 因此编辑音源不需要重新输入密码。
  List<Widget> _credentialFields({
    required String label,
    required FormFieldValidator<String>? validator,
    String? hint,
  }) {
    if (!_usesSecret) return const [];
    if (_credentialSaved && !_replaceSecret) {
      return [_gap, _savedCredentialTile()];
    }
    return [
      _gap,
      _secretField(
        _credentialSaved ? SourcesStrings.newPassword : label,
        _secretRequired ? validator : null,
        hint: hint,
      ),
      if (_credentialSaved) ...[
        const SizedBox(height: LekisSpacing.xs),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _busy || _testing ? null : _cancelReplaceSecret,
            child: Text(SourcesStrings.keepPassword),
          ),
        ),
      ],
    ];
  }

  Widget _savedCredentialTile({String? notice, String? replaceLabel}) {
    final resolvedNotice = notice ?? SourcesStrings.credentialSavedNotice;
    final resolvedReplace = replaceLabel ?? SourcesStrings.replacePassword;
    final colors = context.lekisColors;
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(LekisSpacing.md),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(LekisRadius.sm),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_outline, color: colors.accent),
          const SizedBox(width: LekisSpacing.md),
          Expanded(
            child: Text(
              resolvedNotice,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: LekisSpacing.sm),
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(0, LekisSizes.touchTargetMin),
            ),
            onPressed: _busy || _testing
                ? null
                : () => setState(() => _replaceSecret = true),
            child: Text(resolvedReplace),
          ),
        ],
      ),
    );
  }

  void _cancelReplaceSecret() {
    _secret.clear();
    _passphrase.clear();
    setState(() => _replaceSecret = false);
  }

  List<Widget> _localFields(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final path = _localPath;
    return [
      Text(
        SourcesStrings.localFormBody,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: colors.onSurfaceVariant,
        ),
      ),
      _gap,
      if (path != null) ...[
        Container(
          padding: const EdgeInsets.all(LekisSpacing.md),
          decoration: BoxDecoration(
            color: colors.surfaceVariant,
            borderRadius: BorderRadius.circular(LekisRadius.sm),
          ),
          child: Row(
            children: [
              Icon(Icons.folder, color: colors.accent),
              const SizedBox(width: LekisSpacing.md),
              Expanded(
                child: SelectableText(path, style: theme.textTheme.bodyMedium),
              ),
            ],
          ),
        ),
        _gap,
      ],
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          autofocus: path == null,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, LekisSizes.touchTargetMin),
          ),
          onPressed: _picking || _busy || _testing ? null : _pickFolder,
          icon: const Icon(Icons.folder_open),
          label: Text(
            _picking ? SourcesStrings.pickingFolder : SourcesStrings.pickFolder,
          ),
        ),
      ),
      if (localFolderNeedsPermissionNotice) ...[
        _gap,
        Text(
          SourcesStrings.androidPermissionBody,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
    ];
  }

  List<Widget> _smbFields() => [
    _text(
      controller: _host,
      label: SourcesStrings.fieldHost,
      hint: SourcesStrings.fieldHostHint,
      keyboard: TextInputType.url,
      validator: SourceValidators.host,
      autofocus: _host.text.isEmpty,
    ),
    _gap,
    // 先填账号，再列共享：枚举共享本身就要登录。
    SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(SourcesStrings.guest),
      subtitle: Text(SourcesStrings.guestHint),
      value: _guest,
      onChanged: _busy || _testing
          ? null
          : (v) => setState(() {
              _guest = v;
              if (v) _secret.clear();
            }),
    ),
    if (!_guest) ...[
      _gap,
      _text(
        controller: _username,
        label: SourcesStrings.fieldUsername,
        validator: SourceValidators.username,
        autofill: const [AutofillHints.username],
        autofocus: _host.text.isNotEmpty,
      ),
      ..._credentialFields(
        label: SourcesStrings.fieldPassword,
        validator: SourceValidators.password,
      ),
    ],
    _gap,
    _text(
      controller: _share,
      label: SourcesStrings.fieldShare,
      hint: SourcesStrings.fieldShareHint,
      validator: SourceValidators.share,
    ),
    ..._sharePicker(
      label: SourcesStrings.listShares,
      hint: SourcesStrings.sharesHint,
    ),
    _gap,
    _text(
      controller: _path,
      label: SourcesStrings.fieldPath,
      hint: SourcesStrings.fieldPathHint,
      validator: SourceValidators.subPath,
      suffix: _browseButton(),
    ),
  ];

  List<Widget> _nfsFields(BuildContext context) => [
    _text(
      controller: _host,
      label: SourcesStrings.fieldHost,
      hint: SourcesStrings.fieldNfsHostHint,
      keyboard: TextInputType.url,
      validator: SourceValidators.host,
      autofocus: _host.text.isEmpty,
    ),
    _gap,
    _text(
      controller: _share,
      label: SourcesStrings.fieldExport,
      hint: SourcesStrings.fieldExportHint,
      validator: SourceValidators.nfsExport,
    ),
    ..._sharePicker(
      label: SourcesStrings.listExports,
      hint: SourcesStrings.exportsHint,
    ),
    _gap,
    _text(
      controller: _path,
      label: SourcesStrings.fieldPath,
      hint: SourcesStrings.fieldPathHint,
      validator: SourceValidators.subPath,
      suffix: _browseButton(),
    ),
    _gap,
    Text(
      SourcesStrings.nfsNotice,
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: context.lekisColors.onSurfaceVariant),
    ),
  ];

  List<Widget> _sftpFields() => [
    _text(
      controller: _host,
      label: SourcesStrings.fieldHost,
      hint: SourcesStrings.fieldHostHint,
      keyboard: TextInputType.url,
      validator: SourceValidators.host,
      autofocus: _host.text.isEmpty,
    ),
    _gap,
    _text(
      controller: _port,
      label: SourcesStrings.fieldPort,
      hint: SourcesStrings.fieldPortHint,
      keyboard: TextInputType.number,
      validator: SourceValidators.port,
    ),
    _gap,
    _text(
      controller: _username,
      label: SourcesStrings.fieldUsername,
      validator: SourceValidators.username,
      autofill: const [AutofillHints.username],
    ),
    _gap,
    Align(
      alignment: Alignment.centerLeft,
      child: SegmentedButton<bool>(
        key: ValueKey('sftp-auth-mode'),
        segments: [
          ButtonSegment(
            value: false,
            icon: Icon(Icons.password),
            label: Text(SourcesStrings.authPassword),
          ),
          ButtonSegment(
            value: true,
            icon: Icon(Icons.key),
            label: Text(SourcesStrings.authKey),
          ),
        ],
        selected: {_useKey},
        onSelectionChanged: _busy || _testing
            ? null
            : (v) => setState(() {
                _useKey = v.first;
                _secret.clear();
                _passphrase.clear();
              }),
      ),
    ),
    if (_useKey)
      ..._keyFields()
    else
      ..._credentialFields(
        label: SourcesStrings.fieldPassword,
        validator: SourceValidators.password,
      ),
    _gap,
    _text(
      controller: _path,
      label: SourcesStrings.fieldSftpPath,
      hint: SourcesStrings.fieldSftpPathHint,
      validator: SourceValidators.subPath,
      suffix: _browseButton(),
    ),
  ];

  /// SFTP 私钥：多行粘贴框 + 可选 passphrase。已保存且没要求替换时只显示状态。
  List<Widget> _keyFields() {
    if (_credentialSaved && !_replaceSecret && !_authModeChanged) {
      return [
        _gap,
        _savedCredentialTile(
          notice: SourcesStrings.keySavedNotice,
          replaceLabel: SourcesStrings.replaceKey,
        ),
      ];
    }
    final enabled = !_busy && !_testing;
    return [
      _gap,
      TextFormField(
        key: const ValueKey('sftp-private-key'),
        controller: _secret,
        enabled: enabled,
        minLines: 3,
        maxLines: 6,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.multiline,
        validator: SourceValidators.privateKey,
        style: const TextStyle(fontFamily: 'monospace'),
        decoration: InputDecoration(
          labelText: _credentialSaved
              ? SourcesStrings.newPrivateKey
              : SourcesStrings.fieldPrivateKey,
          hintText: SourcesStrings.fieldPrivateKeyHint,
          hintMaxLines: 3,
          border: const OutlineInputBorder(),
        ),
      ),
      _gap,
      TextFormField(
        controller: _passphrase,
        enabled: enabled,
        obscureText: _obscure,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.visiblePassword,
        decoration: InputDecoration(
          labelText: SourcesStrings.fieldKeyPassphrase,
          border: const OutlineInputBorder(),
          suffixIcon: _obscureToggle(),
        ),
      ),
      if (_credentialSaved && !_authModeChanged) ...[
        const SizedBox(height: LekisSpacing.xs),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _busy || _testing ? null : _cancelReplaceSecret,
            child: Text(SourcesStrings.keepKey),
          ),
        ),
      ],
    ];
  }

  /// 「列出共享 / 导出」按钮 + 结果标签。点标签就填进上面的输入框。
  List<Widget> _sharePicker({required String label, required String hint}) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final shares = _shares;
    final sharesError = _sharesError;
    final current = _share.text.trim();
    return [
      const SizedBox(height: LekisSpacing.sm),
      Row(
        children: [
          OutlinedButton.icon(
            key: const ValueKey('source-list-shares'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, LekisSizes.touchTargetMin),
            ),
            onPressed: _loadingShares || _busy || _testing ? null : _listShares,
            icon: _loadingShares
                ? const SizedBox.square(
                    dimension: LekisSpacing.lg,
                    child: CircularProgressIndicator(
                      strokeWidth: LekisSpacing.xxs,
                    ),
                  )
                : const Icon(Icons.list_alt),
            label: Text(_loadingShares ? SourcesStrings.listingShares : label),
          ),
        ],
      ),
      const SizedBox(height: LekisSpacing.xs),
      if (sharesError != null)
        Text(
          sharesError,
          style: theme.textTheme.bodySmall?.copyWith(color: colors.danger),
        )
      else if (shares == null)
        Text(
          hint,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        )
      else if (shares.isEmpty)
        Text(
          SourcesStrings.noShares,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        )
      else
        Wrap(
          spacing: LekisSpacing.sm,
          runSpacing: LekisSpacing.xs,
          children: [
            for (final share in shares)
              Tooltip(
                message: share.comment,
                child: ChoiceChip(
                  key: ValueKey('share:${share.name}'),
                  avatar: const Icon(Icons.folder_shared_outlined),
                  label: Text(share.name),
                  selected: current == share.name,
                  onSelected: _busy || _testing
                      ? null
                      : (_) => _pickShare(share.name),
                ),
              ),
          ],
        ),
    ];
  }

  Widget _browseButton() => IconButton(
    key: const ValueKey('source-browse-folders'),
    tooltip: SourcesStrings.browseFolders,
    onPressed: _busy || _testing ? null : _browse,
    icon: const Icon(Icons.folder_open),
  );

  Widget _obscureToggle() => IconButton(
    tooltip: _obscure
        ? SourcesStrings.showPassword
        : SourcesStrings.hidePassword,
    onPressed: () => setState(() => _obscure = !_obscure),
    icon: Icon(
      _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
    ),
  );

  Widget _text({
    required TextEditingController controller,
    required String label,
    String? hint,
    TextInputType? keyboard,
    FormFieldValidator<String>? validator,
    List<String>? autofill,
    TextInputAction action = TextInputAction.next,
    bool autofocus = false,
    Widget? suffix,
  }) => TextFormField(
    controller: controller,
    enabled: !_busy && !_testing,
    autofocus: autofocus,
    keyboardType: keyboard,
    autocorrect: false,
    enableSuggestions: false,
    autofillHints: autofill,
    textInputAction: action,
    validator: validator,
    onFieldSubmitted: action == TextInputAction.done ? (_) => _submit() : null,
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      border: const OutlineInputBorder(),
      suffixIcon: suffix,
    ),
  );

  Widget _secretField(
    String label,
    FormFieldValidator<String>? validator, {
    String? hint,
  }) => TextFormField(
    controller: _secret,
    enabled: !_busy && !_testing,
    obscureText: _obscure,
    autocorrect: false,
    enableSuggestions: false,
    autofillHints: const [AutofillHints.password],
    keyboardType: TextInputType.visiblePassword,
    textInputAction: TextInputAction.next,
    validator: validator,
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      border: const OutlineInputBorder(),
      suffixIcon: _obscureToggle(),
    ),
  );
}
