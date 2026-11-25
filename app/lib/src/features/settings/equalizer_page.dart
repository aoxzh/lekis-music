// 10 段均衡器页面（PLY-04）。滑杆先本地刷新，短节流后写回核心。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_l10n.dart';
import '../../rust/api/dto.dart';
import '../../theme/tokens.dart';
import '../../widgets/lekis_slider.dart';
import '../sources/common.dart';
import 'equalizer_providers.dart';
import 'settings_providers.dart';
import 'widgets/settings_widgets.dart';

/// 页面文案。
abstract final class EqualizerStrings {
  /// 页面标题。
  static String get title => L10n.tr('均衡器', 'Equalizer');

  /// 设置页入口说明。
  static String get entryHint => L10n.tr(
    '10 段图形均衡器、preamp 与 AutoEQ 风格耳机预设',
    '10-band graphic EQ, preamp & AutoEQ-style headphone presets',
  );

  /// 启用开关。
  static String get general => L10n.tr('开关与预设', 'Power & Preset');
  static String get enabled => L10n.tr('启用均衡器', 'Enable Equalizer');
  static String get enabledHint =>
      L10n.tr('关闭时完全旁路，不改变任何样本', 'Completely bypassed when off');

  /// 预设。
  static String get preset => L10n.tr('预设', 'Preset');
  static String get aboutPresets => L10n.tr('关于预设', 'About Presets');
  static String get custom => L10n.tr('自定义 / 平直', 'Custom / Flat');
  static String get currentPreset => L10n.tr('当前预设', 'Current Preset');
  static String get presetSource => L10n.tr(
    '预设是 AutoEQ 风格的近似补偿曲线，不是官方测量数据；佩戴方式和固件都会影响实际听感。',
    'Presets are approximate AutoEQ-style curves; fit and firmware affect perceived sound.',
  );
  static String get presetApplied => L10n.tr('已应用预设', 'Preset applied');

  /// preamp。
  static String get preamp => L10n.tr('前级增益（preamp）', 'Preamp');
  static String get preampHint => L10n.tr(
    '整体增减音量，给频段提升留出余量，避免削波',
    'Adjust overall gain to leave headroom and avoid clipping',
  );

  /// 频段。
  static String get bands => L10n.tr('频段增益', 'Bands');
  static const bandRange = '31 Hz – 16 kHz';
  static String get bandsHint => L10n.tr(
    '上下拖动滑杆微调；手动调整后会变为“自定义”。',
    'Drag sliders to adjust; manual changes switch to Custom.',
  );

  /// 按钮。
  static String get reset => L10n.tr('重置为平直', 'Reset Flat');
  static String get retry => L10n.tr('重试', 'Retry');

  /// 说明。
  static String get sharedOnly =>
      L10n.tr('均衡器仅在共享输出模式生效', 'EQ applies in Shared output mode only');
  static String get sharedOnlyHint => L10n.tr(
    '独占 / 比特完美模式会跳过 DSP，以保持源码位模式；需要 EQ 时请切换到共享模式。',
    'Exclusive / bit-perfect mode bypasses DSP; switch to Shared mode to use EQ.',
  );
  static String get exclusiveActive => L10n.tr(
    '当前是独占输出模式，均衡器不会生效。切回共享模式后会自动应用。',
    'Exclusive output mode is active, so EQ is bypassed until you switch back to Shared.',
  );

  /// 错误。
  static String get loadFailed => L10n.tr('读取均衡器设置失败', 'Failed to load EQ');
  static String get saveFailed => L10n.tr('保存均衡器设置失败', 'Failed to save EQ');
  static String get unavailable => L10n.tr('均衡器设置暂不可用', 'EQ unavailable');
}

/// 均衡器页面。
class EqualizerPage extends ConsumerWidget {
  /// 创建页面。
  const EqualizerPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncState = ref.watch(equalizerProvider);
    return SettingsScaffold(
      title: EqualizerStrings.title,
      body: asyncState.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _LoadError(error: error),
        data: (state) => _EqualizerBody(state: state),
      ),
    );
  }
}

class _LoadError extends ConsumerWidget {
  const _LoadError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Center(
    child: Padding(
      padding: const EdgeInsets.all(LekisSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${EqualizerStrings.loadFailed}：${describeCoreError(error)}',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: LekisSpacing.lg),
          FilledButton(
            onPressed: () => ref.read(equalizerProvider.notifier).reload(),
            child: Text(EqualizerStrings.retry),
          ),
        ],
      ),
    ),
  );
}

class _EqualizerBody extends ConsumerWidget {
  const _EqualizerBody({required this.state});

  final EqualizerState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(equalizerProvider.notifier);
    final output = ref.watch(playbackOutputProvider);
    final exclusive = output.mode == OutputModeDto.exclusive;
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final preset = state.currentPreset;

    return SettingsListView(
      children: [
        SettingsSection(
          title: EqualizerStrings.general,
          children: [
            SettingsSwitchTile(
              icon: Icons.graphic_eq_rounded,
              title: EqualizerStrings.enabled,
              subtitle: EqualizerStrings.enabledHint,
              value: state.enabled,
              onChanged: (value) =>
                  _guard(context, () => notifier.setEnabled(value)),
            ),
            SettingsBlockTile(
              icon: Icons.headphones_outlined,
              title: EqualizerStrings.preset,
              hint: preset == null
                  ? '${EqualizerStrings.currentPreset}：${EqualizerStrings.custom}'
                  : '${EqualizerStrings.currentPreset}：${preset.name} — ${preset.description}',
              child: SettingsSelectField<String>(
                key: const Key('equalizer-preset-dropdown'),
                title: EqualizerStrings.preset,
                icon: Icons.headphones_outlined,
                value: state.presetId ?? '',
                choices: [
                  SettingsChoice('', EqualizerStrings.custom),
                  for (final item in state.presets)
                    SettingsChoice(item.id, item.name),
                ],
                onChanged: (id) {
                  if (id.isEmpty) {
                    _guard(context, notifier.resetFlat);
                  } else {
                    _guard(context, () => notifier.applyPreset(id));
                  }
                },
              ),
            ),
            SettingsBlockTile(
              icon: Icons.volume_up_outlined,
              title: EqualizerStrings.preamp,
              hint: EqualizerStrings.preampHint,
              trailing: Text(
                _dbLabel(state.preampDb),
                style: theme.textTheme.titleSmall?.copyWith(
                  color: colors.accent,
                ),
              ),
              child: LekisSlider(
                key: const Key('equalizer-preamp-slider'),
                value: state.preampDb,
                min: equalizerMinGainDb,
                max: equalizerMaxGainDb,
                divisions: 48,
                label: _dbLabel(state.preampDb),
                onChanged: notifier.setPreamp,
                onChangeEnd: (_) => notifier.saveNow(),
              ),
            ),
          ],
        ),
        SettingsSection(
          title: EqualizerStrings.bands,
          children: [
            SettingsBlockTile(
              icon: Icons.tune_rounded,
              title: EqualizerStrings.bandRange,
              hint: EqualizerStrings.bandsHint,
              trailing: TextButton.icon(
                onPressed: state.isFlat
                    ? null
                    : () => _guard(context, notifier.resetFlat),
                icon: const Icon(Icons.restart_alt_rounded),
                label: Text(EqualizerStrings.reset),
              ),
              child: SizedBox(
                height: 246,
                child: LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minWidth: constraints.maxWidth,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          for (
                            var index = 0;
                            index < equalizerBandCount;
                            index++
                          )
                            _BandSlider(
                              index: index,
                              value: state.bandsDb[index],
                              onChanged: (value) =>
                                  notifier.setBand(index, value),
                              onChangeEnd: (_) => notifier.saveNow(),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        SettingsGroup(
          children: [
            if (state.saveError != null)
              SettingsTile(
                icon: Icons.error_outline_rounded,
                title: EqualizerStrings.saveFailed,
                subtitle: Text(
                  describeCoreError(state.saveError!),
                  style: TextStyle(color: colors.danger),
                ),
              ),
            SettingsTile(
              icon: exclusive
                  ? Icons.warning_amber_rounded
                  : Icons.info_outline_rounded,
              title: EqualizerStrings.sharedOnly,
              subtitle: Text(
                exclusive
                    ? EqualizerStrings.exclusiveActive
                    : EqualizerStrings.sharedOnlyHint,
                style: exclusive ? TextStyle(color: colors.danger) : null,
              ),
            ),
            SettingsTile(
              icon: Icons.science_outlined,
              title: EqualizerStrings.aboutPresets,
              subtitle: Text(EqualizerStrings.presetSource),
            ),
          ],
        ),
      ],
    );
  }
}

class _BandSlider extends StatelessWidget {
  const _BandSlider({
    required this.index,
    required this.value,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final int index;
  final double value;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final label = equalizerBandLabel(index);
    return SizedBox(
      width: 54,
      child: Column(
        children: [
          SizedBox(
            height: 22,
            child: Text(
              _dbLabel(value),
              style: theme.textTheme.labelSmall?.copyWith(
                color: value.abs() < 0.05
                    ? colors.onSurfaceVariant
                    : colors.accent,
              ),
            ),
          ),
          SizedBox(
            height: 172,
            width: 40,
            child: RotatedBox(
              quarterTurns: 3,
              child: LekisSlider(
                key: Key('equalizer-band-$index'),
                value: value,
                min: equalizerMinGainDb,
                max: equalizerMaxGainDb,
                divisions: 48,
                label: '$label Hz ${_dbLabel(value)}',
                semanticFormatterCallback: (value) =>
                    '$label Hz ${_dbLabel(value)}',
                onChanged: onChanged,
                onChangeEnd: onChangeEnd,
                trackHeight: LekisSliderGeometry.track,
              ),
            ),
          ),
          const SizedBox(height: LekisSpacing.xs),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

String _dbLabel(double value) {
  final sign = value > 0.05 ? '+' : '';
  return '$sign${value.toStringAsFixed(1)} dB';
}

Future<void> _guard(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (e) {
    if (context.mounted) {
      showFeatureSnack(
        context,
        '${EqualizerStrings.saveFailed}：${describeCoreError(e)}',
      );
    }
  }
}
