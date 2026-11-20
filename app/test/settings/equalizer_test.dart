import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/settings/equalizer_page.dart';
import 'package:lekis/src/features/settings/equalizer_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

EqualizerPresetDto _preset({
  String id = 'sennheiser-hd-600',
  String name = 'Sennheiser HD 600',
  double preamp = -2,
  List<double>? bands,
}) => EqualizerPresetDto(
  id: id,
  name: name,
  description: '接近中性的微调',
  preampDb: preamp,
  bandsDb: Float32List.fromList(
    bands ?? const [0.5, 0.5, 0, -0.5, -0.5, 0, 0.5, 0.5, 0, -0.5],
  ),
);

class _FakeRepository extends EqualizerRepository {
  _FakeRepository(this.initial);

  final EqualizerState initial;
  final List<EqualizerState> saves = [];

  @override
  Future<EqualizerState> load() async => initial;

  @override
  Future<void> save(EqualizerState state) async {
    saves.add(state);
  }
}

void main() {
  test('state maps DTO ranges and preset ids', () {
    final presets = [
      _preset(),
      _preset(id: 'other', name: 'Other', preamp: 20),
    ];
    final state = EqualizerState.fromDto(
      EqualizerDto(
        enabled: true,
        preampDb: 99,
        bandsDb: Float32List.fromList(const [
          -99,
          99,
          double.nan,
          1,
          2,
          3,
          4,
          5,
          6,
        ]),
        preset: 'sennheiser-hd-600',
      ),
      presets,
    );

    expect(state.enabled, isTrue);
    expect(state.preampDb, equalizerMaxGainDb);
    expect(state.bandsDb, hasLength(equalizerBandCount));
    expect(state.bandsDb.first, equalizerMinGainDb);
    expect(state.bandsDb[1], equalizerMaxGainDb);
    expect(state.bandsDb[2], 0);
    expect(state.bandsDb.last, 0);
    expect(state.currentPreset?.name, 'Sennheiser HD 600');
    expect(state.toDto().preset, 'sennheiser-hd-600');
    expect(state.toDto().bandsDb, hasLength(equalizerBandCount));

    final unknown = EqualizerState.fromDto(
      EqualizerDto(
        enabled: false,
        preampDb: 0,
        bandsDb: Float32List(equalizerBandCount),
        preset: 'not-installed',
      ),
      presets,
    );
    expect(unknown.presetId, isNull);
    expect(unknown.currentPreset, isNull);
  });

  test('manual changes clear the preset and clamping stays in range', () {
    final state = EqualizerState.fromDto(
      EqualizerDto(
        enabled: true,
        preampDb: 0,
        bandsDb: Float32List(equalizerBandCount),
        preset: 'sennheiser-hd-600',
      ),
      [_preset()],
    );

    final tweaked = state.withBand(0, 50).withPreamp(-50);
    expect(tweaked.presetId, isNull);
    expect(tweaked.bandsDb.first, equalizerMaxGainDb);
    expect(tweaked.preampDb, equalizerMinGainDb);

    final preset = _preset(preamp: 5, bands: List<double>.filled(10, 3));
    final applied = state.withPreset(preset);
    expect(applied.presetId, 'sennheiser-hd-600');
    expect(applied.preampDb, 5);
    expect(applied.bandsDb.every((gain) => gain == 3), isTrue);
    expect(state.flattened().isFlat, isTrue);
    expect(state.flattened().presetId, isNull);
  });

  test('provider loads, applies presets and persists toggles', () async {
    final initial = EqualizerState.fromDto(
      EqualizerDto(
        enabled: false,
        preampDb: 0,
        bandsDb: Float32List(equalizerBandCount),
        preset: null,
      ),
      [_preset()],
    );
    final repository = _FakeRepository(initial);
    final container = ProviderContainer.test(
      overrides: [equalizerRepositoryProvider.overrideWithValue(repository)],
    );

    final loaded = await container.read(equalizerProvider.future);
    expect(loaded.presets, hasLength(1));
    expect(loaded.enabled, isFalse);

    final notifier = container.read(equalizerProvider.notifier);
    await notifier.applyPreset('sennheiser-hd-600');
    final afterPreset = container.read(equalizerProvider).value!;
    expect(afterPreset.presetId, 'sennheiser-hd-600');
    expect(afterPreset.preampDb, -2);
    expect(repository.saves.last.presetId, 'sennheiser-hd-600');

    await notifier.setEnabled(true);
    expect(container.read(equalizerProvider).value!.enabled, isTrue);
    expect(repository.saves.last.enabled, isTrue);

    notifier.setBand(4, 6);
    expect(container.read(equalizerProvider).value!.bandsDb[4], 6);
    expect(container.read(equalizerProvider).value!.presetId, isNull);
    await notifier.saveNow();
    expect(repository.saves.last.bandsDb[4], 6);
  });

  testWidgets('page renders controls and switches presets', (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _FakeRepository(
      EqualizerState.fromDto(
        EqualizerDto(
          enabled: true,
          preampDb: 1,
          bandsDb: Float32List(equalizerBandCount),
          preset: null,
        ),
        [_preset()],
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [equalizerRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          theme: lekisLightTheme(),
          home: const EqualizerPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('均衡器'), findsOneWidget);
    expect(find.text('启用均衡器'), findsOneWidget);
    expect(find.text('前级增益（preamp）'), findsOneWidget);
    expect(find.textContaining('仅在共享输出模式生效'), findsOneWidget);
    expect(find.byType(Slider), findsNWidgets(equalizerBandCount + 1));
    expect(find.text('31'), findsOneWidget);
    expect(find.text('16k'), findsOneWidget);

    await tester.tap(find.byKey(const Key('equalizer-preset-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sennheiser HD 600').last);
    await tester.pumpAndSettle();

    expect(repository.saves, isNotEmpty);
    expect(repository.saves.last.presetId, 'sennheiser-hd-600');
    expect(find.textContaining('当前预设：Sennheiser HD 600'), findsOneWidget);
  });

  testWidgets('page fits a narrow phone without overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = _FakeRepository(
      EqualizerState.fromDto(
        EqualizerDto(
          enabled: true,
          preampDb: 0,
          bandsDb: Float32List(equalizerBandCount),
          preset: null,
        ),
        [_preset()],
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [equalizerRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          theme: lekisLightTheme(),
          home: const EqualizerPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(Slider), findsNWidgets(equalizerBandCount + 1));
  });
}
