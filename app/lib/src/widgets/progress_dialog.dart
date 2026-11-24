// Shared progress dialog that the system back button cannot dismiss.

import 'package:material_ui/material_ui.dart';

/// A modal progress dialog that cannot be dismissed with the system back
/// button.
///
/// The flow that opens it pops it itself when the work finishes. If back could
/// close it first, that final `pop()` would pop the page underneath instead of
/// an already-closed dialog.
Widget nonDismissibleProgressDialog({Widget? title, Widget? content}) =>
    PopScope(canPop: false, child: AlertDialog(title: title, content: content));
