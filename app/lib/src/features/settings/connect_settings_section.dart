// 「在其他设备上播放」的设置分区，以及配对用的两个对话框。
//
// 两种配对方向都在这里：
// * 控制端：点设备的「配对」→ 对方屏幕显示 6 位码 → 弹窗输入 → 完成；
// * 被控端：核心推 PairingCode → 全 App 任意位置弹出配对码（[ConnectPairingHost]）。

import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/widgets/adaptive_panel.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_l10n.dart';
import '../../theme/theme.dart';
import '../connect/connect_gateway.dart';
import '../../rust/api/error.dart';
import '../sources/common.dart' show describeCoreError;
import '../connect/connect_providers.dart';
import '../connect/connect_strings.dart';
import 'strings.dart';
import 'widgets/settings_widgets.dart';

/// Core error for a toast: the shared wording plus the core's own detail.
///
/// Connect errors are protocol messages we wrote ourselves ("device failed
/// pairing confirmation", "wrong pairing code", …), so unlike other features
/// showing the detail is both safe and the only way to tell them apart —
/// Dart release builds have no `toString` for `CoreError`, so without this the
/// user just sees "Instance of 'CoreError'".
String _connectError(Object error) {
  final text = describeCoreError(error);
  final detail = error is CoreError ? error.detail.trim() : '';
  return detail.isEmpty ? text : '$text（$detail）';
}

/// 设置页里的「在其他设备上播放」。
class ConnectSettingsSection extends ConsumerWidget {
  const ConnectSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(connectProvider);
    final state = async.value;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: context.lekisColors.onSurfaceVariant,
    );

    if (state == null) {
      return SettingsSection(
        title: ConnectStrings.title,
        children: [
          SettingsTile(
            icon: Icons.cast_rounded,
            title: ConnectStrings.searching,
          ),
        ],
      );
    }

    final notifier = ref.read(connectProvider.notifier);
    final settings = state.settings;
    final devices = state.sortedDevices;
    final offline = state.offlinePeers;

    Future<void> guard(
      Future<void> Function() action, {
      String? failure,
    }) async {
      try {
        await action();
      } catch (error) {
        if (!context.mounted) return;
        ScaffoldMessenger.maybeOf(context)
          ?..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                '${failure ?? ConnectStrings.pairFailed}：'
                '${_connectError(error)}',
              ),
            ),
          );
      }
    }

    Future<void> connectTo(ConnectDeviceInfo device) async {
      try {
        final needsCode = await notifier.pair(device.deviceId);
        if (!needsCode || !context.mounted) return;
        final code = await showPairingCodeDialog(context, device: device);
        if (code == null) {
          notifier.pairCancel(device.deviceId);
          return;
        }
        await notifier.pairConfirm(device.deviceId, code);
      } catch (error) {
        if (!context.mounted) return;
        ScaffoldMessenger.maybeOf(context)
          ?..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                '${ConnectStrings.pairFailed}：${_connectError(error)}',
              ),
            ),
          );
      }
    }

    return SettingsSection(
      title: ConnectStrings.title,
      children: [
        // ---- 本机 ----
        KeyedSubtree(
          key: const ValueKey('connect.this-device'),
          child: SettingsTile(
            icon: state.started
                ? Icons.podcasts_rounded
                : Icons.podcasts_outlined,
            title: settings.deviceName.isEmpty
                ? ConnectStrings.thisDevice
                : settings.deviceName,
            subtitle: Text(
              state.started
                  ? '${ConnectStrings.listening} · '
                        '${ConnectStrings.portLabel} ${state.port}'
                  : ConnectStrings.notListening,
              style: muted,
            ),
            chevron: true,
            onTap: () => _rename(context, notifier, settings.deviceName),
          ),
        ),
        KeyedSubtree(
          key: const ValueKey('connect.allow-control'),
          child: SettingsSwitchTile(
            icon: Icons.settings_remote_rounded,
            title: ConnectStrings.allowControl,
            subtitle: ConnectStrings.allowControlHint,
            value: settings.allowControl,
            onChanged: (value) => guard(
              () => notifier.setSettings(
                deviceName: settings.deviceName,
                allowControl: value,
              ),
              failure: SettingsStrings.saveFailed,
            ),
          ),
        ),
        if (state.controllers.isNotEmpty)
          SettingsTile(
            icon: Icons.link_rounded,
            title: ConnectStrings.controlledBy,
            subtitle: Text(state.controllers.join(' · '), style: muted),
          ),

        // ---- 局域网设备 ----
        SettingsSectionHeader(ConnectStrings.nearby),
        if (devices.isEmpty)
          SettingsTile(
            icon: Icons.search_rounded,
            title: ConnectStrings.noDevices,
            subtitle: Text(ConnectStrings.nearbyHint, style: muted),
          ),
        for (final device in devices)
          KeyedSubtree(
            key: ValueKey('connect.device.${device.deviceId}'),
            child: SettingsTile(
              icon: _platformIcon(device.platform),
              title: device.name,
              subtitle: Text(
                [
                  _platformName(device.platform),
                  '${device.host}:${device.port}',
                  if (device.connected) ConnectStrings.connected,
                ].join(' · '),
                style: muted,
              ),
              trailing: _DeviceAction(
                label: device.connected
                    ? ConnectStrings.disconnect
                    : (device.paired
                          ? ConnectStrings.connect
                          : ConnectStrings.pair),
                onPressed: () {
                  if (device.connected) {
                    guard(() => notifier.disconnect(device.deviceId));
                  } else {
                    connectTo(device);
                  }
                },
              ),
            ),
          ),

        // ---- 已配对但不在线 ----
        if (offline.isNotEmpty) ...[
          SettingsSectionHeader(ConnectStrings.paired),
          for (final peer in offline)
            KeyedSubtree(
              key: ValueKey('connect.peer.${peer.deviceId}'),
              child: SettingsTile(
                icon: _platformIcon(peer.platform),
                title: peer.name,
                subtitle: Text(
                  '${_platformName(peer.platform)} · ${ConnectStrings.offline}',
                  style: muted,
                ),
                trailing: _DeviceAction(
                  label: ConnectStrings.forget,
                  onPressed: () => guard(() => notifier.forget(peer.deviceId)),
                ),
              ),
            ),
        ],

        // ---- 手动添加 ----
        SettingsTile(
          key: const ValueKey('connect.add-by-address'),
          icon: Icons.add_link_rounded,
          title: ConnectStrings.addByAddress,
          subtitle: Text(ConnectStrings.addByAddressHint, style: muted),
          chevron: true,
          onTap: () async {
            final target = await showAddByAddressDialog(context);
            if (target == null) return;
            await guard(
              () => notifier.addDevice(host: target.$1, port: target.$2),
            );
          },
        ),
      ],
    );
  }

  Future<void> _rename(
    BuildContext context,
    ConnectNotifier notifier,
    String current,
  ) async {
    final controller = TextEditingController(text: current);
    final name = await showLekisPanel<String>(
      context,
      builder: (context) => LekisPanel(
        title: ConnectStrings.renameTitle,
        body: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: InputDecoration(
            labelText: ConnectStrings.thisDevice,
            hintText: ConnectStrings.renameHint,
          ),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(ConnectStrings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: Text(context.l10n.pick('保存', 'Save')),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == current) return;
    await notifier.rename(trimmed);
  }
}

class _DeviceAction extends StatelessWidget {
  const _DeviceAction({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onPressed,
    style: TextButton.styleFrom(
      minimumSize: const Size(0, LekisSizes.touchTargetMin),
    ),
    child: Text(label),
  );
}

IconData _platformIcon(String platform) => switch (platform) {
  'android' => Icons.smartphone_rounded,
  'windows' => Icons.desktop_windows_rounded,
  'macos' => Icons.laptop_mac_rounded,
  'linux' => Icons.computer_rounded,
  'ios' => Icons.phone_iphone_rounded,
  _ => Icons.speaker_rounded,
};

String _platformName(String platform) => switch (platform) {
  'android' => 'Android',
  'windows' => 'Windows',
  'macos' => 'macOS',
  'linux' => 'Linux',
  'ios' => 'iOS',
  _ => platform,
};

/// 控制端输入 6 位配对码。
Future<String?> showPairingCodeDialog(
  BuildContext context, {
  required ConnectDeviceInfo device,
}) async {
  final controller = TextEditingController();
  final field = GlobalKey<FormFieldState<String>>();
  final code = await showLekisPanel<String>(
    context,
    builder: (context) {
      void submit() {
        if (field.currentState!.validate()) {
          Navigator.of(context).pop(controller.text);
        }
      }

      return LekisPanel(
        title: ConnectStrings.pairTitle,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${device.name}\n\n${ConnectStrings.pairBody}'),
            const SizedBox(height: LekisSpacing.md),
            TextFormField(
              key: field,
              autovalidateMode: AutovalidateMode.onUserInteractionIfError,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              validator: (value) => value?.length == 6
                  ? null
                  : context.l10n.pick('请输入 6 位配对码', 'Enter the six-digit code'),
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall
                  ?.copyWith(letterSpacing: 8),
              decoration: InputDecoration(
                labelText: ConnectStrings.pairCodeLabel,
                counterText: '',
              ),
              onFieldSubmitted: (_) => submit(),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(ConnectStrings.cancel),
          ),
          FilledButton(
            onPressed: submit,
            child: Text(ConnectStrings.pairConfirm),
          ),
        ],
      );
    },
  );
  controller.dispose();
  return code;
}

/// 手动按地址添加。
Future<(String, int)?> showAddByAddressDialog(BuildContext context) async {
  final host = TextEditingController();
  final port = TextEditingController(text: '47655');
  final form = GlobalKey<FormState>();
  final address = await showLekisPanel<(String, int)>(
    context,
    builder: (context) {
      void submit() {
        if (form.currentState!.validate()) {
          Navigator.of(context)
              .pop((host.text.trim(), int.parse(port.text.trim())));
        }
      }

      return LekisPanel(
        title: ConnectStrings.addByAddress,
        body: Form(
          key: form,
          autovalidateMode: AutovalidateMode.onUserInteractionIfError,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: host,
                autofocus: true,
                autocorrect: false,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: ConnectStrings.host,
                  hintText: ConnectStrings.hostHint,
                ),
                validator: (value) => (value ?? '').trim().isEmpty
                    ? context.l10n.pick(
                        '请输入主机名或 IP 地址',
                        'Enter a hostname or IP address',
                      )
                    : null,
              ),
              const SizedBox(height: LekisPanel.fieldGap),
              TextFormField(
                controller: port,
                keyboardType: TextInputType.number,
                onFieldSubmitted: (_) => submit(),
                decoration: InputDecoration(labelText: ConnectStrings.port),
                validator: (value) {
                  final number = int.tryParse((value ?? '').trim());
                  return number == null || number < 1 || number > 65535
                      ? context.l10n.pick(
                          '端口范围为 1–65535',
                          'Enter a port from 1 to 65535',
                        )
                      : null;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(ConnectStrings.cancel),
          ),
          FilledButton(onPressed: submit, child: Text(ConnectStrings.add)),
        ],
      );
    },
  );
  host.dispose();
  port.dispose();
  return address;
}

/// 被控端：有设备来配对时，全 App 任意位置弹出配对码。
///
/// 挂在 shell 外层；`ref.listen` 只在配对码出现 / 消失时触发，不会跟着设备
/// 列表刷新重建。
class ConnectPairingHost extends ConsumerStatefulWidget {
  const ConnectPairingHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ConnectPairingHost> createState() => _ConnectPairingHostState();
}

class _ConnectPairingHostState extends ConsumerState<ConnectPairingHost> {
  bool _showing = false;

  @override
  Widget build(BuildContext context) {
    ref.listen(incomingPairingProvider, (previous, next) {
      if (next == null) {
        _closeIfShowing();
      } else if (!_showing) {
        _showCode(next);
      }
    });
    return widget.child;
  }

  void _closeIfShowing() {
    if (!_showing) return;
    _showing = false;
    Navigator.of(context, rootNavigator: true).maybePop();
  }

  Future<void> _showCode(ConnectPairingCode pairing) async {
    _showing = true;
    await showLekisPanel<void>(
      context,
      dismissible: false,
      builder: (context) => LekisPanel(
        title: ConnectStrings.incomingPairing,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${pairing.peerName}\n\n${ConnectStrings.incomingPairingBody}',
            ),
            const SizedBox(height: LekisSpacing.lg),
            Center(
              child: Text(
                pairing.code,
                style: Theme.of(context).textTheme.displaySmall
                    ?.copyWith(letterSpacing: 10, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              ref.read(connectProvider.notifier).dismissPairing();
            },
            child: Text(ConnectStrings.close),
          ),
        ],
      ),
    );
    _showing = false;
  }
}
