import 'dart:async';

import 'package:flutter/material.dart' hide CarouselView;
import 'package:provider/provider.dart';

import '../pages/carousel_page.dart';
import '../src/rust/domain/view.dart';
import '../state/app_state.dart';
import 'href.dart';

/// 首页轮播位。
///
/// 当前显示哪几条、还剩多久，全部来自 Rust 侧派生状态。时间一到记录自动
/// 消失，位置顺延给下一条 —— 没有「下架」按钮，也没有运营推荐，到点就换人。
class HomeCarousel extends StatefulWidget {
  const HomeCarousel({super.key});

  @override
  State<HomeCarousel> createState() => _HomeCarouselState();
}

class _HomeCarouselState extends State<HomeCarousel> {
  static const _rotate = Duration(seconds: 6);
  static const _dayMs = 24 * 60 * 60 * 1000;

  Timer? _timer;
  Timer? _refresh;
  int _index = 0;
  bool _paused = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_rotate, (_) {
      if (!mounted || _paused) return;
      final active = context.read<AppState>().carousel?.active ?? const [];
      if (active.length < 2) return;
      setState(() => _index = (_index + 1) % active.length);
    });
    _refresh = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      context.read<AppState>().refreshCarousel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _refresh?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    final carousel = state.carousel;
    final active = carousel?.active ?? const <CarouselView>[];
    final slots = carousel?.slots ?? 6;
    final fee = carousel?.fee ?? 100;
    final days = carousel?.windowDays ?? 7;

    if (active.isNotEmpty && _index >= active.length) {
      _index = 0;
    }
    final current = active.isEmpty ? null : active[_index];

    return MouseRegion(
      onEnter: (_) => _paused = true,
      onExit: (_) => _paused = false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.campaign_outlined, size: 19, color: cs.primary),
                        const SizedBox(width: 8),
                        Text(
                          t('home.carousel.title'),
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      t('home.carousel.sub'),
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: () => _openBuy(context),
                icon: const Icon(Icons.add, size: 16),
                label: Text(t('home.carousel.buy')),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (current == null)
            _empty(context, state, slots, fee)
          else
            _slide(context, state, current, active),
          const SizedBox(height: 8),
          Row(
            children: [
              for (var i = 0; i < slots; i++) ...[
                Expanded(
                  child: _Bar(
                    filled: i < active.length,
                    selected: i == _index && active.isNotEmpty,
                    label: i < active.length
                        ? t('home.carousel.goSlot', {
                            'n': i + 1,
                            'title': active[i].title,
                          })
                        : t('home.carousel.slotEmpty', {'n': i + 1}),
                    onTap: i < active.length
                        ? () => setState(() => _index = i)
                        : () => _openBuy(context),
                  ),
                ),
                if (i != slots - 1) const SizedBox(width: 5),
              ],
              const SizedBox(width: 8),
              Text(
                t('home.carousel.used', {
                  'used': active.length,
                  'total': slots,
                }),
                style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              t('home.carousel.disclaimer', {'fee': fee, 'days': days}),
              style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context, AppState state, int slots, int fee) {
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant),
        color: cs.surfaceContainerLow,
      ),
      child: Row(
        children: [
          Icon(Icons.auto_awesome_outlined, color: cs.tertiary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t('home.carousel.empty.title'),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                Text(
                  t('home.carousel.empty.body', {'slots': slots, 'fee': fee}),
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton(
            onPressed: () => _openBuy(context),
            child: Text(t('home.carousel.empty.cta')),
          ),
        ],
      ),
    );
  }

  Widget _slide(
    BuildContext context,
    AppState state,
    CarouselView current,
    List<CarouselView> active,
  ) {
    final t = state.t;
    final hue = _hash(current.id) % 360;
    final now = DateTime.now().millisecondsSinceEpoch;
    final left = ((current.expiresAtMs - now) / _dayMs).ceil().clamp(1, 999);
    final gradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        HSLColor.fromAHSL(1, hue.toDouble(), 0.40, 0.20).toColor(),
        HSLColor.fromAHSL(1, (hue + 34) % 360, 0.44, 0.30).toColor(),
        HSLColor.fromAHSL(1, (hue + 70) % 360, 0.50, 0.26).toColor(),
      ],
    );
    return Container(
      constraints: const BoxConstraints(minHeight: 190),
      decoration: BoxDecoration(
        gradient: gradient,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -40,
            top: -60,
            child: Container(
              width: 180,
              height: 180,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.08),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _pill(t('carousel.kind.${current.kind}')),
                    const SizedBox(width: 6),
                    _pill(t('home.carousel.slot', {'n': active.indexOf(current) + 1})),
                    const Spacer(),
                    _pill(t('carousel.days', {'n': left})),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  current.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    height: 1.15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                if (current.subtitle.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    current.subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.80),
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    if (current.byName.isNotEmpty)
                      Expanded(
                        child: Text(
                          t('home.carousel.by', {'name': current.byName}),
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.75),
                            fontSize: 12,
                          ),
                        ),
                      )
                    else
                      const Spacer(),
                    InkWell(
                      onTap: () => openCarouselHref(context, current.href),
                      child: Text(
                        '${t('home.carousel.visit')}  →',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (active.length > 1) ...[
            Positioned(
              left: 6,
              top: 0,
              bottom: 0,
              child: Center(
                child: IconButton(
                  tooltip: t('home.carousel.prev'),
                  onPressed: () => setState(
                    () => _index = (_index - 1 + active.length) % active.length,
                  ),
                  icon: const Icon(Icons.chevron_left, color: Colors.white),
                ),
              ),
            ),
            Positioned(
              right: 6,
              top: 0,
              bottom: 0,
              child: Center(
                child: IconButton(
                  tooltip: t('home.carousel.next'),
                  onPressed: () => setState(
                    () => _index = (_index + 1) % active.length,
                  ),
                  icon: const Icon(Icons.chevron_right, color: Colors.white),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _pill(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 10.5,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  void _openBuy(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CarouselPage()),
    );
  }

  int _hash(String s) {
    var h = 2166136261;
    for (final code in s.codeUnits) {
      h ^= code;
      h = (h * 16777619) & 0x7fffffff;
    }
    return h;
  }
}

class _Bar extends StatelessWidget {
  const _Bar({
    required this.filled,
    required this.selected,
    required this.label,
    required this.onTap,
  });

  final bool filled;
  final bool selected;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 6,
          decoration: BoxDecoration(
            color: !filled
                ? cs.outlineVariant.withValues(alpha: 0.6)
                : selected
                ? cs.primary
                : cs.primary.withValues(alpha: 0.30),
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
    );
  }
}
