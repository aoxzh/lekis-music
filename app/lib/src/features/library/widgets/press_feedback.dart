import 'package:flutter/gestures.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

/// Scale of a row while a finger rests on it.
const double _pressedScale = 0.98;

/// Subtle "pressed" feedback for list rows: the row sinks very slightly
/// while touched, on top of the ink ripple of its [InkWell].
///
/// It listens to raw pointers (never joins the gesture arena), waits the
/// platform press timeout and cancels as soon as the finger travels, so
/// scrolling a list never makes rows twitch.
class PressFeedback extends StatefulWidget {
  const PressFeedback({super.key, required this.child});

  final Widget child;

  @override
  State<PressFeedback> createState() => _PressFeedbackState();
}

class _PressFeedbackState extends State<PressFeedback> {
  bool _pressed = false;
  int? _pointer;
  Offset _origin = Offset.zero;
  bool _armed = false;

  void _down(PointerDownEvent e) {
    if (_pointer != null) return;
    _pointer = e.pointer;
    _origin = e.position;
    _armed = true;
    Future<void>.delayed(kPressTimeout, () {
      if (mounted && _armed && _pointer == e.pointer) {
        setState(() => _pressed = true);
      }
    });
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    if ((e.position - _origin).distance > kTouchSlop) _release();
  }

  void _up(PointerEvent e) {
    if (e.pointer == _pointer) _release();
  }

  void _release() {
    _armed = false;
    _pointer = null;
    if (_pressed) setState(() => _pressed = false);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: _up,
      onPointerCancel: _up,
      child: AnimatedScale(
        scale: _pressed ? _pressedScale : 1,
        duration: _pressed ? LekisMotion.fast : LekisMotion.normal,
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}
