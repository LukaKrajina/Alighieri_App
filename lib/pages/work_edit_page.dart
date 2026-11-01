import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../src/rust/api.dart';
import '../src/rust/domain/view.dart';
import '../state/app_state.dart';
import '../widgets/widgets.dart';

/// 创作中心：管理一部已经发布的作品。
///
/// 这是 Web 版 `studio` 的核心闭环在移动端的对应物：
/// 改资料、加更、改章节、删章节。所有写入仍然走 Rust 引擎，
/// 由它负责「只能改自己的作品」与「先落盘再广播」—— 顺序错了，谣言就比事实跑得快。
class WorkEditPage extends StatefulWidget {
  const WorkEditPage({super.key, required this.novelId});

  final String novelId;

  @override
  State<WorkEditPage> createState() => _WorkEditPageState();
}

class _WorkEditPageState extends State<WorkEditPage> {
  final _title = TextEditingController();
  final _synopsis = TextEditingController();
  final _tags = TextEditingController();
  NovelCard? _novel;
  List<ChapterView> _chapters = [];
  String _genre = 'daily';
  String _status = 'ongoing';
  String _license = 'alighieri-serial';
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _title.dispose();
    _synopsis.dispose();
    _tags.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final n = await getNovel(novelId: widget.novelId);
      final cs = await getChapters(novelId: widget.novelId);
      if (!mounted) return;
      setState(() {
        _novel = n;
        _chapters = cs;
        if (n != null) {
          _title.text = n.title;
          _synopsis.text = n.synopsis;
          _tags.text = n.tags.join('，');
          _genre = n.genre.isEmpty ? 'daily' : n.genre;
          _status = n.status;
          _license = n.license;
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showError(context, e);
    }
  }

  Future<void> _saveMeta() async {
    final state = context.read<AppState>();
    final t = state.t;
    if (_title.text.trim().isEmpty) {
      showError(context, t('post.name'));
      return;
    }
    setState(() => _saving = true);
    try {
      await updateNovel(
        novelId: widget.novelId,
        title: _title.text.trim(),
        synopsis: _synopsis.text.trim(),
        genre: _genre,
        tags: _tags.text
            .split(RegExp(r'[,，]'))
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList(),
        status: _status,
        license: _license,
      );
      await state.refresh();
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t('post.saved'))));
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showError(context, e);
    }
  }

  Future<void> _editChapter(ChapterView? chapter) async {
    final state = context.read<AppState>();
    final t = state.t;
    final nextNo = _chapters.isEmpty
        ? 1
        : _chapters.map((c) => c.no).reduce((a, b) => a > b ? a : b) + 1;
    final no = TextEditingController(text: '${chapter?.no ?? nextNo}');
    final title = TextEditingController(
      text: chapter == null ? '' : chapterTitleLabel(t, chapter.title, chapter.no),
    );
    final body = TextEditingController(
      text: chapter == null ? '' : chapter.paragraphs.join('\n\n'),
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          chapter == null
              ? t('post.newChapter')
              : t('post.editChapter'),
        ),
        content: SizedBox(
          width: 620,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: no,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: t('post.chapterNo'),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: title,
                        decoration: InputDecoration(
                          labelText: t('post.chapterTitle'),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: body,
                  maxLines: 12,
                  decoration: InputDecoration(
                    labelText: t('post.paragraphs'),
                    alignLabelWithHint: true,
                  ),
                ),
              ],
            ),
          ),
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

    if (ok == true) {
      final n = int.tryParse(no.text.trim());
      final paragraphs = body.text
          .split(RegExp(r'\n\s*\n'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if (n == null || n <= 0 || paragraphs.isEmpty) {
        if (mounted) showError(context, t('post.needBody'));
      } else {
        try {
          await publishChapter(
            novelId: widget.novelId,
            no: n,
            title: title.text.trim(),
            paragraphs: paragraphs,
            volume: null,
          );
          await state.refresh();
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(t('post.chapterSaved'))),
          );
          await _load();
        } catch (e) {
          if (mounted) showError(context, e);
        }
      }
    }
    no.dispose();
    title.dispose();
    body.dispose();
  }

  Future<void> _deleteChapter(ChapterView c) async {
    final state = context.read<AppState>();
    final t = state.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('post.deleteChapter')),
        content: Text(
          t('post.deleteChapterBody', {
            'title': chapterTitleLabel(t, c.title, c.no),
          }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t('common.cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t('common.delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await deleteChapter(novelId: widget.novelId, no: c.no);
      await state.refresh();
      if (!mounted) return;
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _deleteNovel() async {
    final state = context.read<AppState>();
    final t = state.t;
    final title = _novel?.title ?? '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('post.deleteWork')),
        content: Text(t('post.deleteWorkBody', {'title': title})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t('common.cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t('common.delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await deleteNovel(novelId: widget.novelId);
      await state.refresh();
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    final n = _novel;

    return Scaffold(
      appBar: AppBar(
        title: Text(t('post.editWork')),
        actions: [
          IconButton(
            tooltip: t('post.deleteWork'),
            icon: Icon(Icons.delete_outline, color: cs.error),
            onPressed: _deleteNovel,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : n == null
          ? Center(child: Text(t('common.empty')))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SectionHeading(
                        title: t('post.workInfo'),
                        subtitle: t('post.workInfoHint'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _title,
                        decoration: InputDecoration(labelText: t('post.name')),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _synopsis,
                        maxLines: 4,
                        decoration: InputDecoration(
                          labelText: t('post.synopsis'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: state.genres.any((g) => g.slug == _genre)
                            ? _genre
                            : null,
                        decoration: InputDecoration(
                          labelText: t('post.genre'),
                        ),
                        items: [
                          for (final g in state.genres)
                            DropdownMenuItem(value: g.slug, child: Text(g.name)),
                        ],
                        onChanged: (v) => setState(() => _genre = v ?? 'daily'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _tags,
                        decoration: InputDecoration(labelText: t('post.tags')),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              initialValue: _status,
                              decoration: InputDecoration(
                                labelText: t('post.status'),
                              ),
                              items: [
                                for (final s in ['ongoing', 'completed', 'hiatus'])
                                  DropdownMenuItem(
                                    value: s,
                                    child: Text(t('status.$s')),
                                  ),
                              ],
                              onChanged: (v) =>
                                  setState(() => _status = v ?? 'ongoing'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              initialValue:
                                  state.licenses.any((l) => l.id == _license)
                                  ? _license
                                  : null,
                              decoration: InputDecoration(
                                labelText: t('post.license'),
                              ),
                              items: [
                                for (final l in state.licenses)
                                  DropdownMenuItem(
                                    value: l.id,
                                    child: Text(l.shortName),
                                  ),
                              ],
                              onChanged: (v) => setState(
                                () => _license = v ?? 'alighieri-serial',
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: _saving ? null : _saveMeta,
                          child: _saving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(t('common.save')),
                        ),
                      ),
                      const SizedBox(height: 28),
                      Row(
                        children: [
                          Expanded(
                            child: SectionHeading(
                              title: t('novel.toc'),
                              subtitle: t('post.chapterHint'),
                            ),
                          ),
                          FilledButton.tonalIcon(
                            icon: const Icon(Icons.add, size: 18),
                            label: Text(t('post.newChapter')),
                            onPressed: () => _editChapter(null),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_chapters.isEmpty)
                        EmptyState(title: t('post.noChapters'))
                      else
                        Card(
                          margin: EdgeInsets.zero,
                          child: Column(
                            children: [
                              for (final c in _chapters)
                                ListTile(
                                  title: Text(
                                    chapterTitleLabel(t, c.title, c.no),
                                  ),
                                  subtitle: Text(
                                    '${c.words}${t('common.words')} · '
                                    '${t('post.chapterNoShort', {'n': c.no})}',
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        tooltip: t('post.editChapter'),
                                        icon: const Icon(Icons.edit_outlined),
                                        onPressed: () => _editChapter(c),
                                      ),
                                      IconButton(
                                        tooltip: t('post.deleteChapter'),
                                        icon: Icon(
                                          Icons.delete_outline,
                                          color: cs.error,
                                        ),
                                        onPressed: () => _deleteChapter(c),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}