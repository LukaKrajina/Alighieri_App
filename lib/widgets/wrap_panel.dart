import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../src/rust/api.dart';
import '../src/rust/domain/view.dart';
import '../state/app_state.dart';
import 'widgets.dart';

/// 奖励币上链
/// ----------
/// 默认全关：没有唯一桥接节点、HTTPS API 与合约地址时，界面只显示「待配置」。
/// 签名归 Rust，网络归 Dart，谁也别堵住谁。
class WrapPanel extends StatefulWidget {
  const WrapPanel({super.key, required this.onChanged});

  final Future<void> Function() onChanged;

  @override
  State<WrapPanel> createState() => _WrapPanelState();
}

class _WrapPanelState extends State<WrapPanel> {
  WrapCoverageView? _coverage;
  List<WrapCard> _records = [];
  bool _loading = true;
  bool _busy = false;
  bool _nodeReachable = false;
  int _nodeAvailable = 0;
  int _nodeTotal = 0;
  int _nodeWrapped = 0;
  final _address = TextEditingController();
  final _amount = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _address.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final cov = await wrapCoverage();
      final records = await wrapRecords();
      if (!mounted) return;
      setState(() {
        _coverage = cov;
        _records = records;
        _loading = false;
        if (_amount.text.isEmpty) {
          _amount.text = cov.available > 0 ? '${cov.available}' : '';
        }
      });
      if (cov.configured) await _fetchNode(cov);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showError(context, e);
    }
  }

  Future<void> _fetchNode(WrapCoverageView cov) async {
    final state = context.read<AppState>();
    final api = state.settings.bridgeApiUrl;
    final peer = state.settings.bridgePeerId;
    if (api.isEmpty || peer.isEmpty) return;
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      final uri = Uri.parse(
        '${api.replaceAll(RegExp(r'/+$'), '')}/coverage?peerId=${Uri.encodeComponent(peer)}',
      );
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      if (!mounted || res.statusCode != 200) return;
      final data = jsonDecode(text);
      if (data is! Map) return;
      final available = data['available'];
      final total = data['total'];
      final wrapped = data['wrapped'];
      if (available is! num || total is! num || wrapped is! num) return;
      setState(() {
        _nodeReachable = true;
        _nodeAvailable = available.toInt();
        _nodeTotal = total.toInt();
        _nodeWrapped = wrapped.toInt();
      });
    } catch (_) {
      if (mounted) setState(() => _nodeReachable = false);
    } finally {
      client?.close(force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    final cov = _coverage;

    if (_loading) return const Center(child: CircularProgressIndicator());
    if (cov == null) return const SizedBox.shrink();

    if (!cov.configured) {
      return Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.hub_outlined, size: 18, color: cs.outline),
                const SizedBox(width: 8),
                Text(
                  t('wrap.notConfigured'),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(t('wrap.notConfiguredBody')),
            for (final e in cov.configErrors) ...[
              const SizedBox(height: 6),
              Text(e, style: TextStyle(color: cs.error, fontSize: 12)),
            ],
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _configDialog,
              icon: const Icon(Icons.settings_outlined, size: 18),
              label: Text(t('wrap.configure')),
            ),
          ],
        ),
      );
    }

    final pending = (_nodeReachable && cov.available > _nodeAvailable)
        ? cov.available - _nodeAvailable
        : 0;
    final symbol = state.settings.bridgeSymbol;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      t('wrap.intro'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  IconButton(
                    tooltip: t('wrap.coverageRefresh'),
                    icon: const Icon(Icons.refresh, size: 18),
                    onPressed: () async {
                      await _load();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 16,
                runSpacing: 10,
                children: [
                  _Stat(label: t('wrap.balance'), value: '◈ ${cov.balance}'),
                  _Stat(label: t('wrap.wrapped'), value: '◈ ${cov.wrapped}'),
                  _Stat(
                    label: t('wrap.available'),
                    value: '◈ ${cov.available}',
                  ),
                  _Stat(
                    label: t('wrap.node'),
                    value: _nodeReachable
                        ? '◈ $_nodeAvailable / ◈ $_nodeTotal'
                        : '—',
                  ),
                ],
              ),
              if (_nodeReachable)
                Text(
                  '${t('wrap.wrapped')}: ◈ $_nodeWrapped / ◈ $_nodeTotal',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (!_nodeReachable) ...[
                const SizedBox(height: 8),
                Text(
                  t('wrap.nodeOffline'),
                  style: TextStyle(color: cs.outline, fontSize: 12),
                ),
              ] else if (pending > 0) ...[
                const SizedBox(height: 8),
                Text(
                  t('wrap.pending', {'n': pending}),
                  style: TextStyle(color: cs.tertiary, fontSize: 12),
                ),
              ],
              if (cov.configErrors.isNotEmpty) ...[
                const SizedBox(height: 8),
                for (final e in cov.configErrors)
                  Text(e, style: TextStyle(color: cs.error, fontSize: 12)),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (cov.available <= 0)
          EmptyState(title: t('wrap.noRecords'))
        else
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t('wrap.submit'),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _address,
                  decoration: InputDecoration(
                    labelText: t('wrap.address'),
                    hintText: t('wrap.addressHint'),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _amount,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: '${t('wrap.amount')} ($symbol)',
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      onPressed: _busy ? null : _claim,
                      child: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(t('wrap.submit')),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  t('wrap.claimHint'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: SectionHeading(title: t('wrap.records'))),
            OutlinedButton(
              onPressed: _configDialog,
              child: Text(t('wrap.configure')),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_records.isEmpty)
          EmptyState(title: t('wrap.noRecords'))
        else
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                for (final r in _records)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.link, size: 18),
                    title: Text('◈ ${r.amount} → ${_short(r.toAddress)}'),
                    subtitle: Text(
                      r.txHash.isEmpty
                          ? r.onchainId
                          : '${r.onchainId} · ${_short(r.txHash)}',
                    ),
                    trailing: Text(
                      relTime(
                        state.locale,
                        r.atMs,
                        DateTime.now().millisecondsSinceEpoch,
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  String _short(String s) =>
      s.length <= 14 ? s : '${s.substring(0, 8)}…${s.substring(s.length - 4)}';

  Future<void> _claim() async {
    final state = context.read<AppState>();
    final t = state.t;
    final cov = _coverage;
    if (cov == null) return;
    final amount = int.tryParse(_amount.text.trim()) ?? 0;
    final address = _address.text.trim();
    if (amount <= 0 || amount > cov.available) {
      showError(context, t('wrap.amountTooMuch'));
      return;
    }
    if (!RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(address)) {
      showError(context, t('wrap.addressHint'));
      return;
    }
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    HttpClient? client;
    try {
      final reqView = await buildWrapRequest(
        amount: amount,
        toAddress: address,
      );
      client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
      final uri = Uri.parse(
        '${state.settings.bridgeApiUrl.replaceAll(RegExp(r'/+$'), '')}/claim',
      );
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(
        jsonEncode({
          'peerId': reqView.peerId,
          'amount': reqView.amount,
          'opIds': reqView.opIds,
          'toAddress': reqView.toAddress,
          'nonce': reqView.nonce,
          'hash': reqView.hash,
          'signature': reqView.signature,
        }),
      );
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      Map<String, dynamic> data;
      try {
        data = jsonDecode(text) as Map<String, dynamic>;
      } catch (_) {
        data = {'ok': false, 'error': text};
      }
      if (data['ok'] == true) {
        final tx = (data['txHash'] ?? '').toString();
        final claimId = (data['claimId'] ?? '').toString();
        await recordWrap(
          amount: reqView.amount,
          opIds: reqView.opIds,
          toAddress: reqView.toAddress,
          chainId: state.settings.bridgeChainId,
          txHash: tx,
          onchainId: claimId,
        );
        await state.refresh();
        await _load();
        await widget.onChanged();
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              t('wrap.success', {
                'n': reqView.amount,
                'tx': tx.isEmpty ? claimId : tx,
              }),
            ),
          ),
        );
      } else {
        final reason = (data['error'] ?? res.statusCode).toString();
        final note = (data['note'] ?? '').toString();
        final shortfall = data['shortfall'];
        final detail = [
          reason,
          if (shortfall is num) 'shortfall: $shortfall',
          if (note.isNotEmpty) note,
        ].join(' · ');
        messenger.showSnackBar(
          SnackBar(content: Text(t('wrap.failed', {'reason': detail}))),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text(t('wrap.failed', {'reason': e}))),
        );
      }
    } finally {
      client?.close(force: true);
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _configDialog() async {
    final state = context.read<AppState>();
    final t = state.t;
    final s = state.settings;
    final peer = TextEditingController(text: s.bridgePeerId);
    final api = TextEditingController(text: s.bridgeApiUrl);
    final contract = TextEditingController(text: s.bridgeContract);
    final chain = TextEditingController(text: '${s.bridgeChainId}');
    final symbol = TextEditingController(text: s.bridgeSymbol);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('wrap.configure')),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t('wrap.notConfiguredBody'),
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: peer,
                  decoration: InputDecoration(labelText: t('wrap.peerId')),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: api,
                  decoration: InputDecoration(labelText: t('wrap.apiUrl')),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: contract,
                  decoration: InputDecoration(labelText: t('wrap.contract')),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: chain,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: t('wrap.chainId'),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: symbol,
                        decoration: InputDecoration(
                          labelText: t('wrap.symbol'),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
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
    final values = (
      peer.text.trim(),
      api.text.trim(),
      contract.text.trim(),
      int.tryParse(chain.text.trim()) ?? 1,
      symbol.text.trim(),
    );
    peer.dispose();
    api.dispose();
    contract.dispose();
    chain.dispose();
    symbol.dispose();
    if (ok != true) return;
    await state.setBridgeConfig(
      peerId: values.$1,
      apiUrl: values.$2,
      contract: values.$3,
      chainId: values.$4,
      symbol: values.$5.isEmpty ? 'CALC' : values.$5,
    );
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(t('wrap.saved'))));
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        ),
      ],
    );
  }
}
