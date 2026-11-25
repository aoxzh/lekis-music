// Update dialog shared by Settings → About and the proactive startup prompt.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/widgets/adaptive_panel.dart';
import 'package:material_ui/material_ui.dart';

import 'app_updater_provider.dart';
import 'desktop_self_updater.dart';
import 'release_notes_markdown.dart';
import 'strings.dart';

/// Shows the pending update and, on desktop, lets the user download and stage
/// it in place. [onIgnore] adds an "Ignore this version" action for the
/// proactive prompt; the settings page leaves it null.
class AppUpdateDialog extends ConsumerWidget {
  const AppUpdateDialog({super.key, required this.onOpenLink, this.onIgnore});

  final Future<void> Function(String url) onOpenLink;
  final Future<void> Function()? onIgnore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appUpdaterProvider);
    final notifier = ref.read(appUpdaterProvider.notifier);
    final info = state.info;
    if (info == null) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final canInApp = state.canInAppUpdate;
    final progress = state.progress;

    return LekisPanel(
      title: SettingsStrings.updateAvailableTitle(info.version),
      scrollBody: false,
      body: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: SingleChildScrollView(
                child: info.notes.isEmpty
                    ? Text(SettingsStrings.checkUpdatesHint)
                    : ReleaseNotesMarkdown(
                        data: info.notes,
                        onOpenLink: onOpenLink,
                      ),
              ),
            ),
            if (state.phase == AppUpdaterPhase.downloading) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: progress?.fraction),
              const SizedBox(height: 8),
              Text(
                formatUpdateProgressLine(progress),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ] else if (state.phase == AppUpdaterPhase.ready) ...[
              const SizedBox(height: 14),
              Text(
                SettingsStrings.updateReadyHint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ] else if (state.phase == AppUpdaterPhase.restarting) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(SettingsStrings.restartingToUpdate)),
                ],
              ),
            ] else if (state.phase == AppUpdaterPhase.error &&
                state.errorMessage != null) ...[
              const SizedBox(height: 14),
              Text(
                state.errorMessage!,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ] else if (!canInApp && state.capability?.reason != null) ...[
              const SizedBox(height: 12),
              Text(
                state.capability!.reason!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: switch (state.phase) {
        AppUpdaterPhase.downloading => [
          TextButton(
            onPressed: notifier.cancelDownload,
            child: Text(SettingsStrings.cancel),
          ),
        ],
        AppUpdaterPhase.ready => [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(SettingsStrings.later),
          ),
          FilledButton.icon(
            onPressed: notifier.restartToUpdate,
            icon: const Icon(Icons.restart_alt_rounded, size: 18),
            label: Text(SettingsStrings.restartToUpdate),
          ),
        ],
        AppUpdaterPhase.restarting => const [],
        AppUpdaterPhase.error when canInApp => [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              onOpenLink(info.downloadUrl);
            },
            child: Text(SettingsStrings.viewReleasePage),
          ),
          FilledButton(
            onPressed: notifier.downloadAndStage,
            child: Text(SettingsStrings.retry),
          ),
        ],
        AppUpdaterPhase.available when onIgnore != null => [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(SettingsStrings.later),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              unawaited(onIgnore!());
            },
            child: Text(SettingsStrings.ignoreUpdate),
          ),
          FilledButton.icon(
            onPressed: canInApp
                ? notifier.downloadAndStage
                : () {
                    Navigator.of(context).pop();
                    onOpenLink(info.downloadUrl);
                  },
            icon: const Icon(Icons.download_rounded, size: 18),
            label: Text(
              canInApp
                  ? SettingsStrings.downloadAndUpdate
                  : SettingsStrings.downloadUpdate,
            ),
          ),
        ],
        _ when canInApp => [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              onOpenLink(info.releaseUrl);
            },
            child: Text(SettingsStrings.viewReleasePage),
          ),
          FilledButton.icon(
            onPressed: notifier.downloadAndStage,
            icon: const Icon(Icons.download_rounded, size: 18),
            label: Text(SettingsStrings.downloadAndUpdate),
          ),
        ],
        _ => [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              onOpenLink(info.releaseUrl);
            },
            child: Text(SettingsStrings.viewReleasePage),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              onOpenLink(info.downloadUrl);
            },
            child: Text(SettingsStrings.downloadUpdate),
          ),
        ],
      },
    );
  }
}

String formatUpdateProgressLine(UpdateDownloadProgress? progress) {
  if (progress == null) return SettingsStrings.downloadingUpdate;
  switch (progress.step) {
    case UpdateStep.verifying:
      return SettingsStrings.verifyingUpdate;
    case UpdateStep.extracting:
      return SettingsStrings.extractingUpdate;
    case UpdateStep.downloading:
      final rec = _formatMegabytes(progress.receivedBytes);
      if (progress.totalBytes > 0) {
        final tot = _formatMegabytes(progress.totalBytes);
        final pct = ((progress.fraction ?? 0) * 100).round();
        final speed = progress.bytesPerSecond > 0
            ? ' · ${_formatSpeed(progress.bytesPerSecond)}'
            : '';
        return '$rec / $tot ($pct%)$speed';
      }
      return rec;
  }
}

String _formatMegabytes(int bytes) =>
    '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

String _formatSpeed(double bytesPerSecond) {
  final mb = bytesPerSecond / (1024 * 1024);
  if (mb >= 1) return '${mb.toStringAsFixed(1)} MB/s';
  final kb = bytesPerSecond / 1024;
  return '${kb.toStringAsFixed(0)} KB/s';
}
