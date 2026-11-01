import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../src/rust/api.dart';
import '../src/rust/domain/view.dart';
import '../state/app_state.dart';
import '../state/badges.dart';
import '../widgets/widgets.dart';
import 'novel_page.dart';

/// 作者主页。
///
/// 勋章**不是自己填的**，而是社区用签名 op 授予的；界面上不设等级，
/// 每一枚都写明是谁给的。笔名与身份标识始终同时展示 ——
/// 笔名可能撞名，peerId 不会。
class AuthorPage extends StatefulWidget {
  const AuthorPage({super.key, required this.peer});

  final String peer;

  @override
  State<AuthorPage> createState() => _AuthorPageState();
}

class _AuthorPageState extends State<AuthorPage> {
  ProfileCard? _profile;
  List<NovelCard> _works = [];
  List<CertificateCard> _certificates = [];
  CertificateEligibilityView? _eligibility;
  bool _loading = true;
  String? _openBadge;
  bool _pendingOpen = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await profile(peer: widget.peer);
    final all = await listNovels(
      q: '',
      genre: '',
      status: '',
      tag: '',
      sort: 'update',
    );
    final certs = await certificates(peer: widget.peer);
    CertificateEligibilityView? eligibility;
    try {
      eligibility = await certificateEligibility(peer: widget.peer);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _profile = p;
      _works = all
          .where((n) => n.authorPeer == widget.peer && !n.deleted)
          .toList(growable: false);
      _certificates = certs;
      _eligibility = eligibility;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final p = _profile;
    final cs = Theme.of(context).colorScheme;

    final earned = p == null
        ? <BadgeCard>[]
        : p.badges.where((b) => b.earned).toList();
    final pending = p == null
        ? <BadgeCard>[]
        : p.badges.where((b) => !b.earned).toList();
    final me = state.identity?.peerId ?? '';
    final canGrant =
        p != null && me.isNotEmpty && me != p.peerId && pending.isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: Text(p?.name ?? t('common.author'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : p == null
          ? Center(child: Text(t('common.empty')))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Card(
                        margin: EdgeInsets.zero,
                        child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    width: 72,
                                    height: 72,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: cs.primary,
                                      borderRadius: BorderRadius.circular(18),
                                    ),
                                    child: Text(
                                      p.name.isEmpty
                                          ? '?'
                                          : p.name.characters.first,
                                      style: TextStyle(
                                        color: cs.onPrimary,
                                        fontSize: 28,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 4,
                                          crossAxisAlignment:
                                              WrapCrossAlignment.center,
                                          children: [
                                            Text(
                                              p.name,
                                              style: Theme.of(
                                                context,
                                              ).textTheme.headlineSmall,
                                            ),
                                            if (me.isNotEmpty && me == p.peerId)
                                              Chip(
                                                avatar: Icon(
                                                  Icons.badge_outlined,
                                                  size: 15,
                                                  color: cs.primary,
                                                ),
                                                label: Text(t('author.isYou')),
                                                visualDensity:
                                                    VisualDensity.compact,
                                              ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          p.bio.isEmpty
                                              ? (me == p.peerId
                                                    ? t('author.bioEmpty.mine')
                                                    : t('author.bioEmpty'))
                                              : p.bio,
                                          style: TextStyle(
                                            fontSize: 13,
                                            height: 1.6,
                                            color: cs.onSurfaceVariant,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          p.derivedName
                                              ? t('identity.derived')
                                              : t('identity.custom'),
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: cs.onSurfaceVariant,
                                              ),
                                        ),
                                        const SizedBox(height: 4),
                                        SelectableText(
                                          p.peerId,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                fontFamily: 'monospace',
                                                color: cs.onSurfaceVariant,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              const Divider(height: 1),
                              const SizedBox(height: 12),
                              LayoutBuilder(
                                builder: (context, box) {
                                  final columns = box.maxWidth >= 520 ? 4 : 2;
                                  final width =
                                      (box.maxWidth - (columns - 1) * 12) /
                                      columns;
                                  final items = [
                                    (
                                      t('author.education.books'),
                                      '${_works.length}',
                                    ),
                                    (
                                      t('author.totalEpisodes'),
                                      '${p.chapters}',
                                    ),
                                    (
                                      t('author.totalWords'),
                                      _formatCount(p.totalWords),
                                    ),
                                    (
                                      t('author.latestUpdate'),
                                      _latestDate,
                                    ),
                                  ];
                                  return Wrap(
                                    spacing: 12,
                                    runSpacing: 12,
                                    children: [
                                      for (final item in items)
                                        SizedBox(
                                          width: width,
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
                                                  fontSize: 15,
                                                  fontWeight: FontWeight.w800,
                                                  color: cs.onSurface,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                    ],
                                  );
                                },
                              ),
                              if (p.joinedAt != null) ...[
                                const SizedBox(height: 10),
                                const Divider(height: 1),
                                const SizedBox(height: 8),
                                Text(
                                  t('author.joinedAt', {
                                    'date': _isoDate(p.joinedAt),
                                  }),
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      _EducationPanel(profile: p),
                      const SizedBox(height: 16),
                      _RecordPanel(profile: p),
                      const SizedBox(height: 24),
                      SectionHeading(
                        title: t('author.worksTitle'),
                        subtitle: t('author.worksSub'),
                      ),
                      const SizedBox(height: 10),
                      if (_works.isEmpty)
                        Panel(child: Text(t('author.noWorks')))
                      else
                        for (final n in _works)
                          NovelCardTile(
                            novel: n,
                            locale: state.locale,
                            onTap: () async {
                              await Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => NovelPage(novelId: n.id),
                                ),
                              );
                              if (mounted) await _load();
                            },
                          ),
                      if (me == p.peerId) ...[
                        const SizedBox(height: 16),
                        Panel(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.edit_outlined,
                                    size: 17,
                                    color: cs.primary,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    t('author.continue'),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                t('author.continue.body'),
                                style: TextStyle(
                                  fontSize: 12.5,
                                  height: 1.6,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      if (me != p.peerId) ...[
                        const SizedBox(height: 16),
                        Panel(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.info_outline,
                                    size: 17,
                                    color: cs.primary,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    t('author.howNumbers.title'),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                t('author.howNumbers.body'),
                                style: TextStyle(
                                  fontSize: 12.5,
                                  height: 1.6,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: SectionHeading(
                              title: t('author.badges.title'),
                              subtitle: t('author.badges.sub'),
                            ),
                          ),
                          if (canGrant)
                            FilledButton.tonalIcon(
                              icon: const Icon(Icons.add, size: 17),
                              label: Text(t('badge.grant')),
                              onPressed: () => _grantDialog(context, p),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (earned.isEmpty)
                        Panel(child: Text(t('author.badges.empty')))
                      else
                        Panel(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  for (final b in earned)
                                    _earnedChip(context, b),
                                ],
                              ),
                              if (_openBadge != null) ...[
                                const SizedBox(height: 14),
                                _badgeDetail(
                                  context,
                                  earned.firstWhere(
                                    (b) => b.id == _openBadge,
                                    orElse: () => earned.first,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      if (pending.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        TextButton.icon(
                          icon: Icon(
                            _pendingOpen
                                ? Icons.expand_less
                                : Icons.expand_more,
                            size: 18,
                          ),
                          label: Text(
                            '${t('author.badges.pending')} · '
                            '${t('badge.pending', {'n': pending.length})}',
                          ),
                          onPressed: () =>
                              setState(() => _pendingOpen = !_pendingOpen),
                        ),
                        if (_pendingOpen)
                          Panel(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (final b in pending) ...[
                                  Text(
                                    t(badgeDef(b.id)?.titleKey ?? b.id),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    t(badgeDef(b.id)?.criteriaKey ?? ''),
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(color: cs.onSurfaceVariant),
                                  ),
                                  const SizedBox(height: 10),
                                ],
                              ],
                            ),
                          ),
                      ],
                      const SizedBox(height: 24),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: SectionHeading(
                              title: t('cert.title'),
                              subtitle: t('cert.endorseHint'),
                            ),
                          ),
                          if (me.isNotEmpty && me != p.peerId)
                            FilledButton.tonalIcon(
                              icon: const Icon(
                                Icons.workspace_premium,
                                size: 18,
                              ),
                              label: Text(t('cert.endorse')),
                              onPressed: () => _endorseDialog(p),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (me == p.peerId && _eligibility != null)
                        Panel(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    _eligibility!.eligible
                                        ? Icons.verified_outlined
                                        : Icons.hourglass_empty,
                                    size: 18,
                                    color: _eligibility!.eligible
                                        ? cs.primary
                                        : cs.outline,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    _eligibility!.eligible
                                        ? t('cert.eligible')
                                        : t('cert.notEligible'),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              _checkLine(
                                context,
                                _eligibility!.yearsOk,
                                t('cert.yearsOk'),
                              ),
                              _checkLine(
                                context,
                                _eligibility!.peakOk,
                                t('cert.peakOk'),
                              ),
                              if (_eligibility!.peakWorkTitle.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Text(
                                  '${t('cert.peak')}: '
                                  '${_eligibility!.peakWorkTitle} · '
                                  '${t('cert.clicks', {'n': _eligibility!.peakWorkClicks})}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ],
                          ),
                        ),
                      if (_certificates.isEmpty)
                        Panel(child: Text(t('cert.none')))
                      else
                        for (final c in _certificates)
                          Card(
                            margin: const EdgeInsets.only(bottom: 10),
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        c.issuerVerified
                                            ? Icons.verified
                                            : Icons
                                                  .report_gmailerrorred_outlined,
                                        size: 16,
                                        color: c.issuerVerified
                                            ? cs.primary
                                            : cs.error,
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          t('cert.issuedBy', {
                                            'name': c.issuerName.isEmpty
                                                ? c.issuerPeer
                                                : c.issuerName,
                                          }),
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                      Text(
                                        c.issuerVerified
                                            ? t('cert.verified')
                                            : t('cert.unverified'),
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: c.issuerVerified
                                              ? cs.primary
                                              : cs.error,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 6,
                                    children: [
                                      Chip(
                                        label: Text(
                                          t('cert.years', {
                                            'n': c.yearsWriting.toStringAsFixed(
                                              1,
                                            ),
                                          }),
                                        ),
                                      ),
                                      if (c.peakWorkTitle.isNotEmpty)
                                        Chip(
                                          label: Text(
                                            '${t('cert.peak')}: ${c.peakWorkTitle}',
                                          ),
                                        ),
                                      Chip(
                                        label: Text(
                                          t('cert.clicks', {
                                            'n': c.peakWorkClicks,
                                          }),
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (c.note.isNotEmpty) ...[
                                    const SizedBox(height: 6),
                                    Text(c.note),
                                  ],
                                ],
                              ),
                            ),
                          ),
                      const SizedBox(height: 8),
                      if (p.linkUrl.isNotEmpty) ...[
                        const SizedBox(height: 24),
                        SectionHeading(title: t('author.links')),
                        const SizedBox(height: 12),
                        for (var i = 0; i < p.linkUrl.length; i++)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.link, size: 18),
                            title: Text(
                              p.linkLabel.length > i &&
                                      p.linkLabel[i].isNotEmpty
                                  ? p.linkLabel[i]
                                  : p.linkUrl[i],
                            ),
                            subtitle: Text(
                              p.linkPlatform.length > i
                                  ? p.linkPlatform[i]
                                  : '',
                            ),
                            trailing: const Icon(Icons.open_in_new, size: 16),
                            onTap: () => _openLink(p.linkUrl[i]),
                          ),
                      ],
                      const SizedBox(height: 24),
                      _TipPanel(
                        profile: p,
                        isMe: me == p.peerId,
                        onTip: () => _tipDialog(p),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  /// 最近一次更新的日期（毫秒时间戳来自 NovelCard）。
  String get _latestDate {
    var ms = 0;
    for (final n in _works) {
      if (n.updatedAtMs > ms) ms = n.updatedAtMs;
    }
    return ms == 0 ? '—' : _msDate(ms);
  }

  String _formatCount(int n) {
    final s = n.abs().toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return n < 0 ? '-$buf' : buf.toString();
  }

  String _msDate(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  String _isoDate(String? iso) {
    if (iso == null || iso.isEmpty) return '—';
    final d = DateTime.tryParse(iso)?.toLocal();
    return d == null ? iso : _msDate(d.millisecondsSinceEpoch);
  }

  Future<void> _openLink(String raw) async {
    var url = raw.trim();
    if (url.isEmpty) return;
    if (!url.contains('://') && !url.startsWith('mailto:')) {
      url = url.contains('@') && !url.contains('/')
          ? 'mailto:$url'
          : 'https://$url';
    }
    final uri = Uri.tryParse(url);
    var ok = false;
    if (uri != null) {
      try {
        ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {}
    }
    if (!ok && mounted) {
      showError(context, url);
    }
  }

  Future<void> _tipDialog(ProfileCard p) async {
    final state = context.read<AppState>();
    final t = state.t;
    final balance = state.walletSummary?.balance ?? 0;
    final ctrl = TextEditingController(text: '10');
    var amount = 10;
    final sent = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text('${t('novel.tip')} · ${p.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t('wallet.balanceValue', {'n': balance})),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  for (final v in [10, 50, 200])
                    ChoiceChip(
                      label: Text('◈ $v'),
                      selected: amount == v,
                      onSelected: (_) {
                        setDialog(() => amount = v);
                        ctrl.text = '$v';
                      },
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: t('wallet.amount')),
                onChanged: (v) =>
                    setDialog(() => amount = int.tryParse(v.trim()) ?? 0),
              ),
              if (amount <= 0 || amount > balance) ...[
                const SizedBox(height: 8),
                Text(
                  t('wallet.insufficient'),
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(t('common.cancel')),
            ),
            FilledButton(
              onPressed: amount <= 0 || amount > balance
                  ? null
                  : () => Navigator.pop(ctx, amount),
              child: Text(t('common.confirm')),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    if (sent == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await tip(toPeer: p.peerId, amount: sent, reason: null);
      if (!mounted) return;
      await state.refresh();
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(t('wallet.sent', {'n': sent}))),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('${t('error.prefix')}$e')));
    }
  }

  Widget _earnedChip(BuildContext context, BadgeCard b) {
    final def = badgeDef(b.id);
    final state = context.read<AppState>();
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    final open = _openBadge == b.id;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => setState(() => _openBadge = open ? null : b.id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: open ? cs.primaryContainer : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: open ? cs.primary : cs.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.military_tech,
              size: 15,
              color: open ? cs.primary : cs.onSurfaceVariant,
            ),
            const SizedBox(width: 5),
            Text(
              t(def?.titleKey ?? b.id),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: open ? cs.primary : cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _badgeDetail(BuildContext context, BadgeCard b) {
    final state = context.read<AppState>();
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    final def = badgeDef(b.id);
    final names = b.granters
        .map((g) => g.length > 8 ? g.substring(g.length - 8) : g)
        .join(', ');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t(def?.titleKey ?? b.id),
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
          ),
          if (def != null) ...[
            const SizedBox(height: 3),
            Text(t(def.descKey), style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 6),
          Text(
            t('badge.grantedBy', {'names': names.isEmpty ? '—' : names}),
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
          for (final n in b.notes.take(3))
            Text(
              '“$n”',
              style: TextStyle(
                fontSize: 11,
                fontStyle: FontStyle.italic,
                color: cs.onSurfaceVariant,
              ),
            ),
          const SizedBox(height: 3),
          Text(
            t('badge.earnedAt', {'date': _hlcDate(b.earnedAt)}),
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Future<void> _grantDialog(BuildContext context, ProfileCard p) async {
    final state = context.read<AppState>();
    final t = state.t;
    final messenger = ScaffoldMessenger.of(context);
    final earnedIds = p.badges.where((b) => b.earned).map((b) => b.id).toSet();
    final available = kBadges.where((b) => !earnedIds.contains(b.id)).toList();
    String? picked;
    var busy = false;
    var granted = false;
    final note = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) {
          final def = picked == null ? null : badgeDef(picked!);
          return AlertDialog(
            title: Text(t('badge.grant')),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t('badge.grantIntro'),
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    if (available.isEmpty)
                      Text(t('badge.allGranted'))
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final b in available)
                            ChoiceChip(
                              label: Text(t(b.titleKey)),
                              selected: picked == b.id,
                              onSelected: (_) => setDialog(() => picked = b.id),
                            ),
                        ],
                      ),
                    if (def != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Theme.of(ctx)
                              .colorScheme
                              .surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          t(def.criteriaKey),
                          style: Theme.of(ctx).textTheme.bodySmall,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      controller: note,
                      maxLength: 200,
                      maxLines: 2,
                      decoration: InputDecoration(labelText: t('badge.notePh')),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      t('badge.grantNote'),
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
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
                onPressed: (picked == null || busy)
                    ? null
                    : () async {
                        setDialog(() => busy = true);
                        try {
                          await grantBadge(
                            targetPeer: p.peerId,
                            badgeId: picked!,
                            note: note.text.trim(),
                          );
                          granted = true;
                          if (!ctx.mounted) return;
                          Navigator.pop(ctx);
                        } catch (e) {
                          setDialog(() => busy = false);
                          if (ctx.mounted) showError(ctx, e);
                        }
                      },
                child: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(t('badge.grantSubmit')),
              ),
            ],
          );
        },
      ),
    );

    note.dispose();
    if (!granted || !mounted) return;
    await state.refresh();
    if (!mounted) return;
    await _load();
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(content: Text(t('badge.granted'))));
  }

  Widget _checkLine(BuildContext context, bool ok, String text) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle_outline : Icons.circle_outlined,
            size: 14,
            color: ok ? cs.primary : cs.outline,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }

  Future<void> _endorseDialog(ProfileCard p) async {
    final state = context.read<AppState>();
    final t = state.t;
    final note = TextEditingController();
    final startedAt = TextEditingController(
      text: _eligibility?.startedAt?.substring(0, 10) ?? '',
    );
    final years = TextEditingController(
      text: (_eligibility?.yearsWriting ?? 3).toString(),
    );
    final peakTitle = TextEditingController(
      text: _eligibility?.peakWorkTitle ?? '',
    );
    final clicks = TextEditingController(
      text: (_eligibility?.peakWorkClicks ?? 0).toString(),
    );
    final year = TextEditingController(
      text: (_eligibility?.peakYear ?? DateTime.now().year).toString(),
    );
    var busy = false;
    var done = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(t('cert.endorse')),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t('cert.endorseHint'),
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: note,
                    maxLines: 2,
                    decoration: InputDecoration(labelText: t('cert.note')),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: startedAt,
                    decoration: InputDecoration(labelText: t('cert.startedAt')),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: years,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: t('cert.years', {'n': ''}),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: year,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: t('cert.peakYear'),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: peakTitle,
                    decoration: InputDecoration(labelText: t('cert.peakTitle')),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: clicks,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: t('cert.peakClicks'),
                    ),
                  ),
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
                      final y = double.tryParse(years.text.trim()) ?? 0;
                      final c = int.tryParse(clicks.text.trim()) ?? 0;
                      final yr = int.tryParse(year.text.trim()) ?? 0;
                      if (y <= 0 || c <= 0 || yr <= 0) {
                        showError(ctx, t('cert.endorseHint'));
                        return;
                      }
                      setDialog(() => busy = true);
                      try {
                        await putCertificate(
                          targetPeer: p.peerId,
                          note: note.text.trim(),
                          startedAt: startedAt.text.trim(),
                          yearsWriting: y,
                          peakWorkTitle: peakTitle.text.trim(),
                          peakWorkClicks: c,
                          peakYear: yr,
                        );
                        done = true;
                        if (!ctx.mounted) return;
                        Navigator.pop(ctx);
                      } catch (e) {
                        setDialog(() => busy = false);
                        if (ctx.mounted) showError(ctx, e);
                      }
                    },
              child: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(t('cert.endorse')),
            ),
          ],
        ),
      ),
    );
    note.dispose();
    startedAt.dispose();
    years.dispose();
    peakTitle.dispose();
    clicks.dispose();
    year.dispose();
    if (!done || !mounted) return;
    await state.refresh();
    if (!mounted) return;
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(t('cert.submitted'))));
  }

  /// HLC 是 `"base36(wall):counter:node"`，取出物理时间给界面看，时钟细节留给机器。
  String _hlcDate(String h) {
    final wall = int.tryParse(h.split(':').first, radix: 36);
    if (wall == null || wall <= 0) return h;
    final d = DateTime.fromMillisecondsSinceEpoch(wall);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }
}

/// 站内学历：从本机副本算出来的事实，不是自我声明的资历 —— 这里没有「名校毕业」这一项。
class _EducationPanel extends StatelessWidget {
  const _EducationPanel({required this.profile});

  final ProfileCard profile;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    final items = [
      (
        t('author.education.tenure'),
        t('author.unit.days', {'n': profile.tenureDays}),
      ),
      (
        t('author.education.continuity'),
        t('author.unit.years', {'n': profile.continuousYears}),
      ),
      (t('author.education.books'), '${profile.works}'),
      (t('author.education.clicks'), '≈ ${_count(profile.clicks)}'),
    ];
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.school_outlined, size: 17, color: cs.primary),
              const SizedBox(width: 6),
              Text(
                t('author.education.title'),
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            t('author.education.sub'),
            style: TextStyle(
              fontSize: 11.5,
              height: 1.6,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, box) {
              final columns = box.maxWidth >= 520 ? 4 : 2;
              final width = (box.maxWidth - (columns - 1) * 12) / columns;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final item in items)
                    SizedBox(
                      width: width,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
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
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 8),
          Text(
            t('author.education.note'),
            style: TextStyle(
              fontSize: 11.5,
              height: 1.6,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            t('author.howNumbers.body'),
            style: TextStyle(fontSize: 11, height: 1.6, color: cs.outline),
          ),
        ],
      ),
    );
  }

  static String _count(int n) {
    final s = n.abs().toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return n < 0 ? '-$buf' : buf.toString();
  }
}

/// 档案：把公开记录里能算出来的其余聚合一次摆出来，省得逐个翻记录。
class _RecordPanel extends StatelessWidget {
  const _RecordPanel({required this.profile});

  final ProfileCard profile;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    final p = profile;
    final rows = <(String, String)>[
      (t('author.record.span'), t('author.unit.days', {'n': p.spanDays})),
      (t('author.record.reviews'), t('author.unit.times', {'n': p.reviewsFromOthers})),
      (
        t('author.record.tips'),
        t('author.record.tipsValue', {
          'total': p.tipsTotal,
          'n': p.tipsFromOthers,
        }),
      ),
      (
        t('author.record.contestEntries'),
        t('author.unit.times', {'n': p.contestEntries}),
      ),
      (
        t('author.record.translations'),
        t('author.unit.times', {'n': p.translations}),
      ),
      (
        t('author.record.contributions'),
        t('author.unit.times', {'n': p.contributions}),
      ),
      (
        t('author.record.groups'),
        t('author.unit.times', {'n': p.groupMemberships}),
      ),
      (
        t('author.record.contestWins'),
        t('author.unit.times', {'n': p.contestWins}),
      ),
      (
        t('author.record.deals'),
        t('author.unit.times', {'n': p.acceptedDeals}),
      ),
    ];
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.fact_check_outlined, size: 17, color: cs.primary),
              const SizedBox(width: 6),
              Text(
                t('author.record.title'),
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, box) {
              final columns = box.maxWidth >= 620 ? 3 : 2;
              final width = (box.maxWidth - (columns - 1) * 12) / columns;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final row in rows)
                    SizedBox(
                      width: width,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            row.$1,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            row.$2,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 打赏：先看「TA 收到过多少」，再决定要不要掏钱。
class _TipPanel extends StatelessWidget {
  const _TipPanel({
    required this.profile,
    required this.isMe,
    required this.onTip,
  });

  final ProfileCard profile;
  final bool isMe;
  final VoidCallback onTip;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.volunteer_activism_outlined,
                size: 17,
                color: cs.primary,
              ),
              const SizedBox(width: 6),
              Text(
                t('author.tip.title'),
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            t('author.tip.sub'),
            style: TextStyle(
              fontSize: 11.5,
              height: 1.6,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Text(
                  t('author.tip.received'),
                  style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
                ),
                const SizedBox(width: 8),
                Text(
                  '◈ ${profile.tipsTotal}',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '(${profile.tipsFromOthers})',
                  style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (!isMe) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              icon: const Icon(Icons.volunteer_activism_outlined, size: 18),
              label: Text(t('author.tip.cta')),
              onPressed: onTip,
            ),
          ],
        ],
      ),
    );
  }
}