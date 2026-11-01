import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../src/rust/api.dart';
import '../src/rust/domain/view.dart';
import '../state/app_state.dart';
import '../widgets/href.dart';
import '../widgets/my_deals.dart';
import '../widgets/widgets.dart';
import 'contests_page.dart';
import 'publishers_page.dart';

/// 出版社详情。
///
/// 所有统计都从公开记录里数出来：作品看署名，赛事看主办方，
/// 奖金看公开账本。出版社自己填的只有名称、简介与擅长题材，其余得看记录。
class PublisherDetailPage extends StatefulWidget {
  const PublisherDetailPage({super.key, required this.publisherId});

  final String publisherId;

  @override
  State<PublisherDetailPage> createState() => _PublisherDetailPageState();
}

class _PublisherDetailPageState extends State<PublisherDetailPage> {
  List<NovelCard> _works = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    if (state.publishers.isEmpty) {
      try {
        await state.refresh();
      } catch (_) {}
    }
    try {
      final all = await listNovels(
        q: '',
        genre: '',
        status: '',
        tag: '',
        sort: 'update',
      );
      if (!mounted) return;
      setState(() => _works = all);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    PublisherCard? pub;
    for (final p in state.publishers) {
      if (p.id == widget.publisherId) pub = p;
    }

    if (pub == null) {
      return Scaffold(
        appBar: AppBar(title: Text(t('nav.publishers'))),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: EmptyState(
                title: t('pub.detail.notHere'),
                body: t('pub.detail.notHereHint'),
                action: OutlinedButton(
                  onPressed: () => Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (_) => const PublishersPage()),
                  ),
                  child: Text(t('pub.detail.back')),
                ),
              ),
            ),
          ),
        ),
      );
    }

    final p = pub;
    final own = state.contests.where((c) => c.publisherPeer == p.peer).toList();
    final works = _works.where((n) => n.authorPeer == p.peer).toList();
    final authors = {for (final w in works) w.authorPeer}.length;
    final mine = p.peer == (state.identity?.peerId ?? '');

    return Scaffold(
      appBar: AppBar(title: Text(p.name)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: LayoutBuilder(
              builder: (context, box) {
                final wide = box.maxWidth >= 900;
                final main = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _header(context, state, p, authors, works),
                    const SizedBox(height: 22),
                    SectionHeading(
                      title: t('pub.detail.contests'),
                      subtitle: own.isEmpty
                          ? null
                          : '${own.length} · ${t('pub.detail.open')} '
                                '${own.where((c) => c.status == 'open').length}',
                    ),
                    const SizedBox(height: 10),
                    if (own.isEmpty)
                      EmptyState(title: t('pub.detail.none'))
                    else
                      for (final c in own) _contestCard(context, state, c),
                    if (works.isNotEmpty) ...[
                      const SizedBox(height: 22),
                      SectionHeading(
                        title: t('pub.detail.works'),
                        subtitle: '${works.length}',
                      ),
                      const SizedBox(height: 10),
                      for (final w in works) _workCard(context, w),
                    ],
                    if (mine) ...[
                      const SizedBox(height: 22),
                      SectionHeading(
                        title: t('deal.myDeals'),
                        subtitle: t('deal.payHint'),
                      ),
                      const SizedBox(height: 10),
                      MyDealsPanel(
                        onOpenNovel: (id) => openCarouselHref(
                          context,
                          '/novel?id=${Uri.encodeComponent(id)}',
                        ),
                      ),
                    ],
                  ],
                );
                final aside = _aside(context, state, p, own.length);
                if (!wide) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      main,
                      const SizedBox(height: 22),
                      aside,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: main),
                    const SizedBox(width: 22),
                    SizedBox(width: 300, child: aside),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(
    BuildContext context,
    AppState state,
    PublisherCard p,
    int authors,
    List<NovelCard> works,
  ) {
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    final paid = p.rewardsPaid;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: cs.primary,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Text(
                    p.name.isEmpty ? '?' : p.name.substring(0, 1),
                    style: TextStyle(
                      color: cs.onPrimary,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            p.name,
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          Chip(
                            avatar: Icon(
                              p.verified
                                  ? Icons.verified_outlined
                                  : Icons.help_outline,
                              size: 16,
                            ),
                            label: Text(
                              t(
                                p.verified
                                    ? 'pub.card.verified'
                                    : 'pub.card.unverified',
                              ),
                            ),
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                      if (p.tagline.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(p.tagline),
                      ],
                      if (p.about.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          p.about,
                          style: TextStyle(
                            color: cs.onSurfaceVariant,
                            height: 1.6,
                          ),
                        ),
                      ],
                      if (p.genres.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final g in p.genres)
                              Chip(
                                label: Text(g),
                                visualDensity: VisualDensity.compact,
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 28),
            Wrap(
              spacing: 28,
              runSpacing: 14,
              children: [
                _stat(context, t('pub.detail.works'), '${works.length}'),
                _stat(context, t('pub.detail.authors'), '$authors'),
                _stat(context, t('pub.detail.paid'), '$paid'),
                _stat(context, t('pub.detail.open'), '${p.openContests}'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(BuildContext context, String label, String value) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
      ],
    );
  }

  Widget _contestCard(BuildContext context, AppState state, ContestCard c) {
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    final pool = c.prizes.fold<int>(0, (sum, p) => sum + p.coins);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => openCarouselHref(
          context,
          '/contest?id=${Uri.encodeComponent(c.id)}',
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Chip(
                    label: Text(t('contests.status.${c.status}')),
                    visualDensity: VisualDensity.compact,
                  ),
                  const Spacer(),
                  if (c.daysLeft > 0)
                    Text(
                      t('contests.daysLeft', {'n': c.daysLeft}),
                      style: TextStyle(
                        fontSize: 11.5,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                c.title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (c.tagline.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  c.tagline,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: cs.onSurfaceVariant, height: 1.5),
                ),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 14,
                runSpacing: 4,
                children: [
                  Text(
                    t('contests.entries', {'n': c.entries}),
                    style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
                  ),
                  if (pool > 0)
                    Text(
                      '${t('contest.detail.facts.prizes')}: $pool',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _workCard(BuildContext context, NovelCard n) {
    final state = context.watch<AppState>();
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(
          n.title,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          n.tagline.isNotEmpty ? n.tagline : n.synopsis,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: cs.onSurfaceVariant),
        ),
        trailing: Text(
          '${n.episodes}${state.t('common.chapters')}',
          style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
        ),
        onTap: () => openCarouselHref(
          context,
          '/novel?id=${Uri.encodeComponent(n.id)}',
        ),
      ),
    );
  }

  Widget _aside(
    BuildContext context,
    AppState state,
    PublisherCard p,
    int contestCount,
  ) {
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    final updated = p.updatedAtMs > 0
        ? DateFormat.yMMMd(
            state.locale,
          ).add_Hm().format(DateTime.fromMillisecondsSinceEpoch(p.updatedAtMs))
        : '—';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.business_outlined, size: 18, color: cs.primary),
                  const SizedBox(width: 8),
                  Text(
                    t('pub.detail.info'),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _row(context, t('pub.detail.identity'), '…${_tail(p.peer)}'),
              _row(context, t('pub.detail.updated'), updated),
              _row(context, t('pub.detail.contestCount'), '$contestCount'),
              const SizedBox(height: 10),
              Text(
                t('pub.detail.note'),
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.6,
                  color: cs.onSurfaceVariant,
                ),
              ),
              if (p.peer == (state.identity?.peerId ?? '')) ...[
                const Divider(height: 24),
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ContestsPage()),
                  ),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(t('contests.start')),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t('pub.detail.enterTitle'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                t('pub.detail.enterHint'),
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const ContestsPage())),
                icon: const Icon(Icons.emoji_events_outlined, size: 18),
                label: Text(t('pub.detail.viewContests')),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, String label, String value) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }

  String _tail(String peer) =>
      peer.length <= 12 ? peer : peer.substring(peer.length - 12);
}
