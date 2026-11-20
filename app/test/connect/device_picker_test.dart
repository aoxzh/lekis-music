// Connect UI: the device picker, transfer / remote-only, the remote mini
// player and the remote-control page, against an in-memory gateway.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/bridge/core_events.dart';
import 'package:lekis/src/features/connect/connect_active.dart';
import 'package:lekis/src/features/connect/connect_gateway.dart';
import 'package:lekis/src/features/connect/connect_strings.dart';
import 'package:lekis/src/features/connect/device_picker.dart';
import 'package:lekis/src/features/connect/remote_now_playing_bar.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

import 'fake_connect_gateway.dart';

class _FakePlayback extends PlaybackController {
  _FakePlayback(this.hasTrack);

  final bool hasTrack;

  @override
  PlaybackUiState build() => hasTrack
      ? const PlaybackUiState(
          state: PlaybackStateDto.playing,
          trackId: 7,
          durationMs: 60000,
          queueLength: 3,
          queueIndex: 0,
        )
      : const PlaybackUiState();
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  FakeConnectGateway gateway, {
  bool localTrack = true,
  bool alwaysShow = true,
}) async {
  tester.view.physicalSize = const Size(420, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      coreEventsProvider.overrideWith((ref) => const Stream.empty()),
      connectGatewayProvider.overrideWithValue(gateway),
      playbackProvider.overrideWith(() => _FakePlayback(localTrack)),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: lekisDarkTheme(),
        home: Scaffold(
          body: Column(
            children: [
              ConnectDeviceButton(alwaysShow: alwaysShow),
              const Spacer(),
              const ConnectRemoteMiniPlayer(),
            ],
          ),
        ),
      ),
    ),
  );
  // Let ConnectNotifier.build start the (fake) gateway.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return container;
}

Future<void> _openPicker(WidgetTester tester) async {
  await tester.tap(find.byKey(ConnectDeviceButton.buttonKey).first);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('no other Lekis around: the mini player keeps its room', (
    tester,
  ) async {
    await _pump(
      tester,
      FakeConnectGateway(devices: const []),
      alwaysShow: false,
    );
    expect(find.byKey(ConnectDeviceButton.buttonKey), findsNothing);
  });

  testWidgets('tapping a device transfers playback and the mini player '
      'switches to it', (tester) async {
    final gateway = FakeConnectGateway();
    final container = await _pump(tester, gateway);

    await _openPicker(tester);
    expect(find.text(ConnectStrings.pickerTitle), findsOneWidget);
    expect(find.text('书房电脑'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('connect.pick.pc')));
    await tester.pumpAndSettle();

    expect(gateway.calls, containsAllInOrder(['transfer:pc', 'state:pc']));
    expect(container.read(activeRemoteProvider), 'pc');
    expect(find.text(ConnectStrings.playingOnDevice('书房电脑')), findsWidgets);
    expect(find.text('Time'), findsOneWidget);

    // Play / pause on the mini player drives the remote device.
    await tester.tap(find.byKey(const ValueKey('connect.remote-mini.toggle')));
    await tester.pump();
    expect(gateway.controls.single, const ControlActionDto.toggle());
  });

  testWidgets('remote-only opens the remote page without transferring', (
    tester,
  ) async {
    final gateway = FakeConnectGateway();
    await _pump(tester, gateway);

    await _openPicker(tester);
    await tester.tap(find.byKey(const ValueKey('connect.pick.pc.remote')));
    // The remote page ticks while the remote device is playing, so it never
    // "settles": pump a fixed time instead.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(gateway.calls, isNot(contains('transfer:pc')));
    expect(find.byKey(const ValueKey('connect.remote.title')), findsOneWidget);
    expect(
      find.text(ConnectStrings.viaLabel(MediaViaDto.stream)),
      findsOneWidget,
    );
    expect(find.text('The Great Gig in the Sky'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('connect.remote.toggle')));
    await tester.pump();
    expect(gateway.controls.last, const ControlActionDto.toggle());

    // Seeking only goes out when the drag ends.
    final seek = find.byKey(const ValueKey('connect.remote.seek'));
    await tester.drag(seek, const Offset(60, 0));
    await tester.pump();
    expect(gateway.controls.last, isA<ControlActionDto_Seek>());
  });

  testWidgets('nothing playing here: picking a device just opens its remote', (
    tester,
  ) async {
    final gateway = FakeConnectGateway();
    await _pump(tester, gateway, localTrack: false);

    await _openPicker(tester);
    await tester.tap(find.byKey(const ValueKey('connect.pick.pc')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(gateway.calls, isNot(contains('transfer:pc')));
    expect(find.byKey(const ValueKey('connect.remote.title')), findsOneWidget);
  });

  testWidgets('losing the control session drops back to this device', (
    tester,
  ) async {
    final gateway = FakeConnectGateway();
    final container = await _pump(tester, gateway);
    await container.read(activeRemoteProvider.notifier).activate('pc');
    await tester.pump();
    expect(find.byKey(ConnectRemoteMiniPlayer.cardKey), findsOneWidget);

    gateway.setDevices([fakeDevice(connected: false)]);
    await tester.pump();
    await tester.pump();

    expect(container.read(activeRemoteProvider), isNull);
    expect(find.byKey(ConnectRemoteMiniPlayer.cardKey), findsNothing);
  });

  testWidgets('"this device" in the picker stops controlling the remote', (
    tester,
  ) async {
    final gateway = FakeConnectGateway();
    final container = await _pump(tester, gateway);
    await container.read(activeRemoteProvider.notifier).activate('pc');
    await tester.pump();

    await _openPicker(tester);
    await tester.tap(find.byKey(const ValueKey('connect.pick.this-device')));
    await tester.pumpAndSettle();
    expect(container.read(activeRemoteProvider), isNull);
  });
}
