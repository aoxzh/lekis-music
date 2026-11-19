import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/playlists/smart_rules_model.dart';
import 'package:lekis/src/rust/api/dto.dart';

void main() {
  test('new rules use compatible operator/value shapes', () {
    final text = smartNewRule(RuleFieldDto.title);
    expect(text.field, RuleFieldDto.title);
    expect(text.op, RuleOpDto.contains);
    expect(smartTextValue(text.value), '');

    final codec = smartNewRule(RuleFieldDto.codec);
    expect(codec.op, RuleOpDto.eq);
    expect(smartTextValue(codec.value), 'flac');

    final loved = smartNewRule(RuleFieldDto.loved);
    expect(loved.op, RuleOpDto.eq);
    expect(loved.value, isA<RuleValueDto_Bool>());

    final rating = smartNewRule(RuleFieldDto.rating);
    expect(rating.op, RuleOpDto.ge);
    expect(smartNumberValue(rating.value), 0);
  });

  test('operator lists follow field kind', () {
    expect(
      smartOpsForField(RuleFieldDto.title),
      containsAll([RuleOpDto.contains, RuleOpDto.in_, RuleOpDto.notIn]),
    );
    expect(smartOpsForField(RuleFieldDto.loved), [RuleOpDto.eq, RuleOpDto.ne]);
    expect(
      smartOpsForField(RuleFieldDto.year),
      containsAll([RuleOpDto.lt, RuleOpDto.ge, RuleOpDto.between]),
    );
  });

  test('changing operator coerces incompatible values', () {
    final between = smartCoerceValue(
      RuleFieldDto.year,
      RuleOpDto.between,
      const RuleValueDto.number(2020),
    );
    expect(smartListValue(between), ['0', '0']);

    final list = smartCoerceValue(
      RuleFieldDto.genre,
      RuleOpDto.in_,
      const RuleValueDto.text('Rock'),
    );
    expect(smartListValue(list), isEmpty);

    final contains = smartCoerceValue(
      RuleFieldDto.title,
      RuleOpDto.contains,
      const RuleValueDto.number(1),
    );
    expect(smartTextValue(contains), '');

    // 编码字段的 contains 也必须是文本，而不是 Codec 值。
    final codecContains = smartCoerceValue(
      RuleFieldDto.codec,
      RuleOpDto.contains,
      const RuleValueDto.codec('flac'),
    );
    expect(codecContains, isA<RuleValueDto_Text>());
  });

  test('nested group update / add / remove keeps sibling order', () {
    final root = smartEmptyGroup(RuleGroupKindDto.all);
    final inner = smartEmptyGroup(RuleGroupKindDto.any);
    final withInner = smartAddChildAt(root, const [], inner);
    final withRule = smartAddChildAt(withInner, const [
      0,
    ], smartRuleGroup(smartNewRule(RuleFieldDto.loved)));

    expect(withRule.rules.length, 1);
    expect(withRule.rules.first.kind, RuleGroupKindDto.any);
    expect(withRule.rules.first.rules.length, 1);
    expect(withRule.rules.first.rules.first.rule?.field, RuleFieldDto.loved);

    final replaced = smartReplaceRuleAt(withRule, const [
      0,
      0,
    ], smartNewRule(RuleFieldDto.rating));
    expect(replaced.rules.first.rules.first.rule?.field, RuleFieldDto.rating);

    final removed = smartRemoveChildAt(replaced, const [0], 0);
    expect(removed.rules.first.rules, isEmpty);
    expect(smartGroupDepth(withRule), 2);
  });

  test('empty AND matches all and empty OR matches none by convention', () {
    final all = smartEmptyGroup(RuleGroupKindDto.all);
    final any = smartEmptyGroup(RuleGroupKindDto.any);
    expect(all.rules, isEmpty);
    expect(any.rules, isEmpty);
    expect(smartGroupDepth(all), 0);
    expect(smartGroupDepth(any), 0);
  });
}
