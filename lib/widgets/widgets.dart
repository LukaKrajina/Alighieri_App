import 'package:flutter/material.dart';

import '../state/strings.dart';
import '../src/rust/domain/view.dart';

/* ------------------------- 通用面板 ------------------------- */

class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(padding: padding, child: child),
    );
  }
}

class SectionHeading extends StatelessWidget {
  const SectionHeading({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}

/// 空状态。
///
/// 站内刻意不预置作品，所以「空的」是真实状态 —— 空状态得讲道理，
/// 只画一个图标等于什么也没说。
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.title, this.body, this.action});

  final String title;
  final String? body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          if (body != null) ...[
            const SizedBox(height: 8),
            Text(
              body!,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
          if (action != null) const SizedBox(height: 16),
          ?action,
        ],
      ),
    );
  }
}

/* ------------------------- 作品卡片 ------------------------- */

/// 文字卡片。
///
/// 本站不做封面（参照 kakuyomu）：信息层级是
/// 「书名 › 醒目语 › 分类标签 › 统计数字」—— 没有封面，文字就得自己撑场面。
class NovelCardTile extends StatelessWidget {
  const NovelCardTile({
    super.key,
    required this.novel,
    required this.locale,
    this.onTap,
    this.rank,
    this.showPv = false,
  });

  final NovelCard novel;
  final String locale;
  final VoidCallback? onTap;
  final int? rank;

  /// 榜单卡片显示 PV 维度；普通列表不显示，避免每个地方都堆统计数字。
  final bool showPv;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (rank != null) ...[
                    Container(
                      width: 28,
                      height: 28,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: rank! <= 3
                            ? cs.secondaryContainer
                            : cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '$rank',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Text(
                      novel.title,
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (novel.flagged)
                    Tooltip(
                      message: tr(locale, 'review.title'),
                      child: Icon(
                        Icons.flag_outlined,
                        size: 16,
                        color: cs.error,
                      ),
                    ),
                ],
              ),
              if (novel.tagline.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  novel.tagline,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _chip(context, novel.genreName),
                  _chip(context, tr(locale, 'status.${novel.status}')),
                  for (final tag in novel.tags.take(3)) _chip(context, tag),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      novel.authorName,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ),
                  Text(
                    '${novel.episodes}${tr(locale, 'common.chapters')} · ${novel.words}${tr(locale, 'common.words')}',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
              if (showPv) ...[
                const SizedBox(height: 6),
                Text(
                  '${tr(locale, 'pv.total')} ${novel.pvTotal} · '
                  '${tr(locale, 'pv.weekly')} ${novel.pvWeekly}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
              if (novel.progressNo > 0) ...[
                const SizedBox(height: 6),
                Text(
                  tr(locale, 'shelf.progress', {'n': novel.progressNo}),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(BuildContext context, String label) {
    return Chip(
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      label: Text(label),
    );
  }
}

/* ------------------------- 小工具 ------------------------- */

String relTime(String locale, int atMs, int nowMs) {
  if (atMs <= 0) return '';
  final diff = nowMs - atMs;
  final sec = (diff.abs() + 500) ~/ 1000;
  final min = sec ~/ 60;
  final hour = min ~/ 60;
  final day = hour ~/ 24;
  final month = day ~/ 30;
  final year = month ~/ 12;
  if (year >= 1) return tr(locale, 'common.yearsAgo', {'n': year});
  if (month >= 1) return tr(locale, 'common.monthsAgo', {'n': month});
  if (day >= 1) return tr(locale, 'common.daysAgo', {'n': day});
  if (hour >= 1) return tr(locale, 'common.hoursAgo', {'n': hour});
  if (min >= 1) return tr(locale, 'common.minutesAgo', {'n': min});
  return tr(locale, 'common.justNow');
}

/// 报告一条错误。Rust 侧的错误是 `Result` 的字符串，直接显示即可。
void showError(BuildContext context, Object e) {
  final locale = Localizations.localeOf(context).languageCode;
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text('${tr(locale, 'error.prefix')}$e')));
}

Color badgeColor(BuildContext context, String tier) {
  final cs = Theme.of(context).colorScheme;
  return switch (tier) {
    'gold' => const Color(0xFFB8862F),
    'silver' => const Color(0xFF7C8880),
    'special' => cs.secondary,
    _ => const Color(0xFF9A6435),
  };
}

/// 老版本 / 别的客户端可能把章节标题写成 `__first__` 或 `__chapter__:3`。
/// 这是内部哨兵，绝不该原样显示给读者。
String chapterTitleLabel(
  String Function(String, [Map<String, Object>?]) t,
  String title,
  int no,
) {
  if (title == '__first__') return t('chapter.first');
  if (title.startsWith('__chapter__:')) {
    final n = int.tryParse(title.substring('__chapter__:'.length)) ?? no;
    return t('post.chapterTitleAuto', {'n': n});
  }
  if (title.trim().isEmpty) return t('post.chapterTitleAuto', {'n': no});
  return title;
}
