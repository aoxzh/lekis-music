import 'package:lekis/src/features/library/albums_view.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/layout/adaptive_two_pane.dart';
import 'package:lekis/src/layout/fold.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:material_ui/material_ui.dart';

class ScopedAlbumPanes extends StatefulWidget {
  const ScopedAlbumPanes({
    super.key,
    required this.albums,
    required this.empty,
    required this.openRoute,
    required this.menuBuilder,
    required this.detailBuilder,
  });

  final PagedList<AlbumDto> albums;
  final Widget empty;
  final AlbumMenuBuilder menuBuilder;
  final Route<void> Function(AlbumDto album) openRoute;
  final Widget Function(AlbumDto album, VoidCallback close) detailBuilder;

  @override
  State<ScopedAlbumPanes> createState() => _ScopedAlbumPanesState();
}

class _ScopedAlbumPanesState extends State<ScopedAlbumPanes> {
  AlbumDto? _selected;

  @override
  Widget build(BuildContext context) {
    final fold = context.fold.isSeparating;
    final twoPane = isWideLayout(context) || fold;
    final selected = _selected;
    return AdaptiveTwoPane(
      primaryFraction: 0.5,
      primary: AlbumGrid(
        key: ObjectKey(widget.albums),
        list: widget.albums,
        menuBuilder: widget.menuBuilder,
        empty: widget.empty,
        selectedId: twoPane ? selected?.id : null,
        onOpen: (album) {
          if (twoPane) {
            setState(() => _selected = album);
          } else {
            Navigator.of(context).push(widget.openRoute(album));
          }
        },
      ),
      secondary: twoPane && selected != null
          ? KeyedSubtree(
              key: ValueKey(selected.id),
              child: widget.detailBuilder(
                selected,
                () => setState(() => _selected = null),
              ),
            )
          : fold
          ? Center(child: Text(context.l10n.pick('选择一张专辑', 'Select an album')))
          : null,
    );
  }
}
