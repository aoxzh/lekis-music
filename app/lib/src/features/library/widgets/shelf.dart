import 'package:flutter/gestures.dart';
import 'package:lekis/src/features/library/widgets/album_card.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

/// A titled, horizontally scrolling row of artwork cards.
///
/// Mouse users get previous/next page buttons (a vertical wheel does not
/// scroll horizontal lists) and the list accepts mouse drags.
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
    final width = widget.cardWidth ?? LekisSizes.gridArtworkMin;
    final height = width + ArtworkCardFrame.textBlockHeight(context);
    final gutter = pageGutterOf(context);
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
