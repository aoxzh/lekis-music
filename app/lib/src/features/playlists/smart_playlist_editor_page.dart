// 智能歌单规则编辑器：AND / OR 分组、字段 / 操作符 / 值、实时预览数量。
//
// 规则树直接使用桥接层生成的 `RuleGroupDto`；保存时由 Rust 侧的
// `SmartRules` 负责校验和写规范 JSON。

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_actions.dart';
import 'package:lekis/src/features/playlists/playlist_providers.dart';
import 'package:lekis/src/features/playlists/smart_rules_model.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class SmartPlaylistEditorPage extends ConsumerStatefulWidget {
  const SmartPlaylistEditorPage({
    super.key,
    required this.playlistId,
    required this.name,
  });

  final int playlistId;
  final String name;

  static Route<bool> route(int playlistId, {required String name}) =>
      MaterialPageRoute<bool>(
        settings: RouteSettings(name: '/playlist/$playlistId/rules'),
        builder: (_) =>
            SmartPlaylistEditorPage(playlistId: playlistId, name: name),
      );

  @override
  ConsumerState<SmartPlaylistEditorPage> createState() =>
      _SmartPlaylistEditorPageState();
}

class _SmartPlaylistEditorPageState
    extends ConsumerState<SmartPlaylistEditorPage> {
  final _limitController = TextEditingController();

  RuleGroupDto? _root;
  TrackSortDto? _sort;
  bool _sortDesc = false;
  bool _loading = true;
  bool _saving = false;
  bool _counting = false;
  int? _previewCount;
  List<TrackRowDto> _previewTracks = const [];
  String? _previewError;
  String? _loadError;
  Timer? _debounce;
  int _previewToken = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _limitController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rules = await core.getPlaylistRules(playlistId: widget.playlistId);
      final resolved =
          rules ?? smartBuildRules(root: smartEmptyGroup(RuleGroupKindDto.all));
      if (!mounted) return;
      setState(() {
        _root = resolved.root;
        _sort = resolved.sort;
        _sortDesc = resolved.sortDesc;
        _limitController.text = resolved.limit?.toString() ?? '';
        _loading = false;
        _loadError = null;
      });
      _schedulePreview();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = describeCoreError(e);
      });
    }
  }

  SmartRulesDto get _rules => smartBuildRules(
    root: _root ?? smartEmptyGroup(RuleGroupKindDto.all),
    limit: int.tryParse(_limitController.text.trim()),
    sort: _sort,
    sortDesc: _sortDesc,
  );

  void _setRoot(RuleGroupDto root) {
    setState(() => _root = root);
    _schedulePreview();
  }

  void _schedulePreview() {
    _debounce?.cancel();
    final token = ++_previewToken;
    setState(() {
      _counting = true;
      _previewError = null;
    });
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => _refreshPreview(token),
    );
  }

  Future<void> _refreshPreview(int token) async {
    try {
      final rules = _rules;
      final (count, tracks) = await (
        core.countSmartRules(rules: rules),
        core.previewSmartRules(
          rules: rules,
          offset: 0,
          limit: _previewSampleSize,
        ),
      ).wait;
      if (!mounted || token != _previewToken) return;
      setState(() {
        _previewCount = count.toInt();
        _previewTracks = tracks;
        _previewError = null;
        _counting = false;
      });
    } catch (e) {
      if (!mounted || token != _previewToken) return;
      setState(() {
        _previewError = describeCoreError(e);
        _counting = false;
      });
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await core.setPlaylistRules(playlistId: widget.playlistId, rules: _rules);
      ref.invalidate(playlistRulesProvider(widget.playlistId));
      ref.invalidate(smartPlaylistTracksProvider(widget.playlistId));
      ref.invalidate(playlistProvider(widget.playlistId));
      ref.invalidate(playlistsProvider);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _previewError = describeCoreError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('智能歌单规则'),
            Text(
              widget.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: LekisSpacing.lg),
              child: Center(
                child: SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            TextButton(
              onPressed: _loading || _loadError != null ? null : _save,
              child: const Text('保存'),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
          ? Center(child: Text('规则加载失败：$_loadError'))
          : _buildEditor(context),
    );
  }

  Widget _buildEditor(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final root = _root!;
    return ListView(
      padding: EdgeInsets.fromLTRB(
        LekisSpacing.lg,
        LekisSpacing.md,
        LekisSpacing.lg,
        LekisSpacing.xxxl + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        Text(
          '条件在核心里实时求值；同一分组内 AND / OR 可以任意嵌套。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: LekisSpacing.md),
        _GroupEditor(group: root, depth: 0, onUpdate: _setRoot),
        const SizedBox(height: LekisSpacing.lg),
        _SettingsCard(
          limitController: _limitController,
          sort: _sort,
          sortDesc: _sortDesc,
          onLimitChanged: (_) => _schedulePreview(),
          onSortChanged: (sort) {
            setState(() => _sort = sort);
            _schedulePreview();
          },
          onSortDescChanged: (desc) {
            setState(() => _sortDesc = desc);
            _schedulePreview();
          },
        ),
        const SizedBox(height: LekisSpacing.lg),
        _PreviewBar(
          counting: _counting,
          count: _previewCount,
          error: _previewError,
        ),
        if (_previewError == null && _previewTracks.isNotEmpty)
          _PreviewTracks(
            tracks: _previewTracks,
            more: (_previewCount ?? 0) - _previewTracks.length,
          ),
        const SizedBox(height: LekisSpacing.md),
        FilledButton.icon(
          onPressed: _saving ? null : _save,
          icon: const Icon(Icons.check_rounded),
          label: const Text('保存规则'),
        ),
      ],
    );
  }
}

class _GroupEditor extends StatelessWidget {
  const _GroupEditor({
    required this.group,
    required this.depth,
    required this.onUpdate,
    this.onRemove,
  });

  final RuleGroupDto group;
  final int depth;
  final ValueChanged<RuleGroupDto> onUpdate;
  final VoidCallback? onRemove;

  RuleGroupDto _withChildren(List<RuleGroupDto> children) =>
      RuleGroupDto(kind: group.kind, rules: children, rule: group.rule);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final isRule = group.kind == RuleGroupKindDto.rule;
    final isNot = group.kind == RuleGroupKindDto.not;
    final canNest = depth < smartMaxEditorDepth;

    return Container(
      margin: EdgeInsets.only(left: depth == 0 ? 0 : LekisSpacing.md),
      padding: const EdgeInsets.all(LekisSpacing.md),
      decoration: BoxDecoration(
        color: depth.isEven
            ? colors.surfaceVariant.withValues(alpha: 0.35)
            : colors.surfaceElevated.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(LekisRadius.md),
        border: Border.all(color: colors.outline.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (isRule)
                Expanded(
                  child: Text(
                    '条件',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                )
              else if (isNot)
                Expanded(
                  child: Row(
                    children: [
                      const Icon(Icons.not_interested_rounded, size: 18),
                      const SizedBox(width: LekisSpacing.xs),
                      Text(
                        '取反（NOT）',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                )
              else
                Expanded(
                  child: SegmentedButton<RuleGroupKindDto>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: RuleGroupKindDto.all,
                        label: Text('全部满足 AND'),
                      ),
                      ButtonSegment(
                        value: RuleGroupKindDto.any,
                        label: Text('任意满足 OR'),
                      ),
                    ],
                    selected: {group.kind},
                    onSelectionChanged: (selection) {
                      onUpdate(
                        RuleGroupDto(
                          kind: selection.first,
                          rules: group.rules,
                          rule: null,
                        ),
                      );
                    },
                  ),
                ),
              if (onRemove != null)
                IconButton(
                  tooltip: '删除分组',
                  visualDensity: VisualDensity.compact,
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                ),
            ],
          ),
          if (isRule) ...[
            const SizedBox(height: LekisSpacing.sm),
            _RuleEditor(
              rule: group.rule!,
              onChanged: (rule) => onUpdate(smartRuleGroup(rule)),
            ),
          ] else ...[
            const SizedBox(height: LekisSpacing.sm),
            if (group.rules.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: LekisSpacing.sm),
                child: Text(
                  group.kind == RuleGroupKindDto.any
                      ? '空 OR 组匹配不到任何歌曲'
                      : '空 AND 组不过滤（匹配全部歌曲）',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            for (var i = 0; i < group.rules.length; i++)
              Padding(
                padding: const EdgeInsets.only(top: LekisSpacing.sm),
                child: group.rules[i].kind == RuleGroupKindDto.rule
                    ? _RuleEditor(
                        rule: group.rules[i].rule!,
                        onChanged: (rule) {
                          final children = [...group.rules];
                          children[i] = smartRuleGroup(rule);
                          onUpdate(_withChildren(children));
                        },
                        onRemove: isNot
                            ? null
                            : () {
                                final children = [...group.rules]..removeAt(i);
                                onUpdate(_withChildren(children));
                              },
                      )
                    : _GroupEditor(
                        group: group.rules[i],
                        depth: depth + 1,
                        onUpdate: (child) {
                          final children = [...group.rules];
                          children[i] = child;
                          onUpdate(_withChildren(children));
                        },
                        onRemove: isNot
                            ? null
                            : () {
                                final children = [...group.rules]..removeAt(i);
                                onUpdate(_withChildren(children));
                              },
                      ),
              ),
            if (!isNot) ...[
              const SizedBox(height: LekisSpacing.sm),
              Wrap(
                spacing: LekisSpacing.sm,
                runSpacing: LekisSpacing.sm,
                children: [
                  OutlinedButton.icon(
                    onPressed: () {
                      final child = smartRuleGroup(
                        smartNewRule(RuleFieldDto.title),
                      );
                      onUpdate(_withChildren([...group.rules, child]));
                    },
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('添加条件'),
                  ),
                  if (canNest)
                    OutlinedButton.icon(
                      onPressed: () {
                        final child = smartEmptyGroup(RuleGroupKindDto.any);
                        onUpdate(_withChildren([...group.rules, child]));
                      },
                      icon: const Icon(Icons.account_tree_outlined),
                      label: const Text('添加 OR 分组'),
                    ),
                ],
              ),
            ],
            if (!isNot && group.rules.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: LekisSpacing.sm),
                child: Text(
                  group.kind == RuleGroupKindDto.any
                      ? '组内任意一条成立即可'
                      : '组内全部条件都要成立',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _RuleEditor extends StatelessWidget {
  const _RuleEditor({
    required this.rule,
    required this.onChanged,
    this.onRemove,
  });

  final RuleDto rule;
  final ValueChanged<RuleDto> onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final ops = smartOpsForField(rule.field);
    final op = ops.contains(rule.op) ? rule.op : ops.first;
    return Wrap(
      spacing: LekisSpacing.sm,
      runSpacing: LekisSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: 150,
          child: DropdownButtonFormField<RuleFieldDto>(
            key: ValueKey('field-${rule.field.name}'),
            initialValue: rule.field,
            decoration: const InputDecoration(labelText: '字段', isDense: true),
            items: [
              for (final field in RuleFieldDto.values)
                DropdownMenuItem(
                  value: field,
                  child: Text(smartFieldLabels[field] ?? field.name),
                ),
            ],
            onChanged: (field) {
              if (field == null) return;
              final next = smartNewRule(field);
              onChanged(next);
            },
          ),
        ),
        SizedBox(
          width: 140,
          child: DropdownButtonFormField<RuleOpDto>(
            key: ValueKey('op-${rule.field.name}-${rule.op.name}'),
            initialValue: op,
            decoration: const InputDecoration(labelText: '条件', isDense: true),
            items: [
              for (final value in ops)
                DropdownMenuItem(
                  value: value,
                  child: Text(smartOpLabels[value] ?? value.name),
                ),
            ],
            onChanged: (next) {
              if (next == null) return;
              onChanged(
                RuleDto(
                  field: rule.field,
                  op: next,
                  value: smartCoerceValue(rule.field, next, rule.value),
                ),
              );
            },
          ),
        ),
        SizedBox(
          width: 210,
          child: _RuleValueEditor(
            key: ValueKey('${rule.field.name}-${rule.op.name}'),
            field: rule.field,
            op: rule.op,
            value: rule.value,
            onChanged: (value) => onChanged(
              RuleDto(field: rule.field, op: rule.op, value: value),
            ),
          ),
        ),
        if (onRemove != null)
          IconButton(
            tooltip: '删除条件',
            visualDensity: VisualDensity.compact,
            onPressed: onRemove,
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
      ],
    );
  }
}

class _RuleValueEditor extends StatefulWidget {
  const _RuleValueEditor({
    super.key,
    required this.field,
    required this.op,
    required this.value,
    required this.onChanged,
  });

  final RuleFieldDto field;
  final RuleOpDto op;
  final RuleValueDto value;
  final ValueChanged<RuleValueDto> onChanged;

  @override
  State<_RuleValueEditor> createState() => _RuleValueEditorState();
}

class _RuleValueEditorState extends State<_RuleValueEditor> {
  late final TextEditingController _text;
  late final TextEditingController _high;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: _initialText());
    _high = TextEditingController(text: _initialHigh());
  }

  String _initialText() => switch (widget.value) {
    RuleValueDto_Text(:final field0) => field0,
    RuleValueDto_Codec(:final field0) => field0,
    RuleValueDto_Number(:final field0) => '$field0',
    RuleValueDto_TextList(:final field0) => field0.isEmpty ? '' : field0.first,
    _ => '',
  };

  String _initialHigh() {
    final list = smartListValue(widget.value);
    return list != null && list.length >= 2 ? list[1] : '';
  }

  @override
  void dispose() {
    _text.dispose();
    _high.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (smartFieldKind(widget.field) == SmartFieldKind.boolean) {
      final current = widget.value is RuleValueDto_Bool
          ? (widget.value as RuleValueDto_Bool).field0
          : true;
      return DropdownButtonFormField<bool>(
        initialValue: current,
        decoration: const InputDecoration(labelText: '值', isDense: true),
        items: const [
          DropdownMenuItem(value: true, child: Text('是')),
          DropdownMenuItem(value: false, child: Text('否')),
        ],
        onChanged: (value) {
          if (value != null) widget.onChanged(RuleValueDto.bool(value));
        },
      );
    }

    if (widget.op == RuleOpDto.between) {
      return Row(
        children: [
          Expanded(
            child: TextField(
              controller: _text,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: '最小值',
                isDense: true,
              ),
              onChanged: (_) => _emitList(),
            ),
          ),
          const SizedBox(width: LekisSpacing.xs),
          Expanded(
            child: TextField(
              controller: _high,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: '最大值',
                isDense: true,
              ),
              onChanged: (_) => _emitList(),
            ),
          ),
        ],
      );
    }

    final listMode = widget.op == RuleOpDto.in_ || widget.op == RuleOpDto.notIn;
    final numeric = smartFieldKind(widget.field) == SmartFieldKind.number;
    return TextField(
      controller: _text,
      keyboardType: numeric ? TextInputType.number : TextInputType.text,
      inputFormatters: numeric
          ? [FilteringTextInputFormatter.allow(RegExp(r'^-?\d*'))]
          : null,
      decoration: InputDecoration(
        labelText: listMode ? '值（逗号分隔）' : '值',
        hintText: switch (widget.field) {
          RuleFieldDto.codec => 'flac / mp3 / lossless',
          RuleFieldDto.genre => 'Rock, Jazz',
          _ => null,
        },
        isDense: true,
      ),
      onChanged: (_) {
        if (listMode) {
          _emitList();
          return;
        }
        if (numeric) {
          final number = int.tryParse(_text.text.trim());
          if (number != null) {
            widget.onChanged(RuleValueDto.number(number));
          }
        } else if (widget.field == RuleFieldDto.codec &&
            (widget.op == RuleOpDto.eq || widget.op == RuleOpDto.ne)) {
          widget.onChanged(RuleValueDto.codec(_text.text.trim()));
        } else {
          widget.onChanged(RuleValueDto.text(_text.text));
        }
      },
    );
  }

  void _emitList() {
    if (widget.op == RuleOpDto.between) {
      widget.onChanged(
        RuleValueDto.textList([
          _text.text.trim().isEmpty ? '0' : _text.text.trim(),
          _high.text.trim().isEmpty ? '0' : _high.text.trim(),
        ]),
      );
      return;
    }
    final values = _text.text
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    widget.onChanged(RuleValueDto.textList(values));
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.limitController,
    required this.sort,
    required this.sortDesc,
    required this.onLimitChanged,
    required this.onSortChanged,
    required this.onSortDescChanged,
  });

  final TextEditingController limitController;
  final TrackSortDto? sort;
  final bool sortDesc;
  final ValueChanged<String> onLimitChanged;
  final ValueChanged<TrackSortDto?> onSortChanged;
  final ValueChanged<bool> onSortDescChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    return Container(
      padding: const EdgeInsets.all(LekisSpacing.md),
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(LekisRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '其他设置',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: LekisSpacing.sm),
          TextField(
            controller: limitController,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: '最多多少首（留空 = 不限，最大 5000）',
              isDense: true,
            ),
            onChanged: onLimitChanged,
          ),
          const SizedBox(height: LekisSpacing.md),
          Text('排序', style: theme.textTheme.bodySmall),
          const SizedBox(height: LekisSpacing.xs),
          Wrap(
            spacing: LekisSpacing.xs,
            runSpacing: LekisSpacing.xs,
            children: [
              ChoiceChip(
                label: const Text('默认'),
                selected: sort == null,
                onSelected: (_) => onSortChanged(null),
              ),
              for (final option in TrackSortDto.values)
                ChoiceChip(
                  label: Text(smartSortLabels[option] ?? option.name),
                  selected: sort == option,
                  onSelected: (_) => onSortChanged(option),
                ),
            ],
          ),
          if (sort != null)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('倒序'),
              value: sortDesc,
              onChanged: onSortDescChanged,
            ),
        ],
      ),
    );
  }
}

/// 预览列表最多显示几首。
const _previewSampleSize = 8;

/// 规则匹配到的前几首歌，让用户一眼看出规则对不对。
class _PreviewTracks extends StatelessWidget {
  const _PreviewTracks({required this.tracks, required this.more});

  final List<TrackRowDto> tracks;
  final int more;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    return Padding(
      padding: const EdgeInsets.only(top: LekisSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final track in tracks)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: LekisSpacing.sm,
              ),
              leading: SizedBox.square(
                dimension: 36,
                child: TrackArtwork(
                  trackId: track.id.toInt(),
                  hasArtwork: track.artworkId != null,
                  placeholderLabel: track.title,
                ),
              ),
              title: Text(
                track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                track.artistLine,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (more > 0)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: LekisSpacing.sm,
                vertical: LekisSpacing.xs,
              ),
              child: Text(
                '还有 $more 首…',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PreviewBar extends StatelessWidget {
  const _PreviewBar({
    required this.counting,
    required this.count,
    required this.error,
  });

  final bool counting;
  final int? count;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: LekisSpacing.md,
        vertical: LekisSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.accentSoft,
        borderRadius: BorderRadius.circular(LekisRadius.md),
      ),
      child: Row(
        children: [
          if (counting)
            const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(Icons.visibility_outlined, size: 18, color: colors.accent),
          const SizedBox(width: LekisSpacing.sm),
          Expanded(
            child: Text(
              error != null
                  ? '规则无效：$error'
                  : counting
                  ? '正在预览…'
                  : '预览：匹配 ${count ?? 0} 首',
              style: theme.textTheme.bodySmall?.copyWith(
                color: error != null ? colors.danger : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
