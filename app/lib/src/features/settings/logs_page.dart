// Diagnostic log viewer (SET-03). Shows the in-memory ring from the core;
// values after common secret keys are masked before they reach this page.
import 'package:flutter/services.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('日志已复制')));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('诊断日志'),
        actions: [
          IconButton(
            tooltip: '复制',
            onPressed: _lines.isEmpty ? null : _copy,
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(
            tooltip: '清空',
            onPressed: _lines.isEmpty ? null : _clear,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _lines.isEmpty
          ? const Center(child: Text('暂无日志'))
          : SelectionArea(
              child: ListView.separated(
                padding: const EdgeInsets.all(LekisSpacing.lg),
                itemCount: _lines.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, color: Colors.black12),
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: SelectableText(
                    _lines[i],
                    style: text.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
