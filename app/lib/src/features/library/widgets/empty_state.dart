import 'package:flutter/foundation.dart';
import 'package:lekis/src/features/plugins/plugins_page.dart';
import 'package:lekis/src/features/plugins/strings.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/error.dart';
import 'package:lekis/src/shell/app_shell.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:lekis/src/widgets/brand_mark.dart';
import 'package:material_ui/material_ui.dart';

/// Shared empty / first-run state: a quiet moonrise instead of a bare icon.
class LekisEmptyState extends StatelessWidget {
  const LekisEmptyState({
    super.key,
    required this.title,
    this.message = '',
    this.eyebrow,
    this.action,
    this.maxWidth = 420,
  });

  final String title;
  final String message;
  final String? eyebrow;
  final Widget? action;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(LekisSpacing.xl),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _Moonrise(),
              if (eyebrow != null) ...[
                const SizedBox(height: LekisSpacing.xl),
                Text(
                  eyebrow!.toUpperCase(),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colors.moon,
                    letterSpacing: 1.6,
                  ),
                ),
              ],
              const SizedBox(height: LekisSpacing.sm),
              Text(
                title,
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: theme.colorScheme.onSurface,
                ),
                textAlign: TextAlign.center,
              ),
              if (message.isNotEmpty) ...[
                const SizedBox(height: LekisSpacing.md),
                Text(
                  message,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                    height: 1.55,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
              if (action != null) ...[
                const SizedBox(height: LekisSpacing.xl),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Just the brand mark: no halo, frame or badges around it. Static, so it
/// costs nothing to keep on screen.
class _Moonrise extends StatelessWidget {
  const _Moonrise();

  /// Side of the mark in empty states.
  static const double size = 104;

  @override
  Widget build(BuildContext context) => const LekisBrandMark(
    key: ValueKey('empty-state.mark'),
    size: size,
    ring: false,
  );
}

class LibraryEmptyState extends StatelessWidget {
  const LibraryEmptyState({super.key, this.title, this.message});

  final String? title;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return LekisEmptyState(
      eyebrow: l10n.pick('开始使用', 'Get Started'),
      title: title ?? l10n.pick('资料库还是空的', 'Your Library Is Empty'),
      message:
          message ??
          l10n.pick(
            '在“音源”里添加本地文件夹、NAS 共享或媒体服务器，Lekis 会自动建立索引。',
            'Add a local folder, NAS share, or media server in Sources and Lekis will index it automatically.',
          ),
      action: Wrap(
        alignment: WrapAlignment.center,
        spacing: LekisSpacing.sm,
        runSpacing: LekisSpacing.sm,
        children: [
          FilledButton.icon(
            onPressed: () => AppShell.select(context, LekisDestination.sources),
            icon: const Icon(Icons.add_rounded),
            label: Text(l10n.pick('添加音源', 'Add Source')),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.extension_outlined),
            label: Text(PluginStrings.importSource),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const PluginsPage()),
            ),
          ),
        ],
      ),
    );
  }
}

/// Generic error with retry.
class LoadErrorView extends StatelessWidget {
  const LoadErrorView({super.key, required this.error, this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final l10n = context.l10n;
    final detail = error is CoreError
        ? (kDebugMode
              ? '${(error as CoreError).kind.name}: ${(error as CoreError).detail}'
              : l10n.pick('核心返回了错误', 'Core returned an error'))
        : '$error';
    debugPrint('load failed: $detail');
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(LekisSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded, color: colors.danger),
            const SizedBox(height: LekisSpacing.sm),
            Text(
              l10n.pick('加载失败', 'Load Failed'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: LekisSpacing.xs),
            Text(
              detail,
              textAlign: TextAlign.center,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: LekisSpacing.md),
              OutlinedButton(
                onPressed: onRetry,
                child: Text(l10n.pick('重试', 'Retry')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
