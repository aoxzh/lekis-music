// Workaround for a framework semantics bug around Material Slider.
//
// Slider always wraps itself in an OverlayPortal (for its value indicator).
// When the slider's semantics change outside the initial snapshot (it is
// enabled when the saved session is restored, sits in a pushed route, …),
// Flutter <= 3.50 serializes the portal's semantics node without any parent
// listing it as a child. The desktop accessibility bridge (ui::AXTree) then
// rejects every update ("N will not be in the tree and is not the new root"),
// the accessibility tree freezes, and on Windows flutter_windows.dll later
// dereferences a null AXNode (0xC0000005) once anything queries UI Automation.
//
// Framework bug: https://github.com/flutter/flutter/issues/190357
//   fixed by https://github.com/flutter/flutter/pull/193372 (not in 3.50).
// Engine crash on malformed updates: https://github.com/flutter/flutter/issues/175041
//
// Hosting the slider in its own overlay keeps the portal child inside the
// slider's own semantics subtree, so no orphan is ever sent. Drop this
// wrapper once the stable SDK contains #193372
// (test/shell/semantics_tree_test.dart guards the invariant).

import 'package:material_ui/material_ui.dart';

/// Wrap every Material [Slider] in this.
class SliderOverlayHost extends StatelessWidget {
  const SliderOverlayHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Overlay.wrap(
    alwaysSizeToContent: true,
    clipBehavior: Clip.none,
    child: child,
  );
}
