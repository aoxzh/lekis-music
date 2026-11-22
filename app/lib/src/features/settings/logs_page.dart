// Diagnostic log viewer (SET-03). Shows the in-memory ring from the core;
// values after common secret keys are masked before they reach this page.
import 'package:flutter/services.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

import 'strings.dart';
import 'widgets/settings_widgets.dart';

class DiagnosticLogsPage extends StatefulWidget {
  const DiagnosticLogsPage({super.key});

  @override
  State<DiagnosticLogsPage> createState() => _DiagnosticLogsPageState();
}

class _DiagnosticLogsPageState extends State<DiagnosticLogsPage> {
  var _lines = <String>[];
  var _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final lines = core.recentLogs(limit: 1000);
    if (!mounted) return;
    setState(() {
      _lines = lines;
      _loading = false;
    });
  }

  Future<void> _clear() async {
    core.clearLogs();
    await _load();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _lines.join('\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.pick('日志已复制', 'Logs copied'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: SettingsStrings.diagnosticLogs,
      actions: [
        IconButton(
          tooltip: context.l10n.pick('复制', 'Copy'),
          onPressed: _lines.isEmpty ? null : _copy,
          icon: const Icon(Icons.copy_all_outlined),
        ),
        IconButton(
          tooltip: context.l10n.pick('清空', 'Clear'),
          onPressed: _lines.isEmpty ? null : _clear,
          icon: const Icon(Icons.delete_sweep_outlined),
        ),
        IconButton(
          tooltip: context.l10n.pick('刷新', 'Refresh'),
          onPressed: _load,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _lines.isEmpty
          ? Center(
              child: Text(
                context.l10n.pick('暂无日志', 'No logs yet'),
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: context.lekisColors.onSurfaceVariant),
              ),
            )
          : _LogPanel(lines: _lines),
    );
  }
}

/// 日志放在一块分组面板里：小号等宽字、可跨行选择，随页面一起滚动。
class _LogPanel extends StatelessWidget {
  const _LogPanel({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final gutter = pageGutterOf(context);
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      color: theme.colorScheme.onSurface,
    );
    return SelectionArea(
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              gutter,
              LekisSpacing.sm,
              gutter,
              scrollEndPadding(context),
            ),
            sliver: DecoratedSliver(
              decoration: settingsPanelDecoration(context),
              sliver: SliverPadding(
                padding: const EdgeInsets.symmetric(vertical: LekisSpacing.sm),
                sliver: SliverList.separated(
                  itemCount: lines.length,
                  separatorBuilder: (_, _) => const Divider(
                    height: 1,
                    indent: LekisSpacing.lg,
                    endIndent: LekisSpacing.lg,
                  ),
                  itemBuilder: (context, i) => Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: LekisSpacing.lg,
                      vertical: LekisSpacing.xs,
                    ),
                    child: Text(lines[i], style: style),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
