// The base layer of Now Playing, drawn as a handful of baked textures.
//
// It used to be drawn live: a blurred copy of the cover, four drifting
// radial-gradient blobs, a tiled noise shader and a top-bar gradient, every
// frame. Under Impeller (the default renderer on Windows since 3.47, and on
// Android) each of those keeps device-sized GPU memory alive for as long as
// it exists — roughly 100 bytes per covered pixel per live gradient, blur or
// shader (flutter#196198) — which made opening this page cost over a
// gigabyte of private bytes on a 2880×1800 window.
//
// Everything here is therefore rendered once into a small [ui.Image] and
// then blitted as an ordinary texture:
//
//   cover      the artwork blurred inside a 128 px canvas (per track)
//   gradient   the palette gradient at half size      (per palette, size)
//   scrim      the top-bar protection gradient         (per scene, size)
//   grain      one screen-size tile of the noise       (per size)
//
// The drift is a slow pan of the baked gradient instead of four moving
// gradient shaders, so per frame nothing but image draws happen. Track
// changes cross-fade the whole backdrop, exactly like the live version did.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

/// Source pixels of the baked blurred cover. The result is scaled to the
/// window, so a bigger canvas buys nothing.
const int _coverPx = 128;

/// Longest side of the baked gradient.
const int _gradientPx = 1024;

/// Longest side of the baked screen-space layers (grain, top-bar scrim).
const int _screenLayerPx = 2048;

/// How much larger than the window the gradient is drawn, so the drift never
/// exposes an edge.
const double _gradientOverdraw = 1.14;

/// Now Playing's background: the blurred cover, the palette gradient, the
/// top-bar scrim and the grain, cross-faded as a whole when the track, the
/// palette or the scene colour changes.
class NowPlayingBackdrop extends StatefulWidget {
  const NowPlayingBackdrop({
    super.key,
    required this.hash,
    required this.colors,
    required this.opacity,
    required this.scrim,
    required this.cycle,
    this.grain = true,
    this.crossfade = Duration.zero,
  });

  /// Artwork hash of the current track; null when there is no cover.
  final String? hash;

  /// Gradient colours, from the core's palette.
  final List<Color> colors;

  /// Overall opacity of the gradient over the blurred cover.
  final double opacity;

  /// Top-bar protection colour; anything transparent disables the scrim.
  final Color scrim;

  /// Drives the drift. Stopped for low-power / reduced motion.
  final Animation<double> cycle;

  /// Draws the grain. False while the page is still flying in or out: it is
  /// the last thing to appear and the first to be dropped.
  final bool grain;

  /// Length of the cross-fade between two backdrops.
  final Duration crossfade;

  @override
  State<NowPlayingBackdrop> createState() => _NowPlayingBackdropState();
}

class _NowPlayingBackdropState extends State<NowPlayingBackdrop> {
  @override
  Widget build(BuildContext context) {
    // One key for the whole scene: when any input changes, the old backdrop
    // fades out while the new one fades in.
    final signature = [
      widget.hash ?? '-',
      for (final c in widget.colors) c.toARGB32(),
      widget.scrim.toARGB32(),
      (widget.opacity * 100).round(),
    ].join('|');

    return AnimatedSwitcher(
      duration: widget.crossfade,
      switchInCurve: Curves.easeInOut,
      switchOutCurve: Curves.easeInOut,
      layoutBuilder: (current, previous) =>
          Stack(fit: StackFit.expand, children: [...previous, ?current]),
      child: _BakedScene(
        key: ValueKey(signature),
        hash: widget.hash,
        colors: widget.colors,
        opacity: widget.opacity,
        scrim: widget.scrim,
        cycle: widget.cycle,
        grain: widget.grain,
      ),
    );
  }
}

class _BakedScene extends StatefulWidget {
  const _BakedScene({
    super.key,
    required this.hash,
    required this.colors,
    required this.opacity,
    required this.scrim,
    required this.cycle,
    required this.grain,
  });

  final String? hash;
  final List<Color> colors;
  final double opacity;
  final Color scrim;
  final Animation<double> cycle;
  final bool grain;

  @override
  State<_BakedScene> createState() => _BakedSceneState();
}

class _BakedSceneState extends State<_BakedScene> {
  ui.Image? _cover;
  ui.Image? _gradient;
  ui.Image? _scrim;
  ui.Image? _grain;

  Size? _px;
  double? _sigma;
  Timer? _resize;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final px = Size(size.width * dpr, size.height * dpr);
    // The blur has to look the same at every window size, so it is expressed
    // in window pixels and converted into the 128 px canvas.
    final sigma = math
        .max(
          LekisNowPlaying.blurRadius * 0.57735 * _coverPx / size.longestSide,
          1.0,
        )
        .clamp(1.0, _coverPx / 4)
        .toDouble();
    if (_px == px && _sigma == sigma) return;
    _sigma = sigma;
    // Re-baking on every frame of a window drag would be wasteful; wait for
    // the size to hold still.
    _resize?.cancel();
    if (_px == null) {
      _px = px;
      _bake(px, sigma);
    } else {
      _resize = Timer(const Duration(milliseconds: 200), () {
        if (!mounted) return;
        _px = px;
        _bake(px, sigma);
      });
    }
  }

  @override
  void dispose() {
    _resize?.cancel();
    super.dispose();
  }

  void _bake(Size px, double sigma) {
    final hash = widget.hash;
    if (hash != null) {
      _load(_Bakery.cover(hash, sigma), (image) => _cover = image);
    }
    _load(
      _Bakery.gradient(widget.colors, px, widget.opacity),
      (image) => _gradient = image,
    );
    if (widget.scrim.a > 0 && LekisNowPlaying.topBarProtectionOpacity > 0) {
      _load(
        _Bakery.scrim(widget.scrim, px, LekisNowPlaying.topBarProtectionHeight),
        (image) => _scrim = image,
      );
    }
    _load(_Bakery.grain(px), (image) => _grain = image);
  }

  void _load(Future<ui.Image> future, void Function(ui.Image) assign) {
    future.then(
      (image) {
        if (!mounted) return;
        setState(() => assign(image));
      },
      onError: (Object _) {
        // A missing artwork file just leaves the flat palette colour.
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _BackdropPainter(
          cover: _cover,
          gradient: _gradient,
          scrim: _scrim,
          grain: widget.grain ? _grain : null,
          cycle: widget.cycle,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _BackdropPainter extends CustomPainter {
  _BackdropPainter({
    required this.cover,
    required this.gradient,
    required this.scrim,
    required this.grain,
    required this.cycle,
  }) : super(repaint: cycle);

  final ui.Image? cover;
  final ui.Image? gradient;
  final ui.Image? scrim;
  final ui.Image? grain;
  final Animation<double> cycle;

  static Rect _src(ui.Image image) =>
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());

  @override
  void paint(Canvas canvas, Size size) {
    final low = Paint()..filterQuality = FilterQuality.low;

    final c = cover;
    if (c != null) {
      // BoxFit.cover: the blurred cover fills the window.
      final side = math.max(size.width, size.height);
      canvas.drawImageRect(
        c,
        _src(c),
        Rect.fromCenter(
          center: size.center(Offset.zero),
          width: side,
          height: side,
        ),
        low,
      );
    }

    final g = gradient;
    if (g != null) {
      final t = cycle.value * 2 * math.pi;
      final over = size * (_gradientOverdraw - 1);
      // Two different periods so the drift never repeats in a straight line;
      // the full cycle still loops seamlessly at 2π.
      canvas.save();
      canvas.translate(
        math.sin(t) * over.width * 0.5,
        math.cos(t * 0.5) * over.height * 0.5,
      );
      canvas.drawImageRect(
        g,
        _src(g),
        Rect.fromLTWH(
          -over.width * 0.5,
          -over.height * 0.5,
          size.width + over.width,
          size.height + over.height,
        ),
        low,
      );
      canvas.restore();
    }

    final s = scrim;
    if (s != null) {
      canvas.drawImageRect(
        s,
        _src(s),
        Rect.fromLTWH(
          0,
          0,
          size.width,
          size.height * LekisNowPlaying.topBarProtectionHeight,
        ),
        low,
      );
    }

    final n = grain;
    if (n != null) {
      canvas.drawImageRect(
        n,
        _src(n),
        Offset.zero & size,
        Paint()
          ..filterQuality = FilterQuality.none
          ..color = const Color(0xFFFFFFFF)
              .withValues(alpha: LekisNowPlaying.noiseOpacity),
      );
    }
  }

  @override
  bool shouldRepaint(_BackdropPainter old) =>
      old.cover != cover ||
      old.gradient != gradient ||
      old.scrim != scrim ||
      old.grain != grain;
}

/// The one-time renders, cached by key across scenes: a handful of small
/// images, so a track change only bakes the gradient (and the cover, when
/// that track has different artwork).
abstract final class _Bakery {
  /// Enough entries that the previous scene's images survive its cross-fade
  /// plus a few tracks of history.
  static const int _cacheLimit = 12;

  static final Map<String, Future<ui.Image>> _cache = {};

  static Future<ui.Image> cover(String hash, double sigma) {
    final key = 'cover:$hash@$_coverPx:${sigma.toStringAsFixed(2)}';
    return _remember(key, () => _bakeCover(hash, sigma));
  }

  static Future<ui.Image> gradient(
    List<Color> colors,
    Size px,
    double opacity,
  ) {
    final key =
        'gradient:${colors.map((c) => c.toARGB32()).join(',')}'
        '@${px.width.round()}x${px.height.round()}:$opacity';
    return _remember(key, () => _bakeGradient(colors, px, opacity));
  }

  static Future<ui.Image> scrim(Color color, Size px, double heightFactor) {
    final key =
        'scrim:${color.toARGB32()}'
        '@${px.width.round()}x${px.height.round()}:$heightFactor';
    return _remember(key, () => _bakeScrim(color, px, heightFactor));
  }

  static Future<ui.Image> grain(Size px) => _remember(
    'grain:${px.width.round()}x${px.height.round()}',
    () => _bakeGrain(px),
  );

  static Future<ui.Image> _remember(
    String key,
    Future<ui.Image> Function() bake,
  ) {
    final cached = _cache[key];
    if (cached != null) {
      // Refresh insertion order so the oldest entry is the least recently
      // used one.
      _cache
        ..remove(key)
        ..[key] = cached;
      return cached;
    }
    final future = bake();
    _cache[key] = future;
    while (_cache.length > _cacheLimit) {
      _cache.remove(_cache.keys.first);
    }
    return future;
  }

  static Future<ui.Image> _bakeCover(String hash, double sigma) async {
    final bytes = await _coverBytes(hash);
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: _coverPx,
      targetHeight: _coverPx,
    );
    final frame = await codec.getNextFrame();
    codec.dispose();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    // The blur is baked inside a 128 px layer instead of being applied to a
    // window-sized one later; that is the whole saving.
    canvas.saveLayer(
      Rect.fromLTWH(0, 0, _coverPx * 1.0, _coverPx * 1.0),
      Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: sigma,
          sigmaY: sigma,
          tileMode: TileMode.clamp,
        ),
    );
    canvas.drawImage(
      frame.image,
      Offset.zero,
      Paint()..filterQuality = FilterQuality.low,
    );
    canvas.restore();
    final image = await recorder.endRecording().toImage(_coverPx, _coverPx);
    frame.image.dispose();
    return image;
  }

  /// The smallest thumbnail the core has actually generated for [hash]. The
  /// buckets are written on demand, so the 128 px one often does not exist
  /// yet; decoding the 1024 px file down to 128 costs about the same as
  /// decoding the small one.
  static Future<Uint8List> _coverBytes(String hash) async {
    for (final bucket in artworkWidthBuckets) {
      final file = File(artworkFilePath(hash, bucket));
      if (await file.exists()) return file.readAsBytes();
    }
    throw FileSystemException('no artwork bucket for $hash');
  }

  static Future<ui.Image> _bakeGradient(
    List<Color> colors,
    Size px,
    double opacity,
  ) async {
    final scale = math.min(1.0, _gradientPx / px.longestSide);
    final size = _bakeSize(px, scale);
    final recorder = ui.PictureRecorder();
    _paintBlobs(Canvas(recorder), size, colors, opacity);
    return recorder.endRecording().toImage(
      size.width.round(),
      size.height.round(),
    );
  }

  static Future<ui.Image> _bakeScrim(
    Color color,
    Size px,
    double heightFactor,
  ) async {
    final scale = math.min(1.0, _screenLayerPx / px.longestSide);
    final width = math.max((px.width * scale).round(), 1);
    final height = math.max((px.height * scale * heightFactor).round(), 1);
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()
        ..shader =
            LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                color.withValues(
                  alpha: LekisNowPlaying.topBarProtectionOpacity,
                ),
                color.withValues(alpha: 0),
              ],
            ).createShader(
              Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
            ),
    );
    return recorder.endRecording().toImage(width, height);
  }

  static Future<ui.Image> _bakeGrain(Size px) async {
    final scale = math.min(1.0, _screenLayerPx / px.longestSide);
    final size = _bakeSize(px, scale);
    final width = size.width.round();
    final height = size.height.round();
    final tile = await _grainTile();
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()
        ..shader = ImageShader(
          tile,
          TileMode.repeated,
          TileMode.repeated,
          Matrix4.identity().storage,
        ),
    );
    return recorder.endRecording().toImage(width, height);
  }

  static Size _bakeSize(Size px, double scale) {
    final w = math.max((px.width * scale).round(), 1);
    final h = math.max((px.height * scale).round(), 1);
    return Size(w.toDouble(), h.toDouble());
  }

  static Future<ui.Image>? _tile;

  /// Static film grain: light and dark specks, drawn source-over so the
  /// average brightness is kept and no framebuffer read-back is needed.
  static Future<ui.Image> _grainTile() {
    const n = 128;
    return _tile ??= () async {
      final rnd = math.Random(7);
      final px = Uint8List(n * n * 4);
      // Premultiplied: each pixel is white (lighten) or black (darken) with
      // an alpha of twice its distance from mid-grey.
      for (var i = 0; i < n * n; i++) {
        final d = rnd.nextInt(128) - 64;
        final c = d >= 0 ? 255 : 0;
        final a = (d.abs() * 2 * 255 / 128).round().clamp(0, 255);
        final pc = (c * a / 255).round();
        px[i * 4] = pc;
        px[i * 4 + 1] = pc;
        px[i * 4 + 2] = pc;
        px[i * 4 + 3] = a;
      }
      final done = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        px,
        n,
        n,
        ui.PixelFormat.rgba8888,
        done.complete,
      );
      return done.future;
    }();
  }

  /// Four soft radial blobs on closed Lissajous paths (integer frequencies,
  /// so the loop is seamless), at the first frame of the cycle.
  static void _paintBlobs(
    Canvas canvas,
    Size size,
    List<Color> colors,
    double opacity,
  ) {
    final rect = Offset.zero & size;
    Color fade(Color c) => c.withValues(alpha: c.a * opacity);
    canvas.drawRect(rect, Paint()..color = fade(colors.first));
    // The live painter's frequencies only shape the motion; at t = 0 all
    // that is left is the phase.
    const phase = [0.0, 1.7, 3.1, 4.4];
    const amplitude = 0.32;
    const radius = 0.85;
    final r = size.longestSide * radius;
    for (var i = 1; i < colors.length; i++) {
      final k = (i - 1) % phase.length;
      final center = Offset(
        size.width * (0.5 + amplitude * math.sin(phase[k])),
        size.height * (0.5 + amplitude * math.cos(phase[k] * 0.7)),
      );
      canvas.drawRect(
        rect,
        Paint()
          ..shader = RadialGradient(
            colors: [fade(colors[i]), colors[i].withValues(alpha: 0)],
          ).createShader(Rect.fromCircle(center: center, radius: r)),
      );
    }
  }
}
