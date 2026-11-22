// 设置 > 多设备同步（SYN-*）。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../rust/api/dto.dart';
import '../../theme/tokens.dart';
import '../settings/widgets/settings_widgets.dart';
import '../sources/common.dart' show describeCoreError, showFeatureSnack;
import '../sources/sources_providers.dart';
import 'sync_providers.dart';
import 'sync_strings.dart';

/// 多设备同步设置页的全部段落。
List<Widget> buildSyncSettingsSections() => const [
  _SyncChannelSection(),
  _SyncStatusSection(),
];

class _SyncChannelSection extends ConsumerWidget {
  const _SyncChannelSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncControllerProvider).value;
    final sources =
        ref.watch(sourcesProvider).value ?? const <SourceConfigDto>[];
    final eligible = [
      for (final s in sources)
        if (s.id != null && isSyncCapableSource(s.kind)) s,
    ];
    final selectedId =
        sync?.sourceId != null && eligible.any((s) => s.id == sync!.sourceId)
        ? sync!.sourceId
        : null;

    return SettingsSection(
      title: SyncStrings.sectionChannel,
      children: [
        if (eligible.isEmpty)
          SettingsTile(
            icon: Icons.folder_off_outlined,
            title: SyncStrings.noFilesystemSources,
            subtitle: Text(SyncStrings.addSourceHint),
          )
        else
          SettingsDropdownTile<int?>(
            key: const ValueKey('sync.source-picker'),
            icon: Icons.sync_outlined,
            title: SyncStrings.sourceLabel,
            subtitle: SyncStrings.channelHint,
            value: selectedId,
            choices: [
              SettingsChoice<int?>(null, SyncStrings.sourceNone),
              for (final s in eligible) SettingsChoice<int?>(s.id, s.name),
            ],
            onChanged: (id) =>
                ref.read(syncControllerProvider.notifier).setSourceId(id),
          ),
        SettingsSwitchTile(
          key: const ValueKey('sync.auto-on-launch'),
          icon: Icons.autorenew_rounded,
          title: SyncStrings.autoOnLaunch,
          subtitle: SyncStrings.autoOnLaunchHint,
          value: sync?.autoOnLaunch ?? false,
          onChanged: selectedId == null
              ? null
              : (on) => ref
                    .read(syncControllerProvider.notifier)
                    .setAutoOnLaunch(on),
        ),
      ],
    );
  }
}

class _SyncStatusSection extends ConsumerWidget {
  const _SyncStatusSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncControllerProvider).value ?? const SyncUiState();
    final colors = context.lekisColors;
    final statusText = switch (sync.status) {
      SyncStateDto.syncing => SyncStrings.syncing,
      SyncStateDto.unavailable =>
        sync.error != null
            ? SyncStrings.failed(describeCoreError(sync.error!))
            : SyncStrings.unavailable,
      SyncStateDto.idle =>
        sync.lastSummary != null
            ? SyncStrings.lastSynced(sync.lastSummary!)
            : SyncStrings.neverSynced,
    };

    return SettingsSection(
      title: SyncStrings.sectionStatus,
      children: [
        SettingsTile(
          icon: sync.busy
              ? Icons.sync_rounded
              : sync.status == SyncStateDto.unavailable
              ? Icons.sync_problem_outlined
              : Icons.cloud_done_outlined,
          title: sync.busy ? SyncStrings.syncing : SyncStrings.idle,
          subtitle: Text(
            statusText,
            style: sync.status == SyncStateDto.unavailable
                ? TextStyle(color: colors.danger)
                : null,
          ),
          trailing: FilledButton.tonalIcon(
            key: const ValueKey('sync.now-button'),
            onPressed: sync.sourceId == null || sync.busy
                ? null
                : () async {
                    final report = await ref
                        .read(syncControllerProvider.notifier)
                        .syncNow();
                    if (!context.mounted) return;
                    if (report != null) {
                      showFeatureSnack(
                        context,
                        SyncStrings.report(
                          report.pushed.toInt(),
                          report.pulled.toInt(),
                          report.applied.toInt(),
                        ),
                      );
                    }
                  },
            icon: sync.busy
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync_rounded, size: 18),
            label: Text(SyncStrings.syncNow),
          ),
        ),
        SettingsTile(
          icon: Icons.info_outline_rounded,
          title: SyncStrings.whatIsSyncedTitle,
          subtitle: Text(SyncStrings.whatIsSyncedBody),
        ),
      ],
    );
  }
}
