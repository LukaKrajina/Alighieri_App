import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../src/rust/api.dart';
import '../src/rust/domain/view.dart';
import '../state/app_state.dart';
import '../widgets/href.dart';
import '../widgets/widgets.dart';
import 'publisher_detail_page.dart';

/// 赛事详情 + 报名 + 结果公布 + 奖金发放。
///
/// 赛事状态由截止时间与公布时间在本机派生；报名与名次都是签名操作，
/// 界面上看到的每一条都能在别的节点复算 —— 嘴上说的不算数。
class ContestDetailPage extends StatefulWidget {
  const ContestDetailPage({super.key, required this.contestId});

  final String contestId;

  @override
  State<ContestDetailPage> createState() => _ContestDetailPageState();
}

class _ContestDetailPageState extends State<ContestDetailPage> {
  List<ContestEntryView> _entries = [];
  List<ContestPlacementView> _results = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  Future<void> _reload() async {
    final state = context.read<AppState>();
    if (!state.contests.any((c) => c.id == widget.contestId)) {
      try {
        await state.refresh();
      } catch (_) {}
    }
    try {
      final entries = await contestEntries(contestId: widget.contestId);
      final results = await contestResults(contestId: widget.contestId);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _results = results;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    ContestCard? contest;
    for (final c in state.contests) {
      if (c.id == widget.contestId) contest = c;
    }

    if (contest == null) {
      return Scaffold(
        appBar: AppBar(title: Text(t('nav.contests'))),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        EmptyState(
                          title: _error == null
                              ? t('contest.detail.notHere')
                              : _error!,
                          body: t('contest.detail.notHereHint'),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text(t('contest.detail.back')),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      );
    }

    final c = contest;
    final mine = c.publisherPeer == (state.identity?.peerId ?? '');
    return Scaffold(
      appBar: AppBar(title: Text(c.title)),
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
                    _header(context, state, c),
                    const SizedBox(height: 20),
                    SectionHeading(title: t('contest.detail.rules')),
                    const SizedBox(height: 8),
                    Panel(
                      child: Text(
                        c.rules.isEmpty
                            ? t('contest.detail.rulesEmpty')
                            : c.rules,
                        style: const TextStyle(height: 1.7),
                      ),
                    ),
                    if (c.prizes.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      SectionHeading(title: t('contest.detail.prizes')),
                      const SizedBox(height: 8),
                      for (var i = 0; i < c.prizes.length; i++)
                        _prizeRow(context, state, c.prizes[i], i),
                    ],
                    const SizedBox(height: 20),
                    _entryPanel(context, state, c),
                    const SizedBox(height: 20),
                    _resultPanel(context, state, c, mine),
                  ],
                );
                final aside = _aside(context, state, c);
                if (!wide) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      main,
                      const SizedBox(height: 20),
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

  Widget _header(BuildContext context, AppState state, ContestCard c) {
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    final pool = c.prizes.fold<int>(0, (s, p) => s + p.coins);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                Chip(
                  label: Text(t('contests.status.${c.status}')),
                  visualDensity: VisualDensity.compact,
                ),
                if (c.daysLeft > 0 && c.status == 'open')
                  Chip(
                    avatar: const Icon(Icons.schedule, size: 14),
                    label: Text(t('contests.daysLeft', {'n': c.daysLeft})),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              c.title,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w900,
              ),
            ),
            if (c.tagline.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                c.tagline,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.6,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 14),
            Wrap(
              spacing: 24,
              runSpacing: 12,
              children: [
                _fact(
                  context,
                  t('contest.detail.facts.words'),
                  _wordRange(state, c),
                ),
                _fact(
                  context,
                  t('contest.detail.facts.genre'),
                  c.genre.isEmpty ? t('contest.detail.genreAll') : c.genre,
                ),
                _fact(
                  context,
                  t('contest.detail.facts.ongoing'),
                  c.allowOngoing
                      ? t('contest.detail.allowYes')
                      : t('contest.detail.allowNo'),
                ),
                _fact(
                  context,
                  t('contest.detail.facts.prizes'),
                  pool > 0 ? '$pool' : '—',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _wordRange(AppState state, ContestCard c) {
    final t = state.t;
    if (c.minWords > 0 && c.maxWords > 0) {
      return t('contest.detail.facts.wordsRange', {
        'min': (c.minWords / 10000).round(),
        'max': (c.maxWords / 10000).round(),
      });
    }
    if (c.minWords > 0) {
      return t('contest.detail.facts.wordsMin', {
        'min': (c.minWords / 10000).round(),
      });
    }
    return '—';
  }

  Widget _fact(BuildContext context, String label, String value) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
      ],
    );
  }

  Widget _prizeRow(
    BuildContext context,
    AppState state,
    ContestPrizeView p,
    int index,
  ) {
    final cs = Theme.of(context).colorScheme;
    final label = switch (p.place) {
      '1' => state.t('contest.detail.prizePlace1'),
      '2' => state.t('contest.detail.prizePlace2'),
      '3' => state.t('contest.detail.prizePlace3'),
      _ => p.place,
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          radius: 16,
          backgroundColor: index == 0 ? cs.secondary : cs.primaryContainer,
          child: Text('${index + 1}'),
        ),
        title: Text(label),
        subtitle: p.extras.isEmpty ? null : Text(p.extras),
        trailing: p.coins > 0
            ? Text(
                state.t('contest.detail.prizeCoins', {'n': p.coins}),
                style: const TextStyle(fontWeight: FontWeight.w800),
              )
            : null,
      ),
    );
  }

  /* ------------------------- 报名 ------------------------- */

  Widget _entryPanel(BuildContext context, AppState state, ContestCard c) {
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    final peer = state.identity?.peerId ?? '';
    final entered = c.myEntry != null || _entries.any((e) => e.authorPeer == peer);

    if (peer.isEmpty) {
      return Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t('contest.detail.enterTitle'),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(t('contest.detail.needIdentity')),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: () => openCarouselHref(context, '/identity'),
              child: Text(t('contest.detail.createIdentity')),
            ),
          ],
        ),
      );
    }

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.send_outlined, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Text(
                t('contest.detail.enterTitle'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (entered) ...[
            Text(
              t('contest.detail.entryDone'),
              style: TextStyle(color: cs.onSurfaceVariant, height: 1.6),
            ),
            if (c.myEntry != null)
              Text(
                c.myEntry!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
              ),
          ] else if (c.status != 'open') ...[
            Text(
              t('contest.detail.resultPendingClosed'),
              style: TextStyle(color: cs.onSurfaceVariant, height: 1.6),
            ),
          ] else
            _entryForm(context, state, c),
        ],
      ),
    );
  }

  Widget _entryForm(BuildContext context, AppState state, ContestCard c) {
    return FutureBuilder<List<NovelCard>>(
      future: state.myNovels(),
      builder: (context, snap) {
        final t = state.t;
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(8),
            child: LinearProgressIndicator(),
          );
        }
        final works = snap.data ?? const <NovelCard>[];
        if (works.isEmpty) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t('contest.detail.noWorks')),
              const SizedBox(height: 10),
              OutlinedButton(
                onPressed: () => openCarouselHref(context, '/post'),
                child: Text(t('contest.detail.goPost')),
              ),
            ],
          );
        }
        return _EntryFormBody(
          contest: c,
          works: works,
          onDone: _reload,
        );
      },
    );
  }

  /* ------------------------- 结果 ------------------------- */

  Widget _resultPanel(
    BuildContext context,
    AppState state,
    ContestCard c,
    bool mine,
  ) {
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeading(title: t('contest.detail.resultTitle')),
        const SizedBox(height: 10),
        if (_results.isNotEmpty)
          for (final r in _results) _placementCard(context, state, c, r, mine)
        else if (mine)
          _announceForm(context, state, c)
        else
          Panel(
            child: Text(
              c.status == 'open'
                  ? t('contest.detail.resultPendingOpen')
                  : t('contest.detail.resultPendingClosed'),
              style: TextStyle(color: cs.onSurfaceVariant, height: 1.6),
            ),
          ),
        if (_results.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              t('contest.detail.payNote'),
              style: TextStyle(
                fontSize: 11.5,
                height: 1.5,
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }

  Widget _placementCard(
    BuildContext context,
    AppState state,
    ContestCard c,
    ContestPlacementView r,
    bool mine,
  ) {
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    final prize = _prizeFor(c, r.place);
    final coins = prize?.coins ?? 0;
    final label = switch (r.place) {
      1 => t('contest.detail.prizePlace1'),
      2 => t('contest.detail.prizePlace2'),
      3 => t('contest.detail.prizePlace3'),
      _ => t('contest.detail.prizePlaceLabel', {'n': r.place}),
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(radius: 16, child: Text('${r.place}')),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            label,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          InkWell(
                            onTap: () => openCarouselHref(
                              context,
                              '/novel?id=${Uri.encodeComponent(r.novelId)}',
                            ),
                            child: Text(
                              r.novelTitle,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: cs.primary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      InkWell(
                        onTap: () => openCarouselHref(
                          context,
                          '/author?id=${Uri.encodeComponent(r.authorPeer)}',
                        ),
                        child: Text(
                          r.authorName.isEmpty ? r.authorPeer : r.authorName,
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                      if (r.note != null && r.note!.isNotEmpty)
                        Text(
                          r.note!,
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                if (coins > 0)
                  Text(
                    t('contest.detail.prizeCoins', {'n': coins}),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
              ],
            ),
            if (mine) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: coins <= 0
                    ? Text(
                        t('contest.detail.noPrize'),
                        style: TextStyle(
                          fontSize: 11.5,
                          color: cs.onSurfaceVariant,
                        ),
                      )
                    : r.prizePaid
                    ? Chip(
                        avatar: Icon(Icons.check, size: 14, color: cs.primary),
                        label: Text(t('contest.detail.paid')),
                        visualDensity: VisualDensity.compact,
                      )
                    : FilledButton.tonalIcon(
                        onPressed: _busy
                            ? null
                            : () => _payPrize(c.id, r.novelId),
                        icon: const Icon(Icons.payments_outlined, size: 16),
                        label: Text(t('contest.detail.pay')),
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  ContestPrizeView? _prizeFor(ContestCard c, int place) {
    for (final p in c.prizes) {
      if (p.place == '$place') return p;
    }
    return null;
  }

  Future<void> _payPrize(String contestId, String novelId) async {
    final state = context.read<AppState>();
    setState(() => _busy = true);
    try {
      await payContestPrize(contestId: contestId, novelId: novelId);
      await state.refresh();
      await _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _announceForm(BuildContext context, AppState state, ContestCard c) {
    final t = state.t;
    if (_entries.isEmpty) {
      return Panel(child: Text(t('contest.detail.resultNoEntries')));
    }
    return _AnnounceForm(contest: c, entries: _entries, onDone: _reload);
  }

  /* ------------------------- 侧栏 ------------------------- */

  Widget _aside(BuildContext context, AppState state, ContestCard c) {
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t('contest.detail.sponsor'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              InkWell(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => PublisherDetailPage(publisherId: c.publisherPeer),
                  ),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 18,
                      child: Text(
                        c.publisherName.isEmpty
                            ? '?'
                            : c.publisherName.substring(0, 1),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            c.publisherName,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          Text(
                            '…${_tail(c.publisherPeer)}',
                            style: TextStyle(
                              fontSize: 11,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text(
                t('contest.detail.sponsorNote'),
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.6,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t('contest.detail.schedule'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              _timeRow(
                context,
                t('contest.detail.deadline'),
                _date(state.locale, c.deadline),
                highlight: true,
              ),
              _timeRow(
                context,
                t('contest.detail.announce'),
                _date(state.locale, c.announceAt),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${t('contest.detail.entries.title')}: ${c.entries}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                t('contest.detail.entries.body'),
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.6,
                  color: cs.onSurfaceVariant,
                ),
              ),
              if (_entries.isNotEmpty) ...[
                const SizedBox(height: 8),
                for (final e in _entries.take(8))
                  InkWell(
                    onTap: () => openCarouselHref(
                      context,
                      '/novel?id=${Uri.encodeComponent(e.novelId)}',
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Text(
                        e.novelTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _timeRow(
    BuildContext context,
    String label,
    String value, {
    bool highlight = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 58,
            child: Text(
              label,
              style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: highlight ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  String _date(String locale, String iso) {
    final d = DateTime.tryParse(iso)?.toLocal();
    if (d == null) return iso;
    try {
      return DateFormat.yMMMd(locale).format(d);
    } catch (_) {
      return DateFormat.yMMMd().format(d);
    }
  }

  String _tail(String peer) =>
      peer.length <= 12 ? peer : peer.substring(peer.length - 12);
}

/* ------------------------- 报名表单 ------------------------- */

class _EntryFormBody extends StatefulWidget {
  const _EntryFormBody({
    required this.contest,
    required this.works,
    required this.onDone,
  });

  final ContestCard contest;
  final List<NovelCard> works;
  final Future<void> Function() onDone;

  @override
  State<_EntryFormBody> createState() => _EntryFormBodyState();
}

class _EntryFormBodyState extends State<_EntryFormBody> {
  String? _novelId;
  EntryCheckView? _check;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _novelId = widget.works.first.id;
    _runCheck();
  }

  Future<void> _runCheck() async {
    final id = _novelId;
    if (id == null) return;
    try {
      final r = await checkEntry(
        contestId: widget.contest.id,
        novelId: id,
      );
      if (!mounted) return;
      setState(() => _check = r);
    } catch (_) {}
  }

  Future<void> _submit() async {
    final state = context.read<AppState>();
    final id = _novelId;
    if (id == null || _check?.ok != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await submitEntry(contestId: widget.contest.id, novelId: id);
      await state.refresh();
      await widget.onDone();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(state.t('contest.detail.entered'))),
      );
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    final selected = _novelId ?? widget.works.first.id;
    final chosen = widget.works.where((w) => w.id == selected).firstOrNull ??
        widget.works.first;
    final check = _check;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.works.length > 1)
          DropdownButtonFormField<String>(
            initialValue: selected,
            decoration: InputDecoration(labelText: t('contest.detail.entryChoose')),
            items: [
              for (final w in widget.works)
                DropdownMenuItem(value: w.id, child: Text(w.title)),
            ],
            onChanged: (v) {
              setState(() {
                _novelId = v;
                _check = null;
              });
              _runCheck();
            },
          )
        else
          Text(
            t('contest.detail.entryWillUse', {
              'title': chosen.title,
              'n': chosen.words,
            }),
          ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: check?.ok == true
                ? cs.primaryContainer.withValues(alpha: 0.4)
                : cs.surfaceContainerLow,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            check == null
                ? t('contest.detail.entrySubmitting')
                : check.ok
                ? t('contest.detail.entryOk')
                : t(check.reasonKey, {'need': check.need, 'have': check.have}),
            style: const TextStyle(height: 1.5),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: cs.error, fontSize: 12)),
        ],
        const SizedBox(height: 10),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _busy || check?.ok != true ? null : _submit,
              icon: const Icon(Icons.send, size: 16),
              label: Text(
                _busy
                    ? t('contest.detail.entrySubmitting')
                    : t('contest.detail.entrySubmit'),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              t('contest.detail.entryNote'),
              style: TextStyle(
                fontSize: 11,
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/* ------------------------- 公布名次 ------------------------- */

class _AnnounceForm extends StatefulWidget {
  const _AnnounceForm({
    required this.contest,
    required this.entries,
    required this.onDone,
  });

  final ContestCard contest;
  final List<ContestEntryView> entries;
  final Future<void> Function() onDone;

  @override
  State<_AnnounceForm> createState() => _AnnounceFormState();
}

class _AnnounceFormState extends State<_AnnounceForm> {
  final Map<int, String> _picks = {};
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    final state = context.read<AppState>();
    final rows = <ContestPlacementInput>[];
    for (final place in [1, 2, 3]) {
      final id = _picks[place];
      if (id == null || id.isEmpty) continue;
      rows.add(ContestPlacementInput(place: place, novelId: id));
    }
    if (rows.isEmpty) {
      setState(() => _error = state.t('contest.detail.resultErrEmpty'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await publishContestResult(
        contestId: widget.contest.id,
        placements: rows,
      );
      await state.refresh();
      await widget.onDone();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t('contest.detail.resultHint'),
            style: TextStyle(height: 1.6, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          for (final place in [1, 2, 3]) ...[
            Row(
              children: [
                SizedBox(
                  width: 84,
                  child: Text(
                    switch (place) {
                      1 => t('contest.detail.prizePlace1'),
                      2 => t('contest.detail.prizePlace2'),
                      _ => t('contest.detail.prizePlace3'),
                    },
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _picks[place],
                    isExpanded: true,
                    decoration: const InputDecoration(isDense: true),
                    items: [
                      DropdownMenuItem(
                        value: '',
                        child: Text(t('contest.detail.resultSkip')),
                      ),
                      for (final e in widget.entries)
                        DropdownMenuItem(
                          value: e.novelId,
                          child: Text(
                            '${e.novelTitle} — ${e.authorName}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) => setState(() => _picks[place] = v ?? ''),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          if (_error != null)
            Text(_error!, style: TextStyle(color: cs.error, fontSize: 12)),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : _submit,
                icon: const Icon(Icons.campaign_outlined, size: 16),
                label: Text(
                  _busy
                      ? t('contest.detail.resultSubmitting')
                      : t('contest.detail.resultSubmit'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  t('contest.detail.resultRevocable'),
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
