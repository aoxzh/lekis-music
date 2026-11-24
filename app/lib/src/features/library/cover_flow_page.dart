// 封面流：iPod Cover Flow 风格的专辑浏览器（资料库「专辑」页右上角的入口）。
//
// 一条横向的封面带：居中的一张正面朝前、尺寸最大；两侧的绕 Y 轴旋转、后退
// 并压暗，下方各带一条渐隐的镜像倒影。拖动 / 滚轮 / 方向键切换，甩动后吸附
// 到最近的一张；点侧边封面把它移到中间，点中间那张打开专辑页。
//
// 全库入口按需翻页；传入来源时与该来源的专辑分类共用数据和详情页。
// 两种入口都只绘制当前封面及其邻近的几张。

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/album_detail_page.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/scoped_library_view.dart';
import 'package:lekis/src/features/library/widgets/album_card.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/library/widgets/empty_state.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

/// 封面流的几何与手感参数（逻辑像素，或封面边长的比例）。
///
/// 这些只属于这一页的观感，和 design/tokens.json 的通用刻度无关（间距、
/// 圆角、动效仍然走 [LekisSpacing] / [LekisRadius] / [LekisMotion]），所以
/// 留在文件里，不塞进 tokens.dart。
abstract final class _CoverFlowMetrics {
  /// 侧边封面绕 Y 轴的旋转角；iPod 大约 60°。
  static const double sideAngle = 60 * math.pi / 180;

  /// 透视深度（1 / 视距）：越小越平缓，0.0025 接近 iPod 的夸张度。
  static const double perspective = 0.0025;

  /// 侧边封面相对居中封面的缩放。
  static const double sideScale = 0.82;

  /// 侧边封面后退的距离（封面边长的比例）。
  static const double sideDepth = 0.22;

  /// 侧边封面叠 [LekisColors.scrim] 的透明度（越远越暗）。
  static const double sideDim = 0.55;

  /// 一个槽的额外间隙（封面边长的比例）：槽宽 = 边长 × (1 + 该值)。
  static const double slotGap = 0.16;

  /// 倒影的高度（封面边长的比例）和它顶端的不透明度。
  static const double reflectionHeight = 0.34;
  static const double reflectionOpacity = 0.30;

  /// 视口左右各构建几张：更远的封面不建，滑过去时再补。
  static const int window = 2;

  /// 超过一格后多少格淡到完全透明。
  static const double fadeSpan = 1.2;

  /// 居中的封面占可用宽度 / 封面带高度的比例。封面按这两个比例取小值，
  /// 所以窗口再矮、字再大也不会溢出。
  static const double widthShare = 0.32;
  static const double heightShare = 0.6;

  /// 封面边长的上下限。
  static const double minSide = LekisSizes.touchTargetMin;
  static const double maxSide = LekisSizes.gridArtworkMin * 1.6;

  /// 甩动时向前预测的时间（秒），以及算作「甩」的最小速度（逻辑像素/秒）。
  static const double flingProjection = 0.16;
  static const double flingVelocity = 240;

  /// 吸附到下一张的时长；曲线是 [LekisMotion.springStandard] 的弹簧。
  static final Duration snapDuration = LekisMotion.settleDuration(
    LekisMotion.springStandard,
  );
}

/// 封面流页面。
class CoverFlowPage extends ConsumerStatefulWidget {
  const CoverFlowPage({super.key, this.scope});

  final LibraryScope? scope;

  /// 这一页封面的 Hero 域，同一张专辑在别处出现时标签不会撞。
  static const Object heroScope = 'cover-flow';

  static Route<void> route({LibraryScope? scope}) => MaterialPageRoute<void>(
    settings: const RouteSettings(name: '/library/cover-flow'),
    builder: (_) => CoverFlowPage(scope: scope),
  );

  @override
  ConsumerState<CoverFlowPage> createState() => _CoverFlowPageState();
}

class _CoverFlowPageState extends ConsumerState<CoverFlowPage>
    with SingleTickerProviderStateMixin {
  final _focus = FocusNode(debugLabel: 'cover-flow');
  final Curve _snapCurve = LekisSpringCurve(LekisMotion.springStandard);
  late final AnimationController _snap = AnimationController(
    vsync: this,
    duration: _CoverFlowMetrics.snapDuration,
  )..addListener(_onSnapTick);

  /// 当前连续的格位置：0 = 第一张居中，1.4 = 第二张偏右 40%。
  double _position = 0;
  double _snapFrom = 0;
  double _snapTo = 0;

  /// 上一次布局的一个槽宽；拖动 / 甩动的换算在 build 之外跑，需要它。
  double _extent = 1;

  @override
  void didUpdateWidget(CoverFlowPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope != widget.scope) {
      _snap.stop();
      _position = 0;
    }
  }

  @override
  void dispose() {
    _snap.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onSnapTick() {
    // 弹簧曲线会略微过冲；结束时收敛到精确的目标格。
    final t = _snap.isCompleted ? 1.0 : _snapCurve.transform(_snap.value);
    setState(() => _position = _snapFrom + (_snapTo - _snapFrom) * t);
  }

  double _lastPosition(int count) => math.max(0, count - 1).toDouble();

  /// 把第 [index] 张挪到中间（超出范围时夹到两端）。
  ///
  /// 系统要求减少动效时直接跳过去，不做吸附动画。
  void _centre(int index, int count, {bool animate = true}) {
    final target = index.toDouble().clamp(0.0, _lastPosition(count));
    _snap.stop();
    _snapFrom = _position;
    _snapTo = target;
    if (!animate ||
        _snapFrom == _snapTo ||
        MediaQuery.disableAnimationsOf(context)) {
      setState(() => _position = target);
      return;
    }
    _snap.forward(from: 0);
  }

  void _onDragUpdate(DragUpdateDetails details, int count) {
    final delta = details.primaryDelta ?? 0;
    _snap.stop();
    setState(() {
      _position = (_position - delta / _extent).clamp(
        0.0,
        _lastPosition(count),
      );
    });
  }

  void _onDragEnd(DragEndDetails details, int count) {
    final velocity = details.velocity.pixelsPerSecond.dx;
    final flung = velocity.abs() >= _CoverFlowMetrics.flingVelocity;
    final projected =
        _position - velocity * _CoverFlowMetrics.flingProjection / _extent;
    _centre((flung ? projected : _position).round(), count);
  }

  void _onPointerSignal(PointerSignalEvent event, int count) {
    if (event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (signal) {
      final delta = (signal as PointerScrollEvent).scrollDelta;
      // 桌面滚轮默认竖向；Shift + 滚轮、触控板横扫给的是横向。
      final step = delta.dy != 0 ? delta.dy : delta.dx;
      if (step == 0) return;
      _centre(_position.round() + (step > 0 ? 1 : -1), count);
    });
  }

  KeyEventResult _onKey(KeyEvent event, int count) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final current = _position.round();
    if (key == LogicalKeyboardKey.arrowLeft) {
      _centre(current - 1, count);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _centre(current + 1, count);
    } else if (key == LogicalKeyboardKey.home) {
      _centre(0, count);
    } else if (key == LogicalKeyboardKey.end) {
      _centre(count - 1, count);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _open(AlbumDto album) {
    final scope = widget.scope;
    Navigator.of(context).push(
      scope != null
          ? ScopedLibraryAlbumPage.route(scope: scope, album: album)
          : AlbumDetailPage.route(
              album.id.toInt(),
              heroTag: AlbumHeroTag(album.id.toInt(), CoverFlowPage.heroScope),
              initialAlbum: album,
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.pick('封面流', 'Cover Flow'))),
      body: SafeArea(
        // Bottom stays with the page: the shell reports the floating mini
        // player / tab bar through MediaQuery.padding, and the info block
        // below the strip has to clear it (it used to sit underneath).
        top: false,
        bottom: false,
        child: _body(),
      ),
    );
  }

  Widget _body() {
    final scope = widget.scope;
    final list = scope == null
        ? ref.watch(albumsListProvider(TrackSortDto.title))
        : ref.watch(
            scopedAlbumsListProvider((scope, ref.watch(albumSortProvider))),
          );
    return ListenableBuilder(
      listenable: list,
      builder: (context, _) {
        if (list.error != null) {
          return LoadErrorView(error: list.error!, onRetry: list.retry);
        }
        if (list.isInitialLoading) {
          return const Center(child: CircularProgressIndicator());
        }
        if (list.isEmpty) {
          if (scope == null) return const LibraryEmptyState();
          return LibraryEmptyState(
            title: context.l10n.pick('这个音源还没有专辑', 'No albums in this source'),
            message: context.l10n.pick(
              '可以返回曲库切换音源。',
              'Return to the library to choose another source.',
            ),
          );
        }
        return _carousel(list);
      },
    );
  }

  Widget _carousel(PagedList<AlbumDto> list) {
    final count = list.itemCount;
    final base = math.min(
      math.max(_position.round(), 0),
      math.max(0, count - 1),
    );
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: (_, event) => _onKey(event, count),
      child: Listener(
        onPointerSignal: (event) => _onPointerSignal(event, count),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => _strip(
                  list: list,
                  count: count,
                  base: base,
                  constraints: constraints,
                ),
              ),
            ),
            _Info(album: list.itemAt(base), index: base, count: count),
          ],
        ),
      ),
    );
  }

  Widget _strip({
    required PagedList<AlbumDto> list,
    required int count,
    required int base,
    required BoxConstraints constraints,
  }) {
    final side = math
        .min(
          constraints.maxWidth * _CoverFlowMetrics.widthShare,
          constraints.maxHeight * _CoverFlowMetrics.heightShare,
        )
        .clamp(_CoverFlowMetrics.minSide, _CoverFlowMetrics.maxSide);
    final extent = side * (1 + _CoverFlowMetrics.slotGap);
    _extent = extent;

    final position = _position.clamp(0.0, _lastPosition(count));
    final first = math.max(0, base - _CoverFlowMetrics.window);
    final last = math.min(count - 1, base + _CoverFlowMetrics.window);
    // 远的先画，居中的最后画，永远压在最上面。
    final slots = <(double, Widget)>[];
    for (var i = first; i <= last; i++) {
      final offset = i - position;
      slots.add((
        offset.abs(),
        _slot(
          album: list.itemAt(i),
          index: i,
          offset: offset,
          base: base,
          side: side,
          extent: extent,
          centreX: constraints.maxWidth / 2,
          count: count,
        ),
      ));
    }
    slots.sort((a, b) => b.$1.compareTo(a.$1));

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: context.l10n.pick('封面流', 'Cover Flow'),
      customSemanticsActions: {
        CustomSemanticsAction(
          label: context.l10n.pick('上一张', 'Previous'),
        ): () =>
            _centre(base - 1, count),
        CustomSemanticsAction(label: context.l10n.pick('下一张', 'Next')): () =>
            _centre(base + 1, count),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => _onDragUpdate(details, count),
        onHorizontalDragEnd: (details) => _onDragEnd(details, count),
        child: ClipRect(
          child: Stack(
            clipBehavior: Clip.none,
            children: [for (final (_, slot) in slots) slot],
          ),
        ),
      ),
    );
  }

  /// 一张封面在封面带里的位置、朝向和不透明度。
  Widget _slot({
    required AlbumDto? album,
    required int index,
    required double offset,
    required int base,
    required double side,
    required double extent,
    required double centreX,
    required int count,
  }) {
    final distance = offset.abs();
    final near = distance.clamp(0.0, 1.0);
    final scale = 1 + (_CoverFlowMetrics.sideScale - 1) * near;
    final angle = _CoverFlowMetrics.sideAngle * offset.clamp(-1.0, 1.0);
    final depth = side * _CoverFlowMetrics.sideDepth * near;
    final dim = _CoverFlowMetrics.sideDim * near;
    final fade = (1 - (distance - 1) / _CoverFlowMetrics.fadeSpan).clamp(
      0.0,
      1.0,
    );
    final centred = index == base;
    return Positioned(
      left: centreX + offset * extent - side / 2,
      top: 0,
      bottom: 0,
      width: side,
      child: Center(
        child: Opacity(
          opacity: fade,
          child: _Perspective(
            depth: _CoverFlowMetrics.perspective,
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.translationValues(0, 0, -depth)
                ..rotateY(angle),
              child: Transform.scale(
                scale: scale,
                child: _Cover(
                  key: ValueKey('cover-flow.cover-$index'),
                  album: album,
                  scoped: widget.scope != null,
                  side: side,
                  centred: centred,
                  dim: dim,
                  onTap: () {
                    if (!centred) {
                      _centre(index, count);
                    } else if (album != null) {
                      _open(album);
                    }
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 透视外壳：给里面绕 Y 轴的旋转加一点纵深感。
class _Perspective extends StatelessWidget {
  const _Perspective({required this.depth, required this.child});

  /// 1 / 视距：越大透视越夸张。
  final double depth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()..setEntry(3, 2, depth),
      child: child,
    );
  }
}

/// 一张封面：圆角封面、压暗的侧边、下方的镜像倒影。
class _Cover extends StatelessWidget {
  const _Cover({
    super.key,
    required this.album,
    required this.scoped,
    required this.side,
    required this.centred,
    required this.dim,
    required this.onTap,
  });

  final AlbumDto? album;
  final bool scoped;
  final double side;

  /// 是否居中（语义上的 selected，也是唯一参与封面飞行的）。
  final bool centred;

  /// 0 = 原色，1 = 完全压暗。
  final double dim;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final radius = LekisRadius.artworkFor(side);
    final album = this.album;
    final label = album?.title;

    Widget face({required bool hero}) {
      final Widget art = album == null
          ? SizedBox.square(
              dimension: side,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surfaceVariant,
                  borderRadius: BorderRadius.circular(radius),
                ),
              ),
            )
          : SizedBox.square(
              dimension: side,
              child: scoped
                  ? ArtworkImage(
                      hash: album.artworkHash,
                      radius: radius,
                      placeholderIcon: Icons.album_rounded,
                      placeholderSeed: album.id,
                      placeholderLabel: album.title,
                    )
                  : AlbumArtHero(
                      album: album,
                      tag: hero && centred
                          ? AlbumHeroTag(
                              album.id.toInt(),
                              CoverFlowPage.heroScope,
                            )
                          : null,
                      radius: radius,
                    ),
            );
      if (dim <= 0) return art;
      return SizedBox.square(
        dimension: side,
        child: Stack(
          fit: StackFit.expand,
          children: [
            art,
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.scrim.withValues(alpha: dim),
                  borderRadius: BorderRadius.circular(radius),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Semantics(
      button: album != null,
      selected: centred,
      label: label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [face(hero: true), _reflection(face(hero: false))],
          ),
        ),
      ),
    );
  }

  /// 倒影：把封面翻过来只露上面一截，再用遮罩往下淡出。
  Widget _reflection(Widget face) {
    return ExcludeSemantics(
      child: SizedBox(
        width: side,
        height: side * _CoverFlowMetrics.reflectionHeight,
        child: ClipRect(
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            // 只用到 alpha，色相无关紧要。
            shaderCallback: (rect) => LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                const Color(0xFF000000)
                    .withValues(alpha: _CoverFlowMetrics.reflectionOpacity),
                const Color(0x00000000),
              ],
            ).createShader(rect),
            child: OverflowBox(
              alignment: Alignment.topCenter,
              minHeight: side,
              maxHeight: side,
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.diagonal3Values(1, -1, 1),
                child: face,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 封面带下方的信息：标题、艺人、当前位置。
class _Info extends StatelessWidget {
  const _Info({required this.album, required this.index, required this.count});

  final AlbumDto? album;
  final int index;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final gutter = pageGutterOf(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        LekisSpacing.lg,
        gutter,
        LekisSpacing.xl + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            album?.title ?? '',
            key: const ValueKey('cover-flow.title'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge,
          ),
          Text(
            album?.artistLine ?? '',
            key: const ValueKey('cover-flow.artist'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: LekisSpacing.xs),
          Text(
            '${index + 1} / $count',
            key: const ValueKey('cover-flow.position'),
            maxLines: 1,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
