import 'package:lekis/src/layout/window_size.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

/// Horizontal page padding for the current window size.
double pageGutterOf(BuildContext context) =>
    context.widthClass >= WindowWidthClass.expanded
    ? LekisSpacing.pageGutterDesktop
    : LekisSpacing.pageGutter;

/// Space after the last item of a scrolling page: room to breathe plus any
/// bottom inset (gesture area) the page is still responsible for.
double scrollEndPadding(BuildContext context) =>
    LekisSpacing.xxl + MediaQuery.paddingOf(context).bottom;

/// Whether to show one more level of hierarchy side by side.
bool isWideLayout(BuildContext context) =>
    context.widthClass >= WindowWidthClass.expanded;
