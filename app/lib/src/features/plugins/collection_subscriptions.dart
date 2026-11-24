import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust/api/core.dart' as core;

typedef OnlineCollection = ({String plugin, String path, String title});

final collectionSubscriptionsProvider =
    AsyncNotifierProvider<CollectionSubscriptions, List<OnlineCollection>>(
      CollectionSubscriptions.new,
      retry: (_, _) => null,
    );

class CollectionSubscriptions extends AsyncNotifier<List<OnlineCollection>> {
  static const _key = 'plugins.collectionSubscriptions';
  Future<void> _pending = Future.value();

  @override
  Future<List<OnlineCollection>> build() async {
    final raw = await core.getSetting(key: _key);
    if (raw == null || raw.isEmpty) return [];
    return [
      for (final item in jsonDecode(raw) as List)
        if (item case {
          'plugin': String plugin,
          'path': String path,
          'title': String title,
        })
          (plugin: plugin, path: path, title: title),
    ];
  }

  Future<void> setSubscribed(OnlineCollection item, bool subscribed) {
    final write = _pending.then((_) async {
      final current = await future;
      final updated = current
          .where((row) => row.plugin != item.plugin || row.path != item.path)
          .toList();
      if (subscribed) updated.add(item);
      await core.setSetting(
        key: _key,
        value: jsonEncode([
          for (final row in updated)
            {'plugin': row.plugin, 'path': row.path, 'title': row.title},
        ]),
      );
      state = AsyncData(updated);
    });
    _pending = write.catchError((Object _) {});
    return write;
  }
}
