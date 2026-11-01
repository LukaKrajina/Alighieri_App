import 'package:flutter/material.dart' hide CarouselView;
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../src/rust/api.dart' as rust;
import '../src/rust/domain/view.dart';
import '../state/app_state.dart';
import '../widgets/href.dart';
import '../widgets/widgets.dart';

/// 首页轮播位购买与管理页。
///
/// 规则全部在 Rust 侧：当前占用、冷却、余额、能否购买都来自
/// `carouselState()` 的派生结果。界面只负责展示和提交，规则不在这里开后门。
class CarouselPage extends StatefulWidget {
  const CarouselPage({super.key});

  @override
  State<CarouselPage> createState() => _CarouselPageState();
}

class _CarouselPageState extends State<CarouselPage> {
  final _title = TextEditingController();
  final _subtitle = TextEditingController();
  final _target = TextEditingController();
  final _href = TextEditingController();
  final _byName = TextEditingController();
  String _kind = 'novel';
  bool _busy = false;
  String? _error;
  (int, int)? _done;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppState>().refreshCarousel();
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _subtitle.dispose();
    _target.dispose();
    _href.dispose();
    _byName.dispose();
    super.dispose();
  }

  Future<void> _submit(AppState state) async {
    final t = state.t;
    if (_title.text.trim().isEmpty) {
      setState(() => _error = t('carousel.form.errTitle'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = await rust.submitCarousel(
        title: _title.text.trim(),
        subtitle: _subtitle.text.trim(),
        kind: _kind,
        targetId: _target.text.trim(),
        href: _href.text.trim(),
        byName: _byName.text.trim(),
      );
      await state.refresh();
      await state.refreshCarousel();
      if (!mounted) return;
      final mine = state.carousel?.mine ?? const <CarouselView>[];
      CarouselView? created;
      for (final c in mine) {
        if (c.id == id) created = c;
      }
      setState(() {
        if (created != null) {
          _done = (created.startedAtMs.toInt(), created.expiresAtMs.toInt());
        }
        _title.clear();
        _subtitle.clear();
        _target.clear();
        _href.clear();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _errorMessage(state, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _errorMessage(AppState state, Object e) {
    final msg = e.toString();
    if (msg.contains('carousel-cooldown')) {
      return state.t('carousel.form.errCooldown');
    }
    if (msg.contains('carousel-full')) return state.t('carousel.form.errFull');
    if (msg.contains('carousel-balance')) {
      return state.t('carousel.form.errBalance');
    }
    if (msg.contains('carousel-title')) return state.t('carousel.form.errTitle');
    if (msg.contains('carousel-href')) return state.t('carousel.form.errHref');
    if (msg.contains('还没有身份')) return state.t('carousel.form.errIdentity');
    return state.t('carousel.form.err');
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final c = state.carousel;
    final locale = state.locale;
    final cs = Theme.of(context).colorScheme;

    if (c == null) {
      return Scaffold(
        appBar: AppBar(title: Text(t('carousel.title'))),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(t('carousel.title'))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t('carousel.title'),
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  t('carousel.sub'),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),
                LayoutBuilder(
                  builder: (context, box) {
                    final wide = box.maxWidth >= 760;
                    final cards = [
                      _stat(
                        context,
                        t('carousel.balance'),
                        '${c.balance}',
                        primary: true,
                      ),
                      _stat(context, t('carousel.fee'), '${c.fee}'),
                      _stat(context, t('carousel.used'), '${c.active.length} / ${c.slots}'),
                      _stat(
                        context,
                        t('carousel.window'),
                        t('carousel.days', {'n': c.windowDays}),
                      ),
                    ];
                    return GridView.count(
                      crossAxisCount: wide ? 4 : 2,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      childAspectRatio: wide ? 2.2 : 1.8,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      children: cards,
                    );
                  },
                ),
                if (_done != null) ...[
                  const SizedBox(height: 16),
                  Card(
                    color: cs.primaryContainer.withValues(alpha: 0.55),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.check_circle_outline, color: cs.primary),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  t('carousel.success.title'),
                                  style: const TextStyle(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  t('carousel.success.body', {
                                    'start': _date(_done!.$1, locale),
                                    'end': _date(_done!.$2, locale),
                                  }),
                                  style: TextStyle(color: cs.onSurfaceVariant),
                                ),
                              ],
                            ),
                          ),
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: Text(t('carousel.success.cta')),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                LayoutBuilder(
                  builder: (context, box) {
                    final wide = box.maxWidth >= 980;
                    final main = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _slots(context, state, c),
                        const SizedBox(height: 20),
                        _form(context, state, c),
                      ],
                    );
                    final aside = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _mine(context, state, c),
                        const SizedBox(height: 20),
                        _rules(context, state, c),
                        const SizedBox(height: 20),
                        Panel(
                          child: Text(
                            t('carousel.state.note'),
                            style: TextStyle(
                              fontSize: 12.5,
                              height: 1.6,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    );
                    if (!wide) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [main, const SizedBox(height: 20), aside],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: main),
                        const SizedBox(width: 20),
                        SizedBox(width: 340, child: aside),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _stat(
    BuildContext context,
    String label,
    String value, {
    bool primary = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: primary ? cs.primary : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              color: primary ? cs.onPrimary.withValues(alpha: 0.8) : cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: primary ? cs.onPrimary : cs.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _slots(BuildContext context, AppState state, CarouselStateView c) {
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.layers_outlined, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t('carousel.slots.title'),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                t('home.carousel.used', {
                  'used': c.active.length,
                  'total': c.slots,
                }),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, box) {
              final cols = box.maxWidth >= 840 ? 3 : (box.maxWidth >= 540 ? 2 : 1);
              final gap = 8.0;
              final width = (box.maxWidth - gap * (cols - 1)) / cols;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (var i = 0; i < c.slots; i++)
                    SizedBox(
                      width: width,
                      child: i < c.active.length
                          ? _slotCard(context, state, c.active[i], i)
                          : _emptySlot(context, state, i),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _slotCard(
    BuildContext context,
    AppState state,
    CarouselView r,
    int index,
  ) {
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => openCarouselHref(context, r.href),
        child: Container(
          constraints: const BoxConstraints(minHeight: 96),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.6)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Text(
                    t('home.carousel.slot', {'n': index + 1}),
                    style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      t('carousel.kind.${r.kind}'),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant),
                    ),
                  ),
                  if (r.mine)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: cs.primaryContainer,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        t('carousel.slots.mine'),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: cs.primary,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                r.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
              ),
              const SizedBox(height: 2),
              Text(
                t('carousel.slots.expires', {
                  'date': _date(r.expiresAtMs.toInt(), state.locale),
                }),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptySlot(BuildContext context, AppState state, int index) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minHeight: 96),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: cs.outlineVariant,
          style: BorderStyle.solid,
        ),
        color: cs.surface.withValues(alpha: 0.4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            state.t('home.carousel.slot', {'n': index + 1}),
            style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant),
          ),
          Text(
            state.t('carousel.slots.empty'),
            style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _form(BuildContext context, AppState state, CarouselStateView c) {
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    final blocked = _blockMessage(state, c);
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t('carousel.form.title'),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          if (blocked != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.tertiaryContainer.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded, size: 18, color: cs.tertiary),
                  const SizedBox(width: 8),
                  Expanded(child: Text(blocked, style: const TextStyle(height: 1.5))),
                ],
              ),
            )
          else ...[
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _title,
                    maxLength: 48,
                    decoration: InputDecoration(
                      labelText: t('carousel.form.name'),
                      hintText: t('carousel.form.namePh'),
                      counterText: '',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _byName,
                    maxLength: 40,
                    decoration: InputDecoration(
                      labelText: t('carousel.form.byName'),
                      hintText: t('carousel.form.byNamePh'),
                      counterText: '',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _subtitle,
              maxLength: 80,
              decoration: InputDecoration(
                labelText: t('carousel.form.subtitle'),
                hintText: t('carousel.form.subtitlePh'),
                counterText: '',
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                for (final k in const ['novel', 'author', 'publisher', 'link'])
                  ChoiceChip(
                    label: Text(t('carousel.kind.$k')),
                    selected: _kind == k,
                    onSelected: (_) => setState(() => _kind = k),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _href,
              decoration: InputDecoration(
                labelText: t('carousel.form.href'),
                hintText: t('carousel.form.hrefPh'),
                prefixIcon: const Icon(Icons.link),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _target,
              decoration: InputDecoration(
                labelText: t('carousel.form.target'),
                hintText: t('carousel.form.targetPh'),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: cs.error, fontSize: 12.5),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    t('carousel.form.note'),
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.5,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: _busy ? null : () => _submit(state),
                  icon: const Icon(Icons.campaign_outlined),
                  label: Text(
                    _busy
                        ? t('carousel.form.submitting')
                        : t('carousel.form.submit', {'fee': c.fee}),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String? _blockMessage(AppState state, CarouselStateView c) {
    switch (c.blockReason) {
      case 'identity':
        return state.t('carousel.identity.body');
      case 'cooldown':
        return state.t('carousel.state.cooldown', {
          'time': _date(
            DateTime.now().millisecondsSinceEpoch + c.cooldownMs.toInt(),
            state.locale,
          ),
        });
      case 'full':
        return state.t('carousel.state.full');
      case 'balance':
        final need = (c.fee - c.balance).clamp(0, c.fee);
        return state.t('carousel.state.balance', {'n': need});
      default:
        return null;
    }
  }

  Widget _mine(BuildContext context, AppState state, CarouselStateView c) {
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    final now = DateTime.now().millisecondsSinceEpoch;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.history, size: 18, color: cs.onSurfaceVariant),
              const SizedBox(width: 8),
              Text(
                t('carousel.mine.title'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (c.mine.isEmpty)
            Text(
              t('carousel.mine.empty'),
              style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
            )
          else
            for (final r in c.mine)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      InkWell(
                        onTap: () => openCarouselHref(context, r.href),
                        child: Text(
                          r.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        r.expiresAtMs <= now
                            ? t('carousel.mine.expired', {
                                'date': _date(r.expiresAtMs.toInt(), state.locale),
                              })
                            : c.active.any((a) => a.id == r.id)
                            ? t('carousel.mine.active', {
                                'date': _date(r.expiresAtMs.toInt(), state.locale),
                              })
                            : t('carousel.mine.waiting'),
                        style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }

  Widget _rules(BuildContext context, AppState state, CarouselStateView c) {
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.tertiaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, size: 18, color: cs.tertiary),
              const SizedBox(width: 8),
              Text(
                t('carousel.rules.title'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final k in const ['1', '2', '3', '4', '5', '6'])
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '· ${t('carousel.rules.$k', {
                  'slots': c.slots,
                  'days': c.windowDays,
                  'fee': c.fee,
                })}',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.5,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _date(int ms, String locale) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    try {
      return DateFormat.MMMd(locale).add_Hm().format(d);
    } catch (_) {
      return DateFormat.MMMd().add_Hm().format(d);
    }
  }
}
