import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../src/rust/domain/view.dart';
import '../state/app_state.dart';
import '../widgets/home_carousel.dart';
import '../widgets/widgets.dart';
import 'browse_page.dart';
import 'novel_page.dart';
import 'post_page.dart';
import 'ranking_page.dart';

/// 首页。
///
/// 站内**没有预置作品**，所以首页最重要的一块是「为什么这里是空的」：
/// 空状态就是产品说明 —— 没东西可看时，至少把原因说清楚。
/// 所有统计都只算这台设备收到的内容。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _periods = ['daily', 'weekly', 'monthly', 'total'];
  String _latestTab = 'all';
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    final all = state.latest.where((n) => !n.deleted).toList();
    final ongoing = all.where((n) => n.status == 'ongoing').toList();
    final completed = all.where((n) => n.status == 'completed').toList();
    final shown = switch (_latestTab) {
      'ongoing' => ongoing,
      'completed' => completed,
      _ => all,
    };
    final totalChapters = all.fold<int>(0, (s, n) => s + n.episodes);
    final totalWords = all.fold<int>(0, (s, n) => s + n.words);
    final hotTags = _hotTags(all);
    final newArrivals = [...all]
      ..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      children: [
        const HomeCarousel(),
        const SizedBox(height: 24),
        Text(
          '${t('home.hero1')}\n${t('home.hero2')}',
          style: Theme.of(
            context,
          ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Text(t('app.tagline'), style: Theme.of(context).textTheme.bodyMedium),
        if (all.isNotEmpty) ...[
          const SizedBox(height: 14),
          Wrap(
            spacing: 20,
            runSpacing: 6,
            children: [
              _stat(context, t('home.stat.books'), '${all.length}'),
              _stat(context, t('home.stat.chapters'), '$totalChapters'),
              _stat(context, t('home.stat.words'), _format(totalWords)),
            ],
          ),
        ],
        const SizedBox(height: 16),
        TextField(
          controller: _search,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: t('home.searchPlaceholder'),
            suffixIcon: IconButton(
              icon: const Icon(Icons.arrow_forward),
              onPressed: _searchNow,
            ),
          ),
          onSubmitted: (_) => _searchNow(),
        ),
        if (hotTags.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                t('home.searching'),
                style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
              ),
              for (final tag in hotTags.take(6))
                ActionChip(
                  label: Text(tag),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _openBrowse(tag: tag),
                ),
            ],
          ),
        ],
        const SizedBox(height: 24),
        if (all.isEmpty) ...[
          EmptyState(
            title: t('home.whyEmptyTitle'),
            body: t('home.whyEmptyBody'),
            action: FilledButton.icon(
              onPressed: _openPost,
              icon: const Icon(Icons.edit),
              label: Text(t('home.firstCta')),
            ),
          ),
        ] else ...[
          SectionHeading(
            title: t('home.section.latest'),
            subtitle: t('home.section.latestSub'),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final tab in const ['all', 'ongoing', 'completed'])
                ChoiceChip(
                  label: Text(
                    tab == 'all'
                        ? t('common.all')
                        : tab == 'ongoing'
                        ? t('status.ongoing')
                        : t('status.completed'),
                  ),
                  selected: _latestTab == tab,
                  onSelected: (_) => setState(() => _latestTab = tab),
                ),
              TextButton(
                onPressed: () => _openBrowse(sort: 'update'),
                child: Text(t('common.more')),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (shown.isEmpty)
            Panel(child: Text(t('home.latest.empty')))
          else
            for (final n in shown.take(10))
              NovelCardTile(
                novel: n,
                locale: state.locale,
                onTap: () => _openNovel(n.id),
              ),
          const SizedBox(height: 20),
          SectionHeading(
            title: t('home.section.writing'),
            subtitle: t('home.section.writingSub'),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 150,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: newArrivals.take(10).length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, i) {
                final n = newArrivals[i];
                return SizedBox(
                  width: 220,
                  child: Card(
                    margin: EdgeInsets.zero,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => _openNovel(n.id),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              n.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              n.tagline,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              '${n.authorName} · ${n.episodes}${t('common.chapters')}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 24),
          SectionHeading(
            title: t('home.section.genre'),
            subtitle: t('home.section.genre.sub', {'n': state.genres.length}),
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, box) {
              final columns = box.maxWidth >= 760
                  ? 4
                  : box.maxWidth >= 480
                  ? 3
                  : 2;
              final width = (box.maxWidth - (columns - 1) * 10) / columns;
              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final g in state.genres)
                    SizedBox(
                      width: width,
                      child: Card(
                        margin: EdgeInsets.zero,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => _openBrowse(genre: g.slug),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  g.name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  g.desc,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  t('home.card.go'),
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: cs.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          if (completed.isNotEmpty) ...[
            const SizedBox(height: 24),
            SectionHeading(
              title: t('home.section.completed'),
              subtitle: t('home.section.completedSub'),
            ),
            const SizedBox(height: 10),
            for (final n in completed.take(6))
              NovelCardTile(
                novel: n,
                locale: state.locale,
                onTap: () => _openNovel(n.id),
              ),
          ],
        ],
        const SizedBox(height: 24),
        SectionHeading(
          title: t('nav.ranking'),
          subtitle: t('rank.period.${state.rankingPeriod}'),
          trailing: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const RankingPage()),
            ),
            child: Text(t('common.more')),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final p in _periods)
              ChoiceChip(
                label: Text(t('rank.period.$p')),
                selected: state.rankingPeriod == p,
                onSelected: (_) => state.setPeriod(p),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (state.ranked.isEmpty)
          Panel(child: Text(t('home.ranking.empty')))
        else
          Panel(
            child: Column(
              children: [
                for (var i = 0; i < state.ranked.take(5).length; i++)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      radius: 14,
                      child: Text(
                        '${i + 1}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                    title: Text(
                      state.ranked[i].title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${state.ranked[i].authorName} · '
                      '${state.ranked[i].words}${t('common.words')}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => _openNovel(state.ranked[i].id),
                  ),
              ],
            ),
          ),
        if (hotTags.isNotEmpty) ...[
          const SizedBox(height: 20),
          SectionHeading(title: t('home.hotTags')),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final tag in hotTags)
                ActionChip(
                  label: Text('#$tag'),
                  onPressed: () => _openBrowse(tag: tag),
                ),
              for (final g in state.genres.take(6))
                ActionChip(
                  label: Text(g.name),
                  onPressed: () => _openBrowse(genre: g.slug),
                ),
            ],
          ),
        ],
        const SizedBox(height: 20),
        Card(
          margin: EdgeInsets.zero,
          color: cs.primaryContainer.withValues(alpha: 0.5),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t('home.write.title'),
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  t('home.write.body'),
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.6,
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _openPost,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: Text(t('home.write.cta')),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _stat(BuildContext context, String label, String value) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
        ),
        const SizedBox(width: 6),
        Text(
          value,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
      ],
    );
  }

  List<String> _hotTags(List<NovelCard> all) {
    final count = <String, int>{};
    for (final n in all) {
      for (final tag in n.tags) {
        count[tag] = (count[tag] ?? 0) + 1;
      }
    }
    final tags = count.keys.toList()
      ..sort((a, b) {
        final byCount = count[b]!.compareTo(count[a]!);
        return byCount != 0 ? byCount : a.compareTo(b);
      });
    return tags.take(12).toList();
  }

  String _format(int n) {
    final s = n.abs().toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return n < 0 ? '-$buf' : buf.toString();
  }

  void _searchNow() {
    final q = _search.text.trim();
    _openBrowse(q: q);
  }

  void _openBrowse({
    String genre = '',
    String q = '',
    String tag = '',
    String status = '',
    String sort = 'update',
  }) {
    final state = context.read<AppState>();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(state.t('browse.title'))),
          body: BrowsePage(
            initialGenre: genre,
            initialQuery: q,
            initialTag: tag,
            initialStatus: status,
            initialSort: sort,
          ),
        ),
      ),
    );
  }

  void _openNovel(String id) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => NovelPage(novelId: id)));
  }

  void _openPost() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(context.read<AppState>().t('post.title'))),
          body: const PostPage(),
        ),
      ),
    );
  }
}
