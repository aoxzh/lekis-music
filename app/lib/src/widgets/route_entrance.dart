// Detail-page content that settles in behind a cover flight: once the
// route is a third of the way in, each block fades up a few points, one
// after another, finishing together with the route transition.

import 'package:lekis/src/shell/nav_icon.dart' show lekisReduceMotion;
import 'package:material_ui/material_ui.dart';

/// Staggered entrance driven by the enclosing route's own animation, so it
/// costs no extra time and reverses with nothing to clean up.
///
/// Only the first push animates: once the route has finished entering (or
/// if it already had when this mounted, e.g. an embedded two-pane detail or
/// content that arrived late), the child is shown as is. Pops and
/// predictive-back drags therefore never replay it.
///
/// The route must not snapshot its page during the transition
/// (`allowSnapshotting: false`), or the entrance would be frozen.
class RouteEntrance extends StatefulWidget {
  const RouteEntrance({super.key, this.order = 0, required this.child})
    : sliver = false;

  /// Fade-only variant for a sliver (slivers cannot be translated).
  const RouteEntrance.sliver({
    super.key,
    this.order = 0,
    required Widget sliver,
  }) : child = sliver,
       sliver = true;

  /// Stagger slot: 0 starts first, each next one ≈30 ms later.
  final int order;
  final bool sliver;
  final Widget child;

  /// Lift distance in logical pixels.
  static const double rise = 10;

  @override
  State<RouteEntrance> createState() => _RouteEntranceState();
}

class _RouteEntranceState extends State<RouteEntrance> {
  Animation<double>? _route;
  CurvedAnimation? _curved;
  bool _done = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_done) return;
    final route = ModalRoute.of(context);
    final animation = route?.animation;
    if (identical(animation, _route)) return;
    _detach();
    // A pushed page is first built offstage (for hero measurement) with its
    // animation pinned at "completed"; that still counts as entering. Any
    // other completed route (embedded pane, late content) is in place.
    final entering =
        animation != null &&
        (route!.offstage || animation.status != AnimationStatus.completed);
    if (!entering || lekisReduceMotion(context)) {
      _done = true;
      return;
    }
    _route = animation..addStatusListener(_onStatus);
    final start = (0.3 + widget.order * 0.08).clamp(0.0, 0.7);
    _curved = CurvedAnimation(
      parent: animation,
      curve: Interval(start, 1, curve: Curves.easeOutCubic),
    );
  }

  void _onStatus(AnimationStatus status) {
    // Completed: settled. Reverse / dismissed: popped mid-push; the page
    // fades out as a whole, so the content simply stays put.
    if (status == AnimationStatus.forward) return;
    if (!mounted) return;
    setState(() {
      _done = true;
      _detach();
    });
  }

  void _detach() {
    _route?.removeStatusListener(_onStatus);
    _route = null;
    _curved?.dispose();
    _curved = null;
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = _curved;
    if (_done || curved == null) return widget.child;
    if (widget.sliver) {
      return SliverFadeTransition(opacity: curved, sliver: widget.child);
    }
    return FadeTransition(
      opacity: curved,
      child: AnimatedBuilder(
        animation: curved,
        child: widget.child,
        builder: (context, child) => Transform.translate(
          offset: Offset(0, RouteEntrance.rise * (1 - curved.value)),
          child: child,
        ),
      ),
    );
  }
}
