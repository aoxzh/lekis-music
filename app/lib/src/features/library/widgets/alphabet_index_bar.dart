import 'package:flutter/services.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

/// 字母 / 拼音快速索引条（UIX-05）。
///
/// 挂在长列表（按标题排序的歌曲、艺人列表）右侧，支持点按与上下滑动
/// 快速定位到对应首字母段，滑动时在索引条左侧浮出月夜质感的首字母预览气泡。
class AlphabetIndexBar extends StatefulWidget {
  const AlphabetIndexBar({
    super.key,
    required this.offsets,
    required this.onSelect,
    this.padding = const EdgeInsets.symmetric(
      vertical: LekisSpacing.md,
      horizontal: LekisSpacing.xs,
    ),
  });

  /// 按显示顺序排列的首字母及其起始行号（由核心提供）。
  final List<LetterOffsetDto> offsets;

  /// 用户点击或滑动选中某个首字母时触发，参数为目标列表行号。
  final ValueChanged<int> onSelect;

  final EdgeInsetsGeometry padding;

  static const Key railKey = ValueKey('alphabet-index-bar.rail');
  static const Key bubbleKey = ValueKey('alphabet-index-bar.bubble');

  @override
  State<AlphabetIndexBar> createState() => _AlphabetIndexBarState();
}

class _AlphabetIndexBarState extends State<AlphabetIndexBar> {
  final GlobalKey _railBoxKey = GlobalKey();
  int? _activeIndex;

  void _selectAtGlobalDy(double globalDy) {
    final offsets = widget.offsets;
    if (offsets.isEmpty) return;
    final box = _railBoxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || box.size.height <= 0) return;
    final localY = box.globalToLocal(Offset(0, globalDy)).dy;
    final clamped = localY.clamp(0.0, box.size.height - 0.001);
    final idx = ((clamped / box.size.height) * offsets.length).floor().clamp(
      0,
      offsets.length - 1,
    );
    if (idx != _activeIndex) {
      setState(() => _activeIndex = idx);
      HapticFeedback.selectionClick();
      widget.onSelect(offsets[idx].offset);
    }
  }

  void _clearActive() {
    if (_activeIndex != null) {
      setState(() => _activeIndex = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final offsets = widget.offsets;
    if (offsets.length < 2) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final active = _activeIndex != null && _activeIndex! < offsets.length
        ? offsets[_activeIndex!]
        : null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxH = constraints.hasBoundedHeight
            ? (constraints.maxHeight - LekisSpacing.xl * 2).clamp(
                120.0,
                double.infinity,
              )
            : 480.0;
        final rowHeight = (maxH / offsets.length).clamp(11.0, 20.0);
        final fontSize = rowHeight < 14 ? 9.0 : 10.0;

        return Padding(
          padding: widget.padding,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (active != null) ...[
                IgnorePointer(
                  child: Container(
                    key: AlphabetIndexBar.bubbleKey,
                    width: 56,
                    height: 56,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: colors.surfaceElevated.withValues(alpha: 0.94),
                      borderRadius: BorderRadius.circular(LekisRadius.lg),
                      border: Border.all(color: colors.outline),
                      boxShadow: [
                        BoxShadow(
                          color: colors.scrim.withValues(alpha: 0.35),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Text(
                      active.letter,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        color: colors.moon,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: LekisSpacing.md),
              ],
              Semantics(
                label: '首字母快速索引',
                child: GestureDetector(
                  key: AlphabetIndexBar.railKey,
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragDown: (d) =>
                      _selectAtGlobalDy(d.globalPosition.dy),
                  onVerticalDragStart: (d) =>
                      _selectAtGlobalDy(d.globalPosition.dy),
                  onVerticalDragUpdate: (d) =>
                      _selectAtGlobalDy(d.globalPosition.dy),
                  onVerticalDragEnd: (_) => _clearActive(),
                  onVerticalDragCancel: _clearActive,
                  child: Container(
                    key: _railBoxKey,
                    padding: const EdgeInsets.symmetric(
                      horizontal: LekisSpacing.xs,
                      vertical: LekisSpacing.xs,
                    ),
                    decoration: BoxDecoration(
                      color: colors.surfaceElevated.withValues(
                        alpha: active != null ? 0.88 : 0.62,
                      ),
                      borderRadius: BorderRadius.circular(LekisRadius.pill),
                      border: Border.all(
                        color: colors.outline.withValues(alpha: 0.7),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < offsets.length; i++)
                          SizedBox(
                            width: 20,
                            height: rowHeight,
                            child: Center(
                              child: Text(
                                offsets[i].letter,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontSize: fontSize,
                                  height: 1,
                                  fontWeight: i == _activeIndex
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: i == _activeIndex
                                      ? colors.accent
                                      : colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 辅助计算跳到固定行高列表某一行时的滚动偏移。
void jumpScrollControllerToRow(
  ScrollController controller, {
  required int rowIndex,
  required double itemExtent,
  double leadingExtent = 0,
}) {
  if (!controller.hasClients) return;
  final position = controller.position;
  final raw = leadingExtent + rowIndex * itemExtent;
  final target = raw.clamp(position.minScrollExtent, position.maxScrollExtent);
  controller.jumpTo(target);
}
