// Route motion for every MaterialPageRoute (Now Playing has its own route).

import 'package:lekis/src/shell/nav_icon.dart' show lekisReduceMotion;
import 'package:material_ui/material_ui.dart';

/// Android 16-style "fade forwards" push, a little quicker than Flutter's
/// 450 ms, with Android's predictive back on top and a plain short fade
/// under reduced motion.
///
/// * Android: [PredictiveBackPageTransitionsBuilder] – the back gesture
///   peeks the previous page (Android 14+); buttons and programmatic pops
///   fall back to fade forwards.
/// * Windows / Linux: [FadeForwardsPageTransitionsBuilder].
/// * Reduced motion: a 150 ms cross-fade, no slide; the page underneath
///   stays still.
class LekisPageTransitionsBuilder extends PageTransitionsBuilder {
  const LekisPageTransitionsBuilder();

  /// Push. Fade-forwards curves are interval based, so they scale cleanly.
  static const Duration forward = Duration(milliseconds: 380);

  /// Pop: slightly quicker; leaving should never feel like waiting.
  static const Duration reverse = Duration(milliseconds: 320);

  /// Reduced-motion fade length within [forward] / [reverse].
  static const Duration _reducedFade = Duration(milliseconds: 150);

  static const _fadeForwards = FadeForwardsPageTransitionsBuilder();
  static const _predictiveBack = PredictiveBackPageTransitionsBuilder();

  static final Curve _reducedIn = Interval(
    0,
    _reducedFade.inMicroseconds / forward.inMicroseconds,
    curve: Curves.easeOut,
  );
  static final Curve _reducedOut = Interval(
    1 - _reducedFade.inMicroseconds / reverse.inMicroseconds,
    1,
    curve: Curves.easeIn,
  );

  @override
  Duration get transitionDuration => forward;

  @override
  Duration get reverseTransitionDuration => reverse;

  @override
  DelegatedTransitionBuilder? get delegatedTransition => _delegated;

  static Widget? _delegated(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    bool allowSnapshotting,
    Widget? child,
  ) {
    if (lekisReduceMotion(context)) return child;
    return _fadeForwards.delegatedTransition!(
      context,
      animation,
      secondaryAnimation,
      allowSnapshotting,
      child,
    );
  }

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (lekisReduceMotion(context)) {
      return FadeTransition(
        opacity: CurvedAnimation(
          parent: animation,
          curve: _reducedIn,
          reverseCurve: _reducedOut,
        ),
        child: child,
      );
    }
    final base = Theme.of(context).platform == TargetPlatform.android
        ? _predictiveBack
        : _fadeForwards;
    return base.buildTransitions(
      route,
      context,
      animation,
      secondaryAnimation,
      child,
    );
  }
}
