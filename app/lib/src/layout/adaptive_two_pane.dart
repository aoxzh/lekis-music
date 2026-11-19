// List/detail style two-pane layout that respects hinges and folds.

import 'package:material_ui/material_ui.dart';

import 'fold.dart';
import 'window_size.dart';

/// Shows [primary] alone on narrow windows and [primary] + [secondary]
/// side by side on wide ones.
///
/// When the window has a separating hinge or half-opened fold that crosses
/// this widget, the split is placed exactly on it so no content sits on the
/// crease: a vertical hinge splits left/right, a horizontal hinge (tabletop
/// posture) splits top/bottom.
///
/// Both panes keep their state when the arrangement changes (resize, fold,
/// unfold), because each lives under a stable [GlobalKey].
class AdaptiveTwoPane extends StatefulWidget {
  const AdaptiveTwoPane({
    super.key,
    required this.primary,
    this.secondary,
    this.primaryFraction = 0.4,
  }) : assert(primaryFraction > 0 && primaryFraction < 1);

  final Widget primary;
  final Widget? secondary;

  /// Share of the width given to [primary] when there is no hinge.
  final double primaryFraction;

  @override
  State<AdaptiveTwoPane> createState() => _AdaptiveTwoPaneState();
}

class _AdaptiveTwoPaneState extends State<AdaptiveTwoPane> {
  final _primaryKey = GlobalKey(debugLabel: 'AdaptiveTwoPane.primary');
  final _secondaryKey = GlobalKey(debugLabel: 'AdaptiveTwoPane.secondary');

  /// This widget's top-left corner in window coordinates; needed to map the
  /// hinge (reported in window coordinates) into local coordinates.
  Offset _origin = Offset.zero;
  bool _measureScheduled = false;

  void _scheduleMeasure() {
    if (_measureScheduled) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      if (!mounted) return;
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      final origin = box.localToGlobal(Offset.zero);
      if (origin != _origin) setState(() => _origin = origin);
    });
  }

  @override
  Widget build(BuildContext context) {
    final fold = context.fold;
    final widthClass = context.widthClass;
    final secondary = widget.secondary;

    if (fold.isSeparating) _scheduleMeasure();

    final primary = KeyedSubtree(key: _primaryKey, child: widget.primary);
    if (secondary == null) return primary;
    final second = KeyedSubtree(key: _secondaryKey, child: secondary);

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final hinge = fold.isSeparating ? fold.hingeBounds : null;

        if (hinge != null) {
          final local = hinge.shift(-_origin);
          if (fold.hingeAxis == Axis.vertical &&
              local.left > 0 &&
              local.right < size.width) {
            return _split(
              axis: Axis.horizontal,
              first: primary,
              firstExtent: local.left,
              gap: local.width,
              second: second,
            );
          }
          if (fold.hingeAxis == Axis.horizontal &&
              local.top > 0 &&
              local.bottom < size.height) {
            return _split(
              axis: Axis.vertical,
              first: primary,
              firstExtent: local.top,
              gap: local.height,
              second: second,
            );
          }
        }

        if (widthClass >= WindowWidthClass.expanded) {
          return _split(
            axis: Axis.horizontal,
            first: primary,
            firstExtent: size.width * widget.primaryFraction,
            gap: 0,
            second: second,
            divider: true,
          );
        }

        return primary;
      },
    );
  }

  Widget _split({
    required Axis axis,
    required Widget first,
    required double firstExtent,
    required double gap,
    required Widget second,
    bool divider = false,
  }) {
    final horizontal = axis == Axis.horizontal;
    return Flex(
      direction: axis,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: horizontal ? firstExtent : null,
          height: horizontal ? null : firstExtent,
          child: _Pane(
            side: horizontal ? _Side.start : _Side.top,
            child: first,
          ),
        ),
        if (gap > 0)
          SizedBox(
            width: horizontal ? gap : null,
            height: horizontal ? null : gap,
          ),
        if (divider)
          horizontal
              ? const VerticalDivider(width: 1)
              : const Divider(height: 1),
        Expanded(
          child: _Pane(
            side: horizontal ? _Side.end : _Side.bottom,
            child: second,
          ),
        ),
      ],
    );
  }
}

enum _Side { start, end, top, bottom }

/// Gives a pane a [MediaQuery] without the hinge (so nested adaptive widgets
/// don't split again) and without padding on the side facing the other pane.
class _Pane extends StatelessWidget {
  const _Pane({required this.side, required this.child});

  final _Side side;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    EdgeInsets trim(EdgeInsets p) => switch (side) {
      _Side.start => p.copyWith(right: 0),
      _Side.end => p.copyWith(left: 0),
      _Side.top => p.copyWith(bottom: 0),
      _Side.bottom => p.copyWith(top: 0),
    };
    return MediaQuery(
      data: mq.copyWith(
        displayFeatures: const [],
        padding: trim(mq.padding),
        viewPadding: trim(mq.viewPadding),
      ),
      child: child,
    );
  }
}
