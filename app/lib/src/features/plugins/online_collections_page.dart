import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_l10n.dart';
import '../sources/common.dart';
import 'collection_subscriptions.dart';
import 'plugin_browse_page.dart';
import 'plugins_providers.dart';

class OnlineCollectionsPage extends ConsumerWidget {
  const OnlineCollectionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plugins = ref.watch(pluginListProvider);
    final saved = ref.watch(collectionSubscriptionsProvider);
    final l10n = context.l10n;
    final sources = (plugins.value ?? [])
        .where(
          (plugin) =>
              plugin.enabled &&
              plugin.error == null &&
              plugin.kinds.contains('source'),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(title: Text(l10n.pick('在线歌单与榜单', 'Online collections'))),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          ListTile(title: Text(l10n.pick('我的订阅', 'Subscriptions'))),
          if (saved.isLoading) const LinearProgressIndicator(),
          if (saved.hasError) Text(describeCoreError(saved.error!)),
          if (saved.hasValue && saved.value!.isEmpty)
            ListTile(
              subtitle: Text(
                l10n.pick(
                  '打开音源里的歌单或榜单即可订阅。',
                  'Open a collection from a source to subscribe.',
                ),
              ),
            ),
          for (final item in saved.value ?? <OnlineCollection>[])
            ListTile(
              leading: const Icon(Icons.bookmark_outlined),
              title: Text(item.title),
              subtitle: Text(
                sources.where((p) => p.id == item.plugin).firstOrNull?.name ??
                    (plugins.hasValue
                        ? l10n.pick('音源未启用或已移除', 'Source disabled or removed')
                        : item.plugin),
              ),
              onTap: sources.any((p) => p.id == item.plugin)
                  ? () => Navigator.of(context).push(
                      PluginBrowsePage.route(
                        item.plugin,
                        item.title,
                        path: item.path,
                      ),
                    )
                  : null,
              trailing: IconButton(
                tooltip: l10n.pick('取消订阅', 'Unsubscribe'),
                icon: const Icon(Icons.bookmark_remove_outlined),
                onPressed: () async {
                  try {
                    await ref
                        .read(collectionSubscriptionsProvider.notifier)
                        .setSubscribed(item, false);
                  } catch (error) {
                    if (context.mounted) {
                      showFeatureSnack(context, describeCoreError(error));
                    }
                  }
                },
              ),
            ),
          const Divider(),
          ListTile(title: Text(l10n.pick('浏览音源目录', 'Browse source catalogs'))),
          if (plugins.isLoading) const LinearProgressIndicator(),
          if (plugins.hasError) Text(describeCoreError(plugins.error!)),
          if (plugins.hasValue && sources.isEmpty)
            ListTile(
              subtitle: Text(
                l10n.pick(
                  '在插件设置中启用音乐来源后可在这里浏览。',
                  'Enable a music source in plugin settings to browse here.',
                ),
              ),
            ),
          for (final plugin in sources)
            ListTile(
              leading: const Icon(Icons.library_music_outlined),
              title: Text(plugin.name),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () =>
                  Navigator.of(context)
                      .push(PluginBrowsePage.route(plugin.id, plugin.name)),
            ),
        ],
      ),
    );
  }
}
