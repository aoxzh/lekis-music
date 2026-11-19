// “添加音源”流程：先选类型，再填一个尽量短的表单，连接并保存后立即开始扫描。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../rust/api/core.dart' as core;
import '../../../rust/api/dto.dart';
import '../../../theme/tokens.dart';
import '../common.dart';
import '../local_folder_access.dart';
import '../source_draft.dart';
import '../source_kind_info.dart';
import '../sources_providers.dart';
import '../strings.dart';
import 'lan_discovery.dart';
import 'source_status.dart';

/// 添加音源的整个流程（可以嵌进双栏右侧，也可以包成独立页面）。
class AddSourcePane extends StatefulWidget {
  const AddSourcePane({super.key, required this.onDone, this.onCancel});

  /// 保存成功后回调新音源的 ID。
  final ValueChanged<int> onDone;
  final VoidCallback? onCancel;

  @override
  State<AddSourcePane> createState() => _AddSourcePaneState();
}

class _AddSourcePaneState extends State<AddSourcePane> {
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
    appBar: AppBar(title: const Text(SourcesStrings.addSource)),
    body: AddSourcePane(onDone: (id) => Navigator.of(context).pop(id)),
  );
}

/// 编辑已保存音源的独立页面。保存成功时返回 `true`。
class EditSourcePage extends StatelessWidget {
  const EditSourcePage({super.key, required this.source});

  final SourceConfigDto source;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text(SourcesStrings.editSource)),
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
          padding: EdgeInsets.all(context.featureGutter),
          children: [
            Text(
              SourcesStrings.chooseKind,
              style: theme.textTheme.headlineSmall,
            ),
            group(SourcesStrings.groupThisDevice, const [SourceKindDto.local]),
            group(SourcesStrings.groupNetworkShare, const [
              SourceKindDto.smb,
              SourceKindDto.webDav,
            ]),
            group(SourcesStrings.groupMediaServer, const [
              SourceKindDto.openSubsonic,
              SourceKindDto.jellyfin,
              SourceKindDto.plex,
            ]),
            const SizedBox(height: LekisSpacing.xl),
            LanDiscoverySection(onPick: onDiscovered),
          ],
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

  bool _guest = false;
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
    final ref = existing?.credentialRef?.trim() ?? '';
    _credentialSaved = ref.isNotEmpty && core.hasCredential(credentialRef: ref);
    _replaceSecret = !_credentialSaved;
    if (initial == null) return;
    _name.text = initial.name;
    _host.text = initial.host;
    _share.text = initial.share;
    _path.text = initial.path;
    _url.text = initial.url;
    _username.text = initial.username;
    _guest = initial.guest;
    _localPath = initial.kind == SourceKindDto.local && initial.path.isNotEmpty
        ? initial.path
        : null;
  }

  @override
  void dispose() {
    _secret.clear();
    for (final c in [_name, _host, _share, _path, _url, _username, _secret]) {
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
  bool get _useTypedSecret => !_guest && (!_credentialSaved || _replaceSecret);

  bool get _usesSecret => switch (_kind) {
    SourceKindDto.local => false,
    SourceKindDto.smb => !_guest,
    _ => true,
  };

  bool get _secretRequired => switch (_kind) {
    SourceKindDto.smb => !_guest,
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
  );

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
        if (!mounted) return;
        showFeatureSnack(context, SourcesStrings.savedChanges);
        widget.onDone(existing.id?.toInt() ?? 0);
        return;
      }
      final result = await ref.read(sourceActionsProvider).add(draft);
      _secret.clear();
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
    if (!_canSubmit) return;
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
              padding: EdgeInsets.all(context.featureGutter),
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
                      child: const Text(SourcesStrings.cancel),
                    ),
                    OutlinedButton.icon(
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
                      label: Text(
                        _busy
                            ? (_isEdit
                                  ? SourcesStrings.savingChanges
                                  : SourcesStrings.saving)
                            : (_isEdit
                                  ? SourcesStrings.saveChanges
                                  : SourcesStrings.testAndSave),
                      ),
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

  List<Widget> _fields(BuildContext context) => switch (_kind) {
    SourceKindDto.local => _localFields(context),
    SourceKindDto.smb => _smbFields(),
    SourceKindDto.webDav => [
      _text(
        controller: _url,
        label: SourcesStrings.fieldUrl,
        hint: SourcesStrings.fieldWebDavUrlHint,
        keyboard: TextInputType.url,
        validator: SourceValidators.httpUrl,
        autofocus: true,
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
            child: const Text(SourcesStrings.keepPassword),
          ),
        ),
      ],
    ];
  }

  Widget _savedCredentialTile() {
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
              SourcesStrings.credentialSavedNotice,
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
            child: const Text(SourcesStrings.replacePassword),
          ),
        ],
      ),
    );
  }

  void _cancelReplaceSecret() {
    _secret.clear();
    setState(() => _replaceSecret = false);
  }

  List<Widget> _localFields(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final path = _localPath;
    return [
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
      autofocus: true,
    ),
    _gap,
    _text(
      controller: _share,
      label: SourcesStrings.fieldShare,
      hint: SourcesStrings.fieldShareHint,
      validator: SourceValidators.share,
    ),
    _gap,
    _text(
      controller: _path,
      label: SourcesStrings.fieldPath,
      hint: SourcesStrings.fieldPathHint,
      validator: SourceValidators.subPath,
    ),
    _gap,
    SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text(SourcesStrings.guest),
      subtitle: const Text(SourcesStrings.guestHint),
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
      ),
      ..._credentialFields(
        label: SourcesStrings.fieldPassword,
        validator: SourceValidators.password,
      ),
    ],
  ];

  Widget _text({
    required TextEditingController controller,
    required String label,
    String? hint,
    TextInputType? keyboard,
    FormFieldValidator<String>? validator,
    List<String>? autofill,
    TextInputAction action = TextInputAction.next,
    bool autofocus = false,
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
      suffixIcon: IconButton(
        tooltip: _obscure
            ? SourcesStrings.showPassword
            : SourcesStrings.hidePassword,
        onPressed: () => setState(() => _obscure = !_obscure),
        icon: Icon(
          _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
        ),
      ),
    ),
  );
}
