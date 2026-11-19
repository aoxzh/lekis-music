// Shared width / posture checks for the Now Playing layouts.

import 'package:lekis/src/layout/fold.dart';
import 'package:lekis/src/layout/window_size.dart';
import 'package:material_ui/material_ui.dart';

/// Width from which lyrics / queue get a third column next to cover and
/// controls (common 1024-wide tablets in landscape get the reference
/// cover | controls | queue layout).
const double nowPlayingThreePaneMinWidth = 1024;

/// Whether the window is wide and flat enough for the third Now Playing
/// pane. Tabletop posture and vertical hinges keep their dedicated layouts
/// instead (nothing may sit on the crease).
bool usesNowPlayingSidePanels(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  final fold = context.fold;
  return size.width >= nowPlayingThreePaneMinWidth &&
      size.width >= size.height * 0.95 &&
      context.heightClass >= WindowHeightClass.medium &&
      !fold.isTabletop &&
      !(fold.hasHinge && fold.hingeAxis == Axis.vertical);
}
