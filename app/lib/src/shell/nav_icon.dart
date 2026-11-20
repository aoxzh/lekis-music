// Shared navigation motion: one icon bounce language for the floating tab
// bar, the icon rail and the desktop sidebar.

import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

import 'destinations.dart';

export '../platform/ui_profile.dart' show lekisSelectionHaptic;

/// Foreground for an active destination.
///
/// The raw accent works on the pale light-theme surfaces. In dark themes the
/// accent sits on a dark indigo pill, so it is lifted toward the on-surface
/// ink to keep small labels readable (contrast protection).
Color lekisNavForeground(BuildContext context) {
  final colors = context.lekisColors;
  final scheme = Theme.of(context).colorScheme;
  if (scheme.brightness == Brightness.dark) {
    return Color.alphaBlend(
      colors.accent.withValues(alpha: 0.62),
      scheme.onSurface,
    );
  }
  return colors.accent;
}

/// Whether this frame should use the calm 150 ms fallback instead of
/// springs. Android maps its reduced-motion accessibility setting (and some
/// low-power configurations) onto these flags.
bool lekisReduceMotion(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context) ||
    MediaQuery.reduceMotionOf(context);

/// Whether an active destination plays the full squash/lift bounce or the
/// calmer flat-bar scale/fade.
enum NavIconMotion { bounce, fadeScale }

/// Destination icon with a short squash / lift / settle bounce when it
/// becomes active. [NavIconMotion.fadeScale] swaps that for a plain scale /
/// colour fade (the flat tab bar). Reduced motion keeps the colour fade but
/// drops both scale effects.
class LekisNavIcon extends StatefulWidget {
  const LekisNavIcon({
    super.key,
    required this.destination,
    required this.selected,
    this.size = LekisTabBarTokens.iconSize,
    this.reducedMotion = false,
    this.bounceTrigger = 0,
    this.motion = NavIconMotion.bounce,
  });

  final LekisDestination destination;
  final bool selected;
  final double size;
  final bool reducedMotion;
  final NavIconMotion motion;

  /// Bump this to replay the bounce while the tab is already selected.
  final int bounceTrigger;

  @override
  State<LekisNavIcon> createState() => _LekisNavIconState();
}

class _LekisNavIconState extends State<LekisNavIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bounce = AnimationController(
    vsync: this,
    duration: LekisMotion.navBounce,
    value: 1,
  );

  static final TweenSequence<double> _scale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween<double>(
        begin: 1,
        end: 0.86,
      ).chain(CurveTween(curve: Curves.easeOut)),
      weight: 18,
    ),
    TweenSequenceItem(
      tween: Tween<double>(
        begin: 0.86,
        end: 1.16,
      ).chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 32,
    ),
    TweenSequenceItem(
      tween: Tween<double>(
        begin: 1.16,
        end: 0.97,
      ).chain(CurveTween(curve: Curves.easeInOut)),
      weight: 26,
    ),
    TweenSequenceItem(
      tween: Tween<double>(
        begin: 0.97,
        end: 1.0,
      ).chain(CurveTween(curve: Curves.easeOut)),
      weight: 24,
    ),
  ]);

  static final TweenSequence<double> _lift = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween<double>(
        begin: 0,
        end: 1.8,
      ).chain(CurveTween(curve: Curves.easeOut)),
      weight: 18,
    ),
    TweenSequenceItem(
      tween: Tween<double>(
        begin: 1.8,
        end: -2.6,
      ).chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 32,
    ),
    TweenSequenceItem(
      tween: Tween<double>(
        begin: -2.6,
        end: 0.5,
      ).chain(CurveTween(curve: Curves.easeInOut)),
      weight: 28,
    ),
    TweenSequenceItem(
      tween: Tween<double>(
        begin: 0.5,
        end: 0,
      ).chain(CurveTween(curve: Curves.easeOut)),
      weight: 22,
    ),
  ]);

  static final TweenSequence<double> _tilt = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween<double>(
        begin: 0,
        end: -0.045,
      ).chain(CurveTween(curve: Curves.easeOut)),
      weight: 35,
    ),
    TweenSequenceItem(
      tween: Tween<double>(
        begin: -0.045,
        end: 0.025,
      ).chain(CurveTween(curve: Curves.easeInOut)),
      weight: 35,
    ),
    TweenSequenceItem(
      tween: Tween<double>(
        begin: 0.025,
        end: 0,
      ).chain(CurveTween(curve: Curves.easeOut)),
      weight: 30,
    ),
  ]);

  @override
  void didUpdateWidget(LekisNavIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bounceMode = widget.motion == NavIconMotion.bounce;
    final becameSelected = widget.selected && !oldWidget.selected;
    final retapped =
        widget.selected && widget.bounceTrigger != oldWidget.bounceTrigger;
    if ((becameSelected || retapped) && bounceMode && !widget.reducedMotion) {
      _bounce.forward(from: 0);
    }
    if (!widget.selected || widget.reducedMotion || !bounceMode) {
      if (_bounce.isAnimating) _bounce.stop();
      _bounce.value = 1;
    }
  }

  @override
  void dispose() {
    _bounce.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final target = widget.selected
        ? lekisNavForeground(context)
        : colors.onSurfaceVariant;
    final icon = TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: target),
      duration: LekisMotion.fast,
      curve: Curves.easeOut,
      builder: (context, color, _) => Icon(
        widget.selected
            ? widget.destination.selectedIcon
            : widget.destination.icon,
        size: widget.size,
        color:
            color ??
            (widget.selected
                ? lekisNavForeground(context)
                : colors.onSurfaceVariant),
      ),
    );

    if (widget.motion == NavIconMotion.bounce) {
      return AnimatedBuilder(
        animation: _bounce,
        builder: (context, child) {
          final t = _bounce.value;
          return Transform.translate(
            offset: Offset(0, _lift.transform(t)),
            child: Transform.rotate(
              angle: _tilt.transform(t),
              child: Transform.scale(scale: _scale.transform(t), child: child),
            ),
          );
        },
        child: icon,
      );
    }

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(
        end: widget.reducedMotion || widget.selected ? 1.0 : 0.94,
      ),
      duration: widget.reducedMotion ? LekisMotion.fast : LekisMotion.navFlat,
      curve: Curves.easeOutCubic,
      child: icon,
      builder: (context, scale, child) =>
          Transform.scale(scale: scale, child: child),
    );
  }
}
