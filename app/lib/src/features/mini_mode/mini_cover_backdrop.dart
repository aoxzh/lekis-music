import 'package:material_ui/material_ui.dart';

import '../../shell/nav_icon.dart' show lekisReduceMotion;
import '../../theme/theme.dart';
import '../player/widgets/current_track.dart';

class MiniCoverBackdrop extends StatelessWidget {
  const MiniCoverBackdrop({
    super.key,
    required this.panorama,
    required this.thumbnail,
    required this.width,
    required this.inset,
  });

  final bool panorama;
  final double thumbnail;
  final double width;
  final double inset;

  @override
  Widget build(BuildContext context) {
    final surface = context.lekisColors.surfaceElevated;
    return IgnorePointer(
      child: ExcludeSemantics(
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            AnimatedPositioned(
              duration: lekisReduceMotion(context)
                  ? Duration.zero
                  : LekisMotion.normal,
              curve: Curves.easeOutCubic,
              left: panorama ? 0 : inset,
              width: panorama ? width : thumbnail,
              height: panorama ? width : thumbnail,
              child: CurrentArtwork(radius: panorama ? 0 : LekisRadius.sm),
            ),
            if (panorama)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: width,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        surface.withValues(alpha: 0),
                        surface.withValues(alpha: 0.12),
                        surface.withValues(alpha: 0.94),
                        surface,
                      ],
                      stops: const [0, 0.4, 0.77, 1],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
