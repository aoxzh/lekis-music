// The Lekis rabbit mascot. Keep one implementation so launcher, sidebar, home
// and empty states always show the same artwork.
import 'package:material_ui/material_ui.dart';

import '../theme/theme.dart';

class LekisBrandMark extends StatelessWidget {
  const LekisBrandMark({
    super.key,
    this.size = 40,
    this.ring = true,
    this.glow = false,
  });

  final double size;
  final bool ring;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final mark = ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.24),
      child: Image.asset(
        'app_icon.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        semanticLabel: 'Lekis',
        errorBuilder: (context, error, stack) => ColoredBox(
          color: colors.accentSoft,
          child: Icon(
            Icons.nightlight_round,
            size: size * 0.5,
            color: colors.moon,
          ),
        ),
      ),
    );

    final framed = ring
        ? Container(
            width: size,
            height: size,
            padding: EdgeInsets.all(size * 0.035),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(size * 0.28),
              border: Border.all(
                color: colors.moon.withValues(alpha: 0.55),
                width: 1,
              ),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  colors.moon.withValues(alpha: 0.18),
                  colors.accentSoft.withValues(alpha: 0.10),
                ],
              ),
            ),
            child: mark,
          )
        : mark;

    if (!glow) return framed;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.28),
        boxShadow: [
          BoxShadow(
            color: colors.moon.withValues(alpha: 0.24),
            blurRadius: size * 0.45,
            spreadRadius: size * 0.05,
          ),
        ],
      ),
      child: framed,
    );
  }
}
