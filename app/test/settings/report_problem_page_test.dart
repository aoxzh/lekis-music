import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/settings/report_problem_page.dart';
import 'package:lekis/src/features/settings/settings_providers.dart';
import 'package:lekis/src/features/sources/sources_providers.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/platform/ui_profile.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class _EmptySources extends SourcesNotifier {
  @override
  Future<List<SourceConfigDto>> build() async => [];
}

class _Output extends PlaybackOutputNotifier {
  @override
  PlaybackOutputState build() => const PlaybackOutputState();
}

void main() {
  testWidgets('shows the diagnostics preview and both actions', (tester) async {
    UiProfile.debugOverride = UiProfile.desktop;
    addTearDown(() => UiProfile.debugOverride = null);
    tester.view.physicalSize = const Size(900, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sourcesProvider.overrideWith(_EmptySources.new),
          playbackOutputProvider.overrideWith(_Output.new),
          aboutInfoProvider.overrideWithValue(
            const AboutInfo(coreVersion: '0.6.3'),
          ),
        ],
        child: LekisLocale(
          locale: const Locale('en'),
          child: MaterialApp(
            theme: lekisDarkTheme(),
            home: const ReportProblemPage(),
          ),
        ),
      ),
    );
    await tester.pump();
    // Let the desktop-model probe time out under fake time so the page's
    // environment future finishes and no timer survives the test.
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    expect(find.text('Report a Problem'), findsOneWidget);
    expect(find.byKey(const ValueKey('report.description')), findsOneWidget);
    expect(find.byKey(const ValueKey('report.device-id')), findsOneWidget);
    expect(find.byKey(const ValueKey('report.save')), findsOneWidget);
    expect(find.byKey(const ValueKey('report.issue')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
