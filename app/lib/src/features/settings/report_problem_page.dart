// "Report a Problem": the user-facing diagnostics bundle entry.
//
// The pure redaction / zip / issue-URL helpers live in `report_problem.dart`;
// this page only collects the current environment, lets the user review it,
// and saves or submits it. Nothing is uploaded on its own.

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/settings/report_problem.dart';
import 'package:lekis/src/features/settings/settings_providers.dart';
import 'package:lekis/src/features/settings/strings.dart';
import 'package:lekis/src/features/settings/widgets/settings_widgets.dart';
import 'package:lekis/src/features/sources/sources_providers.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/layout/window_size.dart';
import 'package:lekis/src/platform/external_url.dart';
import 'package:lekis/src/platform/ui_profile.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

class ReportProblemPage extends ConsumerStatefulWidget {
  const ReportProblemPage({super.key});

  @override
  ConsumerState<ReportProblemPage> createState() => _ReportProblemPageState();
}

class _ReportProblemPageState extends ConsumerState<ReportProblemPage> {
  final _description = TextEditingController();
  DiagnosticsEnvironment? _environment;
  var _includeDeviceId = false;
  var _loading = true;
  var _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_environment == null && _loading) unawaited(_loadEnvironment());
  }

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  Future<void> _loadEnvironment() async {
    setState(() => _loading = true);
    try {
      final environment = await _collectEnvironment();
      if (mounted) setState(() => _environment = environment);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<DiagnosticsEnvironment> _collectEnvironment() async {
    final info = ref.read(aboutInfoProvider);
    final sources = ref.read(sourcesProvider).value ?? const [];
    final output = ref.read(playbackOutputProvider).mode;
    var environment = await collectDiagnosticsEnvironment(
      coreVersion: info.coreVersion,
      uiProfile: UiProfile.current.formFactor.name,
      appLanguage: L10n.isEnglishActive ? 'en-US' : 'zh-CN',
      windowClass: context.widthClass.name,
      outputMode: output,
      sources: sources,
    );
    if (_includeDeviceId) {
      environment = environment.withDeviceId(info.deviceId);
    }
    return environment;
  }

  Future<void> _copyEnvironment() async {
    final environment = _environment;
    if (environment == null) return;
    await Clipboard.setData(ClipboardData(text: environment.toPlainText()));
    if (!mounted) return;
    _snack(SettingsStrings.reportProblemCopied);
  }

  Future<void> _saveBundle() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final environment = await _collectEnvironment();
      final fileName = diagnosticsFileName(DateTime.now());
      final logLines = _recentLogs();
      final bytes = buildDiagnosticsZip(
        env: environment,
        logLines: logLines,
        problemContext: _description.text,
      );
      final saved = await FilePicker.saveFile(
        dialogTitle: SettingsStrings.reportProblemSaveBundle,
        fileName: fileName,
        bytes: bytes,
        mimeType: 'application/zip',
      );
      if (saved != null && mounted) {
        _snack(SettingsStrings.reportProblemSaved);
      }
    } catch (_) {
      if (mounted) _snack(SettingsStrings.reportProblemSaveFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openIssue() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final environment = await _collectEnvironment();
      final uri = buildIssueUri(
        environment,
        bundleName: diagnosticsFileName(DateTime.now()),
        problemContext: _description.text,
      );
      final opened = await openExternalUrl(uri.toString());
      if (!opened) {
        await Clipboard.setData(ClipboardData(text: uri.toString()));
        if (mounted) _snack(SettingsStrings.reportProblemIssueFallback);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<String> _recentLogs() {
    try {
      return core.recentLogs(limit: 1000);
    } catch (_) {
      return const [];
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final environment = _environment;
    return SettingsScaffold(
      title: SettingsStrings.reportProblem,
      body: SettingsListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              settingsRowInset,
              0,
              settingsRowInset,
              LekisSpacing.lg,
            ),
            child: Text(
              SettingsStrings.reportProblemIntro,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
          SettingsSection(
            title: SettingsStrings.reportProblemDescription,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  settingsRowInset,
                  LekisSpacing.xs,
                  settingsRowInset,
                  LekisSpacing.md,
                ),
                child: TextField(
                  key: const ValueKey('report.description'),
                  controller: _description,
                  minLines: 3,
                  maxLines: 7,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: SettingsStrings.reportProblemDescriptionHint,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(LekisRadius.sm),
                    ),
                  ),
                ),
              ),
              SettingsSwitchTile(
                key: const ValueKey('report.device-id'),
                icon: Icons.fingerprint_rounded,
                title: SettingsStrings.reportProblemIncludeDeviceId,
                subtitle: SettingsStrings.reportProblemIncludeDeviceIdHint,
                value: _includeDeviceId,
                onChanged: (value) {
                  setState(() => _includeDeviceId = value);
                  _environment = null;
                  unawaited(_loadEnvironment());
                },
              ),
            ],
          ),
          SettingsSection(
            title: SettingsStrings.reportProblemEnvironment,
            trailing: environment == null
                ? null
                : IconButton(
                    tooltip: SettingsStrings.reportProblemCopyEnvironment,
                    onPressed: _copyEnvironment,
                    icon: const Icon(Icons.copy_all_outlined, size: 18),
                  ),
            children: [
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(settingsRowInset),
                  child: LinearProgressIndicator(minHeight: 2),
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    settingsRowInset,
                    LekisSpacing.xs,
                    settingsRowInset,
                    LekisSpacing.md,
                  ),
                  child: SelectableText(
                    environment?.toPlainText() ?? SettingsStrings.unavailable,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      height: 1.5,
                    ),
                  ),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              settingsRowInset,
              0,
              settingsRowInset,
              LekisSpacing.sm,
            ),
            child: Text(
              SettingsStrings.reportProblemSaveHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              settingsRowInset,
              0,
              settingsRowInset,
              LekisSpacing.xl,
            ),
            child: Wrap(
              spacing: LekisSpacing.sm,
              runSpacing: LekisSpacing.sm,
              children: [
                FilledButton.icon(
                  key: const ValueKey('report.save'),
                  onPressed: _busy ? null : _saveBundle,
                  icon: const Icon(Icons.save_alt_rounded),
                  label: Text(SettingsStrings.reportProblemSaveBundle),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('report.issue'),
                  onPressed: _busy ? null : _openIssue,
                  icon: const Icon(Icons.bug_report_outlined),
                  label: Text(SettingsStrings.reportProblemOpenIssue),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
