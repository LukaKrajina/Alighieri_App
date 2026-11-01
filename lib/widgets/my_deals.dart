import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../src/rust/api.dart';
import '../src/rust/domain/view.dart';
import '../state/app_state.dart';
import 'widgets.dart';

/// 与当前身份有关的交易（我是作者或出版社）。
/// 出版社页与作者页共用一份 —— 两个页面不需要互相打听状态。
class MyDealsPanel extends StatefulWidget {
  const MyDealsPanel({super.key, this.onOpenNovel});

  final ValueChanged<String>? onOpenNovel;

  @override
  State<MyDealsPanel> createState() => _MyDealsPanelState();
}

class _MyDealsPanelState extends State<MyDealsPanel> {
  List<DealCard> _deals = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final deals = await myDeals();
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
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_deals.isEmpty) return EmptyState(title: t('deal.empty'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
                        child: InkWell(
                          onTap: widget.onOpenNovel == null
                              ? null
                              : () => widget.onOpenNovel!(d.novelId),
                          child: Text(
                            '${d.novelTitle} · ${t('deal.kind.${d.kind}')}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                      _StatusChip(status: d.status),
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
                        color: d.paidOnLedger
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.outline,
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
                              () => respondDeal(dealId: d.dealId, accept: true),
                            ),
                            child: Text(t('deal.accept')),
                          ),
                          OutlinedButton(
                            onPressed: () => _run(
                              () =>
                                  respondDeal(dealId: d.dealId, accept: false),
                            ),
                            child: Text(t('deal.decline')),
                          ),
                        ],
                        if (d.canSettle) ...[
                          FilledButton(
                            onPressed: () => _pay(d),
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

  Future<void> _pay(DealCard d) async {
    final t = context.read<AppState>().t;
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

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

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
