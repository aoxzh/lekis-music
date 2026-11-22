// 正在播放页可选复古载体样式：黑胶唱片（旋转 + 唱臂）与磁带（双卷轴 + 进度带轮）。
//
// 暂停时平稳停转并抬起唱臂；减少动态设置开启时不跑旋转 Ticker，节省电量。

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// 黑胶唱片组件：暗色纹路盘面 + 中央圆形封面标签 + 随播放状态抬落的金属唱臂。
class VinylRecordArtwork extends StatefulWidget {
  const VinylRecordArtwork({
    super.key,
    required this.cover,
    required this.isPlaying,
    required this.reducedMotion,
    this.accent = const Color(0xFF7C5CFF),
  });

  final Widget cover;
  final bool isPlaying;
  final bool reducedMotion;
  final Color accent;

  static const Key vinylKey = ValueKey('now-playing.style.vinyl');

  @override
  State<VinylRecordArtwork> createState() => _VinylRecordArtworkState();
}

class _VinylRecordArtworkState extends State<VinylRecordArtwork>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 12),
  );

  @override
  void initState() {
    super.initState();
    _syncSpin();
  }

  @override
  void didUpdateWidget(covariant VinylRecordArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying ||
        oldWidget.reducedMotion != widget.reducedMotion) {
      _syncSpin();
    }
  }

  void _syncSpin() {
    if (widget.isPlaying && !widget.reducedMotion) {
      if (!_spin.isAnimating) _spin.repeat();
    } else {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      key: VinylRecordArtwork.vinylKey,
      builder: (context, constraints) {
        final side = math.min(constraints.maxWidth, constraints.maxHeight);
        final discSize = side * 0.92;
        final labelSize = discSize * 0.46;
        final spindleSize = math.max(8.0, discSize * 0.045);

        return SizedBox.square(
          dimension: side,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              // 唱片阴影与旋转盘面
              AnimatedBuilder(
                animation: _spin,
                builder: (context, child) => Transform.rotate(
                  angle: _spin.value * math.pi * 2,
                  child: child,
                ),
                child: Container(
                  width: discSize,
                  height: discSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.48),
                        blurRadius: side * 0.08,
                        offset: Offset(0, side * 0.03),
                      ),
                    ],
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CustomPaint(
                        size: Size.square(discSize),
                        painter: _VinylDiscPainter(accent: widget.accent),
                      ),
                      ClipOval(
                        child: SizedBox.square(
                          dimension: labelSize,
                          child: widget.cover,
                        ),
                      ),
                      // 中心轴孔
                      Container(
                        width: spindleSize,
                        height: spindleSize,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF121218),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.35),
                            width: 1.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // 右上角唱臂：播放时落入唱片沟槽，暂停时轻抬归位。
              Positioned(
                top: side * 0.02,
                right: side * 0.02,
                child: IgnorePointer(
                  child: AnimatedRotation(
                    turns: widget.isPlaying ? 0.045 : -0.055,
                    alignment: const Alignment(0.55, -0.78),
                    duration: widget.reducedMotion
                        ? Duration.zero
                        : const Duration(milliseconds: 420),
                    curve: Curves.easeOutCubic,
                    child: CustomPaint(
                      size: Size(side * 0.32, side * 0.52),
                      painter: _TonearmPainter(accent: widget.accent),
                    ),
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

class _VinylDiscPainter extends CustomPainter {
  const _VinylDiscPainter({required this.accent});

  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2;

    // 唱片本体黑胶渐变
    final basePaint = Paint()
      ..shader = const RadialGradient(
        colors: [
          Color(0xFF1F1F27),
          Color(0xFF111116),
          Color(0xFF1A1A22),
          Color(0xFF0B0B0F),
        ],
        stops: [0.0, 0.45, 0.78, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, basePaint);

    // 细密同心唱片纹路
    final groovePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.85;
    for (var r = radius * 0.50; r < radius * 0.96; r += 3.2) {
      final t = ((r / radius) - 0.5) / 0.46;
      groovePaint.color = Colors.white.withValues(
        alpha: 0.045 + 0.03 * math.sin(t * math.pi * 6).abs(),
      );
      canvas.drawCircle(center, r, groovePaint);
    }

    // 对角高光反光扇区
    final sheenPaint = Paint()
      ..shader = SweepGradient(
        colors: [
          Colors.transparent,
          Colors.white.withValues(alpha: 0.10),
          Colors.transparent,
          accent.withValues(alpha: 0.09),
          Colors.transparent,
          Colors.white.withValues(alpha: 0.08),
          Colors.transparent,
        ],
        stops: const [0.0, 0.14, 0.28, 0.50, 0.64, 0.78, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius * 0.97, sheenPaint);

    // 外圈倒角描边
    canvas.drawCircle(
      center,
      radius - 0.8,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = Colors.white.withValues(alpha: 0.18),
    );
  }

  @override
  bool shouldRepaint(_VinylDiscPainter old) => old.accent != accent;
}

class _TonearmPainter extends CustomPainter {
  const _TonearmPainter({required this.accent});

  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final pivot = Offset(size.width * 0.72, size.height * 0.12);
    final elbow = Offset(size.width * 0.56, size.height * 0.68);
    final head = Offset(size.width * 0.26, size.height * 0.88);

    // 底座转轴
    canvas.drawCircle(
      pivot,
      size.width * 0.18,
      Paint()..color = const Color(0xFF282834),
    );
    canvas.drawCircle(
      pivot,
      size.width * 0.18,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = Colors.white.withValues(alpha: 0.28),
    );
    canvas.drawCircle(
      pivot,
      size.width * 0.08,
      Paint()..color = const Color(0xFFBFC4D6),
    );

    // 唱臂金属管（带阴影）
    final armPath = Path()
      ..moveTo(pivot.dx, pivot.dy)
      ..lineTo(elbow.dx, elbow.dy)
      ..lineTo(head.dx, head.dy);
    canvas.drawPath(
      armPath.shift(const Offset(2, 4)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = Colors.black.withValues(alpha: 0.42),
    );
    canvas.drawPath(
      armPath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = const Color(0xFFD7DBE8),
    );

    // 唱头
    canvas.save();
    canvas.translate(head.dx, head.dy);
    canvas.rotate(0.62);
    final cartRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset.zero, width: 14, height: 22),
      const Radius.circular(4),
    );
    canvas.drawRRect(cartRect, Paint()..color = const Color(0xFF22222C));
    canvas.drawRRect(
      cartRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = accent.withValues(alpha: 0.75),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TonearmPainter old) => old.accent != accent;
}

/// 复古磁带组件：半透明月夜外壳 + 专辑封面贴纸 + 随进度消长的双旋转卷轴。
class CassetteArtwork extends StatefulWidget {
  const CassetteArtwork({
    super.key,
    required this.cover,
    required this.title,
    required this.isPlaying,
    required this.progress,
    required this.reducedMotion,
    this.accent = const Color(0xFF7C5CFF),
  });

  final Widget cover;
  final String title;
  final bool isPlaying;
  final double progress;
  final bool reducedMotion;
  final Color accent;

  static const Key cassetteKey = ValueKey('now-playing.style.cassette');

  @override
  State<CassetteArtwork> createState() => _CassetteArtworkState();
}

class _CassetteArtworkState extends State<CassetteArtwork>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 5),
  );

  @override
  void initState() {
    super.initState();
    _syncSpin();
  }

  @override
  void didUpdateWidget(covariant CassetteArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying ||
        oldWidget.reducedMotion != widget.reducedMotion) {
      _syncSpin();
    }
  }

  void _syncSpin() {
    if (widget.isPlaying && !widget.reducedMotion) {
      if (!_spin.isAnimating) _spin.repeat();
    } else {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      key: CassetteArtwork.cassetteKey,
      builder: (context, constraints) {
        final w = constraints.maxWidth * 0.96;
        final h = math.min(constraints.maxHeight * 0.72, w / 1.56);
        final radius = h * 0.09;
        final p = widget.progress.clamp(0.0, 1.0);

        return Center(
          child: Container(
            width: w,
            height: h,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF232330), Color(0xFF14141C)],
              ),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.18),
                width: 1.4,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.46),
                  blurRadius: h * 0.14,
                  offset: Offset(0, h * 0.05),
                ),
              ],
            ),
            child: Stack(
              children: [
                // 封面标签贴纸区域
                Positioned(
                  left: w * 0.06,
                  right: w * 0.06,
                  top: h * 0.09,
                  bottom: h * 0.24,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(radius * 0.6),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Opacity(opacity: 0.85, child: widget.cover),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.black.withValues(alpha: 0.42),
                                Colors.black.withValues(alpha: 0.18),
                                Colors.black.withValues(alpha: 0.55),
                              ],
                            ),
                          ),
                        ),
                        // 顶部标签文字条
                        Positioned(
                          left: w * 0.04,
                          right: w * 0.04,
                          top: h * 0.04,
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: widget.accent.withValues(alpha: 0.85),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text(
                                  'A',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    height: 1.1,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  widget.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.92),
                                    fontSize: math.max(11, h * 0.065),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        // 中间透明带仓与双卷轴
                        Center(
                          child: Container(
                            width: w * 0.64,
                            height: h * 0.30,
                            decoration: BoxDecoration(
                              color: const Color(0xFF0B0B10)
                                  .withValues(alpha: 0.84),
                              borderRadius: BorderRadius.circular(h * 0.15),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.22),
                              ),
                            ),
                            child: AnimatedBuilder(
                              animation: _spin,
                              builder: (context, _) => CustomPaint(
                                painter: _CassetteReelsPainter(
                                  angle: _spin.value * math.pi * 2,
                                  progress: p,
                                  accent: widget.accent,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // 底部磁带梯形读写口
                Positioned(
                  left: w * 0.18,
                  right: w * 0.18,
                  bottom: 0,
                  height: h * 0.18,
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF101017),
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(radius * 0.65),
                      ),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.14),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _hole(h * 0.055),
                        _hole(h * 0.04),
                        _hole(h * 0.04),
                        _hole(h * 0.055),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _hole(double size) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: Colors.black.withValues(alpha: 0.72),
      border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
    ),
  );
}

class _CassetteReelsPainter extends CustomPainter {
  const _CassetteReelsPainter({
    required this.angle,
    required this.progress,
    required this.accent,
  });

  final double angle;
  final double progress;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final leftCenter = Offset(size.width * 0.25, cy);
    final rightCenter = Offset(size.width * 0.75, cy);
    final hubR = size.height * 0.29;
    final maxTapeR = size.height * 0.44;

    // 左卷随播放变薄，右卷随播放变厚
    final leftTapeR = hubR + (maxTapeR - hubR) * (1.0 - progress * 0.75);
    final rightTapeR = hubR + (maxTapeR - hubR) * (0.25 + progress * 0.75);

    final tapePaint = Paint()..color = const Color(0xFF3A2D28);
    canvas.drawCircle(leftCenter, leftTapeR, tapePaint);
    canvas.drawCircle(rightCenter, rightTapeR, tapePaint);

    // 进度刻度条
    final barRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(size.width * 0.5, cy),
        width: size.width * 0.20,
        height: 4,
      ),
      const Radius.circular(2),
    );
    canvas.drawRRect(
      barRect,
      Paint()..color = Colors.white.withValues(alpha: 0.14),
    );
    final fillRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        barRect.left,
        barRect.top,
        barRect.width * progress,
        barRect.height,
      ),
      const Radius.circular(2),
    );
    canvas.drawRRect(fillRect, Paint()..color = accent);

    _drawHub(canvas, leftCenter, hubR, angle);
    _drawHub(canvas, rightCenter, hubR, angle);
  }

  void _drawHub(Canvas canvas, Offset center, double radius, double angle) {
    canvas.drawCircle(center, radius, Paint()..color = const Color(0xFFE7EAF2));
    canvas.drawCircle(
      center,
      radius * 0.62,
      Paint()..color = const Color(0xFF15151E),
    );
    // 6 齿棘轮
    final toothPaint = Paint()
      ..color = const Color(0xFFE7EAF2)
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 6; i++) {
      final a = angle + i * (math.pi / 3);
      final p1 = Offset(
        center.dx + math.cos(a) * radius * 0.46,
        center.dy + math.sin(a) * radius * 0.46,
      );
      final p2 = Offset(
        center.dx + math.cos(a) * radius * 0.74,
        center.dy + math.sin(a) * radius * 0.74,
      );
      canvas.drawLine(p1, p2, toothPaint);
    }
  }

  @override
  bool shouldRepaint(_CassetteReelsPainter old) =>
      old.angle != angle || old.progress != progress || old.accent != accent;
}
