import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../src/rust/api.dart';
import '../src/rust/domain/view.dart';
import '../state/app_state.dart';
import '../widgets/widgets.dart';
import 'novel_page.dart';
import 'post_page.dart';

/// 分类浏览 + 关键词检索。
///
/// 筛选态留在页面内部：改成路由参数的话，每调一次筛选都要重建页面，
/// 滚动位置和输入焦点都会丢 —— 调一次筛选不该让人从头再读。桌面端没有
/// 地址栏，所以筛选语义与 Web 对齐、载体不同：未知取值一律回落成「全部」。
class BrowsePage extends StatefulWidget {
  const BrowsePage({
    super.key,
    this.initialGenre = '',
    this.initialQuery = '',
    this.initialTag = '',
    this.initialStatus = '',
    this.initialSort = 'update',
  });

  final String initialGenre;
  final String initialQuery;
  final String initialTag;
  final String initialStatus;
  final String initialSort;

  @override
  State<BrowsePage> createState() => _BrowsePageState();
}

class _BrowsePageState extends State<BrowsePage> {
  late String _genre;
  late String _status;
  late String _sort;
  late String _tag;
  String _words = 'all';
  bool _grid = false;
  final _q = TextEditingController();
  List<NovelCard> _results = [];
  bool _loading = false;

  static const _statuses = ['', 'ongoing', 'completed', 'hiatus'];
  static const _sorts = ['update', 'words', 'episodes', 'new', 'author'];
  static const _wordRanges = <(String, String)>[
    ('all', 'any'),
    ('s', 'under100k'),
    ('m', '100k500k'),
    ('l', '500k1m'),
    ('xl', 'over1m'),
  ];

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    _genre = state.genres.any((g) => g.slug == widget.initialGenre)
        ? widget.initialGenre
        : '';
    _status = _statuses.contains(widget.initialStatus)
        ? widget.initialStatus
        : '';
    _sort = _sorts.contains(widget.initialSort) ? widget.initialSort : 'update';
    _tag = widget.initialTag;
    _q.text = widget.initialQuery;
    _results = state.latest;
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    setState(() => _loading = true);
    try {
      final res = await listNovels(
        q: _q.text.trim(),
        genre: _genre,
        status: _status,
        tag: _tag,
        sort: _sort,
      );
      if (!mounted) return;
      setState(() => _results = res);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 字数区间与 Web 的搜索侧栏同一档位，免得两边口径打架。
  bool _inWordRange(NovelCard n) {
    final w = n.words;
    return switch (_words) {
      's' => w < 100000,
      'm' => w >= 100000 && w <= 500000,
      'l' => w >= 500000 && w <= 1000000,
      'xl' => w >= 1000000,
      _ => true,
    };
  }

  /// 热门标签从本机收到的作品里统计，不是我们拍脑袋写死的。
  List<String> _hotTags(AppState state) {
    final count = <String, int>{};
    for (final n in state.latest) {
      for (final tag in n.tags) {
        count[tag] = (count[tag] ?? 0) + 1;
      }
    }
    final tags = count.keys.toList()
      ..sort((a, b) {
        final byCount = count[b]!.compareTo(count[a]!);
        return byCount != 0 ? byCount : a.compareTo(b);
      });
    return tags.take(10).toList();
  }

  void _reset() {
    setState(() {
      _q.clear();
      _genre = '';
      _status = '';
      _sort = 'update';
      _tag = '';
      _words = 'all';
    });
    _run();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    final results = _results.where(_inWordRange).toList();
    final totalWords = results.fold<int>(0, (s, n) => s + n.words);
    final hotTags = _hotTags(state);
    final hasQuery = _q.text.trim().isNotEmpty;
    final hasFilter =
        hasQuery ||
        _genre.isNotEmpty ||
        _status.isNotEmpty ||
        _tag.isNotEmpty ||
        _words != 'all' ||
        _sort != 'update';

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      children: [
        Text(
          hasQuery ? t('search.title') : t('browse.title'),
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          hasQuery ? t('search.sub') : t('browse.received', {'n': state.latest.length}),
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _q,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: t('home.searchPlaceholder'),
            suffixIcon: IconButton(
              icon: const Icon(Icons.arrow_forward),
              onPressed: _run,
            ),
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _run(),
        ),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _chip(t('browse.all'), _genre.isEmpty, () {
                setState(() => _genre = '');
                _run();
              }),
              for (final g in state.genres) ...[
                const SizedBox(width: 8),
                _chip(g.name, _genre == g.slug, () {
                  setState(() => _genre = g.slug);
                  _run();
                }),
              ],
            ],
          ),
        ),
        if (hotTags.isNotEmpty) ...[
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Icon(Icons.tag, size: 15, color: cs.onSurfaceVariant),
              for (final tag in hotTags)
                ChoiceChip(
                  label: Text('#$tag'),
                  selected: _tag == tag,
                  visualDensity: VisualDensity.compact,
                  onSelected: (v) {
                    setState(() => _tag = v ? tag : '');
                    _run();
                  },
                ),
            ],
          ),
        ],
        const SizedBox(height: 14),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.tune, size: 16),
                    const SizedBox(width: 6),
                    Text(
                      t('search.filter'),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const Spacer(),
                    Text(
                      t('browse.count', {'n': results.length}),
                      style: TextStyle(
                        fontSize: 11.5,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final s in _statuses)
                      ChoiceChip(
                        label: Text(
                          s.isEmpty ? t('browse.status.all') : t('status.$s'),
                        ),
                        selected: _status == s,
                        onSelected: (_) {
                          setState(() => _status = s);
                          _run();
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final s in _sorts)
                      ChoiceChip(
                        label: Text(t('search.sort.$s')),
                        selected: _sort == s,
                        onSelected: (_) {
                          setState(() => _sort = s);
                          _run();
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final r in _wordRanges)
                      ChoiceChip(
                        label: Text(t('search.words.range.${r.$2}')),
                        selected: _words == r.$1,
                        onSelected: (_) => setState(() => _words = r.$1),
                      ),
                  ],
                ),
                if (hasFilter) ...[
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _reset,
                      icon: const Icon(Icons.clear, size: 16),
                      label: Text(t('search.clear')),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Text(
              hasQuery
                  ? t('search.found', {'n': results.length})
                  : t('browse.received', {'n': results.length}),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            const Spacer(),
            if (results.isNotEmpty)
              Text(
                t('browse.totalWords', {'n': _format(totalWords)}),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            IconButton(
              tooltip: _grid ? t('browse.view.list') : t('browse.view.grid'),
              icon: Icon(_grid ? Icons.view_list : Icons.grid_view, size: 18),
              onPressed: () => setState(() => _grid = !_grid),
            ),
          ],
        ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        const SizedBox(height: 6),
        if (results.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: EmptyState(
              title: state.latest.isEmpty
                  ? t('browse.empty.title')
                  : _genre.isNotEmpty
                  ? t('browse.empty.noGenre')
                  : t('browse.empty.noMatch'),
              body: state.latest.isEmpty
                  ? t('browse.empty.hint0')
                  : t('browse.empty.hint1'),
            ),
          )
        else if (_grid)
          LayoutBuilder(
            builder: (context, box) {
              final columns = box.maxWidth >= 700 ? 2 : 1;
              final width = (box.maxWidth - (columns - 1) * 12) / columns;
              return Wrap(
                spacing: 12,
                runSpacing: 0,
                children: [
                  for (var i = 0; i < results.length; i++)
                    SizedBox(
                      width: width,
                      child: NovelCardTile(
                        novel: results[i],
                        locale: state.locale,
                        rank: i + 1,
                        onTap: () => _open(context, results[i].id),
                      ),
                    ),
                ],
              );
            },
          )
        else
          for (var i = 0; i < results.length; i++)
            NovelCardTile(
              novel: results[i],
              locale: state.locale,
              onTap: () => _open(context, results[i].id),
            ),
        if (results.isNotEmpty) ...[
          const SizedBox(height: 16),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(
                    '${t('browse.cta.title')} ${t('browse.cta.body')}',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => _SimpleScaffold(
                          title: t('post.title'),
                          child: const PostPage(),
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: Text(t('browse.cta.go')),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
    );
  }

  void _open(BuildContext context, String id) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => NovelPage(novelId: id)));
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
}

/// 方便从浏览页跳到投稿页，但不想把 AppShell 的索引传进来 —— 一个跳转不值得牵一条线。
class _SimpleScaffold extends StatelessWidget {
  const _SimpleScaffold({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(appBar: AppBar(title: Text(title)), body: child);
  }
}
