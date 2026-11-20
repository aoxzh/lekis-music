// Route helpers shared by the shell and feature pages.

import 'package:material_ui/material_ui.dart';

import 'package:lekis/src/features/downloads/downloads_page.dart';
import 'package:lekis/src/features/enrich/enrich_review_page.dart';
import 'package:lekis/src/features/plugins/plugins_page.dart';
import 'package:lekis/src/features/podcasts/podcast_detail_page.dart';

export 'package:lekis/src/features/now_playing/now_playing_route.dart'
    show NowPlayingRoute, openNowPlaying;

/// Opens the enrichment review queue inside the current tab, keeping the
/// navigation chrome and player visible. Call from Library or Settings.
Future<void> openEnrichReview(BuildContext context) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/enrich-review'),
        builder: (_) => const EnrichReviewPage(),
      ),
    );

/// Opens the offline downloads page inside the current tab.
Future<void> openDownloads(BuildContext context) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    settings: const RouteSettings(name: '/downloads'),
    builder: (_) => const DownloadsPage(),
  ),
);

/// Opens the local plugin manager inside the current tab.
Future<void> openPlugins(BuildContext context) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    settings: const RouteSettings(name: '/plugins'),
    builder: (_) => const PluginsPage(),
  ),
);

/// Opens one podcast (already in the local library) inside the current tab.
Future<void> openPodcast(BuildContext context, int podcastId) =>
    Navigator.of(context).push(PodcastDetailPage.route(podcastId: podcastId));
