import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../src/rust/api.dart';
import '../state/app_state.dart';
import '../state/strings.dart';
import '../widgets/widgets.dart';

/// 我的身份。
///
/// 没有账号密码：身份是一把 Ed25519 私钥，笔名由它确定性派生。
/// 恢复短语就是这把私钥的十六进制分组 —— 丢了就真的找不回来，没有客服能帮忙。
class IdentityPage extends StatefulWidget {
  const IdentityPage({super.key});

  @override
  State<IdentityPage> createState() => _IdentityPageState();
}

class _IdentityPageState extends State<IdentityPage> {
  final _name = TextEditingController();
  final _bio = TextEditingController();
  final _phrase = TextEditingController();
  final _vaultPass = TextEditingController();
  final List<ProfileLinkInput> _links = [];
  bool _loading = true;
  bool _saving = false;
  bool _vaultBusy = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    for (final c in [_name, _bio, _phrase, _vaultPass]) {
      c.dispose();
    }
    super.dispose();
  }

  /// 引擎返回的口令错误是固定的键，这里换成当前语言，免得用户读一串英文键名。
  String _vaultErr(AppState state, Object e) {
    final s = e.toString();
    if (s.contains('passphrase-wrong')) return state.t('vault.err.wrong');
    if (s.contains('passphrase-too-short')) return state.t('vault.err.tooShort');
    if (s.contains('need-passphrase-first')) {
      return state.t('vault.err.noPassphrase');
    }
    if (s.contains('passphrase-needs-unlock')) {
      return state.t('vault.err.needsUnlock');
    }
    if (s.contains('unsupported-keyvault')) return state.t('vault.err.unsupported');
    return s;
  }

  /* -------- 口令加密：钥匙放在自己手里 -------- */

  Future<void> _vaultUnlock() async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final pass = _vaultPass.text;
    if (pass.isEmpty) return;
    setState(() => _vaultBusy = true);
    try {
      await state.vaultUnlock(pass);
      // 解锁 = 身份回到内存。网络节点也得换用这张新面孔重新握手。
      try {
        await state.reconnectNetwork();
      } catch (e) {
        debugPrint('[identity] 解锁后重连失败：$e');
      }
      await state.refresh();
      if (!mounted) return;
      setState(() {
        _vaultBusy = false;
        _vaultPass.clear();
      });
      await _loadProfile();
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(state.t('vault.unlockDone'))),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _vaultBusy = false);
      messenger.showSnackBar(SnackBar(content: Text(_vaultErr(state, e))));
    }
  }

  Future<void> _vaultSetDialog() async {
    final state = context.read<AppState>();
    final t = state.t;
    final one = TextEditingController();
    final two = TextEditingController();
    var strength = 'weak';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(
            state.vault?.encrypted == true
                ? t('vault.change')
                : t('vault.setPrompt'),
          ),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (state.vault?.encrypted == true) ...[
                  Text(
                    t('vault.changeHint'),
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 10),
                ],
                TextField(
                  controller: one,
                  obscureText: true,
                  autofocus: true,
                  decoration: InputDecoration(labelText: t('vault.passphrase')),
                  onChanged: (v) async {
                    final s = await state.passStrength(v);
                    if (ctx.mounted) setDialog(() => strength = s);
                  },
                ),
                const SizedBox(height: 6),
                Text(
                  t('vault.strength.$strength'),
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: strength == 'strong'
                        ? Theme.of(ctx).colorScheme.primary
                        : Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: two,
                  obscureText: true,
                  decoration: InputDecoration(labelText: t('vault.passphrase2')),
                ),
                const SizedBox(height: 12),
                Text(
                  t('vault.noRecovery'),
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.error,
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
              onPressed: () {
                if (one.text.length < 8) {
                  setDialog(() {});
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(content: Text(t('vault.tooShort'))),
                  );
                  return;
                }
                if (one.text != two.text) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(content: Text(t('vault.mismatch'))),
                  );
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: Text(t('common.confirm')),
            ),
          ],
        ),
      ),
    );
    final pass = one.text;
    one.dispose();
    two.dispose();
    if (ok != true || !mounted) return;
    setState(() => _vaultBusy = true);
    try {
      await state.vaultSetPassphrase(pass);
      if (!mounted) return;
      setState(() => _vaultBusy = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(state.t('vault.done'))));
    } catch (e) {
      if (!mounted) return;
      setState(() => _vaultBusy = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_vaultErr(state, e))));
    }
  }

  Future<void> _vaultLockNow() async {
    final state = context.read<AppState>();
    setState(() => _vaultBusy = true);
    try {
      await state.vaultLock();
      if (!mounted) return;
      setState(() {
        _vaultBusy = false;
        _name.clear();
        _bio.clear();
        _links.clear();
        _loading = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(state.t('vault.lockedNow'))));
    } catch (e) {
      if (!mounted) return;
      setState(() => _vaultBusy = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_vaultErr(state, e))));
    }
  }

  Future<void> _vaultRemoveDialog() async {
    final state = context.read<AppState>();
    final t = state.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('vault.remove')),
        content: Text(t('vault.removeConfirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t('vault.remove')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _vaultBusy = true);
    try {
      await state.vaultRemovePassphrase();
      if (!mounted) return;
      setState(() => _vaultBusy = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(state.t('vault.removedDone'))));
    } catch (e) {
      if (!mounted) return;
      setState(() => _vaultBusy = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_vaultErr(state, e))));
    }
  }

  /// 口令保管面板：上锁 → 解锁入口；已解锁 → 状态与操作。
  Widget _vaultSection(BuildContext context, AppState state) {
    final t = state.t;
    final v = state.vault;
    if (v == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;

    if (v.encrypted && !v.unlocked) {
      return Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.lock_outline, color: cs.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    t('vault.locked'),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(t('vault.lockedHint'), style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            TextField(
              controller: _vaultPass,
              obscureText: true,
              decoration: InputDecoration(labelText: t('vault.passphrase')),
              onSubmitted: (_) => _vaultUnlock(),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _vaultBusy ? null : _vaultUnlock,
                icon: const Icon(Icons.lock_open, size: 18),
                label: Text(t('vault.unlock')),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              t('vault.noRecovery'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.error),
            ),
          ],
        ),
      );
    }

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                v.encrypted ? Icons.lock_outline : Icons.lock_open_outlined,
                color: cs.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  t('vault.title'),
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            v.encrypted ? t('vault.current') : t('vault.currentPlain'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: v.encrypted ? cs.primary : cs.onSurfaceVariant,
              fontWeight: v.encrypted ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
          const SizedBox(height: 8),
          Text(t('vault.hint'), style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
          Text(t('vault.why'), style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
          Text(
            t('vault.noRecovery'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.error),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _vaultBusy ? null : _vaultSetDialog,
                icon: const Icon(Icons.password, size: 18),
                label: Text(
                  v.encrypted ? t('vault.change') : t('vault.set'),
                ),
              ),
              if (v.encrypted)
                OutlinedButton.icon(
                  onPressed: _vaultBusy ? null : _vaultLockNow,
                  icon: const Icon(Icons.lock, size: 18),
                  label: Text(t('vault.lock')),
                ),
              if (v.encrypted)
                TextButton.icon(
                  onPressed: _vaultBusy ? null : _vaultRemoveDialog,
                  icon: const Icon(Icons.lock_open, size: 18),
                  label: Text(t('vault.remove')),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _loadProfile() async {
    final state = context.read<AppState>();
    try {
      final p = await state.myProfile();
      if (!mounted) return;
      setState(() {
        _name.text = p.derivedName ? '' : p.name;
        _bio.text = p.bio;
        _links
          ..clear()
          ..addAll([
            for (var i = 0; i < p.linkUrl.length; i++)
              ProfileLinkInput(
                platform: i < p.linkPlatform.length ? p.linkPlatform[i] : 'other',
                url: p.linkUrl[i],
                label: i < p.linkLabel.length && p.linkLabel[i].isNotEmpty
                    ? p.linkLabel[i]
                    : null,
              ),
          ]);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      debugPrint('[identity] 读取资料失败：$e');
    }
  }

  Future<void> _saveProfile() async {
    final state = context.read<AppState>();
    final t = state.t;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      await updateProfile(name: _name.text.trim(), bio: _bio.text.trim());
      await _saveLinks(silent: true);
      await state.refresh();
      if (!mounted) return;
      state.identity = await identityApi();
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(content: Text(t('post.saved'))));
      await _loadProfile();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(
        SnackBar(content: Text('${tr('zh', 'error.prefix')}$e')),
      );
    }
  }

  Future<void> _saveLinks({bool silent = false}) async {
    final state = context.read<AppState>();
    final t = state.t;
    await setProfileLinks(
      links: [
        for (final l in _links)
          ProfileLinkInput(platform: l.platform, url: l.url, label: l.label),
      ],
    );
    if (!silent && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t('identity.linksSaved'))));
    }
  }

  Future<void> _copy(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$label · ${tr('zh', 'identity.copied')}')));
  }

  Future<void> _addLink() async {
    final state = context.read<AppState>();
    final t = state.t;
    final url = TextEditingController();
    final label = TextEditingController();
    var platform = 'website';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(t('identity.addLink')),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: platform,
                  decoration: InputDecoration(
                    labelText: t('identity.linkPlatform'),
                  ),
                  items: [
                    for (final p in const [
                      'website',
                      'x',
                      'bilibili',
                      'weibo',
                      'github',
                      'youtube',
                      'tiktok',
                      'discord',
                      'email',
                      'other',
                    ])
                      DropdownMenuItem(value: p, child: Text(p)),
                  ],
                  onChanged: (v) =>
                      setDialog(() => platform = v ?? 'website'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: url,
                  decoration: InputDecoration(
                    labelText: t('identity.linkUrl'),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: label,
                  decoration: InputDecoration(
                    labelText:
                        '${t('identity.linkLabel')} (${t('common.optional')})',
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
              child: Text(t('common.save')),
            ),
          ],
        ),
      ),
    );
    final u = url.text.trim();
    final l = label.text.trim();
    url.dispose();
    label.dispose();
    if (ok != true || u.isEmpty) return;
    setState(() {
      _links.add(
        ProfileLinkInput(platform: platform, url: u, label: l.isEmpty ? null : l),
      );
    });
    try {
      await _saveLinks();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _removeLink(int index) async {
    setState(() => _links.removeAt(index));
    try {
      await _saveLinks();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _import() async {
    final state = context.read<AppState>();
    final t = state.t;
    if (_phrase.text.trim().isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('identity.import')),
        content: Text(t('identity.importWarn')),
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
      await importIdentity(recoveryPhrase: _phrase.text.trim());
      if (!mounted) return;
      await state.refresh();
      if (!mounted) return;
      state.identity = await identityApi();
      // 身份换了，网络节点也要重新握手 —— 旧连接不认新身份。
      try {
        await state.reconnectNetwork();
      } catch (e) {
        debugPrint('[identity] 重连失败：$e');
      }
      if (!mounted) return;
      setState(() => _phrase.clear());
      await _loadProfile();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t('identity.imported'))));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = state.t;
    final id = state.identity;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(t('nav.identity'))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t('identity.noServer')),
                const SizedBox(height: 16),
                if (!_loading || state.vault != null)
                  _vaultSection(context, state),
                if (!_loading || state.vault != null) const SizedBox(height: 20),
                if (id != null) ...[
                  Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                t('identity.peerId'),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                            IconButton(
                              tooltip: t('identity.copy'),
                              icon: const Icon(Icons.copy, size: 18),
                              onPressed: () =>
                                  _copy(id.peerId, t('identity.peerId')),
                            ),
                          ],
                        ),
                        SelectableText(
                          id.peerId,
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          t('identity.penName'),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          id.penName,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          t('identity.derived'),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: SectionHeading(title: t('identity.phrase')),
                      ),
                      IconButton(
                        tooltip: t('identity.copy'),
                        icon: const Icon(Icons.copy, size: 18),
                        onPressed: () =>
                            _copy(id.recoveryPhrase, t('identity.phrase')),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    id.recoveryPhrase,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    t('identity.phraseWarn'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.error,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                SectionHeading(title: t('identity.editProfile')),
                const SizedBox(height: 12),
                TextField(
                  controller: _name,
                  decoration: InputDecoration(
                    labelText: t('identity.penName'),
                    hintText: id?.penName,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _bio,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText:
                        '${t('publishers.about')} (${t('common.optional')})',
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  t('identity.renameCooldown'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _saveProfile,
                    icon: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined, size: 18),
                    label: Text(t('common.save')),
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: SectionHeading(title: t('identity.links')),
                    ),
                    TextButton.icon(
                      onPressed: _addLink,
                      icon: const Icon(Icons.add, size: 18),
                      label: Text(t('identity.addLink')),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_loading)
                  const LinearProgressIndicator()
                else if (_links.isEmpty)
                  Panel(child: Text(t('identity.noLinks')))
                else
                  Panel(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      children: [
                        for (var i = 0; i < _links.length; i++)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.link, size: 18),
                            title: Text(
                              _links[i].label?.isNotEmpty == true
                                  ? _links[i].label!
                                  : _links[i].url,
                            ),
                            subtitle: Text(
                              '${_links[i].platform} · ${_links[i].url}',
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () => _removeLink(i),
                            ),
                          ),
                      ],
                    ),
                  ),
                const Divider(height: 40),
                SectionHeading(title: t('identity.import')),
                const SizedBox(height: 8),
                Text(
                  t('identity.importHint'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _phrase,
                  maxLines: 3,
                  decoration: InputDecoration(labelText: t('identity.phrase')),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _import,
                  icon: const Icon(Icons.login),
                  label: Text(t('identity.import')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
