import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../src/rust/api.dart';
import '../src/rust/domain/view.dart';
import '../state/app_state.dart';
import '../widgets/widgets.dart';
import 'novel_page.dart';

/// 联邦审查队列。
///
/// 这里**没有「处理」按钮**：举报不能从任何设备上删掉内容，
/// 它只改变读者本机的可见性。票数按身份去重，不过批量生成新身份这件事，谁也挡不住。
/// 页面结构与 Web 的 /review 对齐：头部统计、本机阈值、全部/我的两个
/// 标签、按作品聚合的可展开明细，以及「诚实的边界」说明。
class ReviewPage extends StatefulWidget {
  const ReviewPage({super.key});

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  static const _options = [0, 1, 2, 3, 5, 10];
  static const _categories = ['spam', 'illegal', 'copyright', 'hate', 'other'];

  String _tab = 'all';
  final Set<String> _open = {};

  /// 给一个身份背书（互证后才进入信任圈）—— 单方面点头不算数。
  Future<void> _attestDialog(BuildContext context) async {
    final state = context.read<AppState>();
    final t = state.t;
    final peer = TextEditingController();
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('trust.attest')),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: peer,
                decoration: InputDecoration(labelText: 'peerId'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: note,
                decoration: InputDecoration(
                  labelText: '${t('identity.editProfile')} (${t('common.optional')})',
                ),
              ),
              const SizedBox(height: 12),
              Text(
                t('trust.attestHint'),
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t('common.confirm')),
          ),
        ],
      ),
    );
    final target = peer.text.trim();
    peer.dispose();
    note.dispose();
    if (ok != true || target.isEmpty || !context.mounted) return;
    if (target == state.identity?.peerId) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t('trust.attestSelf'))));
      return;
    }
    try {
      await state.attest(target, note.text.trim().isEmpty ? null : note.text);
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t('trust.attestDone'))));
    } catch (e) {
      if (!context.mounted) return;
      final msg = e.toString().contains('attest-self')
          ? t('trust.attestSelf')
          : t('trust.attestInvalid');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    final me = state.identity?.peerId ?? '';
    final threshold = state.settings.reviewThreshold;

    final novelById = {for (final n in state.latest) n.id: n};
    final grouped = <String, List<ReportCard>>{};
    for (final r in state.reports) {
      grouped.putIfAbsent(r.novelId, () => []).add(r);
    }
    final groups = grouped.entries
        .map((e) {
          final reports = [...e.value]
            ..sort((a, b) => b.atMs.compareTo(a.atMs));
          final mine = reports.any((r) => me.isNotEmpty && r.reporter == me);
          final flagged = threshold > 0 && reports.length >= threshold;
          return (
            novelId: e.key,
            reports: reports,
            novel: novelById[e.key],
            mine: mine,
            flagged: flagged,
          );
        })
        .toList()
      ..sort((a, b) {
        final byCount = b.reports.length.compareTo(a.reports.length);
        if (byCount != 0) return byCount;
        return a.novelId.compareTo(b.novelId);
      });

    final shown = _tab == 'mine'
        ? groups.where((g) => g.mine).toList()
        : groups;
    final myReports = state.reports
        .where((r) => me.isNotEmpty && r.reporter == me)
        .length;
    final flaggedCount = groups.where((g) => g.flagged).length;

    return Scaffold(
      appBar: AppBar(title: Text(t('review.page.title'))),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.verified_user_outlined,
                                size: 22,
                                color: cs.primary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  t('review.page.title'),
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleLarge
                                      ?.copyWith(fontWeight: FontWeight.w900),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            t('review.page.sub'),
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.7,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 14),
                          LayoutBuilder(
                            builder: (context, box) {
                              final columns = box.maxWidth >= 520 ? 3 : 1;
                              final width =
                                  (box.maxWidth - (columns - 1) * 10) / columns;
                              final items = [
                                (
                                  t('review.page.stat.total'),
                                  '${groups.length}',
                                  cs.onSurface,
                                ),
                                (
                                  t('review.page.stat.flagged'),
                                  '$flaggedCount',
                                  cs.error,
                                ),
                                (
                                  t('review.page.stat.mine'),
                                  '$myReports',
                                  cs.onSurface,
                                ),
                              ];
                              return Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                children: [
                                  for (final item in items)
                                    SizedBox(
                                      width: width,
                                      child: Container(
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                            color: cs.outlineVariant,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              item.$1,
                                              style: TextStyle(
                                                fontSize: 11.5,
                                                color: cs.onSurfaceVariant,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              item.$2,
                                              style: TextStyle(
                                                fontSize: 20,
                                                fontWeight: FontWeight.w900,
                                                color: item.$3,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                ],
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.tune,
                              size: 17,
                              color: cs.primary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              t('review.page.threshold'),
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          t('review.page.thresholdHint'),
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.6,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            for (final n in _options)
                              ChoiceChip(
                                label: Text(
                                  n == 0
                                      ? t('review.page.off')
                                      : '$n',
                                ),
                                selected: threshold == n,
                                onSelected: (_) =>
                                    context.read<AppState>().setThreshold(n),
                              ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Divider(height: 1, color: cs.outlineVariant),
                        const SizedBox(height: 8),
                        Text(
                          t('review.page.thresholdNote'),
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.6,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.hub_outlined,
                              size: 17,
                              color: cs.primary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              t('trust.title'),
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          t('trust.desc'),
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.6,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          t('trust.stats', {
                            'edges': state.attestStats?.totalEdges ?? 0,
                            'mutual': state.attestStats?.mutualEdges ?? 0,
                          }),
                          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                        ),
                        const SizedBox(height: 10),
                        if (state.trustScores.isEmpty)
                          Text(
                            t('trust.none'),
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.6,
                              color: cs.onSurfaceVariant,
                            ),
                          )
                        else
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final entry in state.trustScores.take(10))
                                Chip(
                                  visualDensity: VisualDensity.compact,
                                  avatar: Icon(
                                    entry.score >= 0.5
                                        ? Icons.verified_outlined
                                        : Icons.circle_outlined,
                                    size: 14,
                                    color: entry.score >= 0.5
                                        ? cs.primary
                                        : cs.outline,
                                  ),
                                  label: Text(
                                    '${entry.name.isEmpty ? entry.peer.substring(entry.peer.length - 6) : entry.name} · ${entry.score.toStringAsFixed(1)}',
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ),
                            ],
                          ),
                        const SizedBox(height: 10),
                        Divider(height: 1, color: cs.outlineVariant),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: Text(t('trust.filter')),
                          subtitle: Text(
                            t('trust.filterHint'),
                            style: TextStyle(
                              fontSize: 11.5,
                              height: 1.5,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                          value: state.settings.reviewTrustOnly,
                          onChanged: (v) =>
                              context.read<AppState>().setTrustOnly(v),
                        ),
                        const SizedBox(height: 6),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.handshake_outlined, size: 17),
                            label: Text(t('trust.attest')),
                            onPressed: () => _attestDialog(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      ChoiceChip(
                        label: Text(t('review.page.tab.all')),
                        selected: _tab == 'all',
                        onSelected: (_) => setState(() => _tab = 'all'),
                      ),
                      ChoiceChip(
                        label: Text(t('review.page.tab.mine')),
                        selected: _tab == 'mine',
                        onSelected: (_) => setState(() => _tab = 'mine'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (shown.isEmpty)
                    Panel(
                      child: EmptyState(
                        title: _tab == 'mine'
                            ? t('review.empty.mine')
                            : t('review.empty.title'),
                        body: t('review.empty.hint'),
                      ),
                    )
                  else
                    for (final g in shown)
                      _ReportGroup(
                        novelId: g.novelId,
                        title: g.novel?.title.isNotEmpty == true
                            ? g.novel!.title
                            : g.novelId.length > 8
                            ? g.novelId.substring(g.novelId.length - 8)
                            : g.novelId,
                        authorName: g.novel?.authorName ?? '',
                        reports: g.reports,
                        flagged: g.flagged,
                        mine: g.mine,
                        open: _open.contains(g.novelId),
                        categories: _categories,
                        onToggle: () => setState(() {
                          if (!_open.remove(g.novelId)) _open.add(g.novelId);
                        }),
                        onOpenNovel: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => NovelPage(novelId: g.novelId),
                          ),
                        ),
                        onExempt: () async {
                          try {
                            await setExempt(novelId: g.novelId, exempt: true);
                            if (!context.mounted) return;
                            await context.read<AppState>().refresh();
                          } catch (e) {
                            if (context.mounted) showError(context, e);
                          }
                        },
                      ),
                  const SizedBox(height: 16),
                  Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.info_outline,
                              size: 15,
                              color: cs.onSurfaceVariant,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              t('review.page.limits.title'),
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        for (final key in const [
                          'review.page.limits.1',
                          'review.page.limits.2',
                          'review.page.limits.3',
                        ])
                          Padding(
                            padding: const EdgeInsets.only(bottom: 5),
                            child: Text(
                              '· ${t(key)}',
                              style: TextStyle(
                                fontSize: 11.5,
                                height: 1.65,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReportGroup extends StatelessWidget {
  const _ReportGroup({
    required this.novelId,
    required this.title,
    required this.authorName,
    required this.reports,
    required this.flagged,
    required this.mine,
    required this.open,
    required this.categories,
    required this.onToggle,
    required this.onOpenNovel,
    required this.onExempt,
  });

  final String novelId;
  final String title;
  final String authorName;
  final List<ReportCard> reports;
  final bool flagged;
  final bool mine;
  final bool open;
  final List<String> categories;
  final VoidCallback onToggle;
  final VoidCallback onOpenNovel;
  final Future<void> Function() onExempt;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: flagged ? cs.error.withValues(alpha: 0.35) : cs.outlineVariant,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: t('review.detail'),
                  icon: Icon(
                    open ? Icons.expand_more : Icons.chevron_right,
                    size: 20,
                  ),
                  onPressed: onToggle,
                ),
                const SizedBox(width: 2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          InkWell(
                            onTap: onOpenNovel,
                            child: Text(
                              title,
                              style: TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w800,
                                color: cs.primary,
                              ),
                            ),
                          ),
                          _Tag(
                            icon: Icons.flag_outlined,
                            label: t('review.page.votes', {
                              'n': reports.length,
                            }),
                            color: flagged ? cs.error : cs.onSurfaceVariant,
                            background: flagged
                                ? cs.error.withValues(alpha: 0.12)
                                : cs.surfaceContainerHighest.withValues(
                                    alpha: 0.6,
                                  ),
                          ),
                          if (flagged)
                            _Tag(
                              icon: Icons.shield_outlined,
                              label: t('review.page.flaggedTag'),
                              color: cs.error,
                              background: cs.error.withValues(alpha: 0.12),
                            ),
                          if (mine)
                            _Tag(
                              label: t('review.page.mineTag'),
                              color: cs.primary,
                              background: cs.primary.withValues(alpha: 0.12),
                            ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        authorName.isEmpty ? '—' : authorName,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: onOpenNovel,
                  child: Text(t('review.page.view')),
                ),
              ],
            ),
            if (open) ...[
              const SizedBox(height: 6),
              Divider(height: 1, color: cs.outlineVariant),
              const SizedBox(height: 8),
              for (final r in reports)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    border: Border.all(color: cs.outlineVariant),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: cs.error.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(99),
                            ),
                            child: Text(
                              t('review.cat.${r.category}'),
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: cs.error,
                              ),
                            ),
                          ),
                          Text(
                            r.reporterName.isEmpty
                                ? (r.reporter.length > 8
                                      ? r.reporter.substring(
                                          r.reporter.length - 8,
                                        )
                                      : r.reporter)
                                : r.reporterName,
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            _ago(state.locale, r.atMs),
                            style: TextStyle(
                              fontSize: 11,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                          if (r.chapterNo != null)
                            Text(
                              '· ${t('common.chapters', {'n': r.chapterNo!})}',
                              style: TextStyle(
                                fontSize: 11,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                      if (r.note.isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Text(
                          r.note,
                          style: const TextStyle(fontSize: 12.5, height: 1.6),
                        ),
                      ],
                      if (r.response != null &&
                          r.response!.isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Text(
                          '${t('review.respond')}: ${r.response}',
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.6,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => onExempt(),
                  icon: const Icon(Icons.visibility_outlined, size: 15),
                  label: Text(t('review.exempt')),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({
    required this.label,
    required this.color,
    required this.background,
    this.icon,
  });

  final String label;
  final Color color;
  final Color background;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// 相对时间：与书架同一套口径，为了一句「刚刚」不值得引入一个依赖。
String _ago(String locale, int ms) {
  if (ms <= 0) return '—';
  final diff = DateTime.now().millisecondsSinceEpoch - ms;
  if (diff < 60 * 1000) {
    return switch (locale) {
      'en' => 'just now',
      'ja' => 'たった今',
      'ko' => '방금',
      'ru' => 'только что',
      _ => '刚刚',
    };
  }
  final minutes = diff ~/ (60 * 1000);
  final hours = diff ~/ (60 * 60 * 1000);
  final days = diff ~/ (24 * 60 * 60 * 1000);
  final months = days ~/ 30;
  final years = days ~/ 365;
  String n(int v, String zh, String en, String ja, String ko, String ru) {
    return switch (locale) {
      'en' => '$v$en',
      'ja' => '$v$ja',
      'ko' => '$v$ko',
      'ru' => '$v $ru',
      _ => '$v$zh',
    };
  }

  if (minutes < 60) return n(minutes, ' 分钟前', 'm ago', '分前', '분 전', 'мин назад');
  if (hours < 24) return n(hours, ' 小时前', 'h ago', '時間前', '시간 전', 'ч назад');
  if (days < 30) return n(days, ' 天前', 'd ago', '日前', '일 전', 'дн назад');
  if (months < 12) return n(months, ' 个月前', 'mo ago', 'か月前', '개월 전', 'мес назад');
  return n(years, ' 年前', 'y ago', '年前', '년 전', 'лет назад');
}