// The app's one editor surface: a centred dialog on tablets / desktop, a
// bottom sheet on phones, with the same header, body padding, field styles
// and footer buttons either way. Editors (lyrics, tags, ...) build a
// [LekisPanel] and open it with [showLekisPanel].
//
// Desktop profiles (see [UiProfile.prefersSheets]) never get bottom sheets:
// [showLekisPanel] is always a dialog there, even in a narrow window, and
// [showLekisSheet] opens the same content in a centred dialog. Nothing on
// desktop blurs its backdrop.
//
// The panel keeps the theme of the place it was opened from, so an editor
// opened over the Now Playing artwork uses the on-media (dark glass) variant
// instead of a white Material dialog, while the same editor opened from the
// library uses the regular page theme.

import 'package:material_ui/material_ui.dart';

import '../l10n/app_l10n.dart';
import '../layout/window_size.dart';
import '../platform/ui_profile.dart';
import '../theme/tokens.dart';
import 'glass.dart';

/// Timing shared by menus, sheets and their follow-up dialogs.
AnimationStyle lekisPanelMotion(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.reduceMotionOf(context)
    ? AnimationStyle.noAnimation
    : const AnimationStyle(
        duration: LekisMotion.normal,
        reverseDuration: LekisMotion.fast,
      );

// A selection may open another surface or dispose an editor's controller.
Future<T?> _presentSurface<T>(
  WidgetBuilder builder,
  Future<T?> Function(WidgetBuilder) present,
) async {
  Future<Object?>? dismissed;
  final result = await present((context) {
    dismissed = ModalRoute.of(context)?.completed;
    return builder(context);
  });
  await dismissed;
  return result;
}

/// Widest an editor dialog gets.
const double lekisPanelMaxWidth = 620;

/// Opens [builder] as a dialog (medium windows and up) or a bottom sheet
/// (compact windows). [dismissible] controls tapping outside / dragging the
/// sheet down; editors with unsaved input pass `false`.
Future<T?> showLekisPanel<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool dismissible = true,
}) => _presentSurface<T>(builder, (builder) {
  // The calling subtree's theme: on-media when this panel was opened from
  // Now Playing. Nothing here may force the app theme back on.
  final theme = Theme.of(context);
  Widget themed(BuildContext context, bool sheet) => Theme(
    data: theme,
    child: _LekisPanelMode(
      sheet: sheet,
      child: Builder(builder: builder),
    ),
  );
  final glass = theme.extension<LekisSurfaceStyle>()?.onMedia ?? false;

  if (context.widthClass == WindowWidthClass.compact &&
      UiProfile.current.prefersSheets) {
    return showModalBottomSheet<T>(
      context: context,
      useRootNavigator: true,
      sheetAnimationStyle: lekisPanelMotion(context),
      isScrollControlled: true,
      useSafeArea: true,
      // On media the handle is drawn inside the glass (see [LekisPanel]): the
      // framework's handle sits above the sheet's own background, which is
      // transparent there, so it floated over an unblurred band of artwork.
      showDragHandle: !glass,
      isDismissible: dismissible,
      enableDrag: dismissible,
      // The panel paints its own glass on media; a bar of opaque colour
      // behind it would read as a white strip.
      backgroundColor: glass
          ? Colors.transparent
          : theme.bottomSheetTheme.backgroundColor,
      barrierColor: theme.bottomSheetTheme.modalBarrierColor,
      builder: (context) => themed(context, true),
    );
  }
  return showDialog<T>(
    context: context,
    animationStyle: lekisPanelMotion(context),
    useRootNavigator: true,
    barrierDismissible: dismissible,
    barrierColor: theme.dialogTheme.barrierColor,
    builder: (context) => themed(context, false),
  );
});

/// Opens [builder] as a modal bottom sheet that always stays a sheet on
/// mobile, for the surfaces that belong at the bottom of the window on every
/// phone / tablet size (playback queue, rating, add to playlist). Same rules
/// as [showLekisPanel]: the caller's theme is kept (so over artwork it is
/// dark glass) and on media the sheet paints its own glass instead of an
/// opaque bar.
///
/// Desktop profiles show the same content in a centred dialog instead.
Future<T?> showLekisSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  double? heightFactor = 0.62,
  bool isDismissible = true,
  bool showDragHandle = true,
}) => _presentSurface<T>(builder, (builder) {
  if (!UiProfile.current.prefersSheets) {
    return _showSheetAsDialog<T>(
      context,
      builder: builder,
      heightFactor: heightFactor,
      isDismissible: isDismissible,
    );
  }
  final theme = Theme.of(context);
  final glass = theme.extension<LekisSurfaceStyle>()?.onMedia ?? false;
  final grabber = showDragHandle && glass;
  Widget framed(BuildContext context) {
    Widget content = SafeArea(top: false, child: Builder(builder: builder));
    // The handle belongs to the sheet, so it is inside the sized content:
    // `heightFactor` still describes the whole sheet, and the glass covers
    // the handle instead of leaving a transparent strip above it.
    if (grabber) {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetGrabber(),
          Flexible(child: content),
        ],
      );
    }
    if (heightFactor != null) {
      content = FractionallySizedBox(
        heightFactor: heightFactor,
        child: content,
      );
    }
    if (!glass) return content;
    return _PanelGlass(
      radius: const BorderRadius.vertical(
        top: Radius.circular(LekisRadius.panel),
      ),
      child: content,
    );
  }

  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: true,
    sheetAnimationStyle: lekisPanelMotion(context),
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: showDragHandle && !glass,
    isDismissible: isDismissible,
    enableDrag: isDismissible,
    backgroundColor: glass
        ? Colors.transparent
        : theme.bottomSheetTheme.backgroundColor,
    barrierColor: theme.bottomSheetTheme.modalBarrierColor,
    builder: (context) => Theme(data: theme, child: framed(context)),
  );
});

/// Width of a sheet's content when it opens as a desktop dialog.
const double lekisSheetDialogWidth = 480;

/// Desktop stand-in for [showLekisSheet]: the sheet's content in a centred,
/// opaque dialog. [heightFactor] is applied to the window height (`null`
/// sizes to the content). Escape and a click outside close it.
Future<T?> _showSheetAsDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  required double? heightFactor,
  required bool isDismissible,
}) {
  final theme = Theme.of(context);
  return showDialog<T>(
    context: context,
    animationStyle: lekisPanelMotion(context),
    useRootNavigator: true,
    barrierDismissible: isDismissible,
    barrierColor: theme.dialogTheme.barrierColor,
    builder: (context) {
      final height = MediaQuery.sizeOf(context).height;
      Widget content = Padding(
        // Sheet content assumes a drag handle above it; give the dialog the
        // same breathing room at the top instead.
        padding: const EdgeInsets.only(top: LekisSpacing.xl),
        child: Builder(builder: builder),
      );
      if (heightFactor != null) {
        content = SizedBox(
          height: (height - LekisSpacing.xl * 2) * heightFactor.clamp(0, 1),
          child: content,
        );
      }
      return Theme(
        data: theme,
        child: Dialog(
          key: const ValueKey('lekis-sheet.dialog'),
          insetPadding: const EdgeInsets.all(LekisSpacing.xl),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: lekisSheetDialogWidth,
              maxHeight: height * 0.88,
            ),
            child: content,
          ),
        ),
      );
    },
  );
}

/// Drag handle of a glass sheet: same size and colour as the framework's,
/// painted inside the glass instead of in a transparent strip above it.
class SheetGrabber extends StatelessWidget {
  const SheetGrabber({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size =
        theme.bottomSheetTheme.dragHandleSize ??
        const Size(LekisSpacing.xxl + LekisSpacing.xs, LekisSpacing.xs);
    final color =
        theme.bottomSheetTheme.dragHandleColor ??
        theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4);
    return SizedBox(
      key: const ValueKey('lekis-sheet.grabber'),
      height: LekisSpacing.lg,
      child: Center(
        child: Container(
          width: size.width,
          height: size.height,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(LekisRadius.pill),
          ),
        ),
      ),
    );
  }
}

/// Background, rim and backdrop blur of a panel opened over artwork.
class _PanelGlass extends StatelessWidget {
  const _PanelGlass({required this.child, required this.radius});

  final Widget child;
  final BorderRadius radius;

  @override
  Widget build(BuildContext context) {
    final surface = context.lekisSurface;
    // A Material, not a coloured DecoratedBox: ListTile paints its ink on
    // the nearest Material, and a plain box in between hides it (the
    // framework asserts on that in debug builds).
    final panel = Material(
      color: surface.panel,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: surface.panelBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
    // Desktop: an opaque panel (the on-media theme is opaque there too).
    if (!UiProfile.current.supportsGlass || surface.blurSigma <= 0) {
      return panel;
    }
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: lekisGlassFilter(surface.blurSigma),
        child: panel,
      ),
    );
  }
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
              tooltip: context.l10n.pick('关闭', 'Close'),
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

    final onMedia = context.onMedia;
    // On artwork the panel paints its own dark glass; on regular pages the
    // theme's dialog / sheet surface does the job.
    Widget frame(Widget child, {required bool sheet}) => onMedia
        ? _PanelGlass(
            radius: sheet
                ? const BorderRadius.vertical(
                    top: Radius.circular(LekisRadius.panel),
                  )
                : BorderRadius.circular(
                    UiProfile.current.isDesktop
                        ? LekisRadius.sm
                        : LekisRadius.panel,
                  ),
            child: child,
          )
        : child;

    if (sheet) {
      return Padding(
        // Keep the footer above the keyboard.
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: media.size.height * 0.92),
          child: SafeArea(
            top: false,
            child: frame(
              onMedia
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SheetGrabber(),
                        Flexible(child: column),
                      ],
                    )
                  : column,
              sheet: true,
            ),
          ),
        ),
      );
    }
    return Dialog(
      insetPadding: const EdgeInsets.all(LekisSpacing.xl),
      clipBehavior: Clip.antiAlias,
      // The glass frame is the whole surface on artwork.
      backgroundColor: onMedia ? Colors.transparent : null,
      elevation: onMedia ? 0 : null,
      shadowColor: onMedia ? Colors.transparent : null,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: lekisPanelMaxWidth,
          maxHeight: media.size.height * 0.88,
        ),
        child: frame(column, sheet: false),
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
