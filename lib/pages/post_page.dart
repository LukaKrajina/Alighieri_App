import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../src/rust/api.dart';
import '../src/rust/domain/view.dart';
import '../state/app_state.dart';
import '../widgets/href.dart';
import '../widgets/widgets.dart';
import 'work_edit_page.dart';

/// 投稿 / 创作中心。
///
/// 与 Web 版 /post 对齐：支持本机草稿、一次发布多话、以及从 `/post?fork=`
/// 进入时按源头作品预填（标题、简介、分类、标签、许可证与正文），省得从头再填一遍。
class PostPage extends StatefulWidget {
  const PostPage({super.key, this.forkOf});

  /// 衍生源头作品 id；为空表示普通投稿。
  final String? forkOf;

  @override
  State<PostPage> createState() => _PostPageState();
}

class _PostPageState extends State<PostPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          child: SectionHeading(title: t('post.title'), subtitle: t('post.sub')),
        ),
        TabBar(
          controller: _tabs,
          tabs: [
            Tab(text: t('post.tab.create')),
            Tab(text: t('post.tab.mine')),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              _CreateNovel(
                forkOf: widget.forkOf,
                onPublished: () => _tabs.animateTo(1),
              ),
              const _MyWorks(),
            ],
          ),
        ),
      ],
    );
  }
}

class _ChapterDraft {
  _ChapterDraft({String title = '', String body = ''}) {
    this.title.text = title;
    this.body.text = body;
  }

  final title = TextEditingController();
  final body = TextEditingController();

  void dispose() {
    title.dispose();
    body.dispose();
  }
}

class _CreateNovel extends StatefulWidget {
  const _CreateNovel({required this.onPublished, this.forkOf});

  final VoidCallback onPublished;
  final String? forkOf;

  @override
  State<_CreateNovel> createState() => _CreateNovelState();
}

class _CreateNovelState extends State<_CreateNovel> {
  final _title = TextEditingController();
  final _tagline = TextEditingController();
  final _synopsis = TextEditingController();
  final _tags = TextEditingController();
  final List<_ChapterDraft> _chapters = [];

  String _genre = 'daily';
  String _status = 'ongoing';
  String _license = 'alighieri-serial';
  bool _busy = false;
  String? _publishedId;

  /// 衍生状态：从 /post?fork= 进入后加载源头
  late String? _forkOf = widget.forkOf;
  bool _forkLoading = false;
  String _forkTitle = '';
  String _forkLicense = '';
  int _forkChapters = 0;

  Timer? _saveTimer;
  bool _restored = false;

  bool get _isFork => _forkOf != null && _forkOf!.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _addChapter(notify: false);
    for (final c in [_title, _tagline, _synopsis, _tags]) {
      c.addListener(_onChanged);
    }
    _restore();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    if (!_isFork) unawaited(_saveDraft());
    for (final c in [_title, _tagline, _synopsis, _tags]) {
      c.removeListener(_onChanged);
      c.dispose();
    }
    for (final c in _chapters) {
      c.dispose();
    }
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
    _scheduleSave();
  }

  void _addChapter({bool notify = true, String title = '', String body = ''}) {
    final chapter = _ChapterDraft(title: title, body: body);
    chapter.title.addListener(_onChanged);
    chapter.body.addListener(_onChanged);
    _chapters.add(chapter);
    if (notify && mounted) setState(() {});
    _scheduleSave();
  }

  void _removeChapter(int index) {
    if (_chapters.length <= 1) return;
    final chapter = _chapters.removeAt(index);
    chapter.title.removeListener(_onChanged);
    chapter.body.removeListener(_onChanged);
    chapter.dispose();
    setState(() {});
    _scheduleSave();
  }

  void _resetChapters() {
    for (final c in _chapters) {
      c.title.removeListener(_onChanged);
      c.body.removeListener(_onChanged);
      c.dispose();
    }
    _chapters.clear();
  }

  Future<File> _draftFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}post_draft.json');
  }

  void _scheduleSave() {
    if (_isFork) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 700), _saveDraft);
  }

  Future<void> _saveDraft() async {
    if (_isFork) return;
    final chapters = _chapters
        .map((c) => {'title': c.title.text, 'body': c.body.text})
        .toList();
    final data = {
      'title': _title.text,
      'tagline': _tagline.text,
      'synopsis': _synopsis.text,
      'tags': _tags.text,
      'genre': _genre,
      'status': _status,
      'license': _license,
      'chapters': chapters,
    };
    try {
      final file = await _draftFile();
      await file.writeAsString(jsonEncode(data));
    } catch (_) {
      // 草稿只是便利功能，写不进去就算了，别因此打断灵感。
    }
  }

  Future<void> _restore() async {
    if (_isFork) {
      await _loadFork();
      return;
    }
    try {
      final file = await _draftFile();
      if (!await file.exists()) return;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return;
      final data = jsonDecode(raw);
      if (data is! Map) return;
      if (!mounted) return;
      setState(() {
        _title.text = '${data['title'] ?? ''}';
        _tagline.text = '${data['tagline'] ?? ''}';
        _synopsis.text = '${data['synopsis'] ?? ''}';
        _tags.text = '${data['tags'] ?? ''}';
        _genre = '${data['genre'] ?? _genre}';
        _status = '${data['status'] ?? _status}';
        _license = '${data['license'] ?? _license}';
        final rawChapters = data['chapters'];
        if (rawChapters is List && rawChapters.isNotEmpty) {
          _resetChapters();
          for (final item in rawChapters) {
            if (item is! Map) continue;
            _addChapter(
              notify: false,
              title: '${item['title'] ?? ''}',
              body: '${item['body'] ?? ''}',
            );
          }
          if (_chapters.isEmpty) _addChapter(notify: false);
        }
        _restored = true;
      });
    } catch (_) {
      // 草稿损坏就当没有，不阻塞投稿 —— 坏草稿没资格扣人质。
    }
  }

  Future<void> _loadFork() async {
    final sourceId = _forkOf;
    if (sourceId == null || sourceId.isEmpty) return;
    setState(() => _forkLoading = true);
    try {
      final source = await getNovel(novelId: sourceId);
      if (!mounted) return;
      if (source == null) {
        setState(() => _forkLoading = false);
        return;
      }
      final chapters = await getChapters(novelId: sourceId);
      if (!mounted) return;
      setState(() {
        _forkLoading = false;
        _forkTitle = source.title;
        _forkLicense = source.license;
        _forkChapters = chapters.length;
        _title.text = source.title;
        _tagline.text = source.tagline;
        _synopsis.text = source.synopsis;
        _tags.text = source.tags.join(' ');
        _genre = source.genre;
        _license = source.license.isEmpty
            ? 'alighieri-serial'
            : source.license;
        _status = source.status;
        _resetChapters();
        final visible = chapters
            .where((c) => c.paragraphs.isNotEmpty)
            .toList();
        if (visible.isEmpty) {
          _addChapter(notify: false);
        } else {
          for (final c in visible) {
            _addChapter(
              notify: false,
              title: c.title,
              body: c.paragraphs.join('\n\n'),
            );
          }
        }
        _restored = true;
      });
    } catch (_) {
      if (mounted) setState(() => _forkLoading = false);
    }
  }

  void _cancelFork() {
    setState(() {
      _forkOf = null;
      _forkTitle = '';
      _forkLicense = '';
      _forkChapters = 0;
      _title.clear();
      _tagline.clear();
      _synopsis.clear();
      _tags.clear();
      _genre = 'daily';
      _status = 'ongoing';
      _license = 'alighieri-serial';
      _resetChapters();
      _addChapter(notify: false);
    });
  }

  Future<void> _publish() async {
    final state = context.read<AppState>();
    final t = state.t;
    if (state.identity == null) {
      showError(context, t('post.err.identity'));
      return;
    }
    final title = _title.text.trim();
    final synopsis = _synopsis.text.trim();
    if (title.length < 2) {
      showError(context, t('post.err.name'));
      return;
    }
    if (synopsis.length < 10) {
      showError(context, t('post.err.synopsis'));
      return;
    }
    final filled = _chapters
        .where((c) => c.body.text.trim().isNotEmpty)
        .toList();
    if (filled.isEmpty) {
      showError(context, t('post.err.body'));
      return;
    }

    setState(() => _busy = true);
    try {
      final tags = _tags.text
          .split(RegExp(r'[,，\s]+'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .take(8)
          .toList();
      final id = _isFork
          ? await publishFork(
              sourceId: _forkOf!,
              title: title,
              synopsis: synopsis,
              genre: _genre,
              tags: tags,
              status: _status,
              license: _license,
            )
          : await publishNovel(
              title: title,
              synopsis: synopsis,
              genre: _genre,
              tags: tags,
              status: _status,
              license: _license,
            );
      for (var i = 0; i < filled.length; i++) {
        final chapter = filled[i];
        final no = i + 1;
        final paragraphs = chapter.body.text
            .split(RegExp(r'\n+'))
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        await publishChapter(
          novelId: id,
          no: no,
          title: chapter.title.text.trim().isEmpty
              ? t('post.chapterTitleAuto', {'n': no})
              : chapter.title.text.trim(),
          paragraphs: paragraphs,
          volume: null,
        );
      }
      try {
        final file = await _draftFile();
        if (await file.exists()) await file.delete();
      } catch (_) {}
      await state.refresh();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _publishedId = id;
        _title.clear();
        _tagline.clear();
        _synopsis.clear();
        _tags.clear();
        _genre = 'daily';
        _status = 'ongoing';
        _license = 'alighieri-serial';
        _resetChapters();
        _addChapter(notify: false);
        _forkOf = null;
        _forkTitle = '';
        _forkLicense = '';
        _forkChapters = 0;
      });
      widget.onPublished();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showError(context, t('post.err.publish', {'msg': '$e'}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final totalWords = _chapters.fold<int>(
      0,
      (sum, c) => sum + c.body.text.replaceAll(RegExp(r'\s'), '').length,
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_publishedId != null) ...[
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.check_circle_outline,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            t('post.success.title'),
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        state.stats.netState == 'online' ||
                                state.stats.netState == 'degraded'
                            ? t('post.success.online')
                            : t('post.success.offline'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed: () => openCarouselHref(
                              context,
                              '/novel?id=${_publishedId!}',
                            ),
                            icon: const Icon(Icons.menu_book, size: 17),
                            label: Text(t('post.success.view')),
                          ),
                          OutlinedButton.icon(
                            onPressed: () =>
                                openCarouselHref(context, '/shelf'),
                            icon: const Icon(Icons.bookmarks_outlined, size: 17),
                            label: Text(t('post.success.shelf')),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],
              if (_isFork) ...[
                Panel(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.call_split,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              crossAxisAlignment: WrapCrossAlignment.center,
                              spacing: 6,
                              children: [
                                Text(
                                  t('post.fork.title'),
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                if (_forkTitle.isNotEmpty)
                                  Text(
                                    '《$_forkTitle》',
                                    style: TextStyle(
                                      color:
                                          Theme.of(context).colorScheme.primary,
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _forkLoading
                                  ? t('post.fork.waiting')
                                  : _forkTitle.isEmpty
                                  ? t('post.fork.waiting')
                                  : _forkChapters == 0
                                  ? t('post.fork.noChapters')
                                  : t('post.fork.body', {
                                      'chapters': _forkChapters,
                                      'license': _forkLicense,
                                    }),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: _cancelFork,
                        child: Text(t('post.fork.cancel')),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],
              Text(
                t('post.createHint'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _title,
                decoration: InputDecoration(labelText: t('post.name')),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _tagline,
                decoration: InputDecoration(
                  labelText:
                      '${t('post.tagline')} (${t('common.optional')})',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _synopsis,
                maxLines: 4,
                decoration: InputDecoration(labelText: t('post.synopsis')),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey('genre-$_genre'),
                initialValue: _genre,
                decoration: InputDecoration(labelText: t('post.genre')),
                items: [
                  for (final g in state.genres)
                    DropdownMenuItem(value: g.slug, child: Text(g.name)),
                ],
                onChanged: (v) {
                  setState(() => _genre = v ?? 'daily');
                  _scheduleSave();
                },
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
                      key: ValueKey('status-$_status'),
                      initialValue: _status,
                      decoration: InputDecoration(labelText: t('post.status')),
                      items: [
                        for (final s in ['ongoing', 'completed', 'hiatus'])
                          DropdownMenuItem(
                            value: s,
                            child: Text(t('status.$s')),
                          ),
                      ],
                      onChanged: (v) {
                        setState(() => _status = v ?? 'ongoing');
                        _scheduleSave();
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      key: ValueKey('license-$_license'),
                      initialValue: _license,
                      decoration: InputDecoration(labelText: t('post.license')),
                      items: [
                        for (final l in state.licenses)
                          DropdownMenuItem(
                            value: l.id,
                            child: Text(
                              l.recommended
                                  ? '${l.shortName} ${t('licenses.default')}'
                                  : l.shortName,
                            ),
                          ),
                      ],
                      onChanged: (v) {
                        setState(
                          () => _license = v ?? 'alighieri-serial',
                        );
                        _scheduleSave();
                      },
                    ),
                  ),
                ],
              ),
              const Divider(height: 32),
              Row(
                children: [
                  Expanded(
                    child: SectionHeading(
                      title: t('novel.toc'),
                      subtitle: t('post.firstChapterHint'),
                    ),
                  ),
                  Text(
                    '${_chapters.length} ${t('common.chapters')} · '
                    '${_formatWords(totalWords)} ${t('common.words')}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              for (var i = 0; i < _chapters.length; i++) ...[
                _ChapterEditor(
                  key: ObjectKey(_chapters[i]),
                  index: i,
                  chapter: _chapters[i],
                  canRemove: _chapters.length > 1,
                  onRemove: () => _removeChapter(i),
                ),
                const SizedBox(height: 12),
              ],
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => _addChapter(),
                  icon: const Icon(Icons.add),
                  label: Text(t('post.addChapter')),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _publish,
                  icon: const Icon(Icons.publish),
                  label: Text(
                    _busy ? t('common.loading') : t('common.publish'),
                  ),
                ),
              ),
              if (!_restored) ...[
                const SizedBox(height: 8),
                Text(
                  t('common.loading'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ChapterEditor extends StatelessWidget {
  const _ChapterEditor({
    super.key,
    required this.index,
    required this.chapter,
    required this.canRemove,
    required this.onRemove,
  });

  final int index;
  final _ChapterDraft chapter;
  final bool canRemove;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final t = context.watch<AppState>().t;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    t('post.chapterNoShort', {'n': index + 1}),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (canRemove)
                  IconButton(
                    tooltip: t('post.removeChapter'),
                    icon: const Icon(Icons.delete_outline, size: 19),
                    onPressed: onRemove,
                  ),
              ],
            ),
            const SizedBox(height: 4),
            TextField(
              controller: chapter.title,
              decoration: InputDecoration(labelText: t('post.chapterTitle')),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: chapter.body,
              maxLines: 10,
              decoration: InputDecoration(
                labelText: t('post.paragraphs'),
                alignLabelWithHint: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MyWorks extends StatefulWidget {
  const _MyWorks();

  @override
  State<_MyWorks> createState() => _MyWorksState();
}

class _MyWorksState extends State<_MyWorks> {
  late Future<List<NovelCard>> _future = _load();

  Future<List<NovelCard>> _load() async {
    final state = context.read<AppState>();
    return state.myNovels();
  }

  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    return FutureBuilder<List<NovelCard>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text('${snapshot.error}'));
        }
        final works = snapshot.data ?? const <NovelCard>[];
        if (works.isEmpty) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: EmptyState(
              title: t('post.mine.empty'),
              body: t('post.mine.emptyBody'),
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: () async {
            await state.refresh();
            _reload();
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      t('post.mine.subtitle', {'n': works.length}),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  IconButton(
                    tooltip: t('common.retry'),
                    icon: const Icon(Icons.refresh),
                    onPressed: _reload,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              for (final n in works)
                Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => WorkEditPage(novelId: n.id),
                        ),
                      );
                      if (mounted) {
                        await state.refresh();
                        _reload();
                      }
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  n.title,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                              ),
                              Chip(
                                label: Text(t('status.${n.status}')),
                                visualDensity: VisualDensity.compact,
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${n.episodes}${t('common.chapters')} · '
                            '${n.words}${t('common.words')} · '
                            '${t('status.${n.status}')}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          if (n.latestTitle.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              t('post.latestChapter', {
                                'title': chapterTitleLabel(
                                  t,
                                  n.latestTitle,
                                  n.latestNo,
                                ),
                              }),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerRight,
                            child: Text(
                              t('post.manage'),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

String _formatWords(int n) {
  final s = n.abs().toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return n < 0 ? '-$buf' : buf.toString();
}
