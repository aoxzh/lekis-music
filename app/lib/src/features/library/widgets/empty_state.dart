import 'package:flutter/foundation.dart';
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

/// The brand mark over a soft halo; static, so it costs nothing to keep on
/// screen and degrades gracefully with reduced motion.
class _Moonrise extends StatelessWidget {
  const _Moonrise();

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    return SizedBox(
      width: 190,
      height: 158,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    colors.moon.withValues(alpha: 0.18),
                    colors.accentSoft.withValues(alpha: 0.22),
                    colors.accentSoft.withValues(alpha: 0),
                  ],
                  stops: const [0, 0.45, 1],
                ),
              ),
            ),
          ),
          const LekisBrandMark(size: 104, ring: false),
          Positioned(
            right: 24,
            top: 22,
            child: _Star(size: 6, color: colors.moon.withValues(alpha: 0.6)),
          ),
          Positioned(
            left: 28,
            bottom: 24,
            child: _Star(size: 4, color: colors.aurora.withValues(alpha: 0.65)),
          ),
          Positioned(
            left: 16,
            top: 36,
            child: _Star(
              size: 3,
              color: colors.onSurfaceVariant.withValues(alpha: 0.45),
            ),
          ),
        ],
      ),
    );
  }
}

class _Star extends StatelessWidget {
  const _Star({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    child: SizedBox.square(dimension: size),
  );
}

class LibraryEmptyState extends StatelessWidget {
  const LibraryEmptyState({
    super.key,
    this.title = '资料库还是空的',
    this.message = '在“音源”里添加本地文件夹、NAS 共享或媒体服务器，Lekis 会自动建立索引。',
  });

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return LekisEmptyState(
      eyebrow: '开始使用',
      title: title,
      message: message,
      action: FilledButton.icon(
        onPressed: () => AppShell.select(context, LekisDestination.sources),
        icon: const Icon(Icons.add_rounded),
        label: const Text('添加音源'),
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
    final detail = error is CoreError
        ? (kDebugMode
              ? '${(error as CoreError).kind.name}: ${(error as CoreError).detail}'
              : '核心返回了错误')
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
            Text('加载失败', style: Theme.of(context).textTheme.titleMedium),
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
              OutlinedButton(onPressed: onRetry, child: const Text('重试')),
            ],
          ],
        ),
      ),
    );
  }
}
