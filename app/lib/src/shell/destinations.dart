// Top-level navigation destinations. Same set in every window size.

import 'package:material_ui/material_ui.dart';

import 'package:lekis/src/features/home/home_page.dart';
import 'package:lekis/src/features/library/library_page.dart';
import 'package:lekis/src/features/podcasts/podcasts_page.dart';
import 'package:lekis/src/features/search/search_page.dart';
import 'package:lekis/src/features/settings/settings_page.dart';
import 'package:lekis/src/features/sources/sources_page.dart';

enum LekisDestination {
  home('首页', Icons.home_outlined, Icons.home_rounded),
  library('资料库', Icons.library_music_outlined, Icons.library_music_rounded),
  search('搜索', Icons.search_rounded, Icons.saved_search_rounded),
  podcasts('播客', Icons.podcasts_outlined, Icons.podcasts_rounded),
  sources('音源', Icons.folder_outlined, Icons.folder_rounded),
  settings('设置', Icons.settings_outlined, Icons.settings_rounded);

  const LekisDestination(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;

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
