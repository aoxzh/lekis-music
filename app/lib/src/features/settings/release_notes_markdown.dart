// 轻量级 GitHub Release Notes Markdown 渲染器（零外部依赖）。
//
// 支持标题（#..####）、无序 / 有序列表、分割线（---）、Markdown 表格、
// 以及行内加粗（**...**）、斜体（*...*）、行内代码（`...`）和可点击链接（[text](url)）。

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

/// 将 Release 说明中的 Markdown 渲染为贴合 Material 3 主题的富文本块。
class ReleaseNotesMarkdown extends StatelessWidget {
  const ReleaseNotesMarkdown({
    super.key,
    required this.data,
    required this.onOpenLink,
  });

  final String data;
  final Future<void> Function(String url) onOpenLink;

  @override
  Widget build(BuildContext context) {
    final blocks = _parseBlocks(data);
    final widgets = <Widget>[];
    for (var i = 0; i < blocks.length; i++) {
      if (i > 0) widgets.add(SizedBox(height: blocks[i].topSpacing));
      widgets.add(_buildBlock(context, blocks[i]));
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: widgets,
    );
  }

  Widget _buildBlock(BuildContext context, _MdBlock block) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bodyStyle = theme.textTheme.bodyMedium?.copyWith(height: 1.5);

    switch (block) {
      case _MdHeading(:final level, :final text):
        final style = switch (level) {
          1 => theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          2 => theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: scheme.primary,
          ),
          _ => theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        };
        return _InlineMarkdownText(
          text: text,
          baseStyle: style,
          onOpenLink: onOpenLink,
        );
      case _MdDivider():
        return Divider(
          height: 16,
          color: scheme.outlineVariant.withValues(alpha: 0.6),
        );
      case _MdListItem(:final marker, :final text, :final indent):
        return Padding(
          padding: EdgeInsets.only(left: indent * 14.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: marker == '•' ? 14 : 22,
                child: Text(
                  marker,
                  style: bodyStyle?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Expanded(
                child: _InlineMarkdownText(
                  text: text,
                  baseStyle: bodyStyle,
                  onOpenLink: onOpenLink,
                ),
              ),
            ],
          ),
        );
      case _MdTable(:final headers, :final rows):
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.6),
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Table(
              defaultColumnWidth: const IntrinsicColumnWidth(),
              border: TableBorder.symmetric(
                inside: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.35),
                ),
              ),
              children: [
                TableRow(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                  ),
                  children: [
                    for (final cell in headers)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        child: _InlineMarkdownText(
                          text: cell,
                          baseStyle: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                          onOpenLink: onOpenLink,
                        ),
                      ),
                  ],
                ),
                for (final row in rows)
                  TableRow(
                    children: [
                      for (var col = 0; col < headers.length; col++)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          child: _InlineMarkdownText(
                            text: col < row.length ? row[col] : '',
                            baseStyle: theme.textTheme.bodySmall,
                            onOpenLink: onOpenLink,
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        );
      case _MdParagraph(:final text):
        return _InlineMarkdownText(
          text: text,
          baseStyle: bodyStyle,
          onOpenLink: onOpenLink,
        );
    }
  }
}

sealed class _MdBlock {
  const _MdBlock();
  double get topSpacing => 6;
}

final class _MdHeading extends _MdBlock {
  const _MdHeading(this.level, this.text);
  final int level;
  final String text;
  @override
  double get topSpacing => level <= 2 ? 12 : 8;
}

final class _MdDivider extends _MdBlock {
  const _MdDivider();
  @override
  double get topSpacing => 8;
}

final class _MdListItem extends _MdBlock {
  const _MdListItem(this.marker, this.text, this.indent);
  final String marker;
  final String text;
  final int indent;
  @override
  double get topSpacing => 4;
}

final class _MdTable extends _MdBlock {
  const _MdTable(this.headers, this.rows);
  final List<String> headers;
  final List<List<String>> rows;
  @override
  double get topSpacing => 8;
}

final class _MdParagraph extends _MdBlock {
  const _MdParagraph(this.text);
  final String text;
  @override
  double get topSpacing => 6;
}

List<_MdBlock> _parseBlocks(String raw) {
  final lines = raw.replaceAll('\r\n', '\n').split('\n');
  final blocks = <_MdBlock>[];
  final headingRe = RegExp(r'^(#{1,4})\s+(.+)$');
  final dividerRe = RegExp(r'^(\s*[-*_]\s*){3,}$');
  final bulletRe = RegExp(r'^(\s*)[-*+]\s+(.+)$');
  final orderedRe = RegExp(r'^(\s*)(\d+\.)\s+(.+)$');
  final tableSepRe = RegExp(r'^\|?(\s*:?-{2,}:?\s*\|)+\s*:?-{2,}:?\s*\|?$');

  List<String> splitRow(String line) {
    var trimmed = line.trim();
    if (trimmed.startsWith('|')) trimmed = trimmed.substring(1);
    if (trimmed.endsWith('|')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    return [for (final cell in trimmed.split('|')) cell.trim()];
  }

  var i = 0;
  final paraBuf = <String>[];
  void flushParagraph() {
    if (paraBuf.isEmpty) return;
    blocks.add(_MdParagraph(paraBuf.join(' ').trim()));
    paraBuf.clear();
  }

  while (i < lines.length) {
    final line = lines[i];
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      flushParagraph();
      i++;
      continue;
    }
    if (dividerRe.hasMatch(trimmed)) {
      flushParagraph();
      blocks.add(const _MdDivider());
      i++;
      continue;
    }
    final h = headingRe.firstMatch(trimmed);
    if (h != null) {
      flushParagraph();
      blocks.add(_MdHeading(h.group(1)!.length, h.group(2)!.trim()));
      i++;
      continue;
    }
    if (trimmed.contains('|') &&
        i + 1 < lines.length &&
        tableSepRe.hasMatch(lines[i + 1].trim())) {
      flushParagraph();
      final headers = splitRow(trimmed);
      i += 2;
      final rows = <List<String>>[];
      while (i < lines.length && lines[i].trim().contains('|')) {
        final r = lines[i].trim();
        if (r.isEmpty) break;
        rows.add(splitRow(r));
        i++;
      }
      blocks.add(_MdTable(headers, rows));
      continue;
    }
    final b = bulletRe.firstMatch(line);
    if (b != null) {
      flushParagraph();
      final indent = (b.group(1)!.length / 2).floor().clamp(0, 3);
      blocks.add(_MdListItem('•', b.group(2)!.trim(), indent));
      i++;
      continue;
    }
    final o = orderedRe.firstMatch(line);
    if (o != null) {
      flushParagraph();
      final indent = (o.group(1)!.length / 2).floor().clamp(0, 3);
      blocks.add(_MdListItem(o.group(2)!, o.group(3)!.trim(), indent));
      i++;
      continue;
    }
    paraBuf.add(trimmed);
    i++;
  }
  flushParagraph();
  return blocks;
}

class _InlineMarkdownText extends StatefulWidget {
  const _InlineMarkdownText({
    required this.text,
    required this.baseStyle,
    required this.onOpenLink,
  });

  final String text;
  final TextStyle? baseStyle;
  final Future<void> Function(String url) onOpenLink;

  @override
  State<_InlineMarkdownText> createState() => _InlineMarkdownTextState();
}

class _InlineMarkdownTextState extends State<_InlineMarkdownText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  List<InlineSpan> _parseInline(BuildContext context, String input) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    final scheme = Theme.of(context).colorScheme;
    final tokenRe = RegExp(
      r'\[([^\]]+)\]\((https?://[^)\s]+)\)'
      r'|\*\*([^*]+)\*\*'
      r'|__([^_]+)__'
      r'|`([^`]+)`'
      r'|\*([^*]+)\*',
    );
    final spans = <InlineSpan>[];
    var cursor = 0;

    for (final match in tokenRe.allMatches(input)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: input.substring(cursor, match.start)));
      }
      if (match.group(1) != null && match.group(2) != null) {
        final label = match.group(1)!;
        final url = match.group(2)!;
        final recognizer = TapGestureRecognizer()
          ..onTap = () => widget.onOpenLink(url);
        _recognizers.add(recognizer);
        spans.add(
          TextSpan(
            text: label,
            recognizer: recognizer,
            style: TextStyle(
              color: scheme.primary,
              decoration: TextDecoration.underline,
              decorationColor: scheme.primary,
            ),
          ),
        );
      } else if (match.group(3) != null || match.group(4) != null) {
        spans.add(
          TextSpan(
            text: match.group(3) ?? match.group(4),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        );
      } else if (match.group(5) != null) {
        spans.add(
          TextSpan(
            text: ' ${match.group(5)!} ',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: (widget.baseStyle?.fontSize ?? 14) * 0.88,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
        );
      } else if (match.group(6) != null) {
        spans.add(
          TextSpan(
            text: match.group(6),
            style: const TextStyle(fontStyle: FontStyle.italic),
          ),
        );
      }
      cursor = match.end;
    }

    if (cursor < input.length) {
      spans.add(TextSpan(text: input.substring(cursor)));
    }
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        style: widget.baseStyle,
        children: _parseInline(context, widget.text),
      ),
    );
  }
}
