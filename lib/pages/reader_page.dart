import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../src/rust/api.dart';
import '../src/rust/domain/view.dart';
import '../state/app_state.dart';
import '../state/machine_translate.dart';
import '../state/review_gate.dart';
import '../widgets/reader_shell.dart';
import '../widgets/widgets.dart';

/// 阅读器。
///
/// 读完一话要记一次阅读事件（PV）：同一身份对同一话只计一次，
/// 所以 PV 是「有多少人读过」而不是「被刷新了多少次」。
///
/// 阅读界面与本地书共用 [ReaderScaffold]：正文是主角，工具栏是客人 —— 这条规矩两边都算。
class ReaderPage extends StatefulWidget {
  const ReaderPage({super.key, required this.novelId, required this.chapterNo});

  final String novelId;
  final int chapterNo;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> with WidgetsBindingObserver {
  List<ChapterView> _chapters = [];
  ChapterView? _current;
  List<TranslationView> _translations = [];
  int _translationIndex = 0;
  String _mode = 'original';
  final MachineTranslator _machine = MachineTranslator();
  bool _loading = true;
  int _earned = 0;
  late int _chapterNo;

  final _scroll = ScrollController();

  /// 本话评价与阅读门槛（与 Web 版一致：单话评论需要本话读满 30 秒）。
  List<ReviewView> _reviews = [];
  int _readSeconds = 0;
  final _reviewCtrl = TextEditingController();
  double _rating = 5;
  bool _spoiler = false;
  bool _submitting = false;
  static const _requiredReadSeconds = 30;

  /// 停留计时。低于 20 秒不发币 —— 误点这种事，不该有奖励。
  DateTime? _enteredAt;
  Timer? _timer;

  /// 阅读时长：与 Web 版一致，每累计 30 秒记一条 `read.tick`。
  /// 评论门槛（整部 60 秒 / 单话 30 秒）就是对这些事件求和。
  Timer? _readTimer;
  DateTime _lastReadAt = DateTime.now();
  bool _active = true;

  /// 滚动到章末后的自动下一章倒计时。
  Timer? _autoNextTimer;
  int _autoNextLeft = 0;
  bool _autoNextArmed = false;

  @override
  void initState() {
    super.initState();
    _chapterNo = widget.chapterNo;
    WidgetsBinding.instance.addObserver(this);
    _enteredAt = DateTime.now();
    _lastReadAt = DateTime.now();
    _scroll.addListener(_onScroll);
    _load();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _tick());
    _readTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _readTick(),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _readTimer?.cancel();
    _autoNextTimer?.cancel();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _reviewCtrl.dispose();
    if (_active) _flushReadTail();
    super.dispose();
  }

  int get _index => _chapters.indexWhere((x) => x.no == _chapterNo);
  bool get _hasPrev => _index > 0;
  bool get _hasNext => _index >= 0 && _index < _chapters.length - 1;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _active = true;
      _lastReadAt = DateTime.now();
      return;
    }
    // 切到后台 / 锁屏时不再计时，并把不足 30 秒的尾数记下来。
    if (_active) {
      _flushReadTail();
      _active = false;
    }
  }

  /// 把上次记 tick 之后不足 30 秒的尾数也记下来（最多 29 秒）。
  /// 太短（<5 秒）就不记，免得快速翻页也能刷时长。
  void _flushReadTail() {
    final delta = DateTime.now().difference(_lastReadAt).inSeconds;
    _lastReadAt = DateTime.now();
    if (delta < 5) return;
    unawaited(_recordRead(delta.clamp(0, 120)));
  }

  void _readTick() {
    if (!_active) return;
    final now = DateTime.now();
    final delta = now.difference(_lastReadAt).inSeconds;
    if (delta < 30) return;
    _lastReadAt = now;
    unawaited(_recordRead(delta.clamp(0, 120)));
  }

  /// 记一条阅读时长，并把本话累计秒数取回来 —— 评论门槛据此实时解锁。
  Future<void> _recordRead(int seconds) async {
    try {
      await recordReadTick(
        novelId: widget.novelId,
        chapterNo: _chapterNo,
        seconds: seconds,
      );
      final read = await myReadSeconds(
        novelId: widget.novelId,
        chapterNo: _chapterNo,
      );
      if (!mounted || read == _readSeconds) return;
      setState(() => _readSeconds = read);
    } catch (e) {
      debugPrint('[alighieri] 记录阅读时长失败：$e');
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final cs = await getChapters(novelId: widget.novelId);
      final tr = await getTranslations(
        novelId: widget.novelId,
        chapterNo: _chapterNo,
        lang: '',
      );
      final rs = await getReviews(novelId: widget.novelId);
      final read = await myReadSeconds(
        novelId: widget.novelId,
        chapterNo: _chapterNo,
      );
      // 打开即记进度：不依赖用户翻到页尾，退出后还能从这一话继续 —— 进度不等人。
      try {
        await setProgress(novelId: widget.novelId, chapterNo: _chapterNo);
      } catch (e) {
        debugPrint('[alighieri] 保存阅读进度失败：$e');
      }
      if (!mounted) return;
      setState(() {
        _chapters = cs;
        _translations = tr;
        _translationIndex = 0;
        _reviews = rs
            .where((r) => r.chapterNo == _chapterNo)
            .toList(growable: false);
        _readSeconds = read;
        _current = cs.cast<ChapterView?>().firstWhere(
          (c) => c?.no == _chapterNo,
          orElse: () => null,
        );
        _loading = false;
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        showError(context, e);
      }
    }
  }

  /// 停留满 2.5 秒记一次阅读。与奖励币的门槛一致：防误触也防刷量，大家按同一把尺子。
  Future<void> _tick() async {
    if (!_active) return;
    final entered = _enteredAt;
    if (entered == null) return;
    final dwell = DateTime.now().difference(entered).inMilliseconds;
    if (dwell < 2500) return;
    _enteredAt = null;
    try {
      final got = await finishReading(
        novelId: widget.novelId,
        chapterNo: _chapterNo,
        dwellMs: dwell,
        words: _current?.words ?? 0,
      );
      if (!mounted) return;
      setState(() => _earned = got);
      await context.read<AppState>().refresh();
    } catch (e) {
      debugPrint('[alighieri] 记录阅读失败：$e');
    }
  }

  /// 章内滚动到末尾时启动自动下一章；往上滚回去就取消。
  void _onScroll() {
    if (!_scroll.hasClients || !mounted) return;
    final pos = _scroll.position;
    final atEnd =
        pos.maxScrollExtent > 0 && pos.pixels >= pos.maxScrollExtent - 24;
    final auto = context.read<AppState>().settings.readerAutoNext;
    if (!atEnd || !_hasNext || !auto) {
      _cancelAutoNext();
      return;
    }
    if (_autoNextArmed) return;
    final nextNo = _chapters[_index + 1].no;
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
        _goto(nextNo);
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

  void _goto(int no) {
    if (no == _chapterNo) return;
    _flushReadTail();
    _cancelAutoNext();
    setState(() {
      _chapterNo = no;
      _current = null;
      _earned = 0;
      _readSeconds = 0;
      _translations = [];
      _translationIndex = 0;
      _reviews = [];
    });
    _enteredAt = DateTime.now();
    _lastReadAt = DateTime.now();
    _load();
  }

  Future<void> _openSettings(AppState state) =>
      showReaderSettings(context, state);

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final palette = ReaderPalette.of(context, state);
    final c = _current;

    if (_loading) {
      return Scaffold(
        backgroundColor: palette.background,
        body: Center(child: CircularProgressIndicator(color: palette.accent)),
      );
    }
    if (c == null) {
      return Scaffold(
        backgroundColor: palette.background,
        appBar: AppBar(
          backgroundColor: palette.surface,
          foregroundColor: palette.text,
          title: Text(t('novel.noChapters')),
        ),
        body: Center(
          child: Text(
            t('novel.noChapters'),
            style: TextStyle(color: palette.text),
          ),
        ),
      );
    }

    final idx = _index;
    final title = chapterTitleLabel(t, c.title, c.no);
    final translation = _translations.isEmpty
        ? null
        : _translations[_translationIndex.clamp(0, _translations.length - 1)];

    return ReaderScaffold(
      title: title,
      toc: _toc(context, state),
      positionLabel: t('reader.chapterProgress', {
        'n': idx + 1,
        'total': _chapters.length,
      }),
      progress: _chapters.isEmpty ? 0 : (idx + 1) / _chapters.length,
      hasPrev: _hasPrev,
      hasNext: _hasNext,
      onPrev: _hasPrev ? () => _goto(_chapters[idx - 1].no) : () {},
      onNext: _hasNext ? () => _goto(_chapters[idx + 1].no) : () {},
      onSettings: () => _openSettings(state),
      onHorizontalSwipe: (_) {},
      actions: [
        PopupMenuButton<String>(
          tooltip: t('reader.translation'),
          icon: Icon(Icons.translate, color: palette.text),
          onSelected: (v) => setState(() => _mode = v),
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'original',
              child: Text(t('reader.mode.original')),
            ),
            PopupMenuItem(value: 'both', child: Text(t('reader.mode.both'))),
            PopupMenuItem(
              value: 'translation',
              child: Text(t('reader.mode.translation')),
            ),
          ],
        ),
      ],
      body: _body(context, state, palette, c, translation),
    );
  }

  Widget _body(
    BuildContext context,
    AppState state,
    ReaderPalette palette,
    ChapterView c,
    TranslationView? translation,
  ) {
    final t = state.t;
    final scale = state.settings.readerFontScale;
    final lineHeight = state.settings.readerLineHeight;

    final paragraphStyle = TextStyle(
      color: palette.text,
      fontSize: 17 * scale,
      height: lineHeight,
    );
    final translationStyle = TextStyle(
      color: _mode == 'translation' ? palette.text : palette.muted,
      fontSize: (_mode == 'translation' ? 17 : 15) * scale,
      height: _mode == 'translation' ? lineHeight : 1.7,
    );

    return SingleChildScrollView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(24, 84, 24, 110),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (c.volume != null && c.volume!.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: palette.surface,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: palette.divider),
                      ),
                      child: Text(
                        c.volume!,
                        style: TextStyle(color: palette.muted, fontSize: 11),
                      ),
                    ),
                  const Spacer(),
                  if (_earned > 0)
                    Text(
                      '◈ +$_earned',
                      style: TextStyle(
                        color: palette.accent,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
              if (_translations.length > 1) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: DropdownButton<int>(
                    value: _translationIndex.clamp(0, _translations.length - 1),
                    dropdownColor: palette.surface,
                    underline: const SizedBox.shrink(),
                    style: TextStyle(color: palette.muted, fontSize: 12),
                    items: [
                      for (var i = 0; i < _translations.length; i++)
                        DropdownMenuItem(
                          value: i,
                          child: Text(
                            '${_translations[i].translator} · '
                            '${_translations[i].lang}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                    ],
                    onChanged: (v) =>
                        setState(() => _translationIndex = v ?? 0),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              for (var i = 0; i < c.paragraphs.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_mode != 'translation' || translation == null)
                        Text(c.paragraphs[i], style: paragraphStyle),
                      if (_mode != 'original' &&
                          translation != null &&
                          i < translation.paragraphs.length &&
                          translation.paragraphs[i] != c.paragraphs[i]) ...[
                        if (_mode == 'both') const SizedBox(height: 6),
                        Text(
                          translation.paragraphs[i],
                          style: translationStyle,
                        ),
                      ],
                    ],
                  ),
                ),
              if (_mode != 'original' && translation == null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    t('reader.noTranslation'),
                    style: TextStyle(color: palette.muted, fontSize: 12),
                  ),
                ),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  TextButton.icon(
                    icon: Icon(Icons.add, size: 18, color: palette.accent),
                    label: Text(
                      t('reader.addTranslation'),
                      style: TextStyle(color: palette.accent),
                    ),
                    onPressed: () => _translationDialog(c),
                  ),
                  TextButton.icon(
                    icon: Icon(Icons.auto_awesome, size: 17, color: palette.muted),
                    label: Text(
                      t('reader.machine'),
                      style: TextStyle(color: palette.muted, fontSize: 12.5),
                    ),
                    onPressed: () => _machineTranslate(c, palette),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  if (_hasPrev)
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: palette.text,
                      ),
                      icon: const Icon(Icons.chevron_left, size: 18),
                      label: Text(t('reader.prev')),
                      onPressed: () => _goto(_chapters[_index - 1].no),
                    ),
                  const Spacer(),
                  if (_hasNext)
                    FilledButton.icon(
                      icon: const Icon(Icons.chevron_right, size: 18),
                      label: Text(t('reader.next')),
                      onPressed: () => _goto(_chapters[_index + 1].no),
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
              if (!_hasPrev && !_hasNext) ...[
                const SizedBox(height: 12),
                ReaderEndNotice(palette: palette, text: t('local.finished')),
              ],
              const SizedBox(height: 14),
              Text(
                t('reader.pvNote'),
                style: TextStyle(color: palette.muted, fontSize: 11.5),
              ),
              const SizedBox(height: 28),
              _reviewSection(context, state, palette),
            ],
          ),
        ),
      ),
    );
  }

  /// 目录抽屉：长篇作品不可能靠「上一话 / 下一话」翻到第 80 话，得给个目录。
  Widget _toc(BuildContext context, AppState state) {
    final t = state.t;
    final palette = ReaderPalette.of(context, state);
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
                '${_chapters.length}',
                style: TextStyle(color: palette.muted, fontSize: 12),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: palette.divider),
        Expanded(
          child: ListView.builder(
            itemCount: _chapters.length,
            itemBuilder: (context, i) {
              final c = _chapters[i];
              final selected = c.no == _chapterNo;
              return ListTile(
                dense: true,
                selected: selected,
                selectedTileColor: palette.accent.withValues(alpha: 0.10),
                title: Text(
                  chapterTitleLabel(t, c.title, c.no),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? palette.accent : palette.text,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                    fontSize: 13.5,
                  ),
                ),
                subtitle: Text(
                  '${c.words}${t('common.words')}',
                  style: TextStyle(color: palette.muted, fontSize: 11),
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  if (c.no != _chapterNo) _goto(c.no);
                },
              );
            },
          ),
        ),
      ],
    );
  }

  /// 机器翻译：先说明隐私代价，再逐段请求；失败段落保留原文。
  /// 结果只在本机显示，不会发 `translation.put` —— 机器译文不该冒充人工署名，
  /// 机器也没打算负这个责。
  Future<void> _machineTranslate(
    ChapterView chapter,
    ReaderPalette palette,
  ) async {
    final state = context.read<AppState>();
    final t = state.t;
    final lang = TextEditingController(
      text: state.locale == 'zh' ? 'en' : state.locale,
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('reader.machine')),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: lang,
                decoration: InputDecoration(
                  labelText: t('reader.machineLang'),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                t('reader.machinePrivacy'),
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                t('reader.machineHint'),
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
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
            child: Text(t('reader.machine')),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      lang.dispose();
      return;
    }
    final target = lang.text.trim();
    lang.dispose();
    if (target.isEmpty || !mounted) return;

    final total = chapter.paragraphs.length;
    final progress = ValueNotifier<double>(0);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Text(t('reader.machine')),
          content: ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (_, value, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(
                  value: value,
                  color: palette.accent,
                ),
                const SizedBox(height: 12),
                Text(
                  t('reader.machineProgress', {
                    'done': (value * total).round(),
                    'total': total,
                  }),
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final result = await _machine.translateChapter(
      chapter.paragraphs,
      target,
      onProgress: (done, all) {
        progress.value = all == 0 ? 1 : done / all;
      },
    );
    if (!mounted) {
      progress.dispose();
      return;
    }
    Navigator.of(context, rootNavigator: true).pop();
    progress.dispose();

    if (result.done == 0) {
      final message = switch (result.error) {
        'rate-limited' => t('reader.machineRateLimited'),
        'unsupported' => t('reader.machineUnsupported'),
        _ => t('reader.machineFailed'),
      };
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
      return;
    }

    final view = TranslationView(
      novelId: widget.novelId,
      chapterNo: chapter.no,
      lang: target,
      actor: 'machine',
      translator: t('reader.machine'),
      paragraphs: result.paragraphs,
      note: result.stoppedEarly ? t('reader.machineRateLimited') : null,
      atMs: DateTime.now().millisecondsSinceEpoch,
    );
    setState(() {
      _translations.insert(0, view);
      _translationIndex = 0;
      _mode = 'both';
    });
    final message = result.error != null && result.error != 'rate-limited'
        ? t('reader.machineFailed')
        : result.stoppedEarly || result.error == 'rate-limited'
        ? t('reader.machinePartial', {'n': result.done, 'total': result.total})
        : t('reader.machineDone', {'n': result.done});
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// 提交译文。段数不必与原文完全一致，多出来的段落照样显示；
  /// 不做「多数票」—— 同一话可以有多个译本，由读者自己选，译者也各凭本事。
  Future<void> _translationDialog(ChapterView chapter) async {
    final state = context.read<AppState>();
    final t = state.t;
    final lang = TextEditingController(
      text: state.locale == 'zh' ? 'en' : 'zh',
    );
    final body = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('reader.addTranslation')),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: lang,
                decoration: InputDecoration(
                  labelText: t('reader.translationLang'),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: body,
                maxLines: 10,
                decoration: InputDecoration(
                  labelText: t('reader.translation'),
                  hintText: t('reader.translationHint'),
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
            child: Text(t('common.publish')),
          ),
        ],
      ),
    );

    if (ok == true) {
      final paragraphs = body.text
          .split(RegExp(r'\n\s*\n'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if (paragraphs.isNotEmpty && lang.text.trim().isNotEmpty) {
        try {
          await putTranslation(
            novelId: widget.novelId,
            chapterNo: chapter.no,
            lang: lang.text.trim(),
            paragraphs: paragraphs,
          );
          final tr = await getTranslations(
            novelId: widget.novelId,
            chapterNo: chapter.no,
            lang: '',
          );
          if (!mounted) return;
          final langCode = lang.text.trim();
          var selected = 0;
          for (var i = 0; i < tr.length; i++) {
            if (tr[i].lang == langCode) selected = i;
          }
          setState(() {
            _translations = tr;
            _translationIndex = selected;
            _mode = 'both';
          });
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(t('reader.translationDone'))));
        } catch (e) {
          if (mounted) showError(context, e);
        }
      }
    }
    lang.dispose();
    body.dispose();
  }

  /// 单话评价：与作品评价同一套规则，只是门槛看**这一话**的阅读时长。
  Widget _reviewSection(
    BuildContext context,
    AppState state,
    ReaderPalette palette,
  ) {
    final t = state.t;
    final locked = _readSeconds < _requiredReadSeconds;

    Widget box(Widget child) => Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.divider),
      ),
      child: child,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t('reader.reviews'),
          style: TextStyle(
            color: palette.text,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 12),
        if (locked)
          box(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t('review.needRead', {
                    'have': _readSeconds,
                    'need': _requiredReadSeconds,
                    'scope': t('review.scope.chapter'),
                  }),
                  style: TextStyle(color: palette.text, fontSize: 13),
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: (_readSeconds / _requiredReadSeconds).clamp(0, 1),
                    minHeight: 4,
                    backgroundColor: palette.divider,
                    color: palette.accent,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  t('review.readGateHint'),
                  style: TextStyle(color: palette.muted, fontSize: 11.5),
                ),
              ],
            ),
          )
        else
          box(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _reviewCtrl,
                  maxLines: 3,
                  maxLength: 500,
                  style: TextStyle(color: palette.text, fontSize: 13.5),
                  decoration: InputDecoration(
                    hintText: t('novel.reviewHint'),
                    hintStyle: TextStyle(color: palette.muted),
                    counterStyle: TextStyle(color: palette.muted, fontSize: 10),
                    filled: true,
                    fillColor: palette.background,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: palette.divider),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: palette.divider),
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Wrap(
                  spacing: 2,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (var i = 1; i <= 5; i++)
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 34,
                          minHeight: 34,
                        ),
                        icon: Icon(
                          i <= _rating ? Icons.star : Icons.star_border,
                          size: 19,
                          color: i <= _rating ? palette.accent : palette.muted,
                        ),
                        onPressed: () => setState(() => _rating = i.toDouble()),
                      ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: _spoiler,
                          visualDensity: VisualDensity.compact,
                          side: BorderSide(color: palette.muted),
                          onChanged: (v) =>
                              setState(() => _spoiler = v ?? false),
                        ),
                        const SizedBox(width: 2),
                        Text(
                          t('review.spoiler'),
                          style: TextStyle(color: palette.text, fontSize: 12),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: _submitting ? null : _submitReview,
                    child: _submitting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(t('common.publish')),
                  ),
                ),
              ],
            ),
          ),
        for (final r in _reviews) _reviewCard(palette, r),
      ],
    );
  }

  Widget _reviewCard(ReaderPalette palette, ReviewView r) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  r.authorName,
                  style: TextStyle(
                    color: palette.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (r.rating > 0)
                Text(
                  '${r.rating}★',
                  style: TextStyle(fontSize: 12, color: palette.muted),
                ),
              if (r.spoiler) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: palette.accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    context.read<AppState>().t('review.spoiler'),
                    style: TextStyle(fontSize: 10, color: palette.accent),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            r.body,
            style: TextStyle(color: palette.text, fontSize: 13.5, height: 1.6),
          ),
        ],
      ),
    );
  }

  Future<void> _submitReview() async {
    final body = _reviewCtrl.text.trim();
    if (body.isEmpty) return;
    final state = context.read<AppState>();
    setState(() => _submitting = true);
    try {
      await addReview(
        novelId: widget.novelId,
        chapterNo: _chapterNo,
        body: body,
        rating: _rating.round(),
        spoiler: _spoiler,
      );
      if (!mounted) return;
      _reviewCtrl.clear();
      setState(() {
        _rating = 5;
        _spoiler = false;
        _submitting = false;
      });
      await state.refresh();
      if (!mounted) return;
      final rs = await getReviews(novelId: widget.novelId);
      if (!mounted) return;
      setState(() {
        _reviews = rs
            .where((r) => r.chapterNo == _chapterNo)
            .toList(growable: false);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      showReviewGateError(context, state, e);
    }
  }
}