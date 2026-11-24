import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/queue_move_next.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

class QueueFilter extends ConsumerWidget {
  const QueueFilter({
    super.key,
    required this.controller,
    this.focusNode,
    required this.child,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(
      playbackProvider.select(
        (state) => (state.queueVersion, state.queueLength),
      ),
    );
    return ValueListenableBuilder(
      valueListenable: controller,
      child: child,
      builder: (context, value, unfiltered) {
        final query = value.text.trim().toLowerCase();
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: LekisSpacing.sm),
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  labelText: context.l10n.pick('筛选队列', 'Filter queue'),
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: value.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: context.l10n.pick('清除筛选', 'Clear filter'),
                          onPressed: controller.clear,
                          icon: const Icon(Icons.clear_rounded),
                        ),
                ),
              ),
            ),
            Expanded(
              child: query.isEmpty
                  ? unfiltered!
                  : _QueueMatches(
                      key: ValueKey(queue),
                      query: query,
                      length: queue.$2,
                      version: queue.$1,
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _QueueMatches extends ConsumerStatefulWidget {
  const _QueueMatches({
    required super.key,
    required this.query,
    required this.length,
    required this.version,
  });

  final String query;
  final int length;
  final int version;

  @override
  ConsumerState<_QueueMatches> createState() => _QueueMatchesState();
}

class _QueueMatchesState extends ConsumerState<_QueueMatches> {
  final _rows = <({int id, String title, String artist})>[];
  final _matches = <int>[];
  late StreamSubscription<List<TrackRowDto>> _scan;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    _scan = queuePages(widget.length).listen(
      (rows) {
        setState(() {
          final offset = _rows.length;
          for (final row in rows) {
            _rows.add((id: row.id, title: row.title, artist: row.artistLine));
          }
          _matchFrom(offset);
        });
      },
      onDone: () => setState(() => _loading = false),
      onError: (Object error) => setState(() {
        _failed = true;
        _loading = false;
      }),
      cancelOnError: true,
    );
  }

  void _matchFrom(int offset) {
    for (var index = offset; index < _rows.length; index++) {
      final row = _rows[index];
      if (row.title.toLowerCase().contains(widget.query) ||
          row.artist.toLowerCase().contains(widget.query)) {
        _matches.add(index);
      }
    }
  }

  @override
  void didUpdateWidget(_QueueMatches oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) {
      _matches.clear();
      _matchFrom(0);
    }
  }

  @override
  void dispose() {
    _scan.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(
      playbackProvider.select((state) => state.queueIndex),
    );
    if (_failed) {
      return Center(
        child: TextButton(
          onPressed: () {
            setState(() {
              _failed = false;
              _loading = true;
              _rows.clear();
              _matches.clear();
            });
            _start();
          },
          child: Text(
            context.l10n.pick('队列加载失败，重试', 'Failed to load queue. Retry'),
          ),
        ),
      );
    }
    if (!_loading && _matches.isEmpty) {
      return Center(
        child: Text(context.l10n.pick('没有匹配的曲目', 'No matching tracks')),
      );
    }
    return Column(
      children: [
        if (_loading) const LinearProgressIndicator(),
        Expanded(
          child: ListView.builder(
            key: ValueKey(widget.query),
            itemCount: _matches.length,
            itemBuilder: (context, resultIndex) {
              final index = _matches[resultIndex];
              final row = _rows[index];
              final move = queueMoveToNext(ref, index);
              return ListTile(
                key: ValueKey('queue-filter.row-$index'),
                selected: index == current,
                leading: Text('${index + 1}'),
                title: Text(
                  row.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  row.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  if (ref.read(playbackProvider).queueVersion ==
                      widget.version) {
                    ref
                        .read(playerActionsProvider)
                        .playQueueAt(
                          index,
                          loadedIds: _rows.map((row) => row.id),
                        );
                  }
                },
                trailing: move == null
                    ? null
                    : IconButton(
                        tooltip: moveToNextLabel(context),
                        icon: const Icon(Icons.queue_play_next_rounded),
                        onPressed: move,
                      ),
              );
            },
          ),
        ),
      ],
    );
  }
}
