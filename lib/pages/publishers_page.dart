import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../src/rust/api.dart';
import '../src/rust/domain/view.dart';
import '../state/app_state.dart';
import '../widgets/my_deals.dart';
import '../widgets/widgets.dart';
import 'novel_page.dart';
import 'publisher_detail_page.dart';

/// 出版社。
///
/// 发布一条 `publisher.put` 就是入驻，不需要审核表 ——
/// 任何节点都能自称出版社，所以「已验证」只是展示性标记，不是营业执照。
/// 卡片上的数字全部由公开记录数出来：作品看署名，奖金看公开账本 —— 自己说的不算。
class PublishersPage extends StatefulWidget {
  const PublishersPage({super.key});

  @override
  State<PublishersPage> createState() => _PublishersPageState();
}

class _PublishersPageState extends State<PublishersPage> {
  bool _mineOnly = false;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final me = state.identity?.peerId ?? '';
    final mineCount = state.publishers.where((p) => p.peer == me).length;
    final shown = _mineOnly
        ? state.publishers.where((p) => p.peer == me).toList()
        : state.publishers;
    final openContests = state.contests.where((c) => c.status == 'open').length;

    return Scaffold(
      appBar: AppBar(title: Text(t('nav.publishers'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _join(context),
        icon: const Icon(Icons.add),
        label: Text(t('publishers.start')),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 980),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t('publishers.sub'),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                if (state.publishers.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _Stats(
                    count: state.publishers.length,
                    openContests: openContests,
                    contests: state.contests.length,
                    mine: mineCount,
                  ),
                  if (mineCount > 0) ...[
                    const SizedBox(height: 10),
                    ChoiceChip(
                      label: Text(t('publishers.tab.mine')),
                      selected: _mineOnly,
                      onSelected: (v) => setState(() => _mineOnly = v),
                    ),
                  ],
                  const SizedBox(height: 12),
                ],
                if (state.publishers.isEmpty)
                  EmptyState(
                    title: t('publishers.empty'),
                    action: FilledButton.tonal(
                      onPressed: () => _join(context),
                      child: Text(t('publishers.start')),
                    ),
                  )
                else if (shown.isEmpty)
                  EmptyState(
                    title: t('publishers.mineEmpty'),
                    body: t('publishers.form.intro'),
                  )
                else
                  LayoutBuilder(
                    builder: (context, box) {
                      final columns = box.maxWidth >= 700 ? 2 : 1;
                      final width =
                          (box.maxWidth - (columns - 1) * 12) / columns;
                      return Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          for (final p in shown)
                            SizedBox(
                              width: width,
                              child: _PublisherCard(
                                publisher: p,
                                mine: p.peer == me,
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                const SizedBox(height: 24),
                SectionHeading(
                  title: t('deal.myDeals'),
                  subtitle: t('deal.payHint'),
                ),
                const SizedBox(height: 10),
                MyDealsPanel(
                  onOpenNovel: (id) => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => NovelPage(novelId: id)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _join(BuildContext context) async {
    final state = context.read<AppState>();
    final t = state.t;
    if ((state.identity?.peerId ?? '').isEmpty) {
      showError(context, t('contests.form.needIdentity'));
      return;
    }
    final name = TextEditingController();
    final tagline = TextEditingController();
    final about = TextEditingController();
    final genres = <String>{};
    String? err;
    var busy = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(t('publishers.start')),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t('publishers.form.intro'),
                    style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: name,
                    decoration: InputDecoration(
                      labelText: t('publishers.title'),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: tagline,
                    decoration: InputDecoration(
                      labelText: t('publishers.tagline'),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: about,
                    maxLines: 3,
                    decoration: InputDecoration(
                      labelText: t('publishers.about'),
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    t('publishers.genres'),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final g in state.genres)
                        FilterChip(
                          label: Text(g.name),
                          selected: genres.contains(g.slug),
                          onSelected: (v) => setDialog(() {
                            if (v) {
                              if (genres.length < 8) genres.add(g.slug);
                            } else {
                              genres.remove(g.slug);
                            }
                          }),
                        ),
                    ],
                  ),
                  if (err != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      err!,
                      style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(ctx),
              child: Text(t('common.cancel')),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      if (name.text.trim().characters.length < 2) {
                        setDialog(() => err = t('publishers.form.err.name'));
                        return;
                      }
                      if (tagline.text.trim().characters.length < 4) {
                        setDialog(
                          () => err = t('publishers.form.err.tagline'),
                        );
                        return;
                      }
                      setDialog(() {
                        busy = true;
                        err = null;
                      });
                      try {
                        await putPublisher(
                          name: name.text.trim(),
                          tagline: tagline.text.trim(),
                          about: about.text.trim(),
                          genres: genres.toList(),
                        );
                        await state.refresh();
                        if (!ctx.mounted) return;
                        Navigator.pop(ctx);
                      } catch (e) {
                        setDialog(() {
                          busy = false;
                          err = e.toString();
                        });
                      }
                    },
              child: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(t('common.publish')),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    tagline.dispose();
    about.dispose();
  }
}

class _Stats extends StatelessWidget {
  const _Stats({
    required this.count,
    required this.openContests,
    required this.contests,
    required this.mine,
  });

  final int count;
  final int openContests;
  final int contests;
  final int mine;

  @override
  Widget build(BuildContext context) {
    final t = context.watch<AppState>().t;
    final cs = Theme.of(context).colorScheme;
    final items = [
      (t('publishers.title'), '$count', cs.onSurface),
      (t('contests.filter.open'), '$openContests', cs.primary),
      (t('contest.stat.total'), '$contests', cs.onSurface),
      (t('publishers.card.mine'), '$mine', cs.tertiary),
    ];
    return LayoutBuilder(
      builder: (context, box) {
        final columns = box.maxWidth >= 620 ? 4 : 2;
        final width = (box.maxWidth - (columns - 1) * 10) / columns;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final s in items)
              SizedBox(
                width: width,
                child: Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.$1,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          s.$2,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: s.$3,
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _PublisherCard extends StatelessWidget {
  const _PublisherCard({required this.publisher, required this.mine});

  final PublisherCard publisher;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    final p = publisher;
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PublisherDetailPage(publisherId: p.id),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: cs.primary,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  p.name.isEmpty ? '?' : p.name.characters.first,
                  style: TextStyle(
                    color: cs.onPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          p.name,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (p.verified)
                          Chip(
                            avatar: const Icon(Icons.verified_outlined, size: 14),
                            label: Text(t('pub.card.verified')),
                            visualDensity: VisualDensity.compact,
                          ),
                        if (mine)
                          Chip(
                            label: Text(t('publishers.card.mine')),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                    if (p.tagline.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(p.tagline),
                    ],
                    if (p.genres.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          for (final g in p.genres)
                            Chip(
                              label: Text(g),
                              visualDensity: VisualDensity.compact,
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        Text(
                          t('publishers.works', {'n': p.works}),
                          style: TextStyle(
                            fontSize: 11.5,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        Text(
                          t('publishers.authors', {'n': p.authors}),
                          style: TextStyle(
                            fontSize: 11.5,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        if (p.rewardsPaid > 0)
                          Text(
                            t('publishers.paid', {'n': p.rewardsPaid}),
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: cs.tertiary,
                            ),
                          ),
                        if (p.contests > 0)
                          Text(
                            t('publishers.contests', {'n': p.contests}),
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
            ],
          ),
        ),
      ),
    );
  }
}
