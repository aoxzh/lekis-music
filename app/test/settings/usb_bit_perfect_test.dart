import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/settings/settings_categories.dart';
import 'package:lekis/src/features/settings/settings_providers.dart';
import 'package:lekis/src/features/settings/strings.dart';
import 'package:lekis/src/features/settings/usb_bit_perfect_providers.dart';
import 'package:lekis/src/features/settings/usb_bit_perfect_settings.dart';
import 'package:lekis/src/features/settings/widgets/settings_widgets.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/rust/api/usb_output.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

UsbBitPerfectStatusDto _status({
  bool enabled = false,
  UsbBitPerfectStateDto state = UsbBitPerfectStateDto.disabled,
  String? device,
  int sdk = 35,
  int? rate,
  int? bits,
  int? container,
  bool float = false,
  String? message,
}) => UsbBitPerfectStatusDto(
  available: true,
  enabled: enabled,
  state: state,
  deviceName: device,
  deviceSupportsBitPerfect: device != null,
  sdkInt: sdk,
  sampleRate: rate,
  channels: rate == null ? null : 2,
  sourceBits: bits,
  sourceFloat: float,
  containerBits: container,
  message: message,
);

class _FakeUsbApi implements UsbBitPerfectApi {
  _FakeUsbApi(this.current);

  UsbBitPerfectStatusDto current;

  /// 打开后核心报告的状态。
  UsbBitPerfectStatusDto onEnable = _status(
    enabled: true,
    state: UsbBitPerfectStateDto.active,
    device: 'FiiO KA17',
    rate: 96000,
    bits: 24,
    container: 32,
  );
  final calls = <bool>[];

  @override
  UsbBitPerfectStatusDto status() => current;

  @override
  UsbBitPerfectStatusDto refresh() => current;

  @override
  Future<OutputModeDto?> setEnabled(bool enabled) async {
    calls.add(enabled);
    current = enabled ? onEnable : _status();
    return enabled ? OutputModeDto.exclusive : OutputModeDto.shared;
  }
}

/// 输出模式由测试控制，不碰核心。
class _FakeOutput extends PlaybackOutputNotifier {
  @override
  PlaybackOutputState build() => const PlaybackOutputState();
}

Widget _section({required bool supported, required UsbBitPerfectApi api}) =>
    ProviderScope(
      overrides: [
        usbBitPerfectSupportedProvider.overrideWithValue(supported),
        usbBitPerfectApiProvider.overrideWithValue(api),
        playbackOutputProvider.overrideWith(_FakeOutput.new),
      ],
      child: MaterialApp(
        theme: lekisDarkTheme(),
        home: Material(
          child: Consumer(
            builder: (context, ref, _) => SettingsListView(
              children: [
                SettingsSection(
                  title: SettingsStrings.audioOutput,
                  children: usbBitPerfectTiles(ref),
                ),
              ],
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('hidden on platforms without USB direct output', (tester) async {
    final api = _FakeUsbApi(_status());
    await tester.pumpWidget(_section(supported: false, api: api));
    await tester.pump();

    expect(find.text(SettingsStrings.usbBitPerfect), findsNothing);
    expect(find.byKey(UsbBitPerfectSwitchTile.switchKey), findsNothing);
  });

  testWidgets('toggle turns it on, shows live status and syncs output mode', (
    tester,
  ) async {
    final api = _FakeUsbApi(_status());
    await tester.pumpWidget(_section(supported: true, api: api));
    await tester.pump();

    expect(find.text(SettingsStrings.usbBitPerfect), findsOneWidget);
    expect(find.text(SettingsStrings.usbBitPerfectHint), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    // 没开时不显示状态行。
    expect(find.byKey(UsbBitPerfectStatusTile.statusKey), findsNothing);

    await tester.tap(find.byKey(UsbBitPerfectSwitchTile.switchKey));
    await tester.pump();
    await tester.pump();

    expect(api.calls, [true]);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(find.byKey(UsbBitPerfectStatusTile.statusKey), findsOneWidget);
    expect(
      find.text(
        SettingsStrings.usbStatusActive(
          'FiiO KA17',
          '96 kHz / 24-bit · ${SettingsStrings.usbContainer(32)}',
        ),
      ),
      findsOneWidget,
    );
    expect(find.text(SettingsStrings.usbBypassedNote), findsOneWidget);

    // 输出模式界面跟着核心返回的模式走。
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsListView)),
    );
    expect(
      container.read(playbackOutputProvider).mode,
      OutputModeDto.exclusive,
    );

    // 关掉：状态行消失，模式回到共享。
    await tester.tap(find.byKey(UsbBitPerfectSwitchTile.switchKey));
    await tester.pump();
    await tester.pump();
    expect(api.calls, [true, false]);
    expect(find.byKey(UsbBitPerfectStatusTile.statusKey), findsNothing);
    expect(container.read(playbackOutputProvider).mode, OutputModeDto.shared);
  });

  testWidgets('polling picks up a hot-unplugged DAC', (tester) async {
    final api = _FakeUsbApi(
      _status(
        enabled: true,
        state: UsbBitPerfectStateDto.ready,
        device: 'FiiO KA17',
      ),
    );
    await tester.pumpWidget(_section(supported: true, api: api));
    await tester.pump();
    expect(
      find.text(SettingsStrings.usbStatusReady('FiiO KA17')),
      findsOneWidget,
    );

    api.current = _status(enabled: true, state: UsbBitPerfectStateDto.noDevice);
    await tester.pump(UsbBitPerfectNotifier.pollInterval);
    await tester.pump();
    expect(find.text(SettingsStrings.usbStatusNoDevice), findsOneWidget);
    expect(find.text(SettingsStrings.usbBypassedNote), findsNothing);
  });

  testWidgets('advanced section: Android shows USB switch instead of mode', (
    tester,
  ) async {
    Widget advanced(bool supported) => ProviderScope(
      overrides: [
        usbBitPerfectSupportedProvider.overrideWithValue(supported),
        usbBitPerfectApiProvider.overrideWithValue(_FakeUsbApi(_status())),
        playbackOutputProvider.overrideWith(_FakeOutput.new),
        settingProvider(SettingKeys.replayGain)
            .overrideWith(() => _NullSetting(SettingKeys.replayGain)),
      ],
      child: MaterialApp(
        theme: lekisDarkTheme(),
        home: Material(
          child: SettingsListView(
            children: [SettingsCategory.advanced.sections.first],
          ),
        ),
      ),
    );

    await tester.pumpWidget(advanced(true));
    await tester.pump();
    expect(find.text(SettingsStrings.usbBitPerfect), findsOneWidget);
    expect(find.text(SettingsStrings.outputMode), findsNothing);

    await tester.pumpWidget(advanced(false));
    await tester.pump();
    expect(find.text(SettingsStrings.usbBitPerfect), findsNothing);
    expect(find.text(SettingsStrings.outputMode), findsOneWidget);
  });

  group('status text', () {
    test('old Android and unsupported DAC are told apart', () {
      expect(
        describeUsbBitPerfectStatus(
          _status(
            enabled: true,
            state: UsbBitPerfectStateDto.unsupported,
            sdk: 33,
          ),
        ),
        SettingsStrings.usbStatusOldAndroid(33),
      );
      expect(
        describeUsbBitPerfectStatus(
          _status(
            enabled: true,
            state: UsbBitPerfectStateDto.unsupported,
            device: 'Dongle',
          ),
        ),
        SettingsStrings.usbStatusUnsupported('Dongle'),
      );
    });

    test('format fallback names the track format', () {
      expect(
        describeUsbBitPerfectStatus(
          _status(
            enabled: true,
            state: UsbBitPerfectStateDto.formatFallback,
            device: 'Dongle',
            rate: 44100,
            bits: 16,
            container: 16,
          ),
        ),
        SettingsStrings.usbStatusFormatFallback('Dongle', '44.1 kHz / 16-bit'),
      );
    });

    test('failure carries the reason', () {
      expect(
        describeUsbBitPerfectStatus(
          _status(
            enabled: true,
            state: UsbBitPerfectStateDto.failed,
            message: 'AAudio open failed',
          ),
        ),
        SettingsStrings.usbStatusFailed('AAudio open failed'),
      );
    });
  });
}

class _NullSetting extends SettingNotifier {
  _NullSetting(super.key);

  @override
  Future<String?> build() async => null;
}
