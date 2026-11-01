import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../src/rust/api.dart';
import '../src/rust/domain/view.dart';
import '../state/app_state.dart';
import '../widgets/widgets.dart';
import 'contest_detail_page.dart';
import 'publisher_detail_page.dart';
import 'publishers_page.dart';

/// 大赛。
///
/// 赛事状态（征稿中 / 评审中 / 已结束）在读取时由截稿时间与公布时间派生，
/// 不进记录 —— 状态取决于「现在几点」，而那是收敛性不能依赖的外部输入；
/// 把时钟写进记录，各地节点会吵起来。
///
/// 筛选只影响本机视图：Web 版把条件放在 URL 里，桌面端没有地址栏，
/// 只好把条件放在本地状态里；语义一致（未知取值回落成「全部」）。
class ContestsPage extends StatefulWidget {
  const ContestsPage({super.key});

  @override
  State<ContestsPage> createState() => _ContestsPageState();
}

class _ContestsPageState extends State<ContestsPage> {
  String _kind = 'all';
  String _status = 'all';

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;

    final list = state.contests;
    final results = list.where((c) {
      if (_kind != 'all' && c.kind != _kind) return false;
      if (_status == 'open' && c.status != 'open') return false;
      if (_status == 'ended' && c.status == 'open') return false;
      return true;
    }).toList();

    final openCount = list.where((c) => c.status == 'open').length;
    final totalPrizes = list.fold<int>(
      0,
      (sum, c) => sum + c.prizes.fold<int>(0, (s, p) => s + p.coins),
    );

    return Scaffold(
      appBar: AppBar(title: Text(t('nav.contests'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _startContest(context),
        icon: const Icon(Icons.add),
        label: Text(t('contests.start')),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t('contests.sub'),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                if (list.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _StatsRow(
                    total: list.length,
                    open: openCount,
                    publishers: state.publishers.length,
                    prizes: totalPrizes,
                  ),
                  const SizedBox(height: 16),
                  _Filters(
                    kind: _kind,
                    status: _status,
                    onKind: (v) => setState(() => _kind = v),
                    onStatus: (v) => setState(() => _status = v),
                  ),
                  const SizedBox(height: 12),
                ],
                if (list.isEmpty)
                  EmptyState(
                    title: t('contests.empty'),
                    body: t('contests.emptyBody'),
                    action: FilledButton.tonal(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const PublishersPage()),
                      ),
                      child: Text(t('contest.empty.goPub')),
                    ),
                  )
                else if (results.isEmpty)
                  EmptyState(
                    title: t('contests.noMatch'),
                    body: t('contests.noMatchHint'),
                  )
                else
                  for (final c in results) _ContestCard(contest: c),
                if (state.contestKinds.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  SectionHeading(title: t('contests.kinds.title')),
                  const SizedBox(height: 6),
                  for (final k in state.contestKinds)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(t(k.labelKey)),
                      subtitle: Text(t(k.descKey)),
                    ),
                ],
                if (state.publishers.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  SectionHeading(title: t('contests.sponsors')),
                  const SizedBox(height: 6),
                  for (final p in state.publishers)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        radius: 14,
                        child: Text(
                          p.name.isEmpty ? '?' : p.name.characters.first,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      title: Text(p.name),
                      subtitle: Text(
                        p.openContests > 0
                            ? t('contests.publisher.openCount', {
                                'n': p.openContests,
                              })
                            : '—',
                      ),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => PublisherDetailPage(publisherId: p.id),
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _startContest(BuildContext context) async {
    final state = context.read<AppState>();
    final t = state.t;
    final peer = state.identity?.peerId ?? '';
    if (peer.isEmpty) {
      showError(context, t('contests.form.needIdentity'));
      return;
    }
    final mine = state.publishers.where((p) => p.peer == peer).toList();
    if (mine.isEmpty) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t('contests.start')),
          content: Text(t('contests.form.needPublisher')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t('common.cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t('contest.empty.goPub')),
            ),
          ],
        ),
      );
      if (go == true && context.mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const PublishersPage()),
        );
      }
      return;
    }

    final title = TextEditingController();
    final tagline = TextEditingController();
    final theme = TextEditingController();
    final rules = TextEditingController();
    final minWords = TextEditingController(text: '50000');
    final maxWords = TextEditingController(text: '300000');
    final days = TextEditingController(text: '30');
    final prizeCoins = [
      TextEditingController(text: '30000'),
      TextEditingController(text: '10000'),
      TextEditingController(text: '5000'),
    ];
    final prizeExtras = [
      TextEditingController(),
      TextEditingController(),
      TextEditingController(),
    ];
    String publisherId = mine.first.id;
    String kind = 'call-for-writing';
    String genre = state.genres.isNotEmpty ? state.genres.first.slug : 'daily';
    var allowOngoing = true;
    var busy = false;
    String? err;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) {
          final publisher = mine.firstWhere(
            (p) => p.id == publisherId,
            orElse: () => mine.first,
          );
          return AlertDialog(
            title: Text(t('contests.form.title')),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t('contests.form.intro', {
                        'name': publisher.name,
                        'id': peer.length > 10
                            ? peer.substring(peer.length - 10)
                            : peer,
                        'pen': state.identity?.penName ?? '',
                      }),
                      style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (mine.length > 1) ...[
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: publisherId,
                        decoration: InputDecoration(
                          labelText: t('contests.form.host'),
                        ),
                        items: [
                          for (final p in mine)
                            DropdownMenuItem(value: p.id, child: Text(p.name)),
                        ],
                        onChanged: (v) =>
                            setDialog(() => publisherId = v ?? publisherId),
                      ),
                    ],
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: kind,
                      decoration: InputDecoration(
                        labelText: t('contests.kind'),
                      ),
                      items: [
                        for (final k in state.contestKinds)
                          DropdownMenuItem(
                            value: k.id,
                            child: Text(t(k.labelKey)),
                          ),
                      ],
                      onChanged: (v) =>
                          setDialog(() => kind = v ?? 'call-for-writing'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: title,
                      decoration: InputDecoration(
                        labelText: t('contests.form.name'),
                        hintText: t('contests.form.namePh'),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: tagline,
                      decoration: InputDecoration(
                        labelText: t('contests.tagline'),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: theme,
                            decoration: InputDecoration(
                              labelText: t('contests.form.theme'),
                              hintText: t('contests.form.themeHint'),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: state.genres.isEmpty
                              ? const SizedBox.shrink()
                              : DropdownButtonFormField<String>(
                                  initialValue: genre,
                                  decoration: InputDecoration(
                                    labelText: t('contests.genre'),
                                  ),
                                  items: [
                                    for (final g in state.genres)
                                      DropdownMenuItem(
                                        value: g.slug,
                                        child: Text(g.name),
                                      ),
                                  ],
                                  onChanged: (v) => setDialog(
                                    () => genre = v ?? genre,
                                  ),
                                ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: minWords,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: t('contests.minWords'),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: maxWords,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: t('contests.maxWords'),
                              hintText: t('contests.form.maxWordsHint'),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: days,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: t('contests.form.days'),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      t('contests.form.prizes'),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      t('contests.form.prizeHint'),
                      style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    for (var i = 0; i < 3; i++) ...[
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 13,
                            child: Text(
                              '${i + 1}',
                              style: const TextStyle(fontSize: 11),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 150,
                            child: TextField(
                              controller: prizeCoins[i],
                              keyboardType: TextInputType.number,
                              decoration: InputDecoration(
                                labelText: t('contests.form.prizePlace${i + 1}'),
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: prizeExtras[i],
                              maxLength: 80,
                              decoration: InputDecoration(
                                labelText: t('contests.form.prizeExtras'),
                                hintText: t('contests.form.prizeExtrasPh'),
                                isDense: true,
                                counterText: '',
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                    ],
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(t('contests.allowOngoing')),
                      value: allowOngoing,
                      onChanged: (v) => setDialog(() => allowOngoing = v),
                    ),
                    TextField(
                      controller: rules,
                      maxLines: 4,
                      decoration: InputDecoration(
                        labelText: t('contests.rules'),
                        hintText: t('contests.form.rulesHint'),
                        alignLabelWithHint: true,
                      ),
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
                        final titleText = title.text.trim();
                        if (titleText.characters.length < 4) {
                          setDialog(() => err = t('contests.form.err.name'));
                          return;
                        }
                        final min = int.tryParse(minWords.text.trim()) ?? 0;
                        final max = int.tryParse(maxWords.text.trim()) ?? 0;
                        if (max > 0 && max <= min) {
                          setDialog(() => err = t('contests.form.err.range'));
                          return;
                        }
                        final d = int.tryParse(days.text.trim()) ?? 0;
                        if (d < 1) {
                          setDialog(() => err = t('contests.form.err.days'));
                          return;
                        }
                        final prizes = <ContestPrizeInput>[];
                        for (var i = 0; i < 3; i++) {
                          final coins =
                              int.tryParse(prizeCoins[i].text.trim()) ?? 0;
                          final extras = prizeExtras[i].text.trim();
                          if (coins > 0 || extras.isNotEmpty) {
                            prizes.add(
                              ContestPrizeInput(
                                place: '${i + 1}',
                                coins: coins < 0 ? 0 : coins,
                                extras: extras,
                              ),
                            );
                          }
                        }
                        setDialog(() {
                          busy = true;
                          err = null;
                        });
                        final now = DateTime.now();
                        final deadline = now.add(Duration(days: d));
                        final announce = deadline.add(
                          const Duration(days: 14),
                        );
                        try {
                          await putContest(
                            publisherPeer: publisher.peer,
                            theme: theme.text.trim(),
                            title: titleText,
                            kind: kind,
                            tagline: tagline.text.trim(),
                            rules: rules.text.trim(),
                            genre: genre,
                            deadline: deadline.toUtc().toIso8601String(),
                            announceAt: announce.toUtc().toIso8601String(),
                            minWords: min,
                            maxWords: max,
                            allowOngoing: allowOngoing,
                            prizes: prizes,
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
          );
        },
      ),
    );
    title.dispose();
    tagline.dispose();
    theme.dispose();
    rules.dispose();
    minWords.dispose();
    maxWords.dispose();
    days.dispose();
    for (final c in prizeCoins) {
      c.dispose();
    }
    for (final c in prizeExtras) {
      c.dispose();
    }
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({
    required this.total,
    required this.open,
    required this.publishers,
    required this.prizes,
  });

  final int total;
  final int open;
  final int publishers;
  final int prizes;

  @override
  Widget build(BuildContext context) {
    final t = context.watch<AppState>().t;
    final cs = Theme.of(context).colorScheme;
    final stats = [
      (t('contests.stat.total'), '$total', cs.onSurface),
      (t('contests.stat.open'), '$open', cs.primary),
      (t('contests.stat.publishers'), '$publishers', cs.onSurface),
      (t('contests.stat.prizes'), '$prizes', cs.tertiary),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 620 ? 4 : 2;
        final width = (constraints.maxWidth - (columns - 1) * 10) / columns;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final s in stats)
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
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
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

class _Filters extends StatelessWidget {
  const _Filters({
    required this.kind,
    required this.status,
    required this.onKind,
    required this.onStatus,
  });

  final String kind;
  final String status;
  final ValueChanged<String> onKind;
  final ValueChanged<String> onStatus;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.filter_alt_outlined, size: 16),
                const SizedBox(width: 6),
                Text(
                  t('contests.filter'),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                ChoiceChip(
                  label: Text(t('contests.filter.allKind')),
                  selected: kind == 'all',
                  onSelected: (_) => onKind('all'),
                ),
                for (final k in state.contestKinds)
                  ChoiceChip(
                    label: Text(t(k.labelKey)),
                    selected: kind == k.id,
                    onSelected: (_) => onKind(k.id),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                ChoiceChip(
                  label: Text(t('contests.filter.allStatus')),
                  selected: status == 'all',
                  onSelected: (_) => onStatus('all'),
                ),
                ChoiceChip(
                  label: Text(t('contests.filter.open')),
                  selected: status == 'open',
                  onSelected: (_) => onStatus('open'),
                ),
                ChoiceChip(
                  label: Text(t('contests.filter.ended')),
                  selected: status == 'ended',
                  onSelected: (_) => onStatus('ended'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ContestCard extends StatelessWidget {
  const _ContestCard({required this.contest});

  final ContestCard contest;

  String _genreName(List<Genre> genres, String slug) {
    for (final g in genres) {
      if (g.slug == slug) return g.name;
    }
    return slug;
  }

  String _kindLabel(AppState state, String kind) {
    for (final k in state.contestKinds) {
      if (k.id == kind) return state.t(k.labelKey);
    }
    return kind;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    final mine = contest.publisherPeer == (state.identity?.peerId ?? '');
    final prizePool = contest.prizes.fold<int>(
      0,
      (sum, p) => sum + p.coins,
    );
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Chip(
                  label: Text(t('contests.status.${contest.status}')),
                  visualDensity: VisualDensity.compact,
                ),
                Chip(
                  label: Text(_kindLabel(state, contest.kind)),
                  visualDensity: VisualDensity.compact,
                ),
                if (contest.genre.isNotEmpty)
                  Chip(
                    label: Text(_genreName(state.genres, contest.genre)),
                    visualDensity: VisualDensity.compact,
                  ),
                if (mine)
                  Chip(
                    label: Text(t('contests.mine')),
                    visualDensity: VisualDensity.compact,
                  ),
                if (contest.myEntry != null)
                  Chip(
                    avatar: Icon(Icons.check, size: 16, color: cs.primary),
                    label: Text(t('contests.myEntry')),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              contest.title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (contest.tagline.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(contest.tagline),
            ],
            if (contest.theme != null && contest.theme!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '${t('contests.form.theme')}: ${contest.theme}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 6),
            Text(
              '${contest.publisherName} · '
              '${t('contests.entries', {'n': contest.entries})}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (contest.minWords > 0 || contest.maxWords > 0)
                  Chip(
                    label: Text(
                      t('contests.wordRange', {
                        'min': contest.minWords,
                        'max': contest.maxWords == 0
                            ? '∞'
                            : contest.maxWords,
                      }),
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                if (contest.allowOngoing)
                  Chip(
                    label: Text(t('contests.allowOngoingShort')),
                    visualDensity: VisualDensity.compact,
                  ),
                if (prizePool > 0)
                  Chip(
                    label: Text(t('contests.prizePool', {'n': prizePool})),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            if (contest.status == 'open') ...[
              const SizedBox(height: 6),
              Text(
                contest.daysLeft > 0
                    ? t('contests.daysLeft', {'n': contest.daysLeft})
                    : t('contests.today'),
              ),
            ],
            if (contest.rules.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(contest.rules),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (contest.myEntry == null && contest.status == 'open')
                  FilledButton.tonal(
                    onPressed: () => _enter(context, contest),
                    child: Text(t('contests.enter')),
                  ),
                if (contest.hasResult)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.emoji_events_outlined, size: 18),
                    label: Text(t('contests.results')),
                    onPressed: () => _showResults(context, contest),
                  ),
                TextButton.icon(
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: Text(t('contest.detail.open')),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ContestDetailPage(contestId: contest.id),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _enter(BuildContext context, ContestCard contest) async {
    final state = context.read<AppState>();
    final t = state.t;
    final works = await state.myNovels();
    if (!context.mounted) return;
    if (works.isEmpty) {
      showError(context, t('contests.noWorks'));
      return;
    }
    final picked = await showDialog<NovelCard>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('contests.enterPick')),
        content: SizedBox(
          width: 480,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final n in works)
                ListTile(
                  title: Text(n.title),
                  subtitle: Text(
                    '${n.episodes}${t('common.chapters')} · '
                    '${n.words}${t('common.words')}',
                  ),
                  onTap: () => Navigator.pop(ctx, n),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t('common.cancel')),
          ),
        ],
      ),
    );
    if (picked == null || !context.mounted) return;

    final check = await checkEntry(contestId: contest.id, novelId: picked.id);
    if (!context.mounted) return;
    if (!check.ok) {
      showError(
        context,
        t(check.reasonKey, {'need': check.need, 'have': check.have}),
      );
      return;
    }
    try {
      await submitEntry(contestId: contest.id, novelId: picked.id);
      await state.refresh();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('contests.entered'))),
      );
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _showResults(BuildContext context, ContestCard contest) async {
    final state = context.read<AppState>();
    final t = state.t;
    List<ContestPlacementView> results;
    try {
      results = await contestResults(contestId: contest.id);
    } catch (e) {
      if (context.mounted) showError(context, e);
      return;
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${t('contests.results')} · ${contest.title}'),
        content: SizedBox(
          width: 520,
          child: results.isEmpty
              ? Text(t('contests.noResults'))
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final r in results)
                      ListTile(
                        leading: CircleAvatar(
                          radius: 16,
                          child: Text('${r.place}'),
                        ),
                        title: Text(r.novelTitle),
                        subtitle: Text(
                          '${r.authorName}${r.note == null ? '' : ' · ${r.note}'}',
                        ),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t('common.confirm')),
          ),
        ],
      ),
    );
    await state.refreshStats();
  }
}
