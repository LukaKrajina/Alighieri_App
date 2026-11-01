import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../src/rust/api.dart';
import '../src/rust/domain/view.dart';
import '../state/app_state.dart';
import '../state/review_gate.dart';
import '../widgets/collab_panels.dart';
import '../widgets/href.dart';
import '../widgets/widgets.dart';
import 'author_page.dart';
import 'post_page.dart';
import 'reader_page.dart';
import 'work_edit_page.dart';

class NovelPage extends StatefulWidget {
  const NovelPage({super.key, required this.novelId});

  final String novelId;

  @override
  State<NovelPage> createState() => _NovelPageState();
}

class _NovelPageState extends State<NovelPage> {
  NovelCard? _novel;
  List<ChapterView> _chapters = [];
  List<ReviewView> _reviews = [];
  ForkCard? _forkSource;
  bool _loading = true;
  final _reviewCtrl = TextEditingController();
  double _rating = 5;
  bool _spoiler = false;

  /// 本机在这部作品上的累计阅读秒数（各话相加）。
  /// 与 Web 版一致：整部作品评论门槛 60 秒。
  int _readSeconds = 0;
  static const _requiredReadSeconds = 60;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _reviewCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final n = await getNovel(novelId: widget.novelId);
      final cs = await getChapters(novelId: widget.novelId);
      final rs = await getReviews(novelId: widget.novelId);
      final read = await myReadSeconds(novelId: widget.novelId, chapterNo: 0);
      final source = await forkSource(novelId: widget.novelId);
      if (!mounted) return;
      setState(() {
        _novel = n;
        _chapters = cs;
        _reviews = rs;
        _readSeconds = read;
        _forkSource = source;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        showError(context, e);
      }
    }
  }

  Future<void> _act(Future<void> Function() fn) async {
    try {
      await fn();
      if (!mounted) return;
      await context.read<AppState>().refresh();
      if (!mounted) return;
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final cs = Theme.of(context).colorScheme;

    if (_loading) return const Center(child: CircularProgressIndicator());
    final n = _novel;
    if (n == null) {
      return Center(child: Text(t('common.empty')));
    }
    final isAuthor = state.identity?.peerId == n.authorPeer;

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(n.title, overflow: TextOverflow.ellipsis),
          actions: [
            if (isAuthor)
              IconButton(
                tooltip: t('post.editWork'),
                icon: const Icon(Icons.edit_outlined),
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => WorkEditPage(novelId: n.id),
                    ),
                  );
                  if (mounted) await _load();
                },
              ),
          ],
          bottom: TabBar(
            tabs: [
              Tab(text: t('novel.tab.about')),
              Tab(text: t('novel.tab.toc')),
              Tab(text: t('novel.tab.collab')),
              Tab(text: t('novel.tab.deals')),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _aboutTab(context, state, n, isAuthor, cs),
            _chaptersTab(context, state, n),
            _scrollTab(
              CollabPanel(
                novelId: n.id,
                authorPeer: n.authorPeer,
                license: n.license,
                chapters: _chapters,
                onChanged: _load,
                onOpenNovel: _openNovel,
              ),
            ),
            _scrollTab(
              DealPanel(
                novelId: n.id,
                authorPeer: n.authorPeer,
                authorName: n.authorName,
                onChanged: _load,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _scrollTab(Widget child) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: child,
        ),
      ),
    );
  }

  Widget _aboutTab(
    BuildContext context,
    AppState state,
    NovelCard n,
    bool isAuthor,
    ColorScheme cs,
  ) {
    final t = state.t;
    final genreLabel = n.genreName.isNotEmpty ? n.genreName : n.genre;
    final badge = isAuthor ? t('novel.badge.mine') : t('novel.badge.synced');
    final badgeHint = isAuthor
        ? t('novel.badge.mine.title')
        : t('novel.badge.synced.title');
    final tagline = n.tagline.isNotEmpty ? n.tagline : n.synopsis;
    final awardPlace = n.awardPlace;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  InkWell(
                    onTap: () => openCarouselHref(context, '/'),
                    child: Text(
                      t('nav.home'),
                      style: TextStyle(fontSize: 12, color: cs.primary),
                    ),
                  ),
                  Text(
                    '/',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                  InkWell(
                    onTap: () => openCarouselHref(context, '/browse'),
                    child: Text(
                      genreLabel,
                      style: TextStyle(fontSize: 12, color: cs.primary),
                    ),
                  ),
                  Text(
                    '/',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                  Text(
                    n.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (n.flagged)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: cs.error.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: cs.error.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.flag_outlined, color: cs.error),
                      const SizedBox(width: 10),
                      Expanded(child: Text(t('review.honest'))),
                      TextButton(
                        onPressed: () =>
                            _act(() => setExempt(novelId: n.id, exempt: true)),
                        child: Text(t('review.exempt')),
                      ),
                    ],
                  ),
                ),
              Card(
                margin: EdgeInsets.zero,
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(height: 6, color: cs.primary),
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              _Tag(
                                text: t('status.${n.status}'),
                                fg: cs.onPrimary,
                                bg: cs.primary,
                              ),
                              InkWell(
                                borderRadius: BorderRadius.circular(99),
                                onTap: () =>
                                    openCarouselHref(context, '/browse'),
                                child: _Tag(
                                  text: genreLabel,
                                  fg: cs.onSurfaceVariant,
                                  bg: cs.surfaceContainerHighest,
                                ),
                              ),
                              if (awardPlace > 0)
                                _Tag(
                                  text: t(
                                    'award.place${awardPlace.clamp(1, 3)}',
                                  ),
                                  fg: cs.tertiary,
                                  bg: cs.tertiary.withValues(alpha: 0.12),
                                  icon: Icons.emoji_events_outlined,
                                ),
                              if (n.award != null && n.award!.isNotEmpty)
                                _Tag(
                                  text: n.award!,
                                  fg: cs.onSurfaceVariant,
                                  bg: cs.surfaceContainerHighest,
                                ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            n.title,
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(fontWeight: FontWeight.w900),
                          ),
                          const SizedBox(height: 5),
                          Tooltip(
                            message: badgeHint,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: isAuthor
                                    ? cs.surfaceContainerHighest
                                    : cs.primary.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(99),
                              ),
                              child: Text(
                                badge,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                  color: isAuthor
                                      ? cs.onSurfaceVariant
                                      : cs.primary,
                                ),
                              ),
                            ),
                          ),
                          if (tagline.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Text(
                              tagline,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14.5,
                                height: 1.6,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              InkWell(
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        AuthorPage(peer: n.authorPeer),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.person_outline,
                                      size: 14,
                                      color: cs.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 3),
                                    Text(
                                      n.authorName,
                                      style: const TextStyle(
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Text(
                                '·',
                                style: TextStyle(color: cs.onSurfaceVariant),
                              ),
                              Text(
                                t('common.chapters', {'n': n.episodes}),
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                              if (n.words > 0) ...[
                                Text(
                                  '·',
                                  style: TextStyle(color: cs.onSurfaceVariant),
                                ),
                                Text(
                                  _format(n.words),
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          if (n.tags.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: [
                                for (final tag in n.tags)
                                  InkWell(
                                    borderRadius: BorderRadius.circular(99),
                                    onTap: () =>
                                        openCarouselHref(context, '/browse'),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(99),
                                        border: Border.all(
                                          color: cs.outlineVariant,
                                        ),
                                      ),
                                      child: Text(
                                        '#$tag',
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          color: cs.onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              if (_chapters.isEmpty)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: cs.outlineVariant,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.cloud_download_outlined,
                                        size: 16,
                                        color: cs.onSurfaceVariant,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        t('novel.bodyPending'),
                                        style: TextStyle(
                                          fontSize: 12.5,
                                          color: cs.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                )
                              else ...[
                                FilledButton.icon(
                                  onPressed: () =>
                                      _openReader(_chapters.first.no),
                                  icon: const Icon(Icons.menu_book),
                                  label: Text(t('novel.start')),
                                ),
                                OutlinedButton.icon(
                                  onPressed: () => _openReader(_continueNo(n)),
                                  icon: const Icon(Icons.play_arrow),
                                  label: Text(
                                    n.progressNo > 0 &&
                                            _hasChapter(n.progressNo)
                                        ? t('novel.continue')
                                        : t('novel.readFromStart'),
                                  ),
                                ),
                              ],
                              OutlinedButton.icon(
                                onPressed: () => _act(
                                  () => setBookmark(
                                    novelId: n.id,
                                    on_: !n.inShelf,
                                  ),
                                ),
                                icon: Icon(
                                  n.inShelf
                                      ? Icons.bookmark
                                      : Icons.bookmark_border,
                                ),
                                label: Text(
                                  n.inShelf
                                      ? t('novel.removeShelf')
                                      : t('novel.addShelf'),
                                ),
                              ),
                              OutlinedButton.icon(
                                onPressed: () => _act(
                                  () => setStar(
                                    novelId: n.id,
                                    on_: !n.starredByMe,
                                  ),
                                ),
                                icon: Icon(
                                  n.starredByMe
                                      ? Icons.star
                                      : Icons.star_border,
                                ),
                                label: Text(
                                  '${t('novel.star')} ${_format(n.stars)}',
                                ),
                              ),
                              if (!isAuthor)
                                OutlinedButton.icon(
                                  onPressed: () => Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          PostPage(forkOf: n.id),
                                    ),
                                  ),
                                  icon: const Icon(Icons.call_split),
                                  label: Text(t('collab.fork.title')),
                                ),
                              OutlinedButton.icon(
                                onPressed: () =>
                                    _tipDialog(n.authorPeer, n.authorName),
                                icon: const Icon(
                                  Icons.volunteer_activism_outlined,
                                ),
                                label: Text(t('novel.tip')),
                              ),
                              TextButton.icon(
                                onPressed: () => _reportDialog(n.id),
                                icon: const Icon(Icons.flag_outlined),
                                label: Text(t('novel.report')),
                              ),
                            ],
                          ),
                          if (n.progressNo > 0) ...[
                            const SizedBox(height: 8),
                            Text(
                              t('novel.progressNote', {'n': n.progressNo}),
                              style: TextStyle(
                                fontSize: 11.5,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                          const SizedBox(height: 16),
                          Divider(height: 1, color: cs.outlineVariant),
                          const SizedBox(height: 12),
                          _FactRow(
                            items: [
                              (
                                t('novel.fact.episodes'),
                                t('common.chapters', {'n': n.episodes}),
                              ),
                              (
                                t('novel.fact.words'),
                                n.words > 0 ? _format(n.words) : '—',
                              ),
                              (
                                t('novel.fact.updated'),
                                _ago(state.locale, n.updatedAtMs),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          _FactRow(
                            items: [
                              (
                                t('pv.total'),
                                n.pvTotal > 0 ? _format(n.pvTotal) : '—',
                              ),
                              (
                                t('pv.weekly'),
                                n.pvWeekly > 0 ? _format(n.pvWeekly) : '—',
                              ),
                              (
                                t('pv.unique'),
                                n.uniqueReaders > 0
                                    ? _format(n.uniqueReaders)
                                    : '—',
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            t('pv.disclaimer'),
                            style: TextStyle(
                              fontSize: 11,
                              height: 1.55,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 14),
                          Wrap(
                            spacing: 16,
                            runSpacing: 8,
                            children: [
                              _MiniStat(
                                icon: Icons.star_border,
                                label: t('novel.stat.stars'),
                                value: n.stars,
                              ),
                              _MiniStat(
                                icon: Icons.call_split,
                                label: t('novel.stat.forks'),
                                value: n.forks,
                              ),
                              _MiniStat(
                                icon: Icons.group_outlined,
                                label: t('novel.stat.contributors'),
                                value: n.contributors,
                              ),
                              if (n.openPatches > 0)
                                _MiniStat(
                                  icon: Icons.merge_type,
                                  label: t('novel.stat.patches'),
                                  value: n.openPatches,
                                  color: cs.tertiary,
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              SectionHeading(title: t('novel.synopsis')),
              const SizedBox(height: 8),
              Panel(
                child: Text(
                  n.synopsis.isEmpty ? t('novel.synopsisEmpty') : n.synopsis,
                  style: const TextStyle(fontSize: 14, height: 1.8),
                ),
              ),
              if (_forkSource != null) ...[
                const SizedBox(height: 12),
                Card(
                  margin: EdgeInsets.zero,
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.call_split),
                    title: Text(
                      '${t('collab.forkSource')} · ${_forkSource!.sourceTitle}',
                    ),
                    subtitle: Text(_forkSource!.byName),
                    onTap: () => _openNovel(_forkSource!.sourceId),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t('novel.reactions'),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _ReactionButton(
                          icon: Icons.thumb_up_outlined,
                          label: t('novel.reaction.like'),
                          count: n.likes,
                          onTap: () => _act(
                            () => addReaction(novelId: n.id, kind: 'like'),
                          ),
                        ),
                        _ReactionButton(
                          icon: Icons.lightbulb_outline,
                          label: t('novel.reaction.insightful'),
                          count: n.insightful,
                          onTap: () => _act(
                            () =>
                                addReaction(novelId: n.id, kind: 'insightful'),
                          ),
                        ),
                        _ReactionButton(
                          icon: Icons.favorite_border,
                          label: t('novel.reaction.cry'),
                          count: n.cry,
                          onTap: () => _act(
                            () => addReaction(novelId: n.id, kind: 'cry'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      t('novel.reactionsHint'),
                      style: TextStyle(
                        fontSize: 11.5,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              SectionHeading(title: t('novel.reviews')),
              const SizedBox(height: 12),
              if (_readSeconds < _requiredReadSeconds)
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t('review.needRead', {
                          'have': _readSeconds,
                          'need': _requiredReadSeconds,
                          'scope': t('review.scope.work'),
                        }),
                      ),
                      const SizedBox(height: 10),
                      LinearProgressIndicator(
                        value: (_readSeconds / _requiredReadSeconds).clamp(
                          0,
                          1,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        t('review.readGateHint'),
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                )
              else ...[
                TextField(
                  controller: _reviewCtrl,
                  maxLines: 3,
                  decoration: InputDecoration(hintText: t('novel.reviewHint')),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (var i = 1; i <= 5; i++)
                      IconButton(
                        icon: Icon(
                          i <= _rating ? Icons.star : Icons.star_border,
                          size: 20,
                        ),
                        onPressed: () => setState(() => _rating = i.toDouble()),
                      ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: _spoiler,
                          onChanged: (v) =>
                              setState(() => _spoiler = v ?? false),
                        ),
                        const SizedBox(width: 4),
                        Text(t('review.spoiler')),
                      ],
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => _submitReview(n.id),
                      child: Text(t('common.publish')),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              for (final r in _reviews)
                Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    title: Text(r.authorName),
                    subtitle: Text(r.body),
                    trailing: Text('${r.rating}★'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chaptersTab(BuildContext context, AppState state, NovelCard n) {
    final t = state.t;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionHeading(
                title: t('novel.toc'),
                trailing: Text(
                  '${_chapters.length}${t('common.chapters')}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const SizedBox(height: 12),
              if (_chapters.isEmpty)
                EmptyState(title: t('novel.noChapters'))
              else
                Card(
                  margin: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (final c in _chapters)
                        ListTile(
                          leading: SizedBox(
                            width: 40,
                            child: Text(
                              '${c.no}',
                              textAlign: TextAlign.end,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          title: Text(chapterTitleLabel(t, c.title, c.no)),
                          subtitle: Text('${c.words}${t('common.words')}'),
                          trailing: c.contributor != null
                              ? Tooltip(
                                  message: c.contributor!,
                                  child: const Icon(
                                    Icons.groups_outlined,
                                    size: 18,
                                  ),
                                )
                              : (n.progressNo == c.no
                                    ? Icon(
                                        Icons.play_arrow,
                                        size: 18,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary,
                                      )
                                    : null),
                          onTap: () => _openReader(c.no),
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

  bool _hasChapter(int no) => _chapters.any((c) => c.no == no);

  int _continueNo(NovelCard n) {
    if (n.progressNo > 0 && _hasChapter(n.progressNo)) return n.progressNo;
    return _chapters.isEmpty ? 1 : _chapters.first.no;
  }

  Future<void> _openReader(int no) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReaderPage(novelId: widget.novelId, chapterNo: no),
      ),
    );
    if (mounted) await _load();
  }

  void _openNovel(String id) {
    if (id == widget.novelId) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => NovelPage(novelId: id)),
    );
  }

  Future<void> _submitReview(String novelId) async {
    final state = context.read<AppState>();
    try {
      await addReview(
        novelId: novelId,
        chapterNo: 0,
        body: _reviewCtrl.text,
        rating: _rating.round(),
        spoiler: _spoiler,
      );
      _reviewCtrl.clear();
      if (!mounted) return;
      setState(() {
        _rating = 5;
        _spoiler = false;
      });
      await state.refresh();
      if (!mounted) return;
      await _load();
    } catch (e) {
      if (mounted) showReviewGateError(context, state, e);
    }
  }

  Future<void> _tipDialog(String peer, String name) async {
    final state = context.read<AppState>();
    final t = state.t;
    final balance = state.walletSummary?.balance ?? 0;
    final ctrl = TextEditingController(text: '10');
    var amount = 10;
    final sent = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text('${t('novel.tip')} · $name'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t('wallet.balanceValue', {'n': balance})),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  for (final p in [10, 50, 200])
                    ChoiceChip(
                      label: Text('◈ $p'),
                      selected: amount == p,
                      onSelected: (_) {
                        setDialog(() => amount = p);
                        ctrl.text = '$p';
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
              if (amount > balance) ...[
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
    await _act(() => tip(toPeer: peer, amount: sent, reason: null));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(t('wallet.sent', {'n': sent}))));
  }

  Future<void> _reportDialog(String novelId) async {
    final state = context.read<AppState>();
    final t = state.t;
    String category = 'spam';
    final note = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('novel.report')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: category,
              items: [
                for (final c in [
                  'spam',
                  'illegal',
                  'copyright',
                  'hate',
                  'other',
                ])
                  DropdownMenuItem(value: c, child: Text(t('review.cat.$c'))),
              ],
              onChanged: (v) => category = v ?? 'spam',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: note,
              decoration: InputDecoration(labelText: t('review.note')),
            ),
            const SizedBox(height: 12),
            Text(t('review.honest'), style: Theme.of(ctx).textTheme.bodySmall),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t('common.cancel')),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _act(
                () => reportNovel(
                  novelId: novelId,
                  category: category,
                  note: note.text,
                ),
              );
            },
            child: Text(t('common.confirm')),
          ),
        ],
      ),
    );
  }
}

/* ------------------------- 详情页小部件 ------------------------- */

class _Tag extends StatelessWidget {
  const _Tag({
    required this.text,
    required this.fg,
    required this.bg,
    this.icon,
  });

  final String text;
  final Color fg;
  final Color bg;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

class _FactRow extends StatelessWidget {
  const _FactRow({required this.items});

  final List<(String, String)> items;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 28,
      runSpacing: 10,
      children: [
        for (final item in items)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.$1,
                style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 2),
              Text(
                item.$2,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.icon,
    required this.label,
    required this.value,
    this.color,
  });

  final IconData icon;
  final String label;
  final int value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = color ?? cs.onSurfaceVariant;
    return Tooltip(
      message: label,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 4),
          Text(
            _format(value),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReactionButton extends StatelessWidget {
  const _ReactionButton({
    required this.icon,
    required this.label,
    required this.count,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 17),
      label: Text('$label ${_format(count)}'),
    );
  }
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

  if (minutes < 60) {
    return n(minutes, ' 分钟前', 'm ago', '分前', '분 전', 'мин назад');
  }
  if (hours < 24) {
    return n(hours, ' 小时前', 'h ago', '時間前', '시간 전', 'ч назад');
  }
  if (days < 30) {
    return n(days, ' 天前', 'd ago', '日前', '일 전', 'дн назад');
  }
  if (months < 12) {
    return n(months, ' 个月前', 'mo ago', 'か月前', '개월 전', 'мес назад');
  }
  return n(years, ' 年前', 'y ago', '年前', '년 전', 'лет назад');
}
