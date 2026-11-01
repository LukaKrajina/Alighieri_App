import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../local/local_book.dart';
import '../state/app_state.dart';
import '../widgets/reader_shell.dart';

/// 本地书阅读器。
///
/// 和 P2P 阅读器共享同一套外观与交互（[ReaderScaffold]），但不发任何 op：
/// 本地书不该因为没联网就看不了，也不该顺手给站内作品刷阅读量。
class LocalReaderPage extends StatefulWidget {
  const LocalReaderPage({super.key, required this.bookId});

  final String bookId;

  @override
  State<LocalReaderPage> createState() => _LocalReaderPageState();
}

class _LocalReaderPageState extends State<LocalReaderPage>
    with WidgetsBindingObserver {
  final _scroll = ScrollController();
  final _search = TextEditingController();

  LocalBook? _book;
  int _chapter = 0;
  bool _loading = true;
  String? _error;
  Timer? _saveTimer;

  Timer? _autoNextTimer;
  int _autoNextLeft = 0;
  bool _autoNextArmed = false;
  bool _userScrolled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    _autoNextTimer?.cancel();
    _scroll.removeListener(_onScroll);
    _save();
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _save();
  }

  Future<void> _load() async {
    final library = context.read<AppState>().localLibrary;
    try {
      final book = await library.open(widget.bookId);
      if (!mounted) return;
      final index = book.chapters.isEmpty
          ? 0
          : book.chapterIndex.clamp(0, book.chapters.length - 1);
      setState(() {
        _book = book;
        _chapter = index;
        _loading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _restoreOffset());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _restoreOffset() {
    if (!_scroll.hasClients) return;
    final book = _book;
    if (book == null) return;
    final max = _scroll.position.maxScrollExtent;
    if (max > 0 && book.scrollOffset > 0) {
      _scroll.jumpTo((book.scrollOffset * max).clamp(0, max));
    }
  }

  void _save() {
    final book = _book;
    if (book == null || book.chapters.isEmpty) return;
    double offset;
    if (_scroll.hasClients && _scroll.position.maxScrollExtent > 0) {
      offset = (_scroll.offset / _scroll.position.maxScrollExtent).clamp(
        0.0,
        1.0,
      );
    } else {
      offset = book.scrollOffset;
    }
    unawaited(
      context.read<AppState>().localLibrary.saveProgress(
        book.id,
        chapterIndex: _chapter,
        scrollOffset: offset,
      ),
    );
  }

  void _goTo(int index) {
    final book = _book;
    if (book == null || book.chapters.isEmpty) return;
    final clamped = index.clamp(0, book.chapters.length - 1);
    if (clamped == _chapter) return;
    _save();
    _cancelAutoNext();
    _userScrolled = false;
    setState(() => _chapter = clamped);
    if (_scroll.hasClients) _scroll.jumpTo(0);
    // 换章时把该章进度归零，否则新章一打开就停在上一章的半山腰。
    unawaited(
      context.read<AppState>().localLibrary.saveProgress(
        book.id,
        chapterIndex: clamped,
        scrollOffset: 0,
      ),
    );
  }

  /// 章内滚动到末尾时启动自动下一章；往上滚回去就取消。
  /// 只响应用户拖动，恢复进度时的程序化滚动不触发 —— 不然恢复进度会把自动翻章也一起叫醒。
  void _onScroll() {
    if (!_scroll.hasClients || !mounted) return;
    final book = _book;
    if (book == null || book.chapters.isEmpty) return;
    final pos = _scroll.position;
    final atEnd =
        pos.maxScrollExtent > 0 && pos.pixels >= pos.maxScrollExtent - 24;
    final hasNext = _chapter < book.chapters.length - 1;
    final auto = context.read<AppState>().settings.readerAutoNext;
    if (!atEnd || !hasNext || !auto || !_userScrolled) {
      _cancelAutoNext();
      return;
    }
    if (_autoNextArmed) return;
    _autoNextArmed = true;
    _autoNextLeft = 3;
    setState(() {});
    _autoNextTimer = Timer.periodic(const Duration(seconds: 1), (tm) {
      if (!mounted) {
        tm.cancel();
        return;
      }
      if (_autoNextLeft <= 1) {
        tm.cancel();
        _autoNextTimer = null;
        setState(() => _autoNextArmed = false);
        _goTo(_chapter + 1);
        return;
      }
      setState(() => _autoNextLeft -= 1);
    });
  }

  void _cancelAutoNext() {
    _autoNextTimer?.cancel();
    _autoNextTimer = null;
    if (_autoNextArmed && mounted) {
      setState(() => _autoNextArmed = false);
    } else {
      _autoNextArmed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final palette = ReaderPalette.of(context, state);
    final book = _book;

    if (_loading) {
      return Scaffold(
        backgroundColor: palette.background,
        body: Center(child: CircularProgressIndicator(color: palette.accent)),
      );
    }
    if (book == null || book.chapters.isEmpty) {
      return Scaffold(
        backgroundColor: palette.background,
        appBar: AppBar(
          backgroundColor: palette.surface,
          foregroundColor: palette.text,
          title: Text(t('local.title')),
        ),
        body: Center(
          child: Text(
            _error ?? t('local.empty'),
            style: TextStyle(color: palette.text),
          ),
        ),
      );
    }

    final chapter = book.chapters[_chapter];
    final hasPrev = _chapter > 0;
    final hasNext = _chapter < book.chapters.length - 1;

    return ReaderScaffold(
      title: book.title,
      toc: _toc(context, state, book, palette),
      positionLabel: t('reader.localPosition', {
        'n': _chapter + 1,
        'total': book.chapters.length,
      }),
      progress: (_chapter + 1) / book.chapters.length,
      hasPrev: hasPrev,
      hasNext: hasNext,
      onPrev: hasPrev ? () => _goTo(_chapter - 1) : () {},
      onNext: hasNext ? () => _goTo(_chapter + 1) : () {},
      onSettings: () => showReaderSettings(context, state),
      onHorizontalSwipe: (_) {},
      actions: [
        IconButton(
          tooltip: t('local.search'),
          color: palette.text,
          icon: const Icon(Icons.search),
          onPressed: _searchDialog,
        ),
      ],
      body: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n is ScrollUpdateNotification && n.dragDetails != null) {
            _userScrolled = true;
          }
          // 停止滚动 800ms 后写一次进度；拖动过程中不反复写盘，硬盘也需要喘口气。
          if (n is ScrollEndNotification) {
            _saveTimer?.cancel();
            _saveTimer = Timer(const Duration(milliseconds: 800), _save);
          }
          return false;
        },
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(24, 84, 24, 110),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    chapter.title,
                    style: TextStyle(
                      color: palette.text,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    t('local.chapterWords', {'n': chapter.words}),
                    style: TextStyle(color: palette.muted, fontSize: 12),
                  ),
                  const SizedBox(height: 20),
                  for (final para in _paragraphs(chapter.text))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Text(
                        para,
                        style: TextStyle(
                          color: palette.text,
                          fontSize: 17 * state.settings.readerFontScale,
                          height: state.settings.readerLineHeight,
                        ),
                      ),
                    ),
                  if (book.author.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Text(
                      t('local.authorLine', {'name': book.author}),
                      style: TextStyle(color: palette.muted, fontSize: 12),
                    ),
                  ],
                  const SizedBox(height: 28),
                  Row(
                    children: [
                      if (hasPrev)
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: palette.text,
                          ),
                          icon: const Icon(Icons.chevron_left, size: 18),
                          label: Text(t('reader.prev')),
                          onPressed: () => _goTo(_chapter - 1),
                        ),
                      const Spacer(),
                      if (hasNext)
                        FilledButton.icon(
                          icon: const Icon(Icons.chevron_right, size: 18),
                          label: Text(t('reader.next')),
                          onPressed: () => _goTo(_chapter + 1),
                        ),
                    ],
                  ),
                  if (_autoNextArmed) ...[
                    const SizedBox(height: 12),
                    ReaderEndNotice(
                      palette: palette,
                      text: t('reader.autoNextIn', {'n': _autoNextLeft}),
                      action: TextButton(
                        onPressed: _cancelAutoNext,
                        child: Text(
                          t('common.cancel'),
                          style: TextStyle(color: palette.accent, fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                  if (!hasNext) ...[
                    const SizedBox(height: 14),
                    ReaderEndNotice(
                      palette: palette,
                      text: t('local.finished'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<String> _paragraphs(String text) => text
      .split(RegExp(r'\n+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList(growable: false);

  Widget _toc(
    BuildContext context,
    AppState state,
    LocalBook book,
    ReaderPalette palette,
  ) {
    final t = state.t;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  t('novel.toc'),
                  style: TextStyle(
                    color: palette.text,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
              Text(
                '${book.chapters.length}',
                style: TextStyle(color: palette.muted, fontSize: 12),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: palette.divider),
        Expanded(
          child: ListView.builder(
            itemCount: book.chapters.length,
            itemBuilder: (context, i) {
              final c = book.chapters[i];
              final selected = i == _chapter;
              return ListTile(
                dense: true,
                selected: selected,
                selectedTileColor: palette.accent.withValues(alpha: 0.10),
                leading: SizedBox(
                  width: 32,
                  child: Text(
                    '${i + 1}',
                    textAlign: TextAlign.end,
                    style: TextStyle(color: palette.muted, fontSize: 11),
                  ),
                ),
                title: Text(
                  c.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? palette.accent : palette.text,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                    fontSize: 13.5,
                  ),
                ),
                subtitle: Text(
                  '${c.words}',
                  style: TextStyle(color: palette.muted, fontSize: 11),
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  _goTo(i);
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _searchDialog() async {
    final book = _book;
    if (book == null) return;
    final state = context.read<AppState>();
    final t = state.t;
    var query = '';
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) {
          final results = <(int, String)>[];
          if (query.trim().isNotEmpty) {
            for (var i = 0; i < book.chapters.length; i++) {
              final c = book.chapters[i];
              final idx = c.text.toLowerCase().indexOf(query.toLowerCase());
              if (idx >= 0) {
                final start = (idx - 24).clamp(0, c.text.length);
                final end = (idx + query.length + 40).clamp(0, c.text.length);
                results.add((
                  i,
                  '…${c.text.substring(start, end).replaceAll('\n', ' ')}…',
                ));
              }
              if (results.length >= 80) break;
            }
          }
          return AlertDialog(
            title: Text(t('local.search')),
            content: SizedBox(
              width: 520,
              height: 420,
              child: Column(
                children: [
                  TextField(
                    controller: _search,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: t('local.searchHint'),
                    ),
                    onChanged: (v) => setDialog(() => query = v),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: results.isEmpty
                        ? Center(child: Text(t('local.noResult')))
                        : ListView.builder(
                            itemCount: results.length,
                            itemBuilder: (ctx, i) {
                              final (chapter, snippet) = results[i];
                              return ListTile(
                                dense: true,
                                title: Text(book.chapters[chapter].title),
                                subtitle: Text(snippet),
                                onTap: () {
                                  Navigator.pop(ctx);
                                  _goTo(chapter);
                                },
                              );
                            },
                          ),
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
          );
        },
      ),
    );
  }
}
