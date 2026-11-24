import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_l10n.dart';
import '../now_playing/lyrics_ruby.dart';
import '../now_playing/lyrics_stage_settings.dart';
import 'settings_providers.dart';
import 'strings.dart';
import 'widgets/settings_widgets.dart';

const _profileKeys = [
  SettingKeys.lyricsStage,
  SettingKeys.lyricsFontScale,
  SettingKeys.lyricsTranslation,
  SettingKeys.lyricsSparks,
  SettingKeys.lyricsRuby,
];
const _scales = ['0.85', '1', '1.15', '1.3'];
const _format = 'lekis.lyric-stage';

typedef LyricAppearance = ({
  LyricsStyle style,
  String scale,
  bool translation,
  bool sparks,
  LyricsRubyMode ruby,
});

class LyricPreset {
  const LyricPreset(this.name, this.appearance);
  final String name;
  final LyricAppearance appearance;

  Map<String, Object> toJson() => {
    'format': _format,
    'version': 1,
    'name': name,
    'style': appearance.style.storageValue,
    'scale': appearance.scale,
    'translation': appearance.translation,
    'sparks': appearance.sparks,
    'ruby': appearance.ruby.storageValue,
  };

  factory LyricPreset.fromJson(Object? raw) {
    if (raw
        case {
          'format': _format,
          'version': 1,
          'name': String name,
          'style': String style,
          'scale': String scale,
          'translation': bool translation,
          'sparks': bool sparks,
          'ruby': String ruby,
        }
        when name.trim().isNotEmpty &&
            name.trim().length <= 80 &&
            _scales.contains(scale)) {
      final stage = LyricsStyle.values
          .where((s) => s.storageValue == style)
          .firstOrNull;
      final mode = LyricsRubyMode.values
          .where((s) => s.storageValue == ruby)
          .firstOrNull;
      if (stage != null && mode != null) {
        return LyricPreset(name.trim(), (
          style: stage,
          scale: scale,
          translation: translation,
          sparks: sparks,
          ruby: mode,
        ));
      }
    }
    throw const FormatException('Invalid lyric stage preset');
  }
}

List<LyricPreset> _catalog(String? stored) {
  if (stored == null) return [];
  final raw = jsonDecode(stored);
  if (raw is! List) throw const FormatException('Invalid preset list');
  return raw.map(LyricPreset.fromJson).toList();
}

class LyricsPresetTile extends StatelessWidget {
  const LyricsPresetTile({super.key});

  @override
  Widget build(BuildContext context) => SettingsTile(
    icon: Icons.bookmarks_outlined,
    title: SettingsStrings.lyricsPresets,
    subtitle: Text(
      context.l10n.pick(
        '保存当前组合，或导入分享的 JSON',
        'Save this appearance or import a shared preset',
      ),
    ),
    onTap: () => showDialog<void>(
      context: context,
      builder: (_) => const _PresetDialog(),
    ),
  );
}

class _PresetDialog extends ConsumerStatefulWidget {
  const _PresetDialog();
  @override
  ConsumerState<_PresetDialog> createState() => _PresetDialogState();
}

class _PresetDialogState extends ConsumerState<_PresetDialog> {
  bool busy = false;
  String? message;

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(
          () => message = error is FormatException
              ? context.l10n.pick(
                  '无法读取歌词预设，请检查 JSON 格式和版本。',
                  'Invalid preset JSON or unsupported version.',
                )
              : '${SettingsStrings.saveFailed} · $error',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<String?> _input({required bool importing}) async {
    var value = '';
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(
          importing
              ? context.l10n.pick('导入预设', 'Import preset')
              : context.l10n.pick('保存当前组合', 'Save current appearance'),
        ),
        content: TextField(
          autofocus: true,
          minLines: importing ? 3 : 1,
          maxLines: importing ? 6 : 1,
          maxLength: importing ? 4096 : 80,
          onChanged: (text) => value = text.trim(),
          decoration: InputDecoration(
            labelText: importing
                ? 'JSON'
                : context.l10n.pick('预设名称', 'Preset name'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.pick('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, value),
            child: Text(context.l10n.pick('确定', 'OK')),
          ),
        ],
      ),
    );
  }

  Future<void> _add(LyricAppearance current, {required bool importing}) async {
    final input = await _input(importing: importing);
    if (input == null || !mounted) return;
    if (input.isEmpty) {
      setState(
        () => message = context.l10n.pick(
          '请填写名称或 JSON。',
          'Enter a name or JSON.',
        ),
      );
      return;
    }
    final preset = importing
        ? LyricPreset.fromJson(jsonDecode(input))
        : LyricPreset(input, current);
    final provider = settingProvider(SettingKeys.lyricsPresets);
    final presets = _catalog(await ref.read(provider.future));
    if (!mounted) return;
    if (presets.any((p) => p.name == preset.name)) {
      setState(
        () => message = context.l10n.pick(
          '已有同名预设，请更换名称。',
          'A preset with this name already exists.',
        ),
      );
      return;
    }
    await ref.read(provider.notifier).set(jsonEncode([...presets, preset]));
  }

  Future<void> _apply(LyricAppearance appearance) async {
    final values = [
      appearance.style.storageValue,
      appearance.scale,
      '${appearance.translation}',
      '${appearance.sparks}',
      appearance.ruby.storageValue,
    ];
    final writes = [
      for (final key in _profileKeys) ref.read(settingProvider(key).notifier),
    ];
    final previous = [
      for (final key in _profileKeys) ref.read(settingProvider(key)).value,
    ];
    const defaults = ['classic', '1', 'true', 'true', 'off'];
    final changed = <int>[];
    try {
      for (var i = 0; i < writes.length; i++) {
        if ((previous[i] ?? defaults[i]) == values[i]) continue;
        await writes[i].set(values[i]);
        changed.add(i);
      }
    } catch (_) {
      for (final i in changed.reversed) {
        await writes[i].set(previous[i] ?? defaults[i]);
      }
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    final saved = ref.watch(settingProvider(SettingKeys.lyricsPresets));
    final values = [
      for (final key in _profileKeys) ref.watch(settingProvider(key)),
    ];
    final current = (
      style: LyricsStyle.fromStorage(values[0].value),
      scale: _scales.contains(values[1].value) ? values[1].value! : '1',
      translation: values[2].value != 'false',
      sparks: values[3].value != 'false',
      ruby: LyricsRubyMode.fromStorage(values[4].value),
    );
    final ready =
        !busy &&
        [
          saved,
          ...values,
        ].every((s) => s.hasValue && !s.isLoading && !s.hasError);
    List<LyricPreset>? presets;
    try {
      presets = _catalog(saved.value);
    } on FormatException {
      presets = null;
    }
    final readable = ready && presets != null;
    final l10n = context.l10n;
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        scrollable: true,
        title: Text(SettingsStrings.lyricsPresets),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (presets != null)
                for (final preset in presets)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(preset.name),
                    subtitle: Text(preset.appearance.style.label),
                    selected: preset.appearance == current,
                    leading: Icon(
                      preset.appearance == current
                          ? Icons.check_circle
                          : preset.appearance.style.icon,
                    ),
                    onTap: readable
                        ? () => _run(() => _apply(preset.appearance))
                        : null,
                    trailing: IconButton(
                      tooltip: l10n.pick('复制 JSON', 'Copy JSON'),
                      icon: const Icon(Icons.copy),
                      onPressed: busy
                          ? null
                          : () => _run(() async {
                              await Clipboard.setData(
                                ClipboardData(text: jsonEncode(preset)),
                              );
                              if (mounted) {
                                setState(
                                  () => message = l10n.pick(
                                    '已复制 JSON',
                                    'JSON copied',
                                  ),
                                );
                              }
                            }),
                    ),
                  ),
              if (presets == null || [saved, ...values].any((s) => s.hasError))
                Text(l10n.pick('无法读取歌词设置', 'Unable to read lyric settings')),
              if (message != null)
                Semantics(liveRegion: true, child: Text(message!)),
              Wrap(
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.add),
                    label: Text(l10n.pick('保存当前组合', 'Save current appearance')),
                    onPressed: readable
                        ? () => _run(() => _add(current, importing: false))
                        : null,
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.download_outlined),
                    label: Text(l10n.pick('导入 JSON', 'Import JSON')),
                    onPressed: readable
                        ? () => _run(() => _add(current, importing: true))
                        : null,
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: Text(l10n.pick('关闭', 'Close')),
          ),
        ],
      ),
    );
  }
}
