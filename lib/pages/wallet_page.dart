import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../src/rust/api.dart';
import '../src/rust/domain/view.dart';
import '../src/rust/engine.dart';
import '../state/app_state.dart';
import '../widgets/href.dart';
import '../widgets/widgets.dart';
import '../widgets/wrap_panel.dart';

/// 奖励币钱包。
///
/// 余额永远是算出来的：收到的 - 上链锁定的 - 轮播位花掉的。
/// 规则、持仓榜、收入构成都整条列在页面上，而不是藏在「关于」里 ——
/// 算式公开才谈得上可复算。页面结构与 Web 的 /wallet 对齐 —— 账目不能只给自己看。
class WalletPage extends StatelessWidget {
  const WalletPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final w = state.walletSummary;
    final cs = Theme.of(context).colorScheme;
    final me = state.identity?.peerId ?? '';

    if (w == null) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Panel(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: Text(
                    t('wallet.loading'),
                    style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    final flow = w.ledger.take(50).toList();
    final rules = state.rewardRules;

    final left = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FlowPanel(rows: flow),
        const SizedBox(height: 18),
        _HoldersPanel(holders: w.holders, me: me),
      ],
    );

    final aside = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _IncomePanel(rows: w.income),
        const SizedBox(height: 14),
        _RulesPanel(rules: rules),
        const SizedBox(height: 14),
        _AntiPanel(),
        const SizedBox(height: 14),
        _FormulaPanel(examples: w.examples),
      ],
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
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
                            Icon(
                              Icons.monetization_on_outlined,
                              size: 26,
                              color: cs.primary,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              t('wallet.title'),
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w900),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          t('wallet.sub'),
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.7,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    alignment: WrapAlignment.end,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => _transfer(context),
                        icon: const Icon(Icons.send_outlined, size: 17),
                        label: Text(t('wallet.transfer')),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => state.refresh(),
                        icon: const Icon(Icons.refresh, size: 17),
                        label: Text(t('common.retry')),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SectionHeading(
                      title: t('wrap.title'),
                      subtitle: t('wrap.intro'),
                    ),
                    const SizedBox(height: 10),
                    WrapPanel(onChanged: state.refresh),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              LayoutBuilder(
                builder: (context, box) {
                  final wide = box.maxWidth >= 760;
                  final balance = _BalanceCard(summary: w, me: me);
                  final stats = _StatsGrid(summary: w);
                  if (!wide) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        balance,
                        const SizedBox(height: 12),
                        stats,
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 14, child: balance),
                      const SizedBox(width: 16),
                      Expanded(flex: 10, child: stats),
                    ],
                  );
                },
              ),
              const SizedBox(height: 20),
              LayoutBuilder(
                builder: (context, box) {
                  if (box.maxWidth >= 960) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: left),
                        const SizedBox(width: 20),
                        SizedBox(width: 330, child: aside),
                      ],
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      left,
                      const SizedBox(height: 18),
                      aside,
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _transfer(BuildContext context) async {
    final state = context.read<AppState>();
    final t = state.t;
    final balance = state.walletSummary?.balance ?? 0;
    final peer = TextEditingController();
    final amount = TextEditingController(text: '10');
    final reason = TextEditingController();
    var amountValue = 10;
    final sent = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(t('wallet.transfer')),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t('wallet.balanceValue', {'n': balance})),
                const SizedBox(height: 12),
                TextField(
                  controller: peer,
                  decoration: InputDecoration(
                    labelText: t('wallet.transferTo'),
                    hintText: 'peer id',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: amount,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: t('wallet.amount')),
                  onChanged: (v) => setDialog(
                    () => amountValue = int.tryParse(v.trim()) ?? 0,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: reason,
                  decoration: InputDecoration(
                    labelText:
                        '${t('wallet.reason')} (${t('common.optional')})',
                  ),
                ),
                if (amountValue <= 0 || amountValue > balance) ...[
                  const SizedBox(height: 8),
                  Text(
                    t('wallet.insufficient'),
                    style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  t('wallet.transferNote'),
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(t('common.cancel')),
            ),
            FilledButton(
              onPressed:
                  peer.text.trim().isEmpty ||
                      amountValue <= 0 ||
                      amountValue > balance
                  ? null
                  : () => Navigator.pop(ctx, amountValue),
              child: Text(t('common.confirm')),
            ),
          ],
        ),
      ),
    );
    final to = peer.text.trim();
    final note = reason.text.trim();
    peer.dispose();
    amount.dispose();
    reason.dispose();
    if (sent == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await tip(toPeer: to, amount: sent, reason: note.isEmpty ? null : note);
      await state.refresh();
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(t('wallet.sent', {'n': sent}))),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('${t('error.prefix')}$e')));
    }
  }
}

/* ------------------------- 余额 / 统计 ------------------------- */

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.summary, required this.me});

  final WalletSummary summary;
  final String me;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    final deep = Color.lerp(cs.primary, Colors.black, 0.28) ?? cs.primary;
    final onCard = ThemeData.estimateBrightnessForColor(cs.primary) ==
            Brightness.dark
        ? Colors.white
        : Colors.black;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [cs.primary, deep],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -48,
            top: -48,
            child: Container(
              width: 160,
              height: 160,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.12),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t('wallet.balance'),
                style: TextStyle(
                  fontSize: 12.5,
                  color: onCard.withValues(alpha: 0.8),
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.end,
                spacing: 8,
                children: [
                  Text(
                    _format(summary.balance),
                    style: TextStyle(
                      fontSize: 40,
                      height: 1,
                      fontWeight: FontWeight.w900,
                      color: onCard,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  Text(
                    summary.symbol,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: onCard.withValues(alpha: 0.75),
                    ),
                  ),
                ],
              ),
              if (summary.locked > 0) ...[
                const SizedBox(height: 6),
                Text(
                  t('wallet.locked', {'n': summary.locked}),
                  style: TextStyle(
                    fontSize: 11.5,
                    color: onCard.withValues(alpha: 0.75),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              SelectableText(
                me.isEmpty ? '—' : me,
                style: TextStyle(
                  fontSize: 10.5,
                  fontFamily: 'monospace',
                  color: onCard.withValues(alpha: 0.65),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.summary});

  final WalletSummary summary;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    return LayoutBuilder(
      builder: (context, box) {
        final itemWidth = (box.maxWidth - 12) / 2;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            SizedBox(
              width: itemWidth,
              child: _Stat(
                label: t('wallet.stat.received'),
                value: _format(summary.totalIssued),
              ),
            ),
            SizedBox(
              width: itemWidth,
              child: _Stat(
                label: t('wallet.stat.flow'),
                value: '${summary.ledger.length} ${t('common.unit.entry')}',
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w900,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/* ------------------------- 流水 / 持仓 ------------------------- */

class _FlowPanel extends StatelessWidget {
  const _FlowPanel({required this.rows});

  final List<LedgerEntry> rows;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    return Panel(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PanelHeader(
            icon: Icons.monetization_on_outlined,
            title: t('wallet.flow.title'),
          ),
          Divider(height: 1, color: cs.outlineVariant),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 28, 16, 28),
              child: Column(
                children: [
                  Text(
                    t('wallet.flow.empty'),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    t('wallet.flow.empty.hint'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.6,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    alignment: WrapAlignment.center,
                    children: [
                      FilledButton.icon(
                        onPressed: () =>
                            openCarouselHref(context, '/browse'),
                        icon: const Icon(Icons.search, size: 17),
                        label: Text(t('wallet.findBooks')),
                      ),
                      OutlinedButton.icon(
                        onPressed: () =>
                            openCarouselHref(context, '/contests'),
                        icon: const Icon(Icons.emoji_events_outlined, size: 17),
                        label: Text(t('nav.contests')),
                      ),
                    ],
                  ),
                ],
              ),
            )
          else
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) Divider(height: 1, color: cs.outlineVariant),
              _FlowRow(entry: rows[i]),
            ],
        ],
      ),
    );
  }
}

class _FlowRow extends StatelessWidget {
  const _FlowRow({required this.entry});

  final LedgerEntry entry;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    final positive = entry.amount >= 0;
    final detail = entry.reason?.isNotEmpty == true
        ? entry.reason!
        : (entry.target?.isNotEmpty == true ? entry.target! : '—');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: cs.surfaceContainerHighest,
            ),
            child: Icon(
              _actionIcon(entry.action),
              size: 15,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _actionLabel(t, entry.action, entry.actionLabelKey),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  entry.wrapped
                      ? '$detail · ${t('wrap.wrapped')}'
                      : detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${positive ? '+' : ''}${entry.amount}',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w900,
              color: positive ? cs.primary : cs.error,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _HoldersPanel extends StatelessWidget {
  const _HoldersPanel({
    required this.holders,
    required this.me,
  });

  final List<WalletHolder> holders;
  final String me;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    return Panel(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PanelHeader(
            icon: Icons.people_outline,
            title: t('wallet.holders.title'),
            trailing: Text(
              t('wallet.onlyLocal'),
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ),
          Divider(height: 1, color: cs.outlineVariant),
          if (holders.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 26),
              child: Center(
                child: Text(
                  t('common.empty'),
                  style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
                ),
              ),
            )
          else
            for (var i = 0; i < holders.length; i++) ...[
              if (i > 0) Divider(height: 1, color: cs.outlineVariant),
              _HolderRow(
                index: i,
                holder: holders[i],
                me: me,
              ),
            ],
        ],
      ),
    );
  }
}

class _HolderRow extends StatelessWidget {
  const _HolderRow({
    required this.index,
    required this.holder,
    required this.me,
  });

  final int index;
  final WalletHolder holder;
  final String me;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    final shortPeer = holder.peer.length > 20
        ? '${holder.peer.substring(0, 20)}…'
        : holder.peer;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: Text(
              '${index + 1}',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w900,
                color: index == 0 ? cs.tertiary : cs.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        holder.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (me.isNotEmpty && holder.peer == me) ...[
                      const SizedBox(width: 5),
                      Text(
                        t('wallet.me'),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: cs.primary,
                        ),
                      ),
                    ],
                  ],
                ),
                Text(
                  shortPeer,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    fontFamily: 'monospace',
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _format(holder.coins),
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/* ------------------------- 侧栏 ------------------------- */

class _IncomePanel extends StatelessWidget {
  const _IncomePanel({required this.rows});

  final List<WalletIncome> rows;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t('wallet.income.title'),
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          if (rows.isEmpty)
            Text(
              t('wallet.income.empty'),
              style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
            )
          else
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: cs.surfaceContainerHighest,
                      ),
                      child: Icon(
                        _actionIcon(row.action),
                        size: 13,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _actionLabel(t, row.action, row.labelKey),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _format(row.amount),
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        fontFeatures: [FontFeature.tabularFigures()],
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

class _RulesPanel extends StatelessWidget {
  const _RulesPanel({required this.rules});

  final List<RewardRuleView> rules;

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
              Icon(Icons.lightbulb_outline, size: 17, color: cs.tertiary),
              const SizedBox(width: 6),
              Text(
                t('wallet.rules.title'),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final r in rules)
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Expanded(
                    child: Text(
                      t(r.labelKey),
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Text(
                    '+${r.rate}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (r.dailyCap > 0) ...[
                    const SizedBox(width: 4),
                    Text(
                      t('wallet.rules.dailyCap', {'n': r.dailyCap}),
                      style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _AntiPanel extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.tertiary.withValues(alpha: 0.4)),
        color: cs.tertiary.withValues(alpha: 0.06),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 17, color: cs.tertiary),
              const SizedBox(width: 6),
              Text(
                t('wallet.anti.title'),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final key in const [
            'wallet.anti.1',
            'wallet.anti.2',
            'wallet.anti.3',
            'wallet.anti.4',
            'wallet.anti.5',
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Text(
                '· ${t(key)}',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.55,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _FormulaPanel extends StatelessWidget {
  const _FormulaPanel({required this.examples});

  final RewardExampleView examples;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    final unit = t('coin.unit');
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, size: 15, color: cs.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                t('wallet.formula.title'),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: cs.surface,
            ),
            child: SelectableText(
              'reward = ${examples.authorShareRate} × √uniqueViews ÷ (1 + totalViews / 1000)',
              style: TextStyle(
                fontSize: 10.5,
                height: 1.5,
                fontFamily: 'monospace',
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${t('wallet.formula.explain')} '
            '${t('wallet.formula.example', {'n': examples.authorExample})}',
            style: TextStyle(
              fontSize: 11,
              height: 1.55,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Divider(height: 1, color: cs.outlineVariant),
          const SizedBox(height: 8),
          Text(
            '${t('wallet.examples.title')} '
            '${t('wallet.examples.read')} ${examples.readExample} $unit'
            ' · '
            '${t('wallet.examples.idle')} ${examples.idleExample} $unit',
            style: TextStyle(
              fontSize: 11,
              height: 1.55,
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/* ------------------------- 小工具 ------------------------- */

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.icon, required this.title, this.trailing});

  final IconData icon;
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 18, color: cs.tertiary),
          const SizedBox(width: 6),
          Text(
            title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
  }
}

/// 行为名的字典键。`wallet.rules.other` 之外都走字典；
/// 未知行为与 Web 一样直接显示原始动作名，不认识的词也不硬编。
String _actionLabel(String Function(String, [Map<String, Object>?]) t,
    String action, String labelKey) {
  if (labelKey.isEmpty || labelKey == 'wallet.rules.other') return action;
  return t(labelKey);
}

IconData _actionIcon(String action) => switch (action) {
  'readChapter' || 'finishNovel' => Icons.menu_book_outlined,
  'like' => Icons.favorite_border,
  'bookmark' => Icons.star_border,
  'review' => Icons.edit_outlined,
  'publish' => Icons.auto_awesome_outlined,
  'authorBookmarkShare' => Icons.trending_up,
  'prize' => Icons.emoji_events_outlined,
  'tip' => Icons.volunteer_activism_outlined,
  _ => Icons.paid_outlined,
};

String _format(int n) {
  final s = n.abs().toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return n < 0 ? '-$buf' : buf.toString();
}
