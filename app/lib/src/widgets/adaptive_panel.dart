// The app's one editor surface: a centred dialog on tablets / desktop, a
// bottom sheet on phones, with the same header, body padding, field styles
// and footer buttons either way. Editors (lyrics, tags, ...) build a
// [LekisPanel] and open it with [showLekisPanel].

import 'package:material_ui/material_ui.dart';

import '../layout/window_size.dart';
import '../theme/tokens.dart';

/// Widest an editor dialog gets.
const double lekisPanelMaxWidth = 620;

/// Opens [builder] as a dialog (medium windows and up) or a bottom sheet
/// (compact windows). [dismissible] controls tapping outside / dragging the
/// sheet down; editors with unsaved input pass `false`.
///
/// Always uses the app's base theme, even when opened from a re-themed
/// subtree such as Now Playing, so editors look the same everywhere.
Future<T?> showLekisPanel<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool dismissible = true,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  final base = Theme.of(navigator.context);
  Widget themed(BuildContext context, bool sheet) => Theme(
    data: base,
    child: _LekisPanelMode(sheet: sheet, child: Builder(builder: builder)),
  );

  if (context.widthClass == WindowWidthClass.compact) {
    return showModalBottomSheet<T>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      isDismissible: dismissible,
      enableDrag: dismissible,
      backgroundColor: base.bottomSheetTheme.backgroundColor,
      builder: (context) => themed(context, true),
    );
  }
  return showDialog<T>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: dismissible,
    builder: (context) => themed(context, false),
  );
}

class _LekisPanelMode extends InheritedWidget {
  const _LekisPanelMode({required this.sheet, required super.child});

  final bool sheet;

  @override
  bool updateShouldNotify(_LekisPanelMode old) => old.sheet != sheet;
}

/// Header (title, subtitle, close), scrolling body, footer (error + actions).
///
/// In a sheet the theme's drag handle sits above the header; in a dialog
/// the panel brings its own [Dialog] frame.
class LekisPanel extends StatelessWidget {
  const LekisPanel({
    super.key,
    required this.title,
    required this.body,
    this.subtitle,
    this.actions = const [],
    this.error,
    this.onClose,
    this.scrollBody = true,
  });

  final String title;
  final String? subtitle;
  final Widget body;

  /// Footer buttons, primary last (TextButton, OutlinedButton, FilledButton).
  final List<Widget> actions;

  /// Shown in the footer above the buttons.
  final String? error;

  /// Close button in the header; `null` hides it.
  final VoidCallback? onClose;

  /// `false` when [body] scrolls (or sizes) itself.
  final bool scrollBody;

  /// Vertical gap between form fields.
  static const double fieldGap = LekisSpacing.md;

  /// Horizontal padding of header, body and footer.
  static const double gutter = LekisSpacing.xl;

  static bool _isSheet(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_LekisPanelMode>()?.sheet ??
      false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final sheet = _isSheet(context);
    final media = MediaQuery.of(context);

    final header = Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        sheet ? 0 : LekisSpacing.xl,
        onClose == null ? gutter : LekisSpacing.md,
        LekisSpacing.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  header: true,
                  child: Text(title, style: theme.textTheme.titleLarge),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: LekisSpacing.xxs),
                  Text(
                    subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (onClose != null)
            IconButton(
              tooltip: '关闭',
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded),
            ),
        ],
      ),
    );

    final bodyPadding = const EdgeInsets.fromLTRB(
      gutter,
      LekisSpacing.lg,
      gutter,
      LekisSpacing.lg,
    );
    final content = scrollBody
        ? SingleChildScrollView(padding: bodyPadding, child: body)
        : Padding(padding: bodyPadding, child: body);

    final footer = (actions.isEmpty && error == null)
        ? null
        : Padding(
            padding: const EdgeInsets.fromLTRB(
              gutter,
              LekisSpacing.md,
              gutter,
              LekisSpacing.lg,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: LekisSpacing.sm),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        error!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.danger,
                        ),
                      ),
                    ),
                  ),
                if (actions.isNotEmpty)
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: LekisSpacing.sm,
                    runSpacing: LekisSpacing.sm,
                    children: actions,
                  ),
              ],
            ),
          );

    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Divider(height: 1, color: colors.outline),
        Flexible(child: content),
        if (footer != null) ...[
          Divider(height: 1, color: colors.outline),
          footer,
        ],
      ],
    );

    if (sheet) {
      return Padding(
        // Keep the footer above the keyboard.
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: media.size.height * 0.92),
          child: SafeArea(top: false, child: column),
        ),
      );
    }
    return Dialog(
      insetPadding: const EdgeInsets.all(LekisSpacing.xl),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: lekisPanelMaxWidth,
          maxHeight: media.size.height * 0.88,
        ),
        child: column,
      ),
    );
  }
}

/// Small busy indicator for a panel's primary button.
class LekisPanelProgress extends StatelessWidget {
  const LekisPanelProgress({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: LekisSpacing.lg,
    child: CircularProgressIndicator(strokeWidth: LekisSpacing.xxs),
  );
}
