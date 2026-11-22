// Row motion for lists that are rebuilt wholesale from providers (queue,
// playlist entries): rows slide from where they were to where they are now,
// new rows fade in, removed rows collapse.
//
// Rather than an AnimatedList, which needs every insert / remove replayed
// as an imperative call, the owner just reports "the list changed from A to
// B" and each row looks up where its key used to be (FLIP: first, last,
// invert, play). Lookups are lazy and windowed, so a 100k-row paged queue
// costs nothing beyond the rows on screen.

import 'package:lekis/src/shell/nav_icon.dart' show lekisReduceMotion;
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

/// Identity of the row at an index, or `null` when it is not known (an
/// unloaded page, out of range). Keys only need `==`.
typedef ListKeyAt = Object? Function(int index);

/// Keys for a fully loaded list, with repeats told apart by occurrence
/// (`id`, `id#1`, `id#2`, ...) so duplicates keep their own identity.
List<Object> occurrenceKeys<T>(Iterable<T> items, Object Function(T) keyOf) {
  final seen = <Object, int>{};
  return [
    for (final item in items)
      () {
        final key = keyOf(item);
        final n = seen.update(key, (v) => v + 1, ifAbsent: () => 0);
        return n == 0 ? key : '$key#$n';
      }(),
  ];
}

/// Displacement and opacity of one row at the current frame.
@immutable
class ListRowMotion {
  const ListRowMotion(this.dy, this.opacity);

  static const ListRowMotion still = ListRowMotion(0, 1);

  /// Vertical shift in multiples of the row's own height.
  final double dy;
  final double opacity;

  bool get isStill => dy == 0 && opacity >= 1;
}

/// Drives FLIP-style moves for one list. Owned by a [State] with a ticker.
class ListMotion {
  ListMotion({required TickerProvider vsync, this.window = 4})
    : _controller = AnimationController(vsync: vsync, duration: duration) {
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) _clear();
    });
  }

  /// Standard spring (≈275 ms, a hair of overshoot): moves feel physical
  /// without bouncing.
  static final Duration duration = LekisMotion.settleDuration(
    LekisMotion.springStandard,
  );
  static final Curve _moveCurve = LekisSpringCurve(LekisMotion.springStandard);
  static const Curve _fadeCurve = Curves.easeOutCubic;

  /// How far (in rows) a key is looked for around its new index. Covers a
  /// move by one, a few inserts / removes; anything further fades in.
  final int window;

  final AnimationController _controller;
  ListKeyAt? _old;
  ListKeyAt? _now;
  int _oldLength = 0;
  int _nowLength = 0;
  Map<int, double> _residual = const {};
  final Map<int, double?> _deltas = <int, double?>{};
  int _generation = 0;
  bool _armed = false;
  bool _disposed = false;

  /// Rows listen to this to repaint while a change plays.
  Listenable get listenable => _controller;

  /// Reports that the shown list changed from [old] to [now]. Safe to call
  /// during build: the new layout is drawn first with every row still at
  /// its old place, and the motion starts on the next frame.
  ///
  /// [animate] `false` (reduced motion, an optimistic local edit that is
  /// already on screen) just takes the new order as the resting state.
  void listChanged({
    required ListKeyAt old,
    required int oldLength,
    required ListKeyAt now,
    required int nowLength,
    bool animate = true,
  }) {
    // Rows interrupted mid-move continue from where they are drawn now.
    final remaining = _remaining;
    final residual = <int, double>{};
    if (remaining != 0) {
      _deltas.forEach((index, delta) {
        if (delta != null && delta != 0) residual[index] = delta * remaining;
      });
    }
    _deltas.clear();
    if (!animate) {
      settle();
      return;
    }
    _old = old;
    _now = now;
    _oldLength = oldLength;
    _nowLength = nowLength;
    _residual = residual;
    _armed = true;
    final generation = ++_generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || generation != _generation || !_armed) return;
      _armed = false;
      _controller.forward(from: 0);
    });
  }

  /// Takes what is on screen as the resting state (e.g. a row the user
  /// just dropped by drag). Safe during build.
  void settle() {
    _generation++;
    _controller.stop();
    _clear();
  }

  /// Where row [index] of the new list is drawn this frame.
  ListRowMotion at(int index) {
    if (_old == null || !(_armed || _controller.isAnimating)) {
      return ListRowMotion.still;
    }
    final delta = _deltas.putIfAbsent(index, () => _match(index));
    if (delta == null) {
      final t = _armed ? 0.0 : _controller.value;
      return ListRowMotion(0, _fadeCurve.transform(t));
    }
    if (delta == 0) return ListRowMotion.still;
    return ListRowMotion(delta * _remaining, 1);
  }

  /// Fraction of each move still to go (dips just below 0 on the spring's
  /// small overshoot).
  double get _remaining {
    if (_armed) return 1;
    if (!_controller.isAnimating) return 0;
    return 1 - _moveCurve.transform(_controller.value);
  }

  /// Rows the key at [index] moved by (old index − new index), or `null`
  /// for a key that was not nearby before (fades in).
  double? _match(int index) {
    final old = _old!;
    final key = index < _nowLength ? _now!(index) : null;
    if (key == null) return 0;
    double at(int i) => (i - index) + (_residual[i] ?? 0);
    if (index < _oldLength && old(index) == key) return at(index);
    for (var d = 1; d <= window; d++) {
      final above = index - d;
      if (above >= 0 && above < _oldLength && old(above) == key) {
        return at(above);
      }
      final below = index + d;
      if (below < _oldLength && old(below) == key) return at(below);
    }
    return null;
  }

  // stop() does not notify, so settling is safe mid-build; rows read
  // "still" from then on.
  void _clear() {
    _old = null;
    _now = null;
    _residual = const {};
    _deltas.clear();
    _armed = false;
  }

  void dispose() {
    _disposed = true;
    _controller.dispose();
  }
}

/// Paints one row at its [ListMotion] position. Hit testing follows the
/// painted position, so a row is tappable where it is seen.
class ListMotionRow extends StatelessWidget {
  const ListMotionRow({
    super.key,
    required this.motion,
    required this.index,
    required this.child,
  });

  final ListMotion motion;
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: motion.listenable,
      child: child,
      builder: (context, child) {
        final m = motion.at(index);
        if (m.isStill) return child!;
        Widget out = child!;
        if (m.dy != 0) {
          out = FractionalTranslation(translation: Offset(0, m.dy), child: out);
        }
        if (m.opacity < 1) {
          out = Opacity(opacity: m.opacity, child: out);
        }
        return out;
      },
    );
  }
}

/// Collapses a row (height + fade) while [collapsed]; expands it back if
/// the removal is undone. Rows start expanded: insertion is [ListMotion]'s
/// fade, so a list that first appears does not unfold row by row.
class ListRowCollapse extends StatefulWidget {
  const ListRowCollapse({
    super.key,
    required this.collapsed,
    required this.child,
  });

  /// Removal collapse: short and decisive, finished before the data changes.
  static const Duration duration = Duration(milliseconds: 180);

  final bool collapsed;
  final Widget child;

  @override
  State<ListRowCollapse> createState() => _ListRowCollapseState();
}

class _ListRowCollapseState extends State<ListRowCollapse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: ListRowCollapse.duration,
    value: widget.collapsed ? 0 : 1,
  );
  late final Animation<double> _size = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInOutCubic,
  );
  late final Animation<double> _opacity = CurvedAnimation(
    parent: _controller,
    // Fade out over the first half of the collapse, back in over the last
    // half of an expand.
    curve: const Interval(0.5, 1, curve: Curves.easeOut),
  );

  @override
  void didUpdateWidget(ListRowCollapse oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.collapsed == widget.collapsed) return;
    final target = widget.collapsed ? 0.0 : 1.0;
    if (lekisReduceMotion(context)) {
      _controller.value = target;
    } else {
      _controller.animateTo(target);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        if (_controller.value >= 1) return child!;
        return IgnorePointer(
          child: ClipRect(
            child: Align(
              alignment: Alignment.topCenter,
              heightFactor: _size.value,
              child: Opacity(opacity: _opacity.value, child: child),
            ),
          ),
        );
      },
    );
  }
}
