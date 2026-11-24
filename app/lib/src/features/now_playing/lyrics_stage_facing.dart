part of 'lyrics_stage.dart';

_LineArt _layoutFacing(
  List<_StageLine> lines,
  int index,
  Size size,
  TextStyle base,
  double font,
  Color bright,
  Color accent,
) {
  final line = lines[index];
  final pages = _FacingPages(
    line,
    index + 1 < lines.length ? lines[index + 1] : null,
    size,
    index.isEven,
    base,
    font,
    bright,
    accent,
  );
  return _LineArt(line: line, fontSize: font, glyphs: const [], facing: pages)
    ..hot.add((line.start, line.end));
}

class _FacingPages {
  _FacingPages(
    this.line,
    this.next,
    Size size,
    this.above,
    TextStyle base,
    double font,
    this.bright,
    Color accent,
  ) {
    final inset = math.min(36.0, size.width * 0.045);
    final half = math.min(size.height * 0.47, size.width * 0.62);
    final spine = size.height / 2;
    final gap = math.min(9.0, half * 0.09);
    rail = Rect.fromLTRB(inset, spine - gap, size.width - inset, spine + gap);
    final top = Rect.fromLTRB(inset, spine - half, rail.right, rail.top);
    final bottom = Rect.fromLTRB(inset, rail.bottom, rail.right, spine + half);
    paper = above ? top : bottom;
    final pad = math.min(
      24.0,
      math.min(paper.width * 0.06, paper.height * 0.09),
    );
    body = paper.deflate(pad);
    cueBox = (above ? bottom : top).deflate(pad);
    stock = Color.lerp(accent, bright, 0.22)!.withValues(alpha: 1);
    ink = stock.computeLuminance() > 0.179 ? Colors.black : Colors.white;
    final text = line.line.text;
    var headlineSize = math.min(font, body.height * 0.77);
    TextStyle headlineStyle() => lyricTextStyleFor(text, base).copyWith(
      color: ink,
      fontSize: headlineSize,
      fontWeight: FontWeight.w800,
      height: 1.08,
      letterSpacing: -headlineSize * 0.032,
    );
    headline = _paragraph(text, headlineStyle(), above, body.width);
    if (headline.height > body.height && headlineSize > 20) {
      headlineSize = math.max(
        20,
        headlineSize * math.sqrt(body.height / headline.height) * 0.95,
      );
      headline.dispose();
      headline = _paragraph(text, headlineStyle(), above, body.width);
    }
    reversed = _paragraph(
      text,
      headlineStyle().copyWith(color: stock),
      above,
      body.width,
    );
    var offset = 0;
    for (final word in line.words) {
      final start = text.indexOf(word.text, offset);
      if (start < 0) {
        boxes.add(const []);
        continue;
      }
      offset = start + word.text.length;
      boxes.add(
        headline.getBoxesForSelection(
          TextSelection(baseOffset: start, extentOffset: offset),
        ),
      );
    }
    if (next case final upcoming?) {
      final cueSize = (headlineSize * 0.54).clamp(14.0, 36.0);
      cue = _paragraph(
        upcoming.line.text,
        lyricTextStyleFor(upcoming.line.text, base).copyWith(
          color: bright.withValues(alpha: 0.8),
          fontWeight: FontWeight.w400,
          fontSize: cueSize,
          height: 1.18,
        ),
        !above,
        cueBox.width,
        maxLines: math
            .max(1, (cueBox.height / (cueSize * 1.18)).floor())
            .clamp(1, 3),
      );
    }
  }

  final _StageLine line;
  final _StageLine? next;
  final bool above;
  final Color bright;
  late final Color stock, ink;
  late final Rect rail, paper, body, cueBox;
  late TextPainter headline;
  late final TextPainter reversed;
  TextPainter? cue;
  final boxes = <List<TextBox>>[];
  final brush = Paint();

  TextPainter _paragraph(
    String text,
    TextStyle style,
    bool left,
    double width, {
    int? maxLines,
  }) => TextPainter(
    text: TextSpan(text: text, style: style),
    textAlign: left ? TextAlign.left : TextAlign.right,
    textDirection: TextDirection.ltr,
    maxLines: maxLines,
    ellipsis: maxLines == null ? null : '…',
  )..layout(minWidth: width, maxWidth: width);

  int _wordAt(double time) =>
      line.words.lastIndexWhere((word) => word.start <= time);

  double _advance(int active, double time) {
    if (active < 0) return 0;
    final word = line.words[active];
    final width = boxes[active].fold(0.0, (sum, box) => sum + box.right - box.left);
    return width * _clamp01((time - word.start) / (word.sungEnd - word.start));
  }

  Offset _origin(int active, double advance) {
    if (headline.height <= body.height) {
      return Offset(
        body.left,
        above ? body.bottom - headline.height : body.top,
      );
    }
    var bottom = 0.0;
    if (active >= 0) {
      for (final box in boxes[active]) {
        bottom = box.bottom;
        advance -= box.right - box.left;
        if (advance <= 0) break;
      }
    }
    final scroll = (bottom - body.height).clamp(
      0.0,
      headline.height - body.height,
    );
    return body.topLeft - Offset(0, scroll);
  }

  double? hit(Offset local, double time, bool browsing) {
    if (cueBox.contains(local)) return next?.start;
    if (!body.contains(local)) return null;
    final active = browsing ? -1 : _wordAt(time);
    final point = local - _origin(active, _advance(active, time));
    for (var index = 0; index < boxes.length; index++) {
      if (boxes[index].any((box) => box.toRect().contains(point))) {
        return line.words[index].start;
      }
    }
    return null;
  }

  void paint(
    Canvas canvas,
    double time, {
    required bool still,
    required bool browsing,
    required bool sparks,
  }) {
    canvas.drawRect(paper, brush..color = stock);
    final active = browsing ? -1 : _wordAt(time);
    var advance = _advance(active, time);
    final origin = _origin(active, advance);
    canvas.save();
    canvas.clipRect(body);
    headline.paint(canvas, origin);
    if (active >= 0) {
      for (final box in boxes[active]) {
        final rect = box.toRect().shift(origin);
        final width = still ? rect.width : advance.clamp(0.0, rect.width);
        advance -= rect.width;
        if (width <= 0) continue;
        final swatch = Rect.fromLTWH(
          box.direction == TextDirection.ltr ? rect.left : rect.right - width,
          rect.top,
          width,
          rect.height,
        );
        canvas.save();
        canvas.clipRect(swatch);
        canvas.drawRect(rect, brush..color = ink);
        reversed.paint(canvas, origin);
        canvas.restore();
      }
    }
    canvas.restore();

    if (cue case final preview?) {
      canvas.save();
      canvas.clipRect(cueBox);
      preview.paint(
        canvas,
        Offset(
          cueBox.left,
          above ? cueBox.top : cueBox.bottom - preview.height,
        ),
      );
      canvas.restore();
    }

    final span = math.max(0.001, line.end - line.start);
    final position = browsing
        ? line.start
        : still && active >= 0
        ? line.words[active].start
        : time;
    double railX(double seconds) {
      final fraction = _clamp01((seconds - line.start) / span);
      return rail.left + rail.width * (above ? fraction : 1 - fraction);
    }

    final y = rail.center.dy;
    final cursor = Offset(railX(position), y);
    final start = Offset(railX(line.start), y);
    canvas.drawLine(
      Offset(rail.left, y),
      Offset(rail.right, y),
      brush
        ..color = bright.withValues(alpha: 0.36)
        ..strokeWidth = 1,
    );
    canvas.drawLine(
      start,
      cursor,
      brush
        ..color = stock
        ..strokeWidth = 2,
    );
    for (final word in line.words) {
      final x = railX(word.start);
      canvas.drawLine(
        Offset(x, y - rail.height * 0.22),
        Offset(x, y + rail.height * 0.22),
        brush
          ..color = word.start <= position
              ? stock
              : bright.withValues(alpha: 0.55)
          ..strokeWidth = 1,
      );
    }
    final pulse = sparks && active >= 0
        ? 1 - _clamp01((time - line.words[active].start) / 0.25)
        : 0.0;
    canvas.drawCircle(
      cursor,
      math.min(rail.height / 2, 3 + pulse * 2),
      brush..color = stock,
    );
  }

  void dispose() {
    headline.dispose();
    reversed.dispose();
    cue?.dispose();
  }
}
