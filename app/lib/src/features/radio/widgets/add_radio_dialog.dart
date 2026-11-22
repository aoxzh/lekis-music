// 「添加自定义电台」对话框：名称、流地址（可直接粘贴 M3U / PLS）、可选主页。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/radio/radio_providers.dart';
import 'package:lekis/src/features/radio/radio_strings.dart';
import 'package:lekis/src/features/sources/common.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/rust/api/error.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

/// 打开添加对话框；成功时返回保存后的电台。
Future<RadioStationDto?> showAddRadioDialog(BuildContext context) {
  return showDialog<RadioStationDto>(
    context: context,
    builder: (_) => const AddRadioDialog(),
  );
}

class AddRadioDialog extends ConsumerStatefulWidget {
  const AddRadioDialog({super.key});

  @override
  ConsumerState<AddRadioDialog> createState() => _AddRadioDialogState();
}

class _AddRadioDialogState extends ConsumerState<AddRadioDialog> {
  final _name = TextEditingController();
  final _address = TextEditingController();
  final _homepage = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _homepage.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    final address = _address.text.trim();
    if (address.isEmpty) {
      setState(() => _error = RadioStrings.addressRequired);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final station = await ref
          .read(radioActionsProvider)
          .addCustom(
            name: _name.text.trim(),
            address: address,
            homepage: _homepage.text.trim(),
          );
      if (mounted) Navigator.of(context).pop(station);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = _errorText(e);
      });
    }
  }

  String _errorText(Object error) {
    // 地址/播放列表的问题直接告诉用户哪里不对；其余只显示稳定的类别文案。
    if (error is CoreError && error.kind == ErrorKind.invalidArgument) {
      return error.detail;
    }
    return '${RadioStrings.actionFailed}：${describeCoreError(error)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    return AlertDialog(
      title: Text(RadioStrings.addCustom),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                context.l10n.pick(
                  '支持单条 http/https 流地址，也支持粘贴 M3U / PLS 播放列表。',
                  'Supports a single http/https stream URL or pasting an M3U / PLS playlist.',
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: LekisSpacing.lg),
              TextField(
                controller: _name,
                autofocus: true,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: RadioStrings.fieldName,
                  hintText: RadioStrings.fieldNameHint,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: LekisSpacing.md),
              TextField(
                controller: _address,
                minLines: 2,
                maxLines: 5,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: RadioStrings.fieldAddress,
                  hintText: RadioStrings.fieldAddressHint,
                  helperText: context.l10n.pick(
                    '仅支持 http:// 和 https://；不会保存任何账号密码。',
                    'Only http:// and https:// are supported; no credentials are saved.',
                  ),
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: LekisSpacing.md),
              TextField(
                controller: _homepage,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: RadioStrings.fieldHomepage,
                  hintText: RadioStrings.fieldHomepageHint,
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: LekisSpacing.md),
                Text(
                  _error!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text(RadioStrings.cancel),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: Text(
            _saving ? RadioStrings.saving : RadioStrings.parseAndSave,
          ),
        ),
      ],
    );
  }
}
