// 设置区的共用骨架：页头、分组、行。
//
// 设置是“后台”页面：更安静、更密，但页头位置、边距、字号和资料库 / 音源一致。
// 所有设置页（含子页面）都用这里的组件，不再用 Material 默认的 AppBar / ListTile。

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

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
  final gutter = pageGutterOf(context) - settingsRowInset;
  final right = math.max(
    gutter,
    maxWidth -
        pageGutterOf(context) -
        featureMaxContentWidth -
        settingsRowInset,
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
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
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
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
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
  Widget build(BuildContext context) => SliverMainAxisGroup(
    slivers: [
      SliverToBoxAdapter(child: SettingsSectionHeader(title)),
      SliverList.separated(
        itemCount: itemCount,
        itemBuilder: (context, i) => Material(
          type: MaterialType.transparency,
          child: itemBuilder(context, i),
        ),
        separatorBuilder: (_, _) => Divider(height: 1, indent: dividerIndent),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: LekisSpacing.xl)),
    ],
  );
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
    size: _iconSlot,
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
  });

  final IconData icon;
  final String title;

  /// 说明文字；默认用 bodySmall（元信息色），可以覆盖颜色。
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// 是否在末尾显示进入下一级的箭头。
  final bool chevron;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
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
        constraints: const BoxConstraints(minHeight: LekisSizes.touchTargetMin),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: LekisSpacing.lg,
            vertical: LekisSpacing.sm,
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
  Widget build(BuildContext context) => MergeSemantics(
    child: SettingsTile(
      icon: icon,
      title: title,
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: Switch(value: value, onChanged: onChanged),
      onTap: onChanged == null ? null : () => onChanged!(!value),
    ),
  );
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
