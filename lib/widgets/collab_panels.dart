import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../pages/publishers_page.dart';
import '../src/rust/api.dart';
import '../src/rust/domain/view.dart';
import '../state/app_state.dart';
import 'widgets.dart';

/* ------------------------- 协作面板 ------------------------- */

class CollabPanel extends StatefulWidget {
  const CollabPanel({
    super.key,
    required this.novelId,
    required this.authorPeer,
    required this.license,
    required this.chapters,
    required this.onChanged,
    required this.onOpenNovel,
  });

  final String novelId;
  final String authorPeer;
  final String license;
  final List<ChapterView> chapters;
  final Future<void> Function() onChanged;
  final ValueChanged<String> onOpenNovel;

  @override
  State<CollabPanel> createState() => _CollabPanelState();
}

class _CollabPanelState extends State<CollabPanel> {
  bool _loading = true;
  List<IssueCard> _issues = [];
  List<PatchCard> _patches = [];
  List<MergeCard> _merges = [];
  List<ContributorCard> _contributors = [];
  List<ForkCard> _forks = [];
  List<AwardCard> _awards = [];
  ForkCard? _forkSource;
  GroupCard? _group;
  ContributionGraphView? _graph;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final issues = await issues_(novelId: widget.novelId);
      final patches = await patches_(novelId: widget.novelId);
      final merges = await merges_(novelId: widget.novelId);
      final contributors = await contributors_(novelId: widget.novelId);
      final graph = await contributionGraph_(novelId: widget.novelId);
      final group = await editorGroup_(novelId: widget.novelId);
      final forks = await forksOf_(novelId: widget.novelId);
      final source = await forkSource_(novelId: widget.novelId);
      final awards = await awards_(novelId: widget.novelId);
      if (!mounted) return;
      setState(() {
        _issues = issues;
        _patches = patches;
        _merges = merges;
        _contributors = contributors;
        _graph = graph;
        _group = group;
        _forks = forks;
        _forkSource = source;
        _awards = awards;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showError(context, e);
    }
  }

  Future<void> _run(Future<void> Function() fn, {String? done}) async {
    try {
      await fn();
      if (!mounted) return;
      await context.read<AppState>().refresh();
      if (!mounted) return;
      await _load();
      if (done != null && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(done)));
      }
      await widget.onChanged();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final me = state.identity?.peerId ?? '';
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final graph = _graph;
    final group = _group;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Panel(
          child: Text(
            t('collab.intro'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        if (_forkSource != null) ...[
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: const Icon(Icons.call_split),
              title: Text(
                '${t('collab.forkSource')} · ${_forkSource!.sourceTitle}',
              ),
              subtitle: Text(_forkSource!.byName),
              onTap: () => widget.onOpenNovel(_forkSource!.sourceId),
            ),
          ),
        ],
        if (_awards.isNotEmpty) ...[
          const SizedBox(height: 20),
          SectionHeading(title: t('collab.awards')),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final a in _awards)
                Chip(
                  avatar: const Icon(Icons.emoji_events_outlined, size: 16),
                  label: Text('${a.contestTitle} · #${a.place}'),
                ),
            ],
          ),
        ],
        const SizedBox(height: 20),
        SectionHeading(
          title: t('collab.group'),
          subtitle: graph == null
              ? null
              : t('collab.groupNeed', {'n': group?.minMembers ?? 4}),
        ),
        const SizedBox(height: 8),
        if (group != null && group.exists)
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        group.name,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (!group.customNamed)
                      OutlinedButton(
                        onPressed: () => _renameGroup(group),
                        child: Text(t('collab.groupRename')),
                      ),
                  ],
                ),
                if (!group.customNamed)
                  Text(
                    t('collab.groupDefault'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                const SizedBox(height: 10),
                Text(t('collab.groupMembers')),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (var i = 0; i < group.members.length; i++)
                      Chip(
                        label: Text(
                          i < group.memberNames.length
                              ? group.memberNames[i]
                              : group.members[i],
                        ),
                      ),
                  ],
                ),
              ],
            ),
          )
        else
          EmptyState(
            title: t('collab.group'),
            body: t('collab.groupNeed', {'n': group?.minMembers ?? 4}),
          ),
        const SizedBox(height: 20),
        SectionHeading(
          title: t('collab.contributors'),
          subtitle: t('collab.graphHint'),
        ),
        const SizedBox(height: 8),
        if (_contributors.isEmpty)
          EmptyState(title: t('collab.graphEmpty'))
        else
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                for (final c in _contributors)
                  ListTile(
                    leading: CircleAvatar(
                      child: Text(
                        c.name.isEmpty ? '?' : c.name.characters.first,
                      ),
                    ),
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(
                            c.name.isEmpty ? c.peer : c.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (c.isAuthor) ...[
                          const SizedBox(width: 6),
                          _Tag(t('collab.author')),
                        ],
                        if (c.isMaintainer && !c.isAuthor) ...[
                          const SizedBox(width: 6),
                          _Tag(t('collab.maintainer')),
                        ],
                      ],
                    ),
                    subtitle: Text(
                      '${c.chapters}${t('common.chapters')} · '
                      '${c.words}${t('common.words')}'
                      '${c.translations > 0 ? ' · ${t('collab.translations')} ${c.translations}' : ''}'
                      '${c.ancillaryItems > 0 ? ' · ${t('collab.ancillary')} ${c.ancillaryItems}' : ''}',
                    ),
                    trailing: Text(
                      t('collab.percent', {
                        'n': (c.shareRatio * 100).toStringAsFixed(1),
                      }),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        if (graph != null && graph.shares.isNotEmpty) ...[
          const SizedBox(height: 20),
          SectionHeading(
            title: t('collab.graph'),
            subtitle: t('collab.graphHint'),
            trailing: Text(
              t('collab.graphTotal', {
                'n': (graph.total * 100).toStringAsFixed(1),
              }),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: 8),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _PoolChip(
                      label: t('collab.pool.canon'),
                      ratio: graph.canonPool,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    _PoolChip(
                      label: t('collab.pool.translation'),
                      ratio: graph.translationPool,
                      color: Theme.of(context).colorScheme.tertiary,
                    ),
                    _PoolChip(
                      label: t('collab.pool.ancillary'),
                      ratio: graph.ancillaryPool,
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                for (final s in graph.shares)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${s.name.isEmpty ? s.peer : s.name} · '
                                '${t('collab.pool.${s.kind}')}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              t('collab.percent', {
                                'n': (s.ratio * 100).toStringAsFixed(1),
                              }),
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: s.poolRatio.clamp(0, 1),
                            minHeight: 4,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${t('collab.basis')}: ${s.basis}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 24),
        SectionHeading(
          title: t('collab.issues'),
          trailing: OutlinedButton.icon(
            onPressed: () => _newIssue(),
            icon: const Icon(Icons.add, size: 16),
            label: Text(t('collab.issueNew')),
          ),
        ),
        const SizedBox(height: 8),
        if (_issues.isEmpty)
          EmptyState(title: t('collab.noIssues'))
        else
          for (final i in _issues) _issueCard(context, t, i),
        const SizedBox(height: 24),
        SectionHeading(
          title: t('collab.patches'),
          trailing: OutlinedButton.icon(
            onPressed: () => _newPatch(),
            icon: const Icon(Icons.add, size: 16),
            label: Text(t('collab.patchNew')),
          ),
        ),
        const SizedBox(height: 8),
        if (_patches.isEmpty)
          EmptyState(title: t('collab.noPatches'))
        else
          for (final p in _patches) _patchCard(context, t, p, me),
        if (_merges.isNotEmpty) ...[
          const SizedBox(height: 20),
          SectionHeading(title: t('collab.merges')),
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                for (final m in _merges)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.merge, size: 18),
                    title: Text(
                      '#${m.chapterNos.join(', #')} · ${m.authorName}',
                    ),
                    subtitle: Text(
                      '${m.byName}${m.note == null || m.note!.isEmpty ? '' : ' · ${m.note}'}',
                    ),
                    trailing: Text(relTime(state.locale, m.atMs, _nowMs())),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 24),
        SectionHeading(
          title: t('collab.forks'),
          trailing: me != widget.authorPeer
              ? OutlinedButton.icon(
                  onPressed: () => _forkDialog(),
                  icon: const Icon(Icons.call_split, size: 16),
                  label: Text(t('collab.fork')),
                )
              : null,
        ),
        const SizedBox(height: 8),
        if (_forks.isEmpty)
          EmptyState(title: t('collab.forks'), body: t('collab.forkHint'))
        else
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                for (final f in _forks)
                  ListTile(
                    leading: const Icon(Icons.call_split),
                    title: Text(f.novelTitle),
                    subtitle: Text(
                      '${f.byName}${f.note == null || f.note!.isEmpty ? '' : ' · ${f.note}'}',
                    ),
                    onTap: () => widget.onOpenNovel(f.novelId),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  Widget _issueCard(
    BuildContext context,
    String Function(String, [Map<String, Object>?]) t,
    IssueCard i,
  ) {
    final open = i.state == 'open';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    i.title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                _Tag(
                  open ? t('collab.issueOpen') : t('collab.issueClosed'),
                  color: open
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.outline,
                ),
              ],
            ),
            if (i.body.isNotEmpty) ...[const SizedBox(height: 6), Text(i.body)],
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${i.authorName} · ${relTime(context.read<AppState>().locale, i.atMs, _nowMs())}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (i.canClose)
                  TextButton(
                    onPressed: () => _run(
                      () => closeIssue_(
                        novelId: widget.novelId,
                        issueId: i.issueId,
                        closed: open,
                      ),
                    ),
                    child: Text(
                      open ? t('collab.closeIssue') : t('collab.reopenIssue'),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _patchCard(
    BuildContext context,
    String Function(String, [Map<String, Object>?]) t,
    PatchCard p,
    String me,
  ) {
    final cs = Theme.of(context).colorScheme;
    final open = p.state == 'open' && !p.merged;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    p.title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                if (p.merged)
                  _Tag(t('collab.patchMerged'), color: cs.primary)
                else if (!open)
                  _Tag(t('collab.issueClosed'), color: cs.outline)
                else if (p.hasConflict)
                  _Tag(t('collab.patchConflict'), color: cs.error),
              ],
            ),
            if (p.body.isNotEmpty) ...[const SizedBox(height: 6), Text(p.body)],
            const SizedBox(height: 6),
            Text(
              '${p.authorName} · ${p.chapters.length}${t('common.chapters')} · '
              '${p.chapterNos.map((n) => '#$n').join(', ')}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                TextButton.icon(
                  onPressed: () => _previewPatch(p),
                  icon: const Icon(Icons.visibility_outlined, size: 16),
                  label: Text(t('collab.patchPreview')),
                ),
                if (p.canMerge)
                  FilledButton.tonalIcon(
                    onPressed: () => _mergePatch(p),
                    icon: const Icon(Icons.merge, size: 16),
                    label: Text(t('collab.patchMerge')),
                  ),
                if (p.canClose && open)
                  TextButton(
                    onPressed: () => _run(
                      () => closePatch_(
                        novelId: widget.novelId,
                        patchId: p.patchId,
                        closed: true,
                      ),
                    ),
                    child: Text(t('collab.patchClose')),
                  ),
              ],
            ),
            if (p.hasConflict && open)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  t('collab.patchConflict'),
                  style: TextStyle(color: cs.error, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _newIssue() async {
    final state = context.read<AppState>();
    final t = state.t;
    final title = TextEditingController();
    final body = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('collab.issueNew')),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                autofocus: true,
                decoration: InputDecoration(labelText: t('collab.issueTitle')),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: body,
                maxLines: 5,
                decoration: InputDecoration(
                  labelText: t('collab.issueBody'),
                  alignLabelWithHint: true,
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
            child: Text(t('collab.issueCreate')),
          ),
        ],
      ),
    );
    if (ok == true && title.text.trim().isNotEmpty) {
      await _run(
        () => putIssue(
          novelId: widget.novelId,
          title: title.text.trim(),
          body: body.text.trim(),
        ).then((_) {}),
      );
    }
    title.dispose();
    body.dispose();
  }

  Future<void> _newPatch() async {
    final draft = await showDialog<_PatchDraft>(
      context: context,
      builder: (_) => _PatchDialog(
        nextNo: widget.chapters.isEmpty
            ? 1
            : widget.chapters.map((c) => c.no).reduce((a, b) => a > b ? a : b) +
                  1,
      ),
    );
    if (draft == null || !mounted) return;
    await _run(
      () => putPatch(
        novelId: widget.novelId,
        title: draft.title,
        body: draft.body,
        chapters: draft.chapters,
      ).then((_) {}),
      done: context.read<AppState>().t('collab.patchNew'),
    );
  }

  Future<void> _previewPatch(PatchCard p) async {
    final t = context.read<AppState>().t;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(p.title),
        content: SizedBox(
          width: 640,
          height: 520,
          child: ListView(
            children: [
              for (final c in p.chapters) ...[
                Text(
                  '${t('collab.patchChapterNo', {'n': c.no})} · ${c.title}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                for (final para in c.paragraphs)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(para),
                  ),
                const Divider(height: 28),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t('common.close')),
          ),
        ],
      ),
    );
  }

  Future<void> _mergePatch(PatchCard p) async {
    final state = context.read<AppState>();
    final t = state.t;
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('collab.patchMerge')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (p.hasConflict)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  t('collab.patchConflict'),
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                ),
              ),
            TextField(
              controller: note,
              decoration: InputDecoration(labelText: t('collab.mergeNote')),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t('collab.patchMerge')),
          ),
        ],
      ),
    );
    final noteText = note.text.trim();
    note.dispose();
    if (ok != true) return;
    await _run(
      () => mergePatch(
        novelId: widget.novelId,
        patchId: p.patchId,
        note: noteText,
      ),
    );
  }

  Future<void> _renameGroup(GroupCard group) async {
    final state = context.read<AppState>();
    final t = state.t;
    final ctrl = TextEditingController(text: group.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('collab.groupRename')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: InputDecoration(labelText: t('collab.groupName')),
            ),
            const SizedBox(height: 10),
            Text(
              t('collab.groupRenameOnce'),
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t('common.save')),
          ),
        ],
      ),
    );
    final name = ctrl.text.trim();
    ctrl.dispose();
    if (ok == true && name.isNotEmpty) {
      await _run(() => renameGroup(novelId: widget.novelId, name: name));
    }
  }

  Future<void> _forkDialog() async {
    final state = context.read<AppState>();
    final t = state.t;
    final title = TextEditingController();
    final synopsis = TextEditingController();
    String genre = 'daily';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(t('collab.fork')),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: title,
                  autofocus: true,
                  decoration: InputDecoration(labelText: t('collab.forkTitle')),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: synopsis,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: t('post.synopsis'),
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: genre,
                  decoration: InputDecoration(labelText: t('post.genre')),
                  items: [
                    for (final g in state.genres)
                      DropdownMenuItem(value: g.slug, child: Text(g.name)),
                  ],
                  onChanged: (v) => setDialog(() => genre = v ?? 'daily'),
                ),
                const SizedBox(height: 10),
                Text(
                  t('collab.forkHint'),
                  style: Theme.of(ctx).textTheme.bodySmall,
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
              child: Text(t('common.create')),
            ),
          ],
        ),
      ),
    );
    final name = title.text.trim();
    final pitch = synopsis.text.trim();
    title.dispose();
    synopsis.dispose();
    if (ok != true || name.isEmpty || !mounted) return;
    try {
      final id = await publishFork(
        sourceId: widget.novelId,
        title: name,
        synopsis: pitch,
        genre: genre,
        tags: const [],
        status: 'ongoing',
        license: widget.license,
      );
      if (!mounted) return;
      await state.refresh();
      widget.onOpenNovel(id);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }
}

class _PatchDraft {
  _PatchDraft(this.title, this.body, this.chapters);
  final String title;
  final String body;
  final List<PatchChapterInput> chapters;
}

class _ChapterDraft {
  _ChapterDraft(this.no)
    : title = TextEditingController(),
      body = TextEditingController();

  int no;
  final TextEditingController title;
  final TextEditingController body;

  void dispose() {
    title.dispose();
    body.dispose();
  }
}

class _PatchDialog extends StatefulWidget {
  const _PatchDialog({required this.nextNo});

  final int nextNo;

  @override
  State<_PatchDialog> createState() => _PatchDialogState();
}

class _PatchDialogState extends State<_PatchDialog> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  final List<_ChapterDraft> _chapters = [];

  @override
  void initState() {
    super.initState();
    _chapters.add(_ChapterDraft(widget.nextNo));
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    for (final c in _chapters) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.read<AppState>().t;
    return AlertDialog(
      title: Text(t('collab.patchNew')),
      content: SizedBox(
        width: 640,
        height: 560,
        child: ListView(
          children: [
            TextField(
              controller: _title,
              autofocus: true,
              decoration: InputDecoration(labelText: t('collab.patchTitle')),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _body,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: t('collab.patchBody'),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 16),
            for (var i = 0; i < _chapters.length; i++)
              Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              t('collab.patchChapterNo', {
                                'n': _chapters[i].no,
                              }),
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (_chapters.length > 1)
                            IconButton(
                              tooltip: t('common.delete'),
                              icon: const Icon(Icons.delete_outline, size: 18),
                              onPressed: () => setState(
                                () => _chapters.removeAt(i).dispose(),
                              ),
                            ),
                        ],
                      ),
                      TextField(
                        controller: _chapters[i].title,
                        decoration: InputDecoration(
                          labelText: t('collab.patchChapterNo', {
                            'n': _chapters[i].no,
                          }),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _chapters[i].body,
                        maxLines: 8,
                        decoration: InputDecoration(
                          labelText: t('post.paragraphs'),
                          alignLabelWithHint: true,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            OutlinedButton.icon(
              onPressed: () => setState(() {
                final maxNo = _chapters.isEmpty
                    ? widget.nextNo
                    : _chapters
                          .map((c) => c.no)
                          .reduce((a, b) => a > b ? a : b);
                _chapters.add(_ChapterDraft(maxNo + 1));
              }),
              icon: const Icon(Icons.add),
              label: Text(t('collab.patchAddChapter')),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t('common.cancel')),
        ),
        FilledButton(
          onPressed: () {
            final chapters = <PatchChapterInput>[];
            for (final c in _chapters) {
              final paragraphs = c.body.text
                  .split(RegExp(r'\n+'))
                  .map((s) => s.trim())
                  .where((s) => s.isNotEmpty)
                  .toList();
              if (paragraphs.isEmpty) continue;
              chapters.add(
                PatchChapterInput(
                  no: c.no,
                  title: c.title.text.trim(),
                  paragraphs: paragraphs,
                  volume: null,
                ),
              );
            }
            if (chapters.isEmpty || _title.text.trim().isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(t('collab.patchNoChapters'))),
              );
              return;
            }
            Navigator.pop(
              context,
              _PatchDraft(_title.text.trim(), _body.text.trim(), chapters),
            );
          },
          child: Text(t('common.publish')),
        ),
      ],
    );
  }
}

/* ------------------------- 交易面板 ------------------------- */

class DealPanel extends StatefulWidget {
  const DealPanel({
    super.key,
    required this.novelId,
    required this.authorPeer,
    required this.authorName,
    required this.onChanged,
  });

  final String novelId;
  final String authorPeer;
  final String authorName;
  final Future<void> Function() onChanged;

  @override
  State<DealPanel> createState() => _DealPanelState();
}

class _DealPanelState extends State<DealPanel> {
  bool _loading = true;
  List<DealCard> _deals = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final deals = await dealsForNovel(novelId: widget.novelId);
      if (!mounted) return;
      setState(() {
        _deals = deals;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showError(context, e);
    }
  }

  Future<void> _run(Future<void> Function() fn) async {
    try {
      await fn();
      if (!mounted) return;
      await context.read<AppState>().refresh();
      await _load();
      await widget.onChanged();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final me = state.identity?.peerId ?? '';
    PublisherCard? publisher;
    for (final p in state.publishers) {
      if (p.peer == me) {
        publisher = p;
        break;
      }
    }
    final isAuthor = me == widget.authorPeer;
    final cs = Theme.of(context).colorScheme;

    if (_loading) return const Center(child: CircularProgressIndicator());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t('deal.title'),
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                t('deal.payHint'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              if (!isAuthor)
                if (publisher == null)
                  Row(
                    children: [
                      Expanded(child: Text(t('deal.needPublisher'))),
                      TextButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const PublishersPage(),
                          ),
                        ),
                        child: Text(t('deal.goPublishers')),
                      ),
                    ],
                  )
                else
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      onPressed: _offerDialog,
                      icon: const Icon(Icons.handshake_outlined),
                      label: Text(t('deal.offer')),
                    ),
                  )
              else
                Text(
                  t('deal.payHint'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (_deals.isEmpty)
          EmptyState(title: t('deal.empty'))
        else
          for (final d in _deals)
            Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            t('deal.kind.${d.kind}'),
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        _DealStatus(status: d.status),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${d.publisherName} → ${d.authorName} · ◈ ${d.amount}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (d.terms.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(d.terms),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(
                          d.paidOnLedger
                              ? Icons.verified_outlined
                              : Icons.hourglass_empty,
                          size: 15,
                          color: d.paidOnLedger ? cs.primary : cs.outline,
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            d.paidOnLedger
                                ? t('deal.paidOnLedger')
                                : t('deal.notOnLedger'),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                    if (d.canRespond || d.canSettle) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          if (d.canRespond) ...[
                            FilledButton(
                              onPressed: () => _run(
                                () =>
                                    respondDeal(dealId: d.dealId, accept: true),
                              ),
                              child: Text(t('deal.accept')),
                            ),
                            OutlinedButton(
                              onPressed: () => _run(
                                () => respondDeal(
                                  dealId: d.dealId,
                                  accept: false,
                                ),
                              ),
                              child: Text(t('deal.decline')),
                            ),
                          ],
                          if (d.canSettle) ...[
                            FilledButton(
                              onPressed: () => _payDialog(d),
                              child: Text(t('deal.pay')),
                            ),
                            OutlinedButton(
                              onPressed: () => _run(
                                () => settleDeal(dealId: d.dealId, pay: false),
                              ),
                              child: Text(t('deal.cancel')),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
      ],
    );
  }

  Future<void> _offerDialog() async {
    final state = context.read<AppState>();
    final t = state.t;
    final amount = TextEditingController(text: '100');
    final terms = TextEditingController();
    String kind = 'manga';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(t('deal.offer')),
          content: SizedBox(
            width: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: kind,
                  decoration: InputDecoration(labelText: t('deal.kind')),
                  items: [
                    for (final k in ['manga', 'anime', 'game', 'cover'])
                      DropdownMenuItem(
                        value: k,
                        child: Text(t('deal.kind.$k')),
                      ),
                  ],
                  onChanged: (v) => setDialog(() => kind = v ?? 'manga'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: amount,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: t('deal.amount')),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: terms,
                  maxLines: 4,
                  decoration: InputDecoration(
                    labelText: t('deal.terms'),
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '${t('deal.to')}: ${widget.authorName}',
                  style: Theme.of(ctx).textTheme.bodySmall,
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
              child: Text(t('deal.offer')),
            ),
          ],
        ),
      ),
    );
    final value = int.tryParse(amount.text.trim()) ?? 0;
    final text = terms.text.trim();
    amount.dispose();
    terms.dispose();
    if (ok != true || value <= 0 || !mounted) return;
    await _run(
      () => offerDeal(
        novelId: widget.novelId,
        kind: kind,
        amount: value,
        terms: text,
      ).then((_) {}),
    );
  }

  Future<void> _payDialog(DealCard d) async {
    final state = context.read<AppState>();
    final t = state.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('deal.pay')),
        content: Text(
          '${t('deal.payHint')}\n\n${t('deal.amount')}: ◈ ${d.amount}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t('deal.pay')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() => settleDeal(dealId: d.dealId, pay: true));
  }
}

class _DealStatus extends StatelessWidget {
  const _DealStatus({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final t = context.read<AppState>().t;
    final cs = Theme.of(context).colorScheme;
    final color = switch (status) {
      'paid' => cs.primary,
      'accepted' => cs.tertiary,
      'declined' || 'cancelled' => cs.error,
      _ => cs.secondary,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        t('deal.status.$status'),
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, {this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.secondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(color: c, fontSize: 10, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _PoolChip extends StatelessWidget {
  const _PoolChip({
    required this.label,
    required this.ratio,
    required this.color,
  });

  final String label;
  final double ratio;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$label ${(ratio * 100).round()}%',
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/* ------------------------- 生成函数别名 ------------------------- */
// 与 AppState 的方法名 / Dart 关键字不冲突，但统一加下划线，图的是搜索时少打几个字。

Future<List<IssueCard>> issues_({required String novelId}) =>
    issues(novelId: novelId);

Future<List<PatchCard>> patches_({required String novelId}) =>
    patches(novelId: novelId);

Future<List<MergeCard>> merges_({required String novelId}) =>
    merges(novelId: novelId);

Future<List<ContributorCard>> contributors_({required String novelId}) =>
    contributors(novelId: novelId);

Future<ContributionGraphView> contributionGraph_({required String novelId}) =>
    contributionGraph(novelId: novelId);

Future<GroupCard> editorGroup_({required String novelId}) =>
    editorGroup(novelId: novelId);

Future<List<ForkCard>> forksOf_({required String novelId}) =>
    forksOf(novelId: novelId);

Future<ForkCard?> forkSource_({required String novelId}) =>
    forkSource(novelId: novelId);

Future<List<AwardCard>> awards_({required String novelId}) =>
    awards(novelId: novelId);

Future<void> closeIssue_({
  required String novelId,
  required String issueId,
  required bool closed,
}) => closeIssue(novelId: novelId, issueId: issueId, closed: closed);

Future<void> closePatch_({
  required String novelId,
  required String patchId,
  required bool closed,
}) => closePatch(novelId: novelId, patchId: patchId, closed: closed);
