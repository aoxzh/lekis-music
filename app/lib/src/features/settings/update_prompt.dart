// Proactive "new version available" prompt.
//
// The background check (see scheduleStartupUpdateCheck) flips the updater to
// `available`; this host then offers the update once per version. Choosing
// "Ignore this version" stores the version in core settings so the same
// release is not offered again.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../platform/external_url.dart';
import '../../rust/api/core.dart' as core;
import '../mini_mode/mini_mode_controller.dart';
import 'app_updater_provider.dart';
import 'strings.dart';
import 'update_dialog.dart';

const String kIgnoredUpdateVersionKey = 'ui.update.ignored_version';

/// Shows [AppUpdateDialog] whenever a new release is available, except for
/// versions the user chose to ignore.
class UpdatePromptHost extends ConsumerStatefulWidget {
  const UpdatePromptHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<UpdatePromptHost> createState() => _UpdatePromptHostState();
}

class _UpdatePromptHostState extends ConsumerState<UpdatePromptHost> {
  String? _ignoredVersion;
  bool _loadedIgnoredVersion = false;
  bool _prompting = false;
  bool _deferredForMiniMode = false;

  @override
  void initState() {
    super.initState();
    // The startup check may have finished before this host was mounted.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_maybePrompt(ref.read(appUpdaterProvider)));
    });
  }

  Future<void> _loadIgnoredVersion() async {
    if (_loadedIgnoredVersion) return;
    _loadedIgnoredVersion = true;
    try {
      _ignoredVersion = await core.getSetting(key: kIgnoredUpdateVersionKey);
    } catch (_) {
      // Core may not be available in tests; ignore for this session only.
    }
  }

  Future<void> _maybePrompt(AppUpdaterState state) async {
    if (!state.promptPending ||
        state.phase != AppUpdaterPhase.available ||
        _prompting) {
      return;
    }
    final info = state.info;
    if (info == null) return;
    // The mini player hides the full UI; wait until the window expands again.
    if (ref.read(miniModeProvider)) {
      _deferredForMiniMode = true;
      return;
    }
    await _loadIgnoredVersion();
    if (!mounted) return;
    if (info.version == _ignoredVersion) {
      ref.read(appUpdaterProvider.notifier).clearPromptPending();
      return;
    }
    _prompting = true;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (_) => AppUpdateDialog(
          onOpenLink: _openLink,
          onIgnore: () => _ignoreVersion(info.version),
        ),
      );
    } finally {
      _prompting = false;
      if (mounted) {
        ref.read(appUpdaterProvider.notifier).clearPromptPending();
      }
    }
  }

  Future<void> _ignoreVersion(String version) async {
    _ignoredVersion = version;
    try {
      await core.setSetting(key: kIgnoredUpdateVersionKey, value: version);
    } catch (_) {
      // Session-only ignore when settings are unavailable.
    }
  }

  Future<void> _openLink(String url) async {
    if (await openExternalUrl(url)) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(SettingsStrings.linkCopiedFallback)),
      );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AppUpdaterState>(appUpdaterProvider, (_, next) {
      if (next.phase == AppUpdaterPhase.available) {
        unawaited(_maybePrompt(next));
      }
    });
    ref.listen<bool>(miniModeProvider, (_, mini) {
      if (mini || !_deferredForMiniMode) return;
      _deferredForMiniMode = false;
      unawaited(_maybePrompt(ref.read(appUpdaterProvider)));
    });
    return widget.child;
  }
}
