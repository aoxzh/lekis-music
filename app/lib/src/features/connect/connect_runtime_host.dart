// Starts Connect once per session and shows the pairing code to the controlled
// device.
//
// `connectProvider` is an AsyncNotifier: reading it here kicks off
// `connect_start()` (listen on the control port, advertise over mDNS, browse
// for peers) without rebuilding anything when the device list changes —
// `ref.read` only touches it once. The pairing dialog itself lives in
// `ConnectPairingHost`, which only rebuilds when a code appears or goes away.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../settings/connect_settings_section.dart';
import 'connect_providers.dart';

class ConnectRuntimeHost extends ConsumerStatefulWidget {
  const ConnectRuntimeHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ConnectRuntimeHost> createState() => _ConnectRuntimeHostState();
}

class _ConnectRuntimeHostState extends ConsumerState<ConnectRuntimeHost> {
  @override
  void initState() {
    super.initState();
    // Fire and forget: failures are surfaced in the Connect settings section.
    ref.read(connectProvider);
  }

  @override
  Widget build(BuildContext context) => ConnectPairingHost(child: widget.child);
}
