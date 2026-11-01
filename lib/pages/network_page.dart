import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../src/rust/api.dart';
import '../src/rust/engine.dart';
import '../state/app_state.dart';
import '../widgets/widgets.dart';

/// 网络页。
///
/// 这一页是**术语唯一出现的地方**：其余页面一律说人话
/// （「同步给其他读者」而不是「广播到 gossipsub」）。
///
/// 它同时负责把「连不上」拆开给人看：节点是否启动、连上几个、
/// 其中几个订阅了本站主题、DHT 找到几个、有没有中继预约 ——
/// 一句「网络不好」太敷衍。
class NetworkPage extends StatefulWidget {
  const NetworkPage({super.key});

  @override
  State<NetworkPage> createState() => _NetworkPageState();
}

class _NetworkPageState extends State<NetworkPage> {
  final _addrCtrl = TextEditingController();
  Timer? _poll;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted) return;
      context.read<AppState>().refreshStats();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _addrCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final s = state.stats;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(t('nav.network')),
        actions: [
          IconButton(
            icon: const Icon(Icons.travel_explore),
            tooltip: t('network.retryDiscovery'),
            onPressed: _busy ? null : _retryDiscovery,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: t('common.retry'),
            onPressed: () => context.read<AppState>().refreshStats(),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 880),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t('network.honest'),
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                _statusCard(context, state, s),
                const SizedBox(height: 16),
                _metrics(context, s),
                const SizedBox(height: 16),
                Panel(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    children: [
                      _row(context, t('identity.peerId'), s.peerId, mono: true),
                      _row(context, t('network.port'), '${s.listenPort}'),
                      _row(
                        context,
                        t('network.source'),
                        _sourceLabel(state, s),
                      ),
                      _row(
                        context,
                        t('network.discovery'),
                        t('network.discoveryValue', {
                          'attempts': s.discoveryAttempts,
                          'found': s.providersFound,
                          'dialed': s.providersDialed,
                        }),
                      ),
                      _row(
                        context,
                        t('network.rejectedSigs'),
                        '${s.rejectedSigs}',
                      ),
                      _row(context, t('network.ops'), '${s.ops}'),
                      _row(context, t('network.novels'), '${s.novels}'),
                      _row(context, t('network.chapters'), '${s.chapters}'),
                      _row(context, t('network.storage'), _bytes(s.oplogBytes)),
                      if (s.pendingGated > 0)
                        _row(
                          context,
                          t('network.pendingGated', {'n': s.pendingGated}),
                          '',
                        ),
                    ],
                  ),
                ),
                if (s.lastNetError.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: cs.errorContainer.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                t('network.lastErrorLabel'),
                                style: TextStyle(
                                  color: cs.onErrorContainer,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 28,
                              height: 28,
                              child: IconButton(
                                padding: EdgeInsets.zero,
                                icon: const Icon(Icons.copy, size: 16),
                                tooltip: t('network.copy'),
                                color: cs.onErrorContainer,
                                onPressed: () => _copy(context, s.lastNetError),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        // libp2p 的拨号错误可能带一长串 multiaddr；
                        // 限高滚动，别让一条诊断把整页推走 —— 报错也要注意占地。
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 110),
                          child: SingleChildScrollView(
                            child: SelectableText(
                              s.lastNetError,
                              style: TextStyle(
                                color: cs.onErrorContainer,
                                fontSize: 12,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(child: SectionHeading(title: t('network.peers'))),
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.travel_explore, size: 18),
                      label: Text(t('network.retryDiscovery')),
                      onPressed: _busy ? null : _retryDiscovery,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (s.netPeers.isEmpty)
                  EmptyState(
                    title: t('common.empty'),
                    body: t('network.noPeers'),
                  )
                else
                  for (final p in s.netPeers) _peerCard(context, p),
                const SizedBox(height: 24),
                SectionHeading(title: t('network.listenAddrs')),
                const SizedBox(height: 12),
                Panel(
                  child: s.listenAddrs.isEmpty
                      ? Text(t('network.noListen'))
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final a in s.listenAddrs)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: SelectableText(
                                        a,
                                        style: const TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 12.5,
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.copy, size: 18),
                                      tooltip: t('network.copy'),
                                      onPressed: () => _copy(context, a),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                ),
                const SizedBox(height: 24),
                SectionHeading(title: t('network.addPeer')),
                const SizedBox(height: 12),
                Text(
                  t('network.manualHint'),
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                LayoutBuilder(
                  builder: (context, box) {
                    final field = TextField(
                      controller: _addrCtrl,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                      ),
                      decoration: InputDecoration(
                        labelText: t('network.addPeer'),
                        hintText: t('network.addrHint'),
                      ),
                    );
                    final dial = FilledButton(
                      onPressed: _busy ? null : _addPeer,
                      child: Text(t('network.dial')),
                    );
                    final sync = OutlinedButton(
                      onPressed: _busy ? null : _syncTyped,
                      child: Text(t('network.sync')),
                    );
                    // 手机宽度下按钮和输入框并排会太挤：输入框独占一行，按钮不用挤地铁。
                    if (box.maxWidth < 480) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          field,
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(child: dial),
                              const SizedBox(width: 8),
                              Expanded(child: sync),
                            ],
                          ),
                        ],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(child: field),
                        const SizedBox(width: 12),
                        dial,
                        const SizedBox(width: 8),
                        sync,
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusCard(BuildContext context, AppState state, NodeStats s) {
    final t = state.t;
    final cs = Theme.of(context).colorScheme;
    final online = s.netState == 'online';
    final warn = s.netState == 'degraded' || s.netState == 'error';
    final color = online ? cs.primary : (warn ? cs.error : cs.onSurfaceVariant);
    return Panel(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            online ? Icons.wifi : (warn ? Icons.wifi_off : Icons.wifi_find),
            color: color,
            size: 30,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      t('network.state.${s.netState}'),
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800, color: color),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  t('network.state.hint.${s.netState}'),
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                t('network.peerCount', {'n': s.netPeers.length}),
                style: Theme.of(context).textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (s.relayReservations > 0)
                Text(
                  t('network.relayReservations', {'n': s.relayReservations}),
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _metrics(BuildContext context, NodeStats s) {
    final t = context.read<AppState>().t;
    final items = <(String, String)>[
      (t('network.metric.peers'), '${s.netPeers.length}'),
      (t('network.metric.dht'), '${s.dhtPeers}'),
      (t('network.metric.in'), '${s.opsIn}'),
      (t('network.metric.out'), '${s.opsOut}'),
    ];
    return LayoutBuilder(
      builder: (context, box) {
        final cols = box.maxWidth >= 640 ? 4 : 2;
        return GridView.count(
          crossAxisCount: cols,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: cols == 4 ? 2.4 : 1.7,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          children: [
            for (final it in items)
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(it.$1, style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: 4),
                      Text(
                        it.$2,
                        style: Theme.of(context).textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _peerCard(BuildContext context, NetPeer p) {
    final t = context.read<AppState>().t;
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: p.direction == 'inbound'
                    ? cs.tertiaryContainer
                    : cs.primaryContainer,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                p.direction == 'inbound'
                    ? t('network.inbound')
                    : t('network.outbound'),
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    p.peerId,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                  if (p.addr.isNotEmpty)
                    SelectableText(
                      p.addr,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  if (p.agent.isNotEmpty)
                    Text(
                      p.agent,
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            if (p.subscribed) ...[
              const SizedBox(width: 8),
              Chip(
                label: Text(
                  t('network.subscribed'),
                  style: const TextStyle(fontSize: 11),
                ),
                visualDensity: VisualDensity.compact,
                side: BorderSide(color: cs.primary.withValues(alpha: 0.4)),
                backgroundColor: cs.primaryContainer.withValues(alpha: 0.5),
              ),
            ],
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.sync, size: 19),
              tooltip: t('network.syncPeer'),
              onPressed: _busy ? null : () => _syncPeer(p),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    String label,
    String value, {
    bool mono = false,
  }) {
    return ListTile(
      dense: true,
      title: Text(label),
      subtitle: value.isEmpty
          ? null
          : SelectableText(
              value,
              style: mono
                  ? const TextStyle(fontFamily: 'monospace', fontSize: 12.5)
                  : null,
            ),
    );
  }

  String _sourceLabel(AppState state, NodeStats s) {
    final t = state.t;
    final base = t('network.source.${s.netSource}');
    if (s.netSource == 'site') {
      return '$base · ${t('network.source.siteDetail', {'n': s.siteNodes})}';
    }
    if (s.siteFetched && s.siteNodes > 0) {
      return '$base · ${t('network.source.siteDetail', {'n': s.siteNodes})}';
    }
    return base;
  }

  Future<void> _retryDiscovery() async {
    final state = context.read<AppState>();
    try {
      await retryDiscovery();
      await state.refreshStats();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(state.t('network.retryQueued'))));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _addPeer() async {
    final raw = _addrCtrl.text.trim();
    if (raw.isEmpty) return;
    final state = context.read<AppState>();
    setState(() => _busy = true);
    try {
      await addPeer(addr: raw);
      await state.refreshStats();
      if (!mounted) return;
      _addrCtrl.clear();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(state.t('network.dialQueued'))));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncTyped() async {
    final raw = _addrCtrl.text.trim();
    if (raw.isEmpty) return;
    await _runSync(raw);
  }

  Future<void> _syncPeer(NetPeer p) async {
    final addr = p.addr.isNotEmpty ? p.addr : '/p2p/${p.peerId}';
    await _runSync(addr);
  }

  Future<void> _runSync(String addr) async {
    final state = context.read<AppState>();
    setState(() => _busy = true);
    try {
      final n = await syncNow(addr: addr);
      await state.refreshStats();
      await state.refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(state.t('network.syncResult', {'n': n}))),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy(BuildContext context, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.read<AppState>().t('network.copied'))),
    );
  }

  String _bytes(int n) {
    final units = ['B', 'KB', 'MB', 'GB'];
    var v = n.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i += 1;
    }
    return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
  }
}
