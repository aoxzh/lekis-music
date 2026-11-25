import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/widgets/action_menu.dart';
import 'package:material_ui/material_ui.dart';

enum _BrowseAction { open, play }

class LibraryBrowseMenu extends StatelessWidget {
  const LibraryBrowseMenu({
    super.key,
    required this.title,
    required this.subtitle,
    required this.openLabel,
    required this.icon,
    required this.onOpen,
    required this.onPlay,
    this.playLabel,
  });

  final String title;
  final String subtitle;
  final String openLabel;
  final IconData icon;
  final VoidCallback onOpen;
  final VoidCallback? onPlay;
  final String? playLabel;

  @override
  Widget build(BuildContext context) => LekisActionMenuButton<_BrowseAction>(
    title: title,
    subtitle: subtitle,
    tooltip: context.l10n.pick('更多操作：$title', 'More actions for $title'),
    actions: () => [
      LekisMenuAction(_BrowseAction.open, icon, openLabel),
      LekisMenuAction(
        _BrowseAction.play,
        Icons.play_arrow_rounded,
        playLabel ?? context.l10n.pick('播放', 'Play'),
        enabled: onPlay != null,
      ),
    ],
    onSelected: (action) {
      if (action == _BrowseAction.open) {
        onOpen();
      } else {
        onPlay?.call();
      }
    },
  );
}
