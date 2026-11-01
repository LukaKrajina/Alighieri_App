import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../local/local_book.dart';
import '../src/rust/api.dart';
import '../src/rust/domain/view.dart';
import '../state/app_state.dart';
import '../widgets/href.dart';
import '../widgets/widgets.dart';
import 'local_reader_page.dart';
import 'novel_page.dart';
import 'reader_page.dart';

/// 我的书架。
///
/// 两个 Tab 刻意分开：
///   * 「追更」是 P2P 同步来的站内作品，收藏只在本机可见；
///   * 「本地」是用户自己导入的 TXT / EPUB，不产生任何 op。
/// 两者混在一起，别人会以为本地书也上了网络。
class ShelfPage extends StatelessWidget {
  const ShelfPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;

    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: SectionHeading(title: t('shelf.title')),
          ),
          TabBar(
            tabs: [
              Tab(text: t('shelf.tab.p2p')),
              Tab(text: t('shelf.tab.local')),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: const [_P2PShelf(), _LocalShelf()],
            ),
          ),
        ],
      ),
    );
  }
}

class _P2PShelf extends StatefulWidget {
  const _P2PShelf();

  @override
  State<_P2PShelf> createState() => _P2PShelfState();
}

class _P2PShelfState extends State<_P2PShelf> {
  /// `all` / `mine`，与 Web 书架的筛选一致。
  String _filter = 'all';
  bool _removing = false;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    final me = state.identity?.peerId ?? '';
    final items = [...state.shelf]
      ..sort((a, b) => b.shelfAddedAtMs.compareTo(a.shelfAddedAtMs));
    final mine = items.where((n) => me.isNotEmpty && n.authorPeer == me).toList();
    final shown = _filter == 'mine' ? mine : items;
    final reading = [...state.latest]
      ..removeWhere((n) => n.progressNo == 0)
      ..sort((a, b) => b.progressAtMs.compareTo(a.progressAtMs));

    final left = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (items.isNotEmpty) ...[
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              ChoiceChip(
                label: Text('${t('shelf.tab.all')} ${items.length}'),
                selected: _filter == 'all',
                onSelected: (_) => setState(() => _filter = 'all'),
              ),
              ChoiceChip(
                label: Text('${t('shelf.tab.mine')} ${mine.length}'),
                selected: _filter == 'mine',
                onSelected: (_) => setState(() => _filter = 'mine'),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        if (shown.isEmpty)
          Panel(
            child: EmptyState(
              title: _filter == 'mine'
                  ? t('shelf.empty.mine')
                  : t('shelf.empty'),
              body: _filter == 'mine'
                  ? t('shelf.empty.mineHint')
                  : t('shelf.empty.hint'),
              action: FilledButton.icon(
                onPressed: () => openCarouselHref(context, '/browse'),
                icon: const Icon(Icons.explore_outlined, size: 18),
                label: Text(t('shelf.discover')),
              ),
            ),
          )
        else
          for (final n in shown)
            _ShelfTile(
              novel: n,
              mine: me.isNotEmpty && n.authorPeer == me,
              busy: _removing,
              onOpen: () => _openNovel(n.id),
              onRemove: () => _remove(n.id),
            ),
      ],
    );

    final aside = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RecentPanel(items: reading.take(6).toList()),
        const SizedBox(height: 14),
        _StatsPanel(total: items.length, mine: mine.length),
        const SizedBox(height: 14),
        _PrivacyPanel(),
      ],
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      children: [
        Text(
          t('shelf.sub'),
          style: TextStyle(fontSize: 13, height: 1.7, color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, box) {
            if (box.maxWidth >= 960) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: left),
                  const SizedBox(width: 20),
                  SizedBox(width: 300, child: aside),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                left,
                const SizedBox(height: 20),
                aside,
              ],
            );
          },
        ),
      ],
    );
  }

  Future<void> _remove(String id) async {
    final state = context.read<AppState>();
    setState(() => _removing = true);
    try {
      await setBookmark(novelId: id, on_: false);
      await state.refresh();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _removing = false);
    }
  }

  void _openNovel(String id) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => NovelPage(novelId: id)));
  }
}

/// 一条书架记录：作品事实 + 「多久前加入」+ 移出按钮，来去自由。
class _ShelfTile extends StatelessWidget {
  const _ShelfTile({
    required this.novel,
    required this.mine,
    required this.busy,
    required this.onOpen,
    required this.onRemove,
  });

  final NovelCard novel;
  final bool mine;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    final genre = novel.genre.isEmpty
        ? (novel.genreName.isEmpty ? t('browse.all') : novel.genreName)
        : novel.genre;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          novel.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (mine)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: cs.tertiaryContainer,
                              borderRadius: BorderRadius.circular(99),
                            ),
                            child: Text(
                              t('shelf.tab.mine'),
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: cs.onTertiaryContainer,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                '${novel.authorName} · $genre · '
                '${t('common.chapters', {'n': novel.episodes})}'
                '${novel.words > 0 ? ' · ${t('common.words', {'n': _format(novel.words)})}' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
              ),
              if (novel.tagline.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  novel.tagline,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.6,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
              Row(
                children: [
                  Icon(Icons.schedule, size: 13, color: cs.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Text(
                    t('shelf.addedAgo', {
                      'ago': _ago(state.locale, novel.shelfAddedAtMs),
                    }),
                    style: TextStyle(
                      fontSize: 11,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: busy ? null : onRemove,
                    icon: const Icon(Icons.delete_outline, size: 15),
                    label: Text(t('shelf.remove')),
                    style: TextButton.styleFrom(
                      foregroundColor: cs.error,
                      visualDensity: VisualDensity.compact,
                      textStyle: const TextStyle(fontSize: 11.5),
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
}

class _RecentPanel extends StatelessWidget {
  const _RecentPanel({required this.items});

  final List<NovelCard> items;

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
              Icon(Icons.schedule, size: 16, color: cs.primary),
              const SizedBox(width: 5),
              Text(
                t('shelf.recent'),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (items.isEmpty)
            Text(
              t('shelf.recentEmpty'),
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                color: cs.onSurfaceVariant,
              ),
            )
          else
            for (final n in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ReaderPage(
                        novelId: n.id,
                        chapterNo: n.progressNo == 0 ? 1 : n.progressNo,
                      ),
                    ),
                  ),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          n.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${t('common.chapters', {'n': n.progressNo})} · '
                          '${_ago(state.locale, n.progressAtMs)}',
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.onSurfaceVariant,
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
  }
}

class _StatsPanel extends StatelessWidget {
  const _StatsPanel({required this.total, required this.mine});

  final int total;
  final int mine;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    final rows = <(String, int)>[
      (t('shelf.stat.total'), total),
      (t('shelf.stat.mine'), mine),
      (t('shelf.stat.others'), total - mine),
    ];
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t('shelf.stats'),
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Text(
                    row.$1,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${row.$2}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _PrivacyPanel extends StatelessWidget {
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
              Icon(Icons.lock_outline, size: 15, color: cs.onSurfaceVariant),
              const SizedBox(width: 5),
              Text(
                t('shelf.privacy.title'),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            t('shelf.privacy.body'),
            style: TextStyle(
              fontSize: 11.5,
              height: 1.65,
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 相对时间。Web 用 i18n 的 `ago`；桌面端不引入额外依赖，按语言直接拼 —— 少一个依赖少一份麻烦。
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

  if (minutes < 60) return n(minutes, ' 分钟前', 'm ago', '分前', '분 전', 'мин назад');
  if (hours < 24) return n(hours, ' 小时前', 'h ago', '時間前', '시간 전', 'ч назад');
  if (days < 30) return n(days, ' 天前', 'd ago', '日前', '일 전', 'дн назад');
  if (months < 12) return n(months, ' 个月前', 'mo ago', 'か月前', '개월 전', 'мес назад');
  return n(years, ' 年前', 'y ago', '年前', '년 전', 'лет назад');
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

class _LocalShelf extends StatefulWidget {
  const _LocalShelf();

  @override
  State<_LocalShelf> createState() => _LocalShelfState();
}

class _LocalShelfState extends State<_LocalShelf> {
  bool _busy = false;
  String _busyLabel = '';

  Future<void> _import() async {
    final state = context.read<AppState>();
    final t = state.t;
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        // Android 的 content:// 不总有可直接读取的路径；同时把字节带回来，
        // 路径拿不到时还能从内存救回来。
        withData: true,
        type: FileType.custom,
        allowedExtensions: ['txt', 'epub', 'md', 'markdown', 'html', 'htm', 'xhtml'],
      );
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    if (result == null || result.files.isEmpty) return;

    setState(() {
      _busy = true;
      _busyLabel = '';
    });
    var ok = 0;
    final failures = <String>[];
    for (final file in result.files) {
      setState(() => _busyLabel = file.name);
      try {
        if (file.path != null) {
          await state.localLibrary.importFile(file.path!, displayName: file.name);
        } else if (file.bytes != null) {
          await state.localLibrary.importBytes(file.bytes!, file.name);
        } else {
          throw const FormatException('无法读取该文件的位置与内容');
        }
        ok++;
      } catch (e) {
        failures.add('${file.name}: $e');
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _busyLabel = '';
    });
    final messenger = ScaffoldMessenger.of(context);
    if (ok > 0) {
      messenger.showSnackBar(
        SnackBar(content: Text(t('local.importedCount', {'n': ok}))),
      );
    }
    if (failures.isNotEmpty) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${t('local.importFailed')}\n${failures.take(3).join('\n')}',
          ),
          duration: const Duration(seconds: 8),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final library = state.localLibrary;
    final books = library.books;

    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 96),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    t('local.subtitle'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _import,
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(t('local.import')),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (library.error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  '${t('local.error')}: ${library.error}',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (books.isEmpty)
              EmptyState(
                title: t('local.empty'),
                body: t('local.emptyBody'),
                action: FilledButton.icon(
                  onPressed: _busy ? null : _import,
                  icon: const Icon(Icons.file_open_outlined),
                  label: Text(t('local.import')),
                ),
              )
            else
              for (final b in books)
                _LocalBookTile(
                  book: b,
                  onOpen: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => LocalReaderPage(bookId: b.id),
                    ),
                  ),
                  onRename: () => _rename(b),
                  onDelete: () => _delete(b),
                ),
          ],
        ),
        if (_busy)
          Positioned(
            left: 0,
            right: 0,
            bottom: 16,
            child: Center(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 12,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          _busyLabel.isEmpty
                              ? t('local.importing')
                              : '${t('local.importing')} · $_busyLabel',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _rename(LocalBook book) async {
    final state = context.read<AppState>();
    final t = state.t;
    final title = TextEditingController(text: book.title);
    final author = TextEditingController(text: book.author);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('local.rename')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: title,
              decoration: InputDecoration(labelText: t('local.bookTitle')),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: author,
              decoration: InputDecoration(
                labelText: '${t('local.bookAuthor')} (${t('common.optional')})',
              ),
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
    if (ok == true) {
      await state.localLibrary.rename(book.id, title.text, author.text);
    }
    title.dispose();
    author.dispose();
  }

  Future<void> _delete(LocalBook book) async {
    final state = context.read<AppState>();
    final t = state.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('local.deleteTitle')),
        content: Text(t('local.deleteBody', {'title': book.title})),
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
    if (ok == true) await state.localLibrary.deleteBook(book.id);
  }
}

class _LocalBookTile extends StatelessWidget {
  const _LocalBookTile({
    required this.book,
    required this.onOpen,
    required this.onRename,
    required this.onDelete,
  });

  final LocalBook book;
  final VoidCallback onOpen;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    final readNo = book.chapterIndex.clamp(0, book.chapterCount == 0 ? 0 : book.chapterCount - 1) + 1;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 46,
                height: 60,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  book.format.toUpperCase(),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: cs.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    if (book.author.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        book.author,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    const SizedBox(height: 6),
                    Text(
                      '${t('local.chapterCount', {'n': book.chapterCount})} · '
                      '${book.words}${t('common.words')}',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                    if (book.chapterCount > 0) ...[
                      const SizedBox(height: 4),
                      Text(
                        t('local.progress', {
                          'n': readNo,
                          'total': book.chapterCount,
                        }),
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: cs.primary),
                      ),
                    ],
                  ],
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'rename') onRename();
                  if (v == 'delete') onDelete();
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'rename',
                    child: Text(t('local.rename')),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(t('common.delete')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
