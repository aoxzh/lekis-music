// Top-level navigation destinations. Same set in every window size.

import 'package:material_ui/material_ui.dart';

import 'package:lekis/src/features/home/home_page.dart';
import 'package:lekis/src/features/library/library_page.dart';
import 'package:lekis/src/features/podcasts/podcasts_page.dart';
import 'package:lekis/src/features/search/search_page.dart';
import 'package:lekis/src/features/settings/settings_page.dart';
import 'package:lekis/src/features/sources/sources_page.dart';
import 'package:lekis/src/l10n/app_l10n.dart';

enum LekisDestination {
  home('首页', 'Home', Icons.home_outlined, Icons.home_rounded),
  library(
    '资料库',
    'Library',
    Icons.library_music_outlined,
    Icons.library_music_rounded,
  ),
  search('搜索', 'Search', Icons.search_rounded, Icons.saved_search_rounded),
  podcasts('播客', 'Podcasts', Icons.podcasts_outlined, Icons.podcasts_rounded),
  sources('音源', 'Sources', Icons.folder_outlined, Icons.folder_rounded),
  settings('设置', 'Settings', Icons.settings_outlined, Icons.settings_rounded);

  const LekisDestination(this._zh, this._en, this.icon, this.selectedIcon);

  final String _zh;
  final String _en;
  final IconData icon;
  final IconData selectedIcon;

  String get label => L10n.tr(_zh, _en);

  /// Localized label respecting the active app locale.
  String labelOf(BuildContext context) {
    final l10n = context.l10n;
    return switch (this) {
      home => l10n.navHome,
      library => l10n.navLibrary,
      search => l10n.navSearch,
      podcasts => l10n.navPodcasts,
      sources => l10n.navSources,
      settings => l10n.navSettings,
    };
  }

  /// Root page of this destination's tab.
  Widget buildPage() => switch (this) {
    home => const HomePage(),
    library => const LibraryPage(),
    search => const SearchPage(),
    podcasts => const PodcastsPage(),
    sources => const SourcesPage(),
    settings => const SettingsPage(),
  };
}
