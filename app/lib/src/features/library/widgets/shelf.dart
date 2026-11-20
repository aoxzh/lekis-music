import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:lekis/src/features/library/widgets/album_card.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/platform/ui_profile.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

/// A titled, horizontally scrolling row of artwork cards.
///
/// Cards are sized by [shelfCardWidth] (several per row, the next one
/// peeking). When the row overflows, pointer platforms get previous/next
/// page buttons (a vertical wheel does not scroll horizontal lists; touch
/// users swipe instead and should not see desktop arrows). The list also
/// accepts mouse drags.
class ArtworkShelf extends StatefulWidget {
  const ArtworkShelf({
    super.key,
    required this.title,
    required this.itemCount,
    required this.itemBuilder,
    this.trailing,
    this.cardWidth,
  });

  final String title;
  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final Widget? trailing;
  final double? cardWidth;

  @override
  State<ArtworkShelf> createState() => _ArtworkShelfState();
}

class _ArtworkShelfState extends State<ArtworkShelf> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _page(int direction) {
    if (!_controller.hasClients) return;
    final pos = _controller.position;
    final target = (pos.pixels + direction * pos.viewportDimension * 0.8).clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );
    _controller.animateTo(
      target,
      duration: LekisMotion.settleDuration(LekisMotion.springStandard),
      curve: LekisSpringCurve(LekisMotion.springStandard),
    );
  }

  @override
  Widget build(BuildContext context) {
    final gutter = pageGutterOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth - gutter * 2;
        final width = widget.cardWidth ?? shelfCardWidth(available);
        final contentWidth =
            widget.itemCount * (width + LekisSpacing.lg) - LekisSpacing.lg;
        final overflows = contentWidth > available + 0.5;
        return _build(context, gutter, width, overflows);
      },
    );
  }

  Widget _build(
    BuildContext context,
    double gutter,
    double width,
    bool overflows,
  ) {
    final height = width + ArtworkCardFrame.textBlockHeight(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            gutter,
            LekisSpacing.xl,
            gutter - LekisSpacing.sm,
            LekisSpacing.sm,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: LekisSizes.touchTargetMin,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      widget.title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ),
                ?widget.trailing,
                // Paging buttons only when there is somewhere to page to and
                // a pointer to click them; phones / tablets swipe the row.
                if (overflows && _usesPointer()) ...[
                  IconButton(
                    tooltip: '上一页',
                    onPressed: () => _page(-1),
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                  IconButton(
                    tooltip: '下一页',
                    onPressed: () => _page(1),
                    icon: const Icon(Icons.chevron_right_rounded),
                  ),
                ],
              ],
            ),
          ),
        ),
        SizedBox(
          height: height,
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(
              dragDevices: {
                PointerDeviceKind.touch,
                PointerDeviceKind.mouse,
                PointerDeviceKind.trackpad,
                PointerDeviceKind.stylus,
              },
            ),
            child: ListView.separated(
              controller: _controller,
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: gutter),
              itemCount: widget.itemCount,
              separatorBuilder: (_, _) =>
                  const SizedBox(width: LekisSpacing.lg),
              itemBuilder: (context, i) =>
                  SizedBox(width: width, child: widget.itemBuilder(context, i)),
            ),
          ),
        ),
      ],
    );
  }
}

/// Whether the current platform expects a pointer (desktop) rather than a
/// finger. Touch platforms rely on the horizontal swipe.
bool _usesPointer() => UiProfile.current.pointerFirst;

/// Smallest / largest shelf card side.
const double shelfCardMin = LekisSizes.gridArtworkMin * 0.75;
const double shelfCardMax = LekisSizes.gridArtworkMin;

/// Share of one more card left peeking at the edge of a shelf that scrolls,
/// so it reads as scrollable on touch screens.
const double _shelfPeek = 0.35;

/// Card width for a shelf [available] logical pixels wide (inside the
/// gutters): as many cards of at least [shelfCardMin] as fit, plus a peek of
/// the next one. Every shelf at the same width gets the same card size,
/// whatever its item count, so stacked shelves line up.
double shelfCardWidth(double available) {
  const gap = LekisSpacing.lg;
  if (!available.isFinite || available <= 0) return shelfCardMin;
  final columns = math.max(
    2,
    ((available + gap) / (shelfCardMin + gap)).floor(),
  );
  final width = (available - gap * columns) / (columns + _shelfPeek);
  return width.clamp(shelfCardMin * 0.85, shelfCardMax);
}
