// 设置区的共用骨架：页头、分组、行。
//
// 设置是“后台”页面：更安静、更密，但页头位置、边距、字号和资料库 / 音源一致。
// 所有设置页（含子页面）都用这里的组件，不再用 Material 默认的 AppBar / ListTile。
//
// 两种外观，由 [UiProfile.desktopSettings] 决定，调用方不用分支：
//  * 手机 / 平板：平铺的行 + 发丝分隔线，控件放在标题下面。
//  * 桌面（Windows / macOS / Linux）：Windows 11 设置那样的分组卡片，
//    行更紧凑，开关前面带“开 / 关”，选项用下拉框（[SettingsDropdownTile]）。

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../../platform/ui_profile.dart';
import '../../../theme/tokens.dart';
import '../../library/widgets/page_gutter.dart';
import '../../sources/common.dart';

/// 行首图标占的宽度（也是图标尺寸）。
const double _iconSlot = LekisSpacing.xl;

/// 行自身的左右内边距（水波纹铺满整行，内容仍落在页边距上）。
const double settingsRowInset = LekisSpacing.lg;

/// 行内文字相对分组左边缘的起点；分隔线从这里开始。
const double settingsTextInset = LekisSpacing.lg + _iconSlot + LekisSpacing.lg;

/// 分组面板的外观：卡片底色 + 1px 描边，不用投影。
BoxDecoration settingsPanelDecoration(BuildContext context) {
  final colors = context.lekisColors;
  return BoxDecoration(
    color: colors.surfaceVariant.withValues(alpha: 0.5),
    borderRadius: BorderRadius.circular(LekisRadius.md),
  );
}

/// 桌面分组卡片：略高于页面底色的面 + 1px 描边，Fluent 的小圆角，不用投影。
BoxDecoration settingsCardDecoration(BuildContext context) {
  final colors = context.lekisColors;
  return BoxDecoration(
    color: colors.surfaceElevated,
    borderRadius: BorderRadius.circular(LekisRadius.sm),
    border: Border.all(color: colors.outline),
  );
}

bool get _desktop => UiProfile.current.desktopSettings;

/// 与资料库同位置、同字号的页头。被推入的子页面自动带返回按钮。
class SettingsPageHeader extends StatelessWidget {
  const SettingsPageHeader({
    super.key,
    required this.title,
    this.actions = const [],
  });

  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final gutter = pageGutterOf(context);
    final canPop = ModalRoute.of(context)?.impliesAppBarDismissal ?? false;
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        // 返回按钮的图标和下方内容的左边缘对齐。
        canPop ? gutter - LekisSpacing.md : gutter,
        LekisSpacing.lg,
        gutter - LekisSpacing.sm,
        LekisSpacing.md,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: LekisSizes.touchTargetMin),
        child: Row(
          children: [
            if (canPop) ...[
              const BackButton(),
              const SizedBox(width: LekisSpacing.xs),
            ],
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            ...actions,
          ],
        ),
      ),
    );
  }
}

/// 设置页面骨架：页头 + 内容，内容区自己负责滚动和底部留白。
class SettingsScaffold extends StatelessWidget {
  const SettingsScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions = const [],
  });

  final String title;
  final List<Widget> actions;
  final Widget body;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsPageHeader(title: title, actions: actions),
          Expanded(child: body),
        ],
      ),
    ),
  );
}

/// 设置内容的左右边距：页面边距；宽窗口里限制内容宽度并靠左对齐在标题下方。
/// 底部留出迷你播放器 / 浮动标签栏的空间。
EdgeInsets settingsContentPadding(BuildContext context, double maxWidth) {
  // Rows are flat (no card) and carry their own 16dp inner padding so the
  // ripple spans the row; pull the list out by that much so icons, section
  // headers and the page title all start on the page gutter.
  // Desktop cards carry the inset inside themselves, so no pull-out.
  final pull = _desktop ? 0.0 : settingsRowInset;
  final gutter = pageGutterOf(context) - pull;
  final right = math.max(
    gutter,
    maxWidth - pageGutterOf(context) - featureMaxContentWidth - pull,
  );
  return EdgeInsets.fromLTRB(
    gutter,
    LekisSpacing.sm,
    right,
    scrollEndPadding(context),
  );
}

/// 设置内容列表（少量固定内容）。
class SettingsListView extends StatelessWidget {
  const SettingsListView({super.key, required this.children, this.physics});

  final List<Widget> children;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => ListView(
      physics: physics,
      padding: settingsContentPadding(context, constraints.maxWidth),
      children: children,
    ),
  );
}

/// 设置内容的 sliver 版本，给可能很长的列表用（下载、补全等）。
class SettingsScrollView extends StatelessWidget {
  const SettingsScrollView({super.key, required this.slivers, this.physics});

  final List<Widget> slivers;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => CustomScrollView(
      physics: physics,
      slivers: [
        SliverPadding(
          padding: settingsContentPadding(context, constraints.maxWidth),
          sliver: SliverMainAxisGroup(slivers: slivers),
        ),
      ],
    ),
  );
}

/// 小节标题：与首页书架标题同一风格，缩小一级。
class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: _desktop
          // Desktop: a semibold label just above its card, like Windows 11.
          ? const EdgeInsets.fromLTRB(
              LekisSpacing.xxs,
              LekisSpacing.sm,
              LekisSpacing.xxs,
              LekisSpacing.sm,
            )
          : const EdgeInsets.fromLTRB(
              settingsRowInset,
              LekisSpacing.sm,
              settingsRowInset,
              LekisSpacing.xs,
            ),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: _desktop
                    ? text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)
                    : text.labelLarge?.copyWith(
                        color: context.lekisColors.onSurfaceVariant,
                        letterSpacing: 0.4,
                      ),
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// 一组可能很长的行（sliver）：小标题 + 平铺的行，按需构建。
///
/// 面板里每行自带透明 Material，水波纹画在面板之上。
class SettingsSliverSection extends StatelessWidget {
  const SettingsSliverSection({
    super.key,
    required this.title,
    required this.itemCount,
    required this.itemBuilder,
    this.dividerIndent = settingsTextInset,
  });

  final String title;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final double dividerIndent;

  @override
  Widget build(BuildContext context) {
    Widget list = SliverList.separated(
      itemCount: itemCount,
      itemBuilder: (context, i) => Material(
        type: MaterialType.transparency,
        child: itemBuilder(context, i),
      ),
      separatorBuilder: (_, _) =>
          Divider(height: 1, indent: _desktop ? 0 : dividerIndent),
    );
    if (_desktop) {
      list = DecoratedSliver(
        decoration: settingsCardDecoration(context),
        sliver: list,
      );
    }
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(child: SettingsSectionHeader(title)),
        list,
        const SliverToBoxAdapter(child: SizedBox(height: LekisSpacing.xl)),
      ],
    );
  }
}

/// 一组设置：小标题 + 平铺的行。
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    required this.children,
    this.dividerIndent = settingsTextInset,
  });

  final String title;
  final List<Widget> children;
  final double dividerIndent;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: LekisSpacing.xl),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionHeader(title),
        SettingsGroup(dividerIndent: dividerIndent, children: children),
      ],
    ),
  );
}

/// 平铺的一组行，行与行之间是从文字起点开始的 1px 分隔线。
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    required this.children,
    this.dividerIndent = settingsTextInset,
  });

  final List<Widget> children;

  /// 分隔线起点；行首不是图标（例如封面）时传入对应的文字起点。
  final double dividerIndent;

  @override
  Widget build(BuildContext context) {
    if (_desktop) {
      // Windows 11: one card per group, full-width hairlines between rows.
      final colors = context.lekisColors;
      return DecoratedBox(
        decoration: settingsCardDecoration(context),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(LekisRadius.sm),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: colors.outline),
                  children[i],
                ],
              ],
            ),
          ),
        ),
      );
    }
    // Flat rows on the page background, hairline dividers between them —
    // no card, so Settings reads like the rest of the app's lists.
    return Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 1, indent: dividerIndent),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// IconButton 自带一圈内边距；把它向外挪一点，让图标和箭头 / 数值的右边缘对齐。
Widget settingsAlignTrailing(Widget trailing) => trailing is IconButton
    ? Transform.translate(
        offset: const Offset(LekisSpacing.md, 0),
        child: trailing,
      )
    : trailing;

/// 行首图标：统一尺寸、元信息色；需要强调（如错误）时可以覆盖颜色。
class SettingsLeadingIcon extends StatelessWidget {
  const SettingsLeadingIcon(this.icon, {super.key, this.color});

  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) => Icon(
    icon,
    size: _desktop ? LekisSpacing.lg + LekisSpacing.xs : _iconSlot,
    color: color ?? context.lekisColors.onSurfaceVariant,
  );
}

/// 一行设置：图标、标题、可选说明、右侧的值 / 控件 / 箭头。最小高度 48dp。
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.chevron = false,
    this.selected = false,
  });

  final IconData icon;
  final String title;

  /// 说明文字；默认用 bodySmall（元信息色），可以覆盖颜色。
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// 是否在末尾显示进入下一级的箭头。
  final bool chevron;

  /// 双栏布局里右栏正在显示这一行对应的子页面。
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    if (selected) {
      return Semantics(
        selected: true,
        child: DecoratedBox(
          decoration: settingsPanelDecoration(context),
          child: _build(context, theme, colors),
        ),
      );
    }
    return _build(context, theme, colors);
  }

  Widget _build(BuildContext context, ThemeData theme, LekisColors colors) {
    final end = chevron
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (trailing != null) ...[
                trailing!,
                const SizedBox(width: LekisSpacing.xs),
              ],
              const Icon(Icons.chevron_right_rounded),
            ],
          )
        : trailing;

    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        // Desktop rows are a touch taller (Windows 11 cards) but carry the
        // same content; mobile keeps the 48 dp touch target.
        constraints: BoxConstraints(
          minHeight: _desktop
              ? LekisSizes.touchTargetMin + LekisSpacing.md
              : LekisSizes.touchTargetMin,
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: LekisSpacing.lg,
            vertical: _desktop ? LekisSpacing.md : LekisSpacing.sm,
          ),
          child: Row(
            children: [
              SettingsLeadingIcon(icon),
              const SizedBox(width: LekisSpacing.lg),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.bodyLarge),
                    if (subtitle != null) ...[
                      const SizedBox(height: LekisSpacing.xxs),
                      DefaultTextStyle.merge(
                        style: theme.textTheme.bodySmall,
                        child: subtitle!,
                      ),
                    ],
                  ],
                ),
              ),
              if (end != null) ...[
                const SizedBox(width: LekisSpacing.md),
                IconTheme.merge(
                  data: IconThemeData(color: colors.onSurfaceVariant),
                  child: DefaultTextStyle.merge(
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                    child: settingsAlignTrailing(end),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 开关行：整行可点。
class SettingsSwitchTile extends StatelessWidget {
  const SettingsSwitchTile({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final toggle = Switch(value: value, onChanged: onChanged);
    return MergeSemantics(
      child: SettingsTile(
        icon: icon,
        title: title,
        subtitle: subtitle == null ? null : Text(subtitle!),
        // Windows-style toggle: the state is spelled out next to it.
        trailing: _desktop
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ExcludeSemantics(
                    child: Text(
                      value
                          ? SettingsWidgetStrings.on
                          : SettingsWidgetStrings.off,
                    ),
                  ),
                  const SizedBox(width: LekisSpacing.sm),
                  toggle,
                ],
              )
            : toggle,
        onTap: onChanged == null ? null : () => onChanged!(!value),
      ),
    );
  }
}

/// 控件放在标题下面的设置行（分段按钮、下拉框、预览选择器等）。
class SettingsBlockTile extends StatelessWidget {
  const SettingsBlockTile({
    super.key,
    required this.icon,
    required this.title,
    required this.child,
    this.hint,
    this.trailing,
    this.titleStyle,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final String? hint;
  final Widget? trailing;

  /// 覆盖标题样式（例如把状态文字作为标题时用元信息色）。
  final TextStyle? titleStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 宽窗口里控件和标题文字对齐；手机上让控件用满整行宽度。
    final indent = context.isCompactWidth
        ? 0.0
        : settingsTextInset - LekisSpacing.lg;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: LekisSpacing.lg,
        vertical: LekisSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: _iconSlot),
            child: Row(
              children: [
                SettingsLeadingIcon(icon),
                const SizedBox(width: LekisSpacing.lg),
                Expanded(
                  child: Text(
                    title,
                    style: titleStyle ?? theme.textTheme.bodyLarge,
                  ),
                ),
                if (trailing != null) settingsAlignTrailing(trailing!),
              ],
            ),
          ),
          const SizedBox(height: LekisSpacing.sm),
          Padding(
            padding: EdgeInsets.only(left: indent),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                child,
                if (hint != null) ...[
                  const SizedBox(height: LekisSpacing.sm),
                  Text(hint!, style: theme.textTheme.bodySmall),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 设置控件自己的几处文案。
abstract final class SettingsWidgetStrings {
  static const on = '开';
  static const off = '关';
}

/// 下拉框里的一个选项。
@immutable
class SettingsChoice<T> {
  const SettingsChoice(this.value, this.label, {this.enabled = true});

  final T value;
  final String label;

  /// `false`：显示但不能选（例如当前设备不支持独占）。
  final bool enabled;
}

/// 桌面的下拉框（Windows 的 ComboBox）：当前值 + 向下箭头，点开是菜单，
/// 当前项前面打勾。支持键盘（方向键 / Enter / Esc）和鼠标悬停。
class SettingsComboBox<T> extends StatelessWidget {
  const SettingsComboBox({
    super.key,
    required this.value,
    required this.choices,
    required this.onChanged,
    this.controller,
    this.minWidth = 160,
    this.maxWidth = 280,
  });

  final T value;
  final List<SettingsChoice<T>> choices;

  /// `null` 时禁用。
  final ValueChanged<T>? onChanged;

  /// 让整行点击也能打开菜单。
  final MenuController? controller;
  final double minWidth;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final current = choices.where((c) => c.value == value).firstOrNull;
    return MenuAnchor(
      controller: controller,
      menuChildren: [
        for (final choice in choices)
          MenuItemButton(
            key: ValueKey('settings-choice-${choice.label}'),
            leadingIcon: SizedBox.square(
              dimension: LekisSpacing.lg,
              child: choice.value == value
                  ? const Icon(Icons.check_rounded, size: LekisSpacing.lg)
                  : null,
            ),
            onPressed: choice.enabled && onChanged != null
                ? () => onChanged!(choice.value)
                : null,
            child: Text(choice.label),
          ),
      ],
      builder: (context, menu, _) => ConstrainedBox(
        constraints: BoxConstraints(minWidth: minWidth, maxWidth: maxWidth),
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, LekisSpacing.xxl + LekisSpacing.xs),
            padding: const EdgeInsets.symmetric(horizontal: LekisSpacing.md),
            alignment: AlignmentDirectional.centerStart,
            foregroundColor: theme.colorScheme.onSurface,
            side: BorderSide(color: colors.outline),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(LekisRadius.xs),
            ),
          ),
          onPressed: onChanged == null
              ? null
              : () => menu.isOpen ? menu.close() : menu.open(),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  current?.label ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              const SizedBox(width: LekisSpacing.sm),
              Icon(
                Icons.expand_more_rounded,
                size: LekisSpacing.lg + LekisSpacing.xxs,
                color: colors.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一行“标题 + 说明 + 右侧下拉框”的设置（桌面用它代替分段按钮 / 选择片）。
/// 整行可点，点击打开下拉菜单。
class SettingsDropdownTile<T> extends StatefulWidget {
  const SettingsDropdownTile({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.choices,
    required this.onChanged,
    this.subtitle,
    this.leading = const [],
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final T value;
  final List<SettingsChoice<T>> choices;
  final ValueChanged<T>? onChanged;

  /// 放在下拉框前面的附加控件（例如“刷新设备”按钮）。
  final List<Widget> leading;

  @override
  State<SettingsDropdownTile<T>> createState() =>
      _SettingsDropdownTileState<T>();
}

class _SettingsDropdownTileState<T> extends State<SettingsDropdownTile<T>> {
  final _menu = MenuController();

  @override
  Widget build(BuildContext context) => SettingsTile(
    icon: widget.icon,
    title: widget.title,
    subtitle: widget.subtitle == null ? null : Text(widget.subtitle!),
    onTap: widget.onChanged == null ? null : _menu.open,
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ...widget.leading,
        SettingsComboBox<T>(
          controller: _menu,
          value: widget.value,
          choices: widget.choices,
          onChanged: widget.onChanged,
        ),
      ],
    ),
  );
}
