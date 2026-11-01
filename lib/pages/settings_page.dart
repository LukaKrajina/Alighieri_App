import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../src/rust/api.dart';
import '../src/rust/store.dart';
import '../state/app_state.dart';
import '../state/strings.dart';
import '../widgets/widgets.dart';

/// 设置。
///
/// 品牌色是「色相 + 饱和度」两个滑杆：整套设计令牌由它推导，
/// 所以调一个色，所有强调色与边框会一起协调 —— 牵一发而动全身，这次是好事。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  /// 预设色。名字走字典（`set.preset.*`），与 Web 版一致。
  static const _presets = [
    ('set.preset.moss', 152, 64),
    ('set.preset.sea', 205, 72),
    ('set.preset.dusk', 272, 58),
    ('set.preset.sakura', 338, 66),
    ('set.preset.amber', 36, 78),
    ('set.preset.vermilion', 8, 70),
    ('set.preset.frost', 188, 62),
    ('set.preset.ink', 220, 12),
  ];

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final s = state.settings;

    return Scaffold(
      appBar: AppBar(title: Text(t('nav.settings'))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SectionHeading(title: t('settings.appearance')),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(
                      value: 'light',
                      label: Text(t('settings.mode.light')),
                    ),
                    ButtonSegment(
                      value: 'dark',
                      label: Text(t('settings.mode.dark')),
                    ),
                  ],
                  selected: {s.themeMode},
                  onSelectionChanged: (v) =>
                      context.read<AppState>().setThemeMode(v.first),
                ),
                const SizedBox(height: 20),
                Text('${t('settings.brand')}  H${s.hue} S${s.sat}'),
                Slider(
                  value: s.hue.toDouble(),
                  min: 0,
                  max: 359,
                  divisions: 359,
                  label: '${s.hue}°',
                  onChanged: (v) =>
                      context.read<AppState>().setBrand(v.round(), s.sat),
                ),
                Slider(
                  value: s.sat.toDouble(),
                  min: 0,
                  max: 100,
                  divisions: 100,
                  label: '${s.sat}%',
                  onChanged: (v) =>
                      context.read<AppState>().setBrand(s.hue, v.round()),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final p in _presets)
                      ActionChip(
                        label: Text(tr(state.locale, p.$1)),
                        avatar: CircleAvatar(
                          backgroundColor: HSLColor.fromAHSL(
                            1,
                            p.$2.toDouble(),
                            p.$3 / 100,
                            0.45,
                          ).toColor(),
                          radius: 8,
                        ),
                        onPressed: () =>
                            context.read<AppState>().setBrand(p.$2, p.$3),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(t('settings.glass')),
                Slider(
                  value: s.glassLevel,
                  min: 0,
                  max: 1,
                  divisions: 20,
                  label: s.glassLevel.toStringAsFixed(2),
                  onChanged: (v) => context.read<AppState>().setGlass(v),
                ),
                Text(
                  t('settings.glassHint'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const Divider(height: 36),
                SectionHeading(title: t('settings.locale')),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final l in kLocales)
                      FilterChip(
                        label: Text(kLocaleNames[l] ?? l),
                        selected: state.locale == l,
                        onSelected: (_) =>
                            context.read<AppState>().setLocale(l),
                      ),
                  ],
                ),
                const Divider(height: 36),
                SectionHeading(title: t('settings.reader')),
                const SizedBox(height: 12),
                Slider(
                  value: s.readerFontScale,
                  min: 0.85,
                  max: 1.6,
                  divisions: 15,
                  label: s.readerFontScale.toStringAsFixed(2),
                  onChanged: (v) => context.read<AppState>().setFontScale(v),
                ),
                const SizedBox(height: 8),
                Text(t('settings.readerTheme')),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final k in const [
                      ('white', 'reader.theme.white'),
                      ('paper', 'reader.theme.paper'),
                      ('dark', 'reader.theme.dark'),
                    ])
                      ChoiceChip(
                        label: Text(t(k.$2)),
                        selected: s.readerTheme == k.$1,
                        onSelected: (_) => context
                            .read<AppState>()
                            .setReaderLook(theme: k.$1),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  '${t('settings.lineHeight')}  ${s.readerLineHeight.toStringAsFixed(2)}',
                ),
                Slider(
                  value: s.readerLineHeight.clamp(1.2, 2.6),
                  min: 1.2,
                  max: 2.6,
                  divisions: 28,
                  onChanged: (v) => context
                      .read<AppState>()
                      .setReaderLook(lineHeight: v),
                ),
                const SizedBox(height: 8),
                Text(t('settings.pageMode')),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(
                      value: 'scroll',
                      label: Text(t('settings.pageMode.scroll')),
                    ),
                    ButtonSegment(
                      value: 'page',
                      label: Text(t('settings.pageMode.page')),
                    ),
                  ],
                  selected: {s.readerPageMode},
                  onSelectionChanged: (v) => context
                      .read<AppState>()
                      .setReaderLook(pageMode: v.first),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(t('settings.autoNext')),
                  value: s.readerAutoNext,
                  onChanged: (v) => context
                      .read<AppState>()
                      .setReaderLook(autoNext: v),
                ),
                const Divider(height: 36),
                SectionHeading(title: t('settings.moderation')),
                const SizedBox(height: 12),
                Text(
                  '${t('settings.reviewThreshold')}: ${s.reviewThreshold}',
                ),
                Slider(
                  value: s.reviewThreshold.clamp(1, 10).toDouble(),
                  min: 1,
                  max: 10,
                  divisions: 9,
                  label: '${s.reviewThreshold}',
                  onChanged: (v) =>
                      context.read<AppState>().setThreshold(v.round()),
                ),
                Text(
                  t('settings.reviewThresholdHint'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(t('settings.autoMerge')),
                  subtitle: Text(t('settings.autoMergeHint')),
                  value: s.autoMerge,
                  onChanged: (v) => context.read<AppState>().setAutoMerge(v),
                ),
                const Divider(height: 36),
                SectionHeading(title: t('settings.network')),
                const SizedBox(height: 12),
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _netRow(
                        context,
                        t('settings.siteUrl'),
                        s.siteUrl.isEmpty
                            ? t('settings.siteUrlNone')
                            : s.siteUrl,
                      ),
                      _netRow(
                        context,
                        t('settings.bootstrap'),
                        s.bootstrap.isEmpty
                            ? t('settings.usingDefault')
                            : t('settings.nodeCount', {
                                'n': s.bootstrap.length,
                              }),
                      ),
                      _netRow(
                        context,
                        t('settings.relays'),
                        s.relays.isEmpty
                            ? t('settings.usingDefault')
                            : t('settings.nodeCount', {'n': s.relays.length}),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        t('settings.networkHint'),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            icon: const Icon(Icons.edit_outlined),
                            label: Text(t('settings.editNetwork')),
                            onPressed: () => _editNetwork(context, state, s),
                          ),
                          FilledButton.tonalIcon(
                            icon: const Icon(Icons.sync),
                            label: Text(t('settings.reconnect')),
                            onPressed: () async {
                              try {
                                final port = await state.reconnectNetwork();
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      t('settings.reconnected', {'port': port}),
                                    ),
                                  ),
                                );
                              } catch (e) {
                                if (context.mounted) showError(context, e);
                              }
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Divider(height: 36),
                SectionHeading(title: t('settings.data')),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.delete_forever_outlined),
                  label: Text(t('settings.wipe')),
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text(t('settings.wipe')),
                        content: Text(t('settings.wipeConfirm')),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: Text(t('common.cancel')),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: Text(t('common.confirm')),
                          ),
                        ],
                      ),
                    );
                    if (ok != true) return;
                    try {
                      await wipeAll();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已清空本机数据，请重启应用')),
                        );
                      }
                    } catch (e) {
                      if (context.mounted) showError(context, e);
                    }
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

  Widget _netRow(BuildContext context, String label, String value) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(label, style: TextStyle(color: cs.onSurfaceVariant)),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editNetwork(
    BuildContext context,
    AppState state,
    Settings s,
  ) async {
    final t = state.t;
    final site = TextEditingController(text: s.siteUrl);
    final bootstrap = TextEditingController(text: s.bootstrap.join('\n'));
    final relays = TextEditingController(text: s.relays.join('\n'));

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('settings.editNetwork')),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: site,
                  decoration: InputDecoration(
                    labelText: t('settings.siteUrl'),
                    hintText: 'https://example.org',
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: bootstrap,
                  minLines: 3,
                  maxLines: 6,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12.5,
                  ),
                  decoration: InputDecoration(
                    labelText: t('settings.bootstrap'),
                    hintText: '/ip4/1.2.3.4/tcp/7788/p2p/12D3…',
                    helperText: t('settings.onePerLine'),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: relays,
                  minLines: 2,
                  maxLines: 5,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12.5,
                  ),
                  decoration: InputDecoration(
                    labelText: t('settings.relays'),
                    hintText: '/dnsaddr/relay.example.org/p2p/12D3…',
                    helperText: t('settings.onePerLine'),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  t('settings.networkHint'),
                  style: Theme.of(ctx).textTheme.bodySmall,
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

    if (ok != true) {
      site.dispose();
      bootstrap.dispose();
      relays.dispose();
      return;
    }
    try {
      await state.setNetworkConfig(
        siteUrl: site.text.trim(),
        bootstrap: _lines(bootstrap.text),
        relays: _lines(relays.text),
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t('settings.networkSaved'))));
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    } finally {
      site.dispose();
      bootstrap.dispose();
      relays.dispose();
    }
  }

  List<String> _lines(String raw) => raw
      .split(RegExp(r'[\n,]'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
}
