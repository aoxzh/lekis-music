// 智能歌单规则编辑的纯函数模型。
//
// 这里不定义新的规则格式：所有结构都直接用桥接层生成的 `RuleGroupDto` /
// `SmartRulesDto`，保存时由 Rust 侧转成规范 JSON（SmartRules::to_json）。

import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/dto.dart';

enum SmartFieldKind { text, number, boolean }

SmartFieldKind smartFieldKind(RuleFieldDto field) => switch (field) {
  RuleFieldDto.title ||
  RuleFieldDto.artist ||
  RuleFieldDto.album ||
  RuleFieldDto.genre ||
  RuleFieldDto.codec => SmartFieldKind.text,
  RuleFieldDto.loved => SmartFieldKind.boolean,
  _ => SmartFieldKind.number,
};

Map<RuleFieldDto, String> get smartFieldLabels => {
  RuleFieldDto.title: L10n.tr('标题', 'Title'),
  RuleFieldDto.artist: L10n.tr('艺人', 'Artist'),
  RuleFieldDto.album: L10n.tr('专辑', 'Album'),
  RuleFieldDto.genre: L10n.tr('流派', 'Genre'),
  RuleFieldDto.year: L10n.tr('年份', 'Year'),
  RuleFieldDto.durationMs: L10n.tr('时长（毫秒）', 'Duration (ms)'),
  RuleFieldDto.bitrateKbps: L10n.tr('码率（kbps）', 'Bitrate (kbps)'),
  RuleFieldDto.sampleRate: L10n.tr('采样率（Hz）', 'Sample Rate (Hz)'),
  RuleFieldDto.bitDepth: L10n.tr('位深', 'Bit Depth'),
  RuleFieldDto.codec: L10n.tr('编码格式', 'Codec'),
  RuleFieldDto.loved: L10n.tr('喜欢', 'Loved'),
  RuleFieldDto.rating: L10n.tr('评分', 'Rating'),
  RuleFieldDto.playCount: L10n.tr('播放次数', 'Play Count'),
  RuleFieldDto.addedAt: L10n.tr('入库时间', 'Date Added'),
  RuleFieldDto.lastPlayed: L10n.tr('最近播放', 'Last Played'),
  RuleFieldDto.qualityScore: L10n.tr('音质分', 'Quality Score'),
};

Map<RuleOpDto, String> get smartOpLabels => {
  RuleOpDto.eq: L10n.tr('等于', 'Equals'),
  RuleOpDto.ne: L10n.tr('不等于', 'Not Equals'),
  RuleOpDto.lt: L10n.tr('小于', 'Less Than'),
  RuleOpDto.le: L10n.tr('小于等于', 'Less or Equal'),
  RuleOpDto.gt: L10n.tr('大于', 'Greater Than'),
  RuleOpDto.ge: L10n.tr('大于等于', 'Greater or Equal'),
  RuleOpDto.contains: L10n.tr('包含', 'Contains'),
  RuleOpDto.notContains: L10n.tr('不包含', 'Does Not Contain'),
  RuleOpDto.in_: L10n.tr('属于', 'In'),
  RuleOpDto.notIn: L10n.tr('不属于', 'Not In'),
  RuleOpDto.between: L10n.tr('区间', 'Between'),
};

Map<TrackSortDto, String> get smartSortLabels => {
  TrackSortDto.title: L10n.tr('标题', 'Title'),
  TrackSortDto.artist: L10n.tr('艺人', 'Artist'),
  TrackSortDto.album: L10n.tr('专辑', 'Album'),
  TrackSortDto.recentlyAdded: L10n.tr('最近添加', 'Recently Added'),
  TrackSortDto.mostPlayed: L10n.tr('最常播放', 'Most Played'),
};

List<RuleOpDto> smartOpsForField(RuleFieldDto field) =>
    switch (smartFieldKind(field)) {
      SmartFieldKind.text => const [
        RuleOpDto.eq,
        RuleOpDto.ne,
        RuleOpDto.contains,
        RuleOpDto.notContains,
        RuleOpDto.in_,
        RuleOpDto.notIn,
      ],
      SmartFieldKind.boolean => const [RuleOpDto.eq, RuleOpDto.ne],
      SmartFieldKind.number => const [
        RuleOpDto.eq,
        RuleOpDto.ne,
        RuleOpDto.lt,
        RuleOpDto.le,
        RuleOpDto.gt,
        RuleOpDto.ge,
        RuleOpDto.between,
        RuleOpDto.in_,
        RuleOpDto.notIn,
      ],
    };

/// 新规则默认值：尽量做到"选中就能用"，之后再改具体值。
RuleValueDto smartDefaultValue(RuleFieldDto field, RuleOpDto op) {
  if (op == RuleOpDto.between) {
    return const RuleValueDto.textList(['0', '0']);
  }
  if (op == RuleOpDto.in_ || op == RuleOpDto.notIn) {
    return const RuleValueDto.textList([]);
  }
  if (op == RuleOpDto.contains || op == RuleOpDto.notContains) {
    // contains 在核心里只接受 Text；编码字段也要先转成文本再比较。
    return const RuleValueDto.text('');
  }
  return switch (smartFieldKind(field)) {
    SmartFieldKind.boolean => const RuleValueDto.bool(true),
    SmartFieldKind.number => const RuleValueDto.number(0),
    SmartFieldKind.text =>
      field == RuleFieldDto.codec
          ? const RuleValueDto.codec('flac')
          : const RuleValueDto.text(''),
  };
}

/// 根据字段生成一条可编辑的初始条件。
RuleDto smartNewRule(RuleFieldDto field) {
  final op = switch (smartFieldKind(field)) {
    SmartFieldKind.boolean => RuleOpDto.eq,
    SmartFieldKind.number => RuleOpDto.ge,
    SmartFieldKind.text =>
      field == RuleFieldDto.codec ? RuleOpDto.eq : RuleOpDto.contains,
  };
  return RuleDto(field: field, op: op, value: smartDefaultValue(field, op));
}

/// 字段 / 操作符变化后，把值调整成兼容的形状；已有兼容值保留。
RuleValueDto smartCoerceValue(
  RuleFieldDto field,
  RuleOpDto op,
  RuleValueDto value,
) {
  if (op == RuleOpDto.between) {
    if (value is RuleValueDto_TextList && value.field0.length == 2) {
      return value;
    }
    return smartDefaultValue(field, op);
  }
  if (op == RuleOpDto.in_ || op == RuleOpDto.notIn) {
    if (value is RuleValueDto_TextList) return value;
    return smartDefaultValue(field, op);
  }
  if (op == RuleOpDto.contains || op == RuleOpDto.notContains) {
    if (value is RuleValueDto_Text) return value;
    return smartDefaultValue(field, op);
  }
  // eq / ne：按字段类型保留同类型值。
  return switch (smartFieldKind(field)) {
    SmartFieldKind.boolean =>
      value is RuleValueDto_Bool ? value : smartDefaultValue(field, op),
    SmartFieldKind.number =>
      value is RuleValueDto_Number ? value : smartDefaultValue(field, op),
    SmartFieldKind.text =>
      field == RuleFieldDto.codec
          ? (value is RuleValueDto_Codec ? value : smartDefaultValue(field, op))
          : (value is RuleValueDto_Text ? value : smartDefaultValue(field, op)),
  };
}

RuleGroupDto smartEmptyGroup(RuleGroupKindDto kind) =>
    RuleGroupDto(kind: kind, rules: const [], rule: null);

RuleGroupDto smartRuleGroup(RuleDto rule) =>
    RuleGroupDto(kind: RuleGroupKindDto.rule, rules: const [], rule: rule);

/// 按子组下标路径找到规则组（空路径 = 根）。
RuleGroupDto smartGroupAt(RuleGroupDto root, List<int> path) {
  var group = root;
  for (final index in path) {
    group = group.rules[index];
  }
  return group;
}

/// 按子组下标路径替换规则组。
RuleGroupDto smartUpdateGroupAt(
  RuleGroupDto root,
  List<int> path,
  RuleGroupDto Function(RuleGroupDto group) update,
) {
  if (path.isEmpty) return update(root);
  final index = path.first;
  final rules = [...root.rules];
  rules[index] = smartUpdateGroupAt(rules[index], path.sublist(1), update);
  return RuleGroupDto(kind: root.kind, rules: rules, rule: root.rule);
}

RuleGroupDto smartAddChildAt(
  RuleGroupDto root,
  List<int> parentPath,
  RuleGroupDto child,
) => smartUpdateGroupAt(
  root,
  parentPath,
  (group) => RuleGroupDto(
    kind: group.kind,
    rules: [...group.rules, child],
    rule: group.rule,
  ),
);

RuleGroupDto smartRemoveChildAt(
  RuleGroupDto root,
  List<int> parentPath,
  int childIndex,
) => smartUpdateGroupAt(root, parentPath, (group) {
  final rules = [...group.rules]..removeAt(childIndex);
  return RuleGroupDto(kind: group.kind, rules: rules, rule: group.rule);
});

RuleGroupDto smartReplaceRuleAt(
  RuleGroupDto root,
  List<int> path,
  RuleDto rule,
) => smartUpdateGroupAt(
  root,
  path,
  (group) => RuleGroupDto(kind: group.kind, rules: group.rules, rule: rule),
);

/// 规则组的最大嵌套层数（核心上限 32；UI 不让人一路点到底）。
const int smartMaxEditorDepth = 6;

int smartGroupDepth(RuleGroupDto group) {
  if (group.rules.isEmpty) return 0;
  var max = 0;
  for (final child in group.rules) {
    final depth = smartGroupDepth(child);
    if (depth > max) max = depth;
  }
  return max + 1;
}

SmartRulesDto smartBuildRules({
  required RuleGroupDto root,
  int? limit,
  TrackSortDto? sort,
  bool sortDesc = false,
}) => SmartRulesDto(root: root, limit: limit, sort: sort, sortDesc: sortDesc);

/// 读取数字值（非数字返回 null）。
int? smartNumberValue(RuleValueDto value) =>
    value is RuleValueDto_Number ? value.field0.toInt() : null;

/// 读取文本值。
String? smartTextValue(RuleValueDto value) => switch (value) {
  RuleValueDto_Text(:final field0) => field0,
  RuleValueDto_Codec(:final field0) => field0,
  _ => null,
};

/// 读取多值列表。
List<String>? smartListValue(RuleValueDto value) =>
    value is RuleValueDto_TextList ? value.field0 : null;
