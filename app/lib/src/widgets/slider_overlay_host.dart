// Hosts a Material [Slider]'s value-indicator overlay inside the slider.
//
// Slider always wraps itself in an OverlayPortal (for its value indicator),
// and Flutter <= 3.50 serializes the portal child's semantics node in ways
// the desktop accessibility bridge (ui::AXTree) rejects: as an orphan
// (https://github.com/flutter/flutter/issues/190357, fixed upstream by
// https://github.com/flutter/flutter/pull/193372, not in 3.50), or moved to a
// rebuilt semantics parent without an update of its own. ui::AXTree then
// fails every later update and flutter_windows.dll crashes (0xC0000005).
//
// Hosting the portal in its own overlay keeps the portal child inside the
// slider's widget subtree, so an ExcludeSemantics around this host removes
// it from the semantics tree as well; LekisSlider does exactly that and
// supplies its own slider node. Without the host the portal child would live
// in the route's overlay, outside any ExcludeSemantics around the slider.

import 'package:material_ui/material_ui.dart';

/// Puts [child]'s overlay portals in an overlay of their own; see above.
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
