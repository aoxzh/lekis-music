import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'adaptive_panel.dart';

/// Returns an idempotent close callback for this operation's panel. Another
/// route can appear above it, or the work can finish before the first frame.
Future<void> Function() showProgressPanel(
  BuildContext context, {
  required String title,
  required ValueNotifier<int> progress,
  required Widget Function(int done) builder,
}) {
  final opened = Completer<ModalRoute<void>>();
  final dismissed = showLekisPanel<void>(
    context,
    dismissible: false,
    builder: (panel) {
      if (!opened.isCompleted) opened.complete(ModalRoute.of<void>(panel)!);
      return PopScope(
        canPop: false,
        child: LekisPanel(
          title: title,
          body: ValueListenableBuilder<int>(
            valueListenable: progress,
            builder: (_, done, _) => builder(done),
          ),
        ),
      );
    },
  );

  Future<void> close() async {
    final route = await Future.any([
      opened.future,
      dismissed.then((_) => null),
    ]);
    if (route?.isCurrent ?? false) {
      route!.navigator!.pop();
    } else if (route?.isActive ?? false) {
      route!.navigator!.removeRoute(route);
    }
    await dismissed;
    progress.dispose();
  }

  Future<void>? closing;
  return () => closing ??= close();
}
