// Route helpers shared by the shell and feature pages.

import 'package:material_ui/material_ui.dart';

import 'package:lekis/src/features/enrich/enrich_review_page.dart';

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
