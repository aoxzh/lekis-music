import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/now_playing/now_playing_tint.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:material_ui/material_ui.dart';

class TrackDial extends ConsumerWidget {
  const TrackDial({super.key, required this.cover});

  final Widget cover;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final known = ref.watch(
      playbackProvider.select(
        (state) => state.hasTrack && state.durationMs > 0,
      ),
    );
    final percent = known
        ? ref.watch(progressProvider.select((value) => (value * 100).floor()))
        : null;
    final state = ref.watch(playbackProvider.select((value) => value.state));
    final scheme = Theme.of(context).colorScheme;
    final face = Color.lerp(const Color(0xff13171c), scheme.primary, 0.08)!;
    final ink = readableAccent(scheme.primary, face);
    final symbol = switch (state) {
      PlaybackStateDto.playing => Icons.play_arrow_rounded,
      PlaybackStateDto.loading ||
      PlaybackStateDto.buffering => Icons.hourglass_empty_rounded,
      PlaybackStateDto.paused => Icons.pause_rounded,
      _ => Icons.stop_rounded,
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.biggest.shortestSide;
        if (side < 96) return cover;
        return RepaintBoundary(
          child: Stack(
            fit: StackFit.expand,
            alignment: Alignment.center,
            children: [
              CustomPaint(
                painter: _DialFace(face: face, ink: ink, percent: percent),
              ),
              Center(
                child: SizedBox.square(
                  dimension: side * 0.48,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(side * 0.025),
                    child: RepaintBoundary(child: cover),
                  ),
                ),
              ),
              Positioned(
                bottom: side * 0.105,
                height: side * 0.105,
                width: side * 0.49,
                child: FittedBox(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(symbol, size: 15, color: ink),
                      const SizedBox(width: 4),
                      Text(
                        percent == null ? '—' : '$percent%',
                        style: const TextStyle(
                          color: Color(0xfff5f4ee),
                          fontSize: 24,
                          fontWeight: FontWeight.w500,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DialFace extends CustomPainter {
  const _DialFace({
    required this.face,
    required this.ink,
    required this.percent,
  });

  final Color face;
  final Color ink;
  final int? percent;

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    final center = size.center(Offset.zero);
    const start = math.pi * 0.75;
    const sweep = math.pi * 1.5;
    final paint = Paint()..color = face;
    canvas.drawCircle(center, side * 0.493, paint);
    paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white24;
    canvas.drawCircle(center, side * 0.49, paint);
    final rail = Rect.fromCircle(center: center, radius: side * 0.392);
    paint
      ..strokeWidth = side * 0.011
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rail, start, sweep, false, paint);
    final fraction = (percent ?? 0) / 100;
    if (fraction > 0) {
      paint.color = ink;
      canvas.drawArc(rail, start, sweep * fraction, false, paint);
    }
    for (var index = 0; index <= 60; index++) {
      final unit = Offset.fromDirection(start + sweep * index / 60);
      final major = index % 5 == 0;
      paint
        ..color = percent != null && index / 60 <= fraction
            ? ink
            : major
            ? Colors.white70
            : Colors.white30
        ..strokeWidth = side * (major ? 0.006 : 0.003);
      canvas.drawLine(
        center + unit * (side * (major ? 0.413 : 0.432)),
        center + unit * (side * 0.453),
        paint,
      );
    }
    if (percent != null) {
      final unit = Offset.fromDirection(start + sweep * fraction);
      paint
        ..color = Colors.white
        ..strokeWidth = side * 0.012;
      canvas.drawLine(
        center + unit * (side * 0.376),
        center + unit * (side * 0.459),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_DialFace old) =>
      percent != old.percent || ink != old.ink || face != old.face;
}
