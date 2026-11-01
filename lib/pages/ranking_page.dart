import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../src/rust/domain/view.dart';
import '../state/app_state.dart';
import '../widgets/widgets.dart';
import 'novel_page.dart';

/// 排行榜。
///
/// 只排「你这台设备收到的内容」—— 没有服务器能统计全站，
/// 编一个「全站人气」出来会是一个一查就穿的谎，所以页面上明说。
///
/// 与 Web 版同三个维度：活跃度（默认，按更新时间衰减）、総 PV、週間読者。
/// 后两个直接读副本里已有的 `pvTotal` / `pvWeekly`，不需要额外统计。
class RankingPage extends StatefulWidget {
  const RankingPage({super.key});

  @override
  State<RankingPage> createState() => _RankingPageState();
}

class _RankingPageState extends State<RankingPage> {
  static const _periods = ['daily', 'weekly', 'monthly', 'quarter', 'total'];
  int _metric = 0;
  String _genre = '';

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final shown = _ranked(state);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
          child: SectionHeading(title: t('rank.title')),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            t('rank.honest'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Row(
            children: [
              for (final p in _periods) ...[
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: Text(t('rank.period.$p')),
                    selected: state.rankingPeriod == p,
                    onSelected: (_) => context.read<AppState>().setPeriod(p),
                  ),
                ),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (var i = 0; i < 3; i++)
                FilterChip(
                  label: Text(
                    i == 0
                        ? t('rank.metric.activity')
                        : i == 1
                        ? t('pv.total')
                        : t('pv.weekly'),
                  ),
                  selected: _metric == i,
                  onSelected: (_) => setState(() => _metric = i),
                  avatar: Icon(
                    i == 0
                        ? Icons.bolt_outlined
                        : i == 1
                        ? Icons.visibility_outlined
                        : Icons.people_outline,
                    size: 15,
                  ),
                ),
              const SizedBox(width: 6),
              DropdownButton<String>(
                value: _genre,
                underline: const SizedBox.shrink(),
                style: Theme.of(context).textTheme.bodySmall,
                items: [
                  DropdownMenuItem(value: '', child: Text(t('common.all'))),
                  for (final g in state.genres)
                    DropdownMenuItem(value: g.slug, child: Text(g.name)),
                ],
                onChanged: (v) => setState(() => _genre = v ?? ''),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: shown.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: EmptyState(
                    title: t('common.empty'),
                    body: t('home.whyEmptyBody'),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                  children: [
                    for (var i = 0; i < shown.length; i++)
                      NovelCardTile(
                        novel: shown[i],
                        locale: state.locale,
                        rank: i + 1,
                        showPv: true,
                        onTap: () => _open(context, shown[i].id),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  List<NovelCard> _ranked(AppState state) {
    var list = state.ranked;
    if (_genre.isNotEmpty) {
      list = list.where((n) => n.genre == _genre).toList(growable: false);
    }
    // 活跃度：归约器已经排好；界面只负责按当前列表顺序报数。
    if (_metric == 0) return list;

    final sorted = [...list]
      ..sort((a, b) {
        final primary = _metric == 1
            ? b.pvTotal.compareTo(a.pvTotal)
            : b.pvWeekly.compareTo(a.pvWeekly);
        if (primary != 0) return primary;
        final tie = b.pvTotal.compareTo(a.pvTotal);
        return tie != 0 ? tie : a.id.compareTo(b.id);
      });
    return sorted;
  }

  void _open(BuildContext context, String id) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => NovelPage(novelId: id)));
  }
}
