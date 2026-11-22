// 音源页：窄窗口是列表 + 推入详情 / 添加页；宽窗口是左右双栏（折叠屏按铰链切分）。
//
// 快捷键（桌面）：Ctrl+N 添加音源，F5 重新扫描当前选中的音源。

import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../layout/adaptive_two_pane.dart';
import '../../theme/tokens.dart';
import '../library/widgets/page_gutter.dart';
import 'common.dart';
import 'sources_providers.dart';
import 'strings.dart';
import 'widgets/add_source.dart';
import 'widgets/source_detail.dart';
import 'widgets/source_list.dart';

class SourcesPage extends ConsumerStatefulWidget {
  const SourcesPage({super.key});

  @override
  ConsumerState<SourcesPage> createState() => _SourcesPageState();
}

/// 宽窗口右栏显示什么。
sealed class _Selection {
  const _Selection();
}

final class _None extends _Selection {
  const _None();
}

final class _Adding extends _Selection {
  const _Adding();
}

final class _Source extends _Selection {
  const _Source(this.id);
  final int id;
}

class _SourcesPageState extends ConsumerState<SourcesPage> {
  _Selection _selection = const _None();

  void _open(int id) {
    if (!isWideLayout(context)) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _SourceDetailPage(sourceId: id),
        ),
      );
    } else {
      setState(() => _selection = _Source(id));
    }
  }

  Future<void> _add() async {
    if (!isWideLayout(context)) {
      final id = await Navigator.of(context).push<int>(
        MaterialPageRoute<int>(builder: (_) => const AddSourcePage()),
      );
      if (id != null && mounted) _open(id);
    } else {
      setState(() => _selection = const _Adding());
    }
  }

  void _rescanSelected() {
    final s = _selection;
    if (s is _Source) rescanWithFeedback(context, ref, s.id);
  }

  @override
  Widget build(BuildContext context) {
    final compact = context.isCompactWidth;
    final twoPane = isWideLayout(context);
    final hasSources = ref
        .watch(sourcesProvider)
        .maybeWhen(data: (items) => items.isNotEmpty, orElse: () => false);
    final selection = _selection;
    final selectedId = selection is _Source ? selection.id : null;

    final list = SourceList(
      selectedId: twoPane ? selectedId : null,
      onOpen: _open,
      onAdd: _add,
      // Room for the extended FAB below the last row on phones.
      bottomClearance: compact && hasSources
          ? LekisSizes.touchTargetMin + LekisSpacing.xl
          : 0,
    );

    final Widget body = !twoPane
        ? list
        : AdaptiveTwoPane(
            primaryFraction: 0.38,
            primary: list,
            secondary: switch (selection) {
              _None() => const _Placeholder(),
              _Adding() => AddSourcePane(
                onDone: (id) => setState(() => _selection = _Source(id)),
                onCancel: () => setState(() => _selection = const _None()),
              ),
              _Source(:final id) => SourceDetail(
                key: ValueKey(id),
                sourceId: id,
                onDeleted: () => setState(() => _selection = const _None()),
              ),
            },
          );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): _add,
        const SingleActivator(LogicalKeyboardKey.f5): _rescanSelected,
      },
      child: FocusScope(
        autofocus: true,
        child: Scaffold(
          body: SafeArea(
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(onAdd: compact ? null : _add),
                Expanded(child: body),
              ],
            ),
          ),
          floatingActionButton: compact && hasSources
              ? Padding(
                  // The shell may float its mini player / tab bar over the
                  // page and report them in MediaQuery.padding (not
                  // viewPadding, which is all Scaffold keeps the FAB above).
                  padding: EdgeInsets.only(
                    bottom: math.max(
                      0,
                      MediaQuery.paddingOf(context).bottom -
                          MediaQuery.viewPaddingOf(context).bottom,
                    ),
                  ),
                  child: FloatingActionButton.extended(
                    onPressed: _add,
                    icon: const Icon(Icons.add),
                    label: Text(SourcesStrings.addSource),
                  ),
                )
              : null,
        ),
      ),
    );
  }
}

/// Page title (+ "add" on wider windows), laid out like the library header
/// so switching tabs does not shift the title.
class _Header extends StatelessWidget {
  const _Header({required this.onAdd});

  /// `null` → no button (phones use the floating action button).
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final gutter = pageGutterOf(context);
    final add = onAdd;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        LekisSpacing.lg,
        gutter,
        LekisSpacing.md,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: LekisSizes.touchTargetMin),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  SourcesStrings.title,
                  style: Theme.of(context).textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ),
            if (add != null)
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, LekisSizes.touchTargetMin),
                ),
                onPressed: add,
                icon: const Icon(Icons.add),
                label: Text(SourcesStrings.addSource),
              ),
          ],
        ),
      ),
    );
  }
}

class _SourceDetailPage extends StatelessWidget {
  const _SourceDetailPage({required this.sourceId});
  final int sourceId;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(),
    body: SourceDetail(sourceId: sourceId),
  );
}

class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: EdgeInsets.all(context.featureGutter),
      child: Text(
        SourcesStrings.selectHint,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium
            ?.copyWith(color: context.lekisColors.onSurfaceVariant),
      ),
    ),
  );
}
