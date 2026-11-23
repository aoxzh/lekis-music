// 网络电台页面（SRC-11）：热门 / 搜索、收藏、自定义、最近播放。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/widgets/empty_state.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/radio/radio_providers.dart';
import 'package:lekis/src/features/radio/radio_strings.dart';
import 'package:lekis/src/features/radio/widgets/add_radio_dialog.dart';
import 'package:lekis/src/features/radio/widgets/radio_station_tile.dart';
import 'package:lekis/src/features/settings/widgets/settings_widgets.dart';
import 'package:lekis/src/features/sources/common.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

enum _RadioTab { popular, favorites, custom, recent }

class RadioPage extends ConsumerStatefulWidget {
  const RadioPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(
    builder: (_) => const RadioPage(),
    settings: const RouteSettings(name: 'radio'),
  );

  @override
  ConsumerState<RadioPage> createState() => _RadioPageState();
}

class _RadioPageState extends ConsumerState<RadioPage> {
  final _search = TextEditingController();
  final _localSearch = TextEditingController();
  final Map<int, bool> _favoriteOverrides = {};
  _RadioTab _tab = _RadioTab.popular;
  String? _countryCode;
  String? _language;
  String? _tag;

  @override
  void initState() {
    super.initState();
    _search.addListener(_onSearchChanged);
    _localSearch.addListener(_onSearchChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 从正在播放页收藏 / 最近播放后回到这里时，列表需要重新读库。
      ref.invalidate(radioFavoritesProvider);
      ref.invalidate(radioCustomProvider);
      ref.invalidate(radioRecentProvider);
    });
  }

  @override
  void dispose() {
    _search.removeListener(_onSearchChanged);
    _search.dispose();
    _localSearch.removeListener(_onSearchChanged);
    _localSearch.dispose();
    super.dispose();
  }

  void _onSearchChanged() => setState(() {});

  bool _favoriteOf(RadioStationDto station) =>
      _favoriteOverrides[station.id] ?? station.favorite;

  bool _matchesLocal(RadioStationDto station, String query) {
    bool has(String? value) =>
        value != null && value.toLowerCase().contains(query);
    return has(station.name) ||
        has(station.country) ||
        has(station.countryCode) ||
        has(station.language) ||
        has(station.codec) ||
        station.tags.any((tag) => tag.toLowerCase().contains(query));
  }

  Future<void> _applyBrowse() async {
    try {
      await ref
          .read(radioBrowseProvider.notifier)
          .reload(
            search: _search.text,
            countryCode: _countryCode,
            language: _language,
            tag: _tag,
          );
    } catch (e) {
      if (mounted) {
        showFeatureSnack(
          context,
          '${RadioStrings.actionFailed}：${describeCoreError(e)}',
        );
      }
    }
  }

  Future<void> _refreshActiveTab() async {
    switch (_tab) {
      case _RadioTab.popular:
        await _applyBrowse();
      case _RadioTab.favorites:
        ref.invalidate(radioFavoritesProvider);
      case _RadioTab.custom:
        ref.invalidate(radioCustomProvider);
      case _RadioTab.recent:
        ref.invalidate(radioRecentProvider);
    }
  }

  Future<void> _addCustom() async {
    final station = await showAddRadioDialog(context);
    if (station == null || !mounted) return;
    setState(() => _tab = _RadioTab.custom);
    showFeatureSnack(context, RadioStrings.added);
  }

  Future<void> _deleteCustom(RadioStationDto station) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(RadioStrings.deleteTitle),
        content: Text(RadioStrings.deleteBody(station.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(RadioStrings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(RadioStrings.delete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(radioActionsProvider).deleteCustom(station);
      _favoriteOverrides.remove(station.id);
      if (mounted) showFeatureSnack(context, RadioStrings.deleted);
    } catch (e) {
      if (mounted) {
        showFeatureSnack(
          context,
          '${RadioStrings.actionFailed}：${describeCoreError(e)}',
        );
      }
    }
  }

  Future<void> _toggleFavorite(RadioStationDto station) async {
    final current = _favoriteOf(station);
    final next = !current;
    setState(() => _favoriteOverrides[station.id] = next);
    try {
      await ref.read(radioActionsProvider).setFavorite(station, next);
      if (mounted) {
        showFeatureSnack(
          context,
          next ? RadioStrings.favoriteDone : RadioStrings.unfavoriteDone,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _favoriteOverrides[station.id] = current);
      showFeatureSnack(
        context,
        '${RadioStrings.actionFailed}：${describeCoreError(e)}',
      );
    }
  }

  Future<void> _play(List<RadioStationDto> stations, int index) async {
    try {
      await ref.read(radioActionsProvider).playStations(stations, index);
    } catch (e) {
      if (mounted) {
        showFeatureSnack(
          context,
          '${RadioStrings.actionFailed}：${describeCoreError(e)}',
        );
      }
    }
  }

  Future<void> _loadMore() async {
    try {
      await ref.read(radioBrowseProvider.notifier).loadMore();
    } catch (e) {
      if (mounted) {
        showFeatureSnack(
          context,
          '${RadioStrings.actionFailed}：${describeCoreError(e)}',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentTrackId = ref.watch(playbackProvider.select((s) => s.trackId));
    return SettingsScaffold(
      title: RadioStrings.title,
      actions: [
        IconButton(
          tooltip: RadioStrings.refresh,
          onPressed: _refreshActiveTab,
          icon: const Icon(Icons.refresh_rounded),
        ),
        IconButton(
          tooltip: RadioStrings.addCustom,
          onPressed: _addCustom,
          icon: const Icon(Icons.add_rounded),
        ),
      ],
      body: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  pageGutterOf(context),
                  LekisSpacing.sm,
                  pageGutterOf(context),
                  LekisSpacing.sm,
                ),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedButton<_RadioTab>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                        value: _RadioTab.popular,
                        label: Text(RadioStrings.tabPopular),
                        icon: Icon(Icons.local_fire_department_rounded),
                      ),
                      ButtonSegment(
                        value: _RadioTab.favorites,
                        label: Text(RadioStrings.tabFavorites),
                        icon: Icon(Icons.favorite_rounded),
                      ),
                      ButtonSegment(
                        value: _RadioTab.custom,
                        label: Text(RadioStrings.tabCustom),
                        icon: Icon(Icons.radio_rounded),
                      ),
                      ButtonSegment(
                        value: _RadioTab.recent,
                        label: Text(RadioStrings.tabRecent),
                        icon: Icon(Icons.history_rounded),
                      ),
                    ],
                    selected: {_tab},
                    onSelectionChanged: (selection) {
                      setState(() => _tab = selection.first);
                    },
                  ),
                ),
              ),
              if (_tab == _RadioTab.popular) _buildSearchPanel(context),
              Expanded(
                child: AnimatedSwitcher(
                  duration: LekisMotion.fast,
                  child: KeyedSubtree(
                    key: ValueKey(_tab),
                    child: _buildTab(context, currentTrackId),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchPanel(BuildContext context) {
    final filters = ref.watch(radioFilterOptionsProvider);
    final options = filters.value;
    final countries = options?.countries.isNotEmpty == true
        ? options!.countries
        : _fallbackCountries;
    final languages = options?.languages.isNotEmpty == true
        ? options!.languages
        : _fallbackLanguages;
    final tags = options?.tags.isNotEmpty == true
        ? options!.tags
        : _fallbackTags;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        pageGutterOf(context),
        0,
        pageGutterOf(context),
        LekisSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _search,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _applyBrowse(),
            decoration: InputDecoration(
              hintText: RadioStrings.searchHint,
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: RadioStrings.clear,
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () {
                        _search.clear();
                        _applyBrowse();
                      },
                    ),
              isDense: true,
            ),
          ),
          const SizedBox(height: LekisSpacing.sm),
          Wrap(
            spacing: LekisSpacing.sm,
            runSpacing: LekisSpacing.sm,
            children: [
              _FilterDropdown(
                label: RadioStrings.country,
                allLabel: RadioStrings.allCountries,
                value: _countryCode,
                options: countries,
                onChanged: (value) {
                  setState(() => _countryCode = value);
                  _applyBrowse();
                },
              ),
              _FilterDropdown(
                label: RadioStrings.language,
                allLabel: RadioStrings.allLanguages,
                value: _language,
                options: languages,
                onChanged: (value) {
                  setState(() => _language = value);
                  _applyBrowse();
                },
              ),
              _FilterDropdown(
                label: RadioStrings.tag,
                allLabel: RadioStrings.allTags,
                value: _tag,
                options: tags,
                onChanged: (value) {
                  setState(() => _tag = value);
                  _applyBrowse();
                },
              ),
            ],
          ),
          if (filters.hasError)
            Padding(
              padding: const EdgeInsets.only(top: LekisSpacing.xs),
              child: Text(
                RadioStrings.filterFailed,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: context.lekisColors.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTab(BuildContext context, int? currentTrackId) {
    return switch (_tab) {
      _RadioTab.popular => _buildPopular(context, currentTrackId),
      _RadioTab.favorites => _buildLocalList(
        context,
        ref.watch(radioFavoritesProvider),
        currentTrackId: currentTrackId,
        emptyTitle: RadioStrings.favoritesEmpty,
        emptyBody: RadioStrings.favoritesEmptyBody,
        onRetry: () => ref.invalidate(radioFavoritesProvider),
      ),
      _RadioTab.custom => _buildLocalList(
        context,
        ref.watch(radioCustomProvider),
        currentTrackId: currentTrackId,
        emptyTitle: RadioStrings.customEmpty,
        emptyBody: RadioStrings.customEmptyBody,
        onRetry: () => ref.invalidate(radioCustomProvider),
        deletable: true,
      ),
      _RadioTab.recent => _buildLocalList(
        context,
        ref.watch(radioRecentProvider),
        currentTrackId: currentTrackId,
        emptyTitle: RadioStrings.recentEmpty,
        emptyBody: RadioStrings.recentEmptyBody,
        onRetry: () => ref.invalidate(radioRecentProvider),
      ),
    };
  }

  Widget _buildPopular(BuildContext context, int? currentTrackId) {
    final browse = ref.watch(radioBrowseProvider);
    return browse.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => _ErrorState(error: error, onRetry: _applyBrowse),
      data: (state) {
        if (state.stations.isEmpty) {
          return _EmptyState(
            icon: Icons.radio_outlined,
            title: RadioStrings.popularEmpty,
            message: RadioStrings.popularEmptyBody,
            action: OutlinedButton.icon(
              onPressed: () {
                _search.clear();
                setState(() {
                  _countryCode = null;
                  _language = null;
                  _tag = null;
                });
                _applyBrowse();
              },
              icon: const Icon(Icons.filter_alt_off_rounded),
              label: Text(context.l10n.pick('清除筛选', 'Clear Filters')),
            ),
          );
        }
        return NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification.metrics.extentAfter < 400 &&
                state.hasMore &&
                !state.loadingMore) {
              _loadMore();
            }
            return false;
          },
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              pageGutterOf(context) - LekisSpacing.sm,
              LekisSpacing.xs,
              pageGutterOf(context) - LekisSpacing.sm,
              scrollEndPadding(context),
            ),
            itemCount: state.stations.length + (state.hasMore ? 1 : 0),
            itemBuilder: (context, index) {
              if (index >= state.stations.length) return _loadMoreRow(state);
              final station = state.stations[index];
              return RadioStationTile(
                station: station,
                playing: currentTrackId == -station.id,
                favorite: _favoriteOf(station),
                onPlay: () => _play(state.stations, index),
                onToggleFavorite: () => _toggleFavorite(station),
              );
            },
          ),
        );
      },
    );
  }

  Widget _loadMoreRow(RadioBrowseState state) {
    if (state.loadingMore) {
      return const Padding(
        padding: EdgeInsets.all(LekisSpacing.lg),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(LekisSpacing.md),
      child: Center(
        child: OutlinedButton.icon(
          onPressed: _loadMore,
          icon: const Icon(Icons.expand_more_rounded),
          label: Text(RadioStrings.loadMore),
        ),
      ),
    );
  }

  Widget _buildLocalList(
    BuildContext context,
    AsyncValue<List<RadioStationDto>> stations, {
    required int? currentTrackId,
    required String emptyTitle,
    required String emptyBody,
    required VoidCallback onRetry,
    bool deletable = false,
  }) {
    return stations.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => _ErrorState(error: error, onRetry: onRetry),
      data: (list) {
        if (list.isEmpty) {
          return _EmptyState(
            icon: deletable ? Icons.add_link_rounded : Icons.radio_outlined,
            title: emptyTitle,
            message: emptyBody,
            action: deletable
                ? FilledButton.tonalIcon(
                    onPressed: _addCustom,
                    icon: const Icon(Icons.add_rounded),
                    label: Text(RadioStrings.addCustom),
                  )
                : null,
          );
        }
        final query = _localSearch.text.trim().toLowerCase();
        final filtered = query.isEmpty
            ? list
            : [
                for (final station in list)
                  if (_matchesLocal(station, query)) station,
              ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                pageGutterOf(context),
                LekisSpacing.xs,
                pageGutterOf(context),
                LekisSpacing.sm,
              ),
              child: TextField(
                controller: _localSearch,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: RadioStrings.localSearchHint,
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: RadioStrings.clear,
                          icon: const Icon(Icons.close_rounded),
                          onPressed: _localSearch.clear,
                        ),
                  isDense: true,
                ),
              ),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? _EmptyState(
                      icon: Icons.search_off_rounded,
                      title: RadioStrings.noMatch,
                      message: RadioStrings.noMatchBody,
                      action: OutlinedButton.icon(
                        onPressed: _localSearch.clear,
                        icon: const Icon(Icons.close_rounded),
                        label: Text(RadioStrings.clearSearch),
                      ),
                    )
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.fromLTRB(
                        pageGutterOf(context) - LekisSpacing.sm,
                        LekisSpacing.xs,
                        pageGutterOf(context) - LekisSpacing.sm,
                        scrollEndPadding(context),
                      ),
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final station = filtered[index];
                        return RadioStationTile(
                          station: station,
                          playing: currentTrackId == -station.id,
                          favorite: _favoriteOf(station),
                          onPlay: () => _play(filtered, index),
                          onToggleFavorite: () => _toggleFavorite(station),
                          onDelete: deletable
                              ? () => _deleteCustom(station)
                              : null,
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _FilterDropdown extends StatelessWidget {
  const _FilterDropdown({
    required this.label,
    required this.allLabel,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final String allLabel;
  final String? value;
  final List<RadioFilterOptionDto> options;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 210,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: LekisSpacing.md,
            vertical: LekisSpacing.sm,
          ),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            isExpanded: true,
            value: value,
            hint: Text(allLabel),
            items: [
              DropdownMenuItem(value: '', child: Text(allLabel)),
              for (final option in options)
                DropdownMenuItem(
                  value: option.value,
                  child: Text(
                    option.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (next) =>
                onChanged(next == null || next.isEmpty ? null : next),
          ),
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return LekisEmptyState(
      eyebrow: RadioStrings.eyebrow,
      title: RadioStrings.loadFailed,
      message: '${describeCoreError(error)}\n${RadioStrings.networkHint}',
      maxWidth: 460,
      action: FilledButton.icon(
        onPressed: onRetry,
        icon: const Icon(Icons.refresh_rounded),
        label: Text(RadioStrings.retry),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return LekisEmptyState(
      eyebrow: RadioStrings.eyebrow,
      title: title,
      message: message,
      maxWidth: 460,
      action: action,
    );
  }
}

List<RadioFilterOptionDto> get _fallbackCountries => [
  RadioFilterOptionDto(
    name: L10n.tr('中国', 'China'),
    value: 'CN',
    stationCount: 0,
  ),
  RadioFilterOptionDto(
    name: L10n.tr('美国', 'United States'),
    value: 'US',
    stationCount: 0,
  ),
  RadioFilterOptionDto(
    name: L10n.tr('英国', 'United Kingdom'),
    value: 'GB',
    stationCount: 0,
  ),
  RadioFilterOptionDto(
    name: L10n.tr('日本', 'Japan'),
    value: 'JP',
    stationCount: 0,
  ),
  RadioFilterOptionDto(
    name: L10n.tr('德国', 'Germany'),
    value: 'DE',
    stationCount: 0,
  ),
  RadioFilterOptionDto(
    name: L10n.tr('法国', 'France'),
    value: 'FR',
    stationCount: 0,
  ),
  RadioFilterOptionDto(
    name: L10n.tr('加拿大', 'Canada'),
    value: 'CA',
    stationCount: 0,
  ),
  RadioFilterOptionDto(
    name: L10n.tr('澳大利亚', 'Australia'),
    value: 'AU',
    stationCount: 0,
  ),
  RadioFilterOptionDto(
    name: L10n.tr('韩国', 'South Korea'),
    value: 'KR',
    stationCount: 0,
  ),
  RadioFilterOptionDto(
    name: L10n.tr('台湾地区', 'Taiwan'),
    value: 'TW',
    stationCount: 0,
  ),
  RadioFilterOptionDto(
    name: L10n.tr('香港', 'Hong Kong'),
    value: 'HK',
    stationCount: 0,
  ),
  RadioFilterOptionDto(
    name: L10n.tr('新加坡', 'Singapore'),
    value: 'SG',
    stationCount: 0,
  ),
];

List<RadioFilterOptionDto> get _fallbackLanguages => [
  RadioFilterOptionDto(
    name: L10n.tr('中文', 'Chinese'),
    value: 'chinese',
    stationCount: 0,
  ),
  RadioFilterOptionDto(
    name: L10n.tr('英语', 'English'),
    value: 'english',
    stationCount: 0,
  ),
  RadioFilterOptionDto(
    name: L10n.tr('日语', 'Japanese'),
    value: 'japanese',
    stationCount: 0,
  ),
  RadioFilterOptionDto(
    name: L10n.tr('韩语', 'Korean'),
    value: 'korean',
    stationCount: 0,
  ),
  RadioFilterOptionDto(
    name: L10n.tr('西班牙语', 'Spanish'),
    value: 'spanish',
    stationCount: 0,
  ),
  RadioFilterOptionDto(
    name: L10n.tr('法语', 'French'),
    value: 'french',
    stationCount: 0,
  ),
  RadioFilterOptionDto(
    name: L10n.tr('德语', 'German'),
    value: 'german',
    stationCount: 0,
  ),
  RadioFilterOptionDto(
    name: L10n.tr('意大利语', 'Italian'),
    value: 'italian',
    stationCount: 0,
  ),
  RadioFilterOptionDto(
    name: L10n.tr('葡萄牙语', 'Portuguese'),
    value: 'portuguese',
    stationCount: 0,
  ),
  RadioFilterOptionDto(
    name: L10n.tr('俄语', 'Russian'),
    value: 'russian',
    stationCount: 0,
  ),
];

const _fallbackTags = [
  RadioFilterOptionDto(name: 'pop', value: 'pop', stationCount: 0),
  RadioFilterOptionDto(name: 'rock', value: 'rock', stationCount: 0),
  RadioFilterOptionDto(name: 'jazz', value: 'jazz', stationCount: 0),
  RadioFilterOptionDto(name: 'classical', value: 'classical', stationCount: 0),
  RadioFilterOptionDto(
    name: 'electronic',
    value: 'electronic',
    stationCount: 0,
  ),
  RadioFilterOptionDto(name: 'news', value: 'news', stationCount: 0),
  RadioFilterOptionDto(name: 'talk', value: 'talk', stationCount: 0),
  RadioFilterOptionDto(name: 'oldies', value: 'oldies', stationCount: 0),
  RadioFilterOptionDto(name: '80s', value: '80s', stationCount: 0),
  RadioFilterOptionDto(name: '90s', value: '90s', stationCount: 0),
  RadioFilterOptionDto(name: 'blues', value: 'blues', stationCount: 0),
  RadioFilterOptionDto(name: 'folk', value: 'folk', stationCount: 0),
  RadioFilterOptionDto(name: 'metal', value: 'metal', stationCount: 0),
  RadioFilterOptionDto(name: 'ambient', value: 'ambient', stationCount: 0),
];
