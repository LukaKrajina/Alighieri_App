import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

/// 阅读器外观
/// ----------
/// 番茄 / Kakuyomu 这类阅读 App 的共同点：正文是主角，工具栏是客人。
/// 所以这里只保留三件事：纸面颜色、行距、字号；其它全部退到浮层里 ——
/// 客人要有客人的自觉。
class ReaderPalette {
  const ReaderPalette({
    required this.background,
    required this.surface,
    required this.text,
    required this.muted,
    required this.divider,
    required this.accent,
    required this.isDark,
  });

  final Color background;
  final Color surface;
  final Color text;
  final Color muted;
  final Color divider;
  final Color accent;
  final bool isDark;

  static ReaderPalette of(BuildContext context, AppState state) {
    return switch (state.settings.readerTheme) {
      'white' => const ReaderPalette(
        background: Color(0xFFFDFDFC),
        surface: Color(0xFFFFFFFF),
        text: Color(0xFF1C211E),
        muted: Color(0xFF6B766F),
        divider: Color(0xFFE3E8E4),
        accent: Color(0xFF229B62),
        isDark: false,
      ),
      'dark' => const ReaderPalette(
        background: Color(0xFF141614),
        surface: Color(0xFF1D211E),
        text: Color(0xFFD9DDD8),
        muted: Color(0xFF8B948D),
        divider: Color(0xFF2C322E),
        accent: Color(0xFF6FCF97),
        isDark: true,
      ),
      _ => const ReaderPalette(
        background: Color(0xFFF6F0E2),
        surface: Color(0xFFFBF7EC),
        text: Color(0xFF332E25),
        muted: Color(0xFF7C7465),
        divider: Color(0xFFE4DAC6),
        accent: Color(0xFF8A6A3B),
        isDark: false,
      ),
    };
  }
}

/// 统一的阅读器外壳。
///
/// 内容区完全由页面提供；这里只负责：
///   · 点击中部呼出 / 收起工具栏；
///   · 点击左右两侧翻章（翻页模式下也支持横滑）；
///   · 顶部标题、目录、设置；底部章节位置与进度。
class ReaderScaffold extends StatefulWidget {
  const ReaderScaffold({
    super.key,
    required this.title,
    required this.body,
    required this.toc,
    required this.positionLabel,
    required this.progress,
    required this.hasPrev,
    required this.hasNext,
    required this.onPrev,
    required this.onNext,
    required this.onSettings,
    this.actions = const [],
    this.footer,
    this.onHorizontalSwipe,
    this.showBack = true,
  });

  final String title;
  final Widget body;
  final Widget toc;
  final String positionLabel;
  final double progress;
  final bool hasPrev;
  final bool hasNext;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onSettings;
  final List<Widget> actions;
  final Widget? footer;
  final ValueChanged<int>? onHorizontalSwipe;
  final bool showBack;

  @override
  State<ReaderScaffold> createState() => _ReaderScaffoldState();
}

class _ReaderScaffoldState extends State<ReaderScaffold> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _chrome = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_chrome) return;
    _hideTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _chrome = false);
    });
  }

  void _toggleChrome() {
    setState(() => _chrome = !_chrome);
    _scheduleHide();
  }

  void _handleTap(TapUpDetails details) {
    final size = MediaQuery.sizeOf(context);
    final dx = details.localPosition.dx;
    final dy = details.localPosition.dy;
    // 只在贴近屏幕边缘的窄条里翻章：误触翻章比读错字更扫兴。
    final edge = (size.width * 0.15).clamp(48.0, 96.0);
    final inBody = dy > 110 && dy < size.height - 130;
    if (inBody && dx < edge && widget.hasPrev) {
      widget.onPrev();
      return;
    }
    if (inBody && dx > size.width - edge && widget.hasNext) {
      widget.onNext();
      return;
    }
    _toggleChrome();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final palette = ReaderPalette.of(context, state);
    final t = state.t;
    final pageMode = state.settings.readerPageMode == 'page';

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: palette.background,
      endDrawer: Drawer(
        backgroundColor: palette.surface,
        child: SafeArea(child: widget.toc),
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapUp: _handleTap,
              onHorizontalDragEnd: pageMode && widget.onHorizontalSwipe != null
                  ? (d) {
                      final v = d.primaryVelocity ?? 0;
                      if (v > 180 && widget.hasPrev) widget.onPrev();
                      if (v < -180 && widget.hasNext) widget.onNext();
                    }
                  : null,
              child: widget.body,
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: IgnorePointer(
              ignoring: !_chrome,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 180),
                opacity: _chrome ? 1 : 0,
                child: _TopBar(
                  title: widget.title,
                  palette: palette,
                  showBack: widget.showBack,
                  actions: [
                    ...widget.actions,
                    IconButton(
                      tooltip: t('reader.toc'),
                      color: palette.text,
                      icon: const Icon(Icons.format_list_numbered),
                      onPressed: () =>
                          _scaffoldKey.currentState?.openEndDrawer(),
                    ),
                    IconButton(
                      tooltip: t('reader.settings'),
                      color: palette.text,
                      icon: const Icon(Icons.text_fields),
                      onPressed: widget.onSettings,
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              ignoring: !_chrome,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 180),
                opacity: _chrome ? 1 : 0,
                child: _BottomBar(
                  palette: palette,
                  positionLabel: widget.positionLabel,
                  progress: widget.progress,
                  hasPrev: widget.hasPrev,
                  hasNext: widget.hasNext,
                  onPrev: widget.onPrev,
                  onNext: widget.onNext,
                  footer: widget.footer,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.palette,
    required this.actions,
    required this.showBack,
  });

  final String title;
  final ReaderPalette palette;
  final List<Widget> actions;
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: palette.surface.withValues(alpha: 0.94),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              if (showBack)
                IconButton(
                  color: palette.text,
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.of(context).maybePop(),
                )
              else
                const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.text,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
              ),
              ...actions,
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.palette,
    required this.positionLabel,
    required this.progress,
    required this.hasPrev,
    required this.hasNext,
    required this.onPrev,
    required this.onNext,
    this.footer,
  });

  final ReaderPalette palette;
  final String positionLabel;
  final double progress;
  final bool hasPrev;
  final bool hasNext;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: palette.surface.withValues(alpha: 0.94),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  IconButton(
                    color: palette.text,
                    onPressed: hasPrev ? onPrev : null,
                    icon: const Icon(Icons.chevron_left),
                    tooltip: context.read<AppState>().t('reader.prev'),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        Text(
                          positionLabel,
                          style: TextStyle(fontSize: 12, color: palette.muted),
                        ),
                        const SizedBox(height: 4),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: progress.clamp(0, 1),
                            minHeight: 3,
                            backgroundColor: palette.divider,
                            color: palette.accent,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    color: palette.text,
                    onPressed: hasNext ? onNext : null,
                    icon: const Icon(Icons.chevron_right),
                    tooltip: context.read<AppState>().t('reader.next'),
                  ),
                ],
              ),
              ?footer,
            ],
          ),
        ),
      ),
    );
  }
}

/// 阅读设置。所有项都写回本机设置，站内书和本地书都认这套口味。
Future<void> showReaderSettings(BuildContext context, AppState state) async {
  var scale = state.settings.readerFontScale;
  var lineHeight = state.settings.readerLineHeight;
  var theme = state.settings.readerTheme;
  var pageMode = state.settings.readerPageMode;
  var autoNext = state.settings.readerAutoNext;
  final t = state.t;
  final palette = ReaderPalette.of(context, state);

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: palette.surface,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t('reader.settings'),
                style: TextStyle(
                  color: palette.text,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 18),
              _SheetLabel(t('reader.fontScale'), palette),
              Row(
                children: [
                  Text(
                    'A',
                    style: TextStyle(color: palette.muted, fontSize: 13),
                  ),
                  Expanded(
                    child: Slider(
                      value: scale,
                      min: 0.8,
                      max: 1.8,
                      divisions: 10,
                      label: '${(scale * 100).round()}%',
                      onChanged: (v) => setSheet(() => scale = v),
                    ),
                  ),
                  Text(
                    'A',
                    style: TextStyle(color: palette.text, fontSize: 20),
                  ),
                ],
              ),
              _SheetLabel(t('reader.lineHeight'), palette),
              Slider(
                value: lineHeight,
                min: 1.4,
                max: 2.4,
                divisions: 10,
                label: lineHeight.toStringAsFixed(1),
                onChanged: (v) => setSheet(() => lineHeight = v),
              ),
              _SheetLabel(t('reader.theme'), palette),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                children: [
                  for (final (id, bg, fg) in [
                    ('white', const Color(0xFFFDFDFC), const Color(0xFF1C211E)),
                    ('paper', const Color(0xFFF6F0E2), const Color(0xFF332E25)),
                    ('dark', const Color(0xFF141614), const Color(0xFFD9DDD8)),
                  ])
                    ChoiceChip(
                      selected: theme == id,
                      onSelected: (_) => setSheet(() => theme = id),
                      backgroundColor: bg,
                      selectedColor: bg,
                      label: Text(
                        t('reader.theme.$id'),
                        style: TextStyle(color: fg),
                      ),
                      avatar: theme == id
                          ? Icon(Icons.check, size: 16, color: fg)
                          : null,
                    ),
                ],
              ),
              const SizedBox(height: 14),
              _SheetLabel(t('reader.pageMode'), palette),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(
                    value: 'scroll',
                    icon: const Icon(Icons.swap_vert),
                    label: Text(t('reader.pageMode.scroll')),
                  ),
                  ButtonSegment(
                    value: 'page',
                    icon: const Icon(Icons.swap_horiz),
                    label: Text(t('reader.pageMode.page')),
                  ),
                ],
                selected: {pageMode},
                onSelectionChanged: (s) => setSheet(() => pageMode = s.first),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: autoNext,
                onChanged: (v) => setSheet(() => autoNext = v),
                title: Text(
                  t('reader.autoNext'),
                  style: TextStyle(color: palette.text, fontSize: 14),
                ),
                subtitle: Text(
                  t('reader.autoNextHint'),
                  style: TextStyle(color: palette.muted, fontSize: 12),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () async {
                    await state.setFontScale(scale);
                    await state.setReaderLook(
                      theme: theme,
                      lineHeight: lineHeight,
                      pageMode: pageMode,
                      autoNext: autoNext,
                    );
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  child: Text(t('common.save')),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                t('reader.fontNote'),
                style: TextStyle(color: palette.muted, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _SheetLabel extends StatelessWidget {
  const _SheetLabel(this.text, this.palette);

  final String text;
  final ReaderPalette palette;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: palette.muted,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/// 章末提示：自动下一章倒计时或全书读完。
class ReaderEndNotice extends StatelessWidget {
  const ReaderEndNotice({
    super.key,
    required this.palette,
    required this.text,
    this.action,
  });

  final ReaderPalette palette;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 20),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: palette.divider),
        borderRadius: BorderRadius.circular(12),
        color: palette.surface.withValues(alpha: 0.6),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: palette.muted, fontSize: 12.5),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}
