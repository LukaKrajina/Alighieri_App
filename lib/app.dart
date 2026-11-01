import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'pages/about_page.dart';
import 'pages/browse_page.dart';
import 'pages/carousel_page.dart';
import 'pages/contests_page.dart';
import 'pages/home_page.dart';
import 'pages/identity_page.dart';
import 'pages/licenses_page.dart';
import 'pages/network_page.dart';
import 'pages/post_page.dart';
import 'pages/publishers_page.dart';
import 'pages/ranking_page.dart';
import 'pages/review_page.dart';
import 'pages/settings_page.dart';
import 'pages/shelf_page.dart';
import 'pages/wallet_page.dart';
import 'state/app_state.dart';
import 'state/strings.dart';
import 'theme/app_theme.dart';
import 'widgets/widgets.dart';

class AlighieriApp extends StatelessWidget {
  const AlighieriApp({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final dark = state.settings.themeMode == 'dark';
    return MaterialApp(
      title: 'Alighieri',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(
        state.palette,
        dark: dark,
        fontScale: state.settings.readerFontScale,
        glass: state.settings.glassLevel,
      ),
      locale: Locale(state.locale),
      supportedLocales: const [
        Locale('zh'),
        Locale('en'),
        Locale('ja'),
        Locale('ko'),
        Locale('ru'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const AppShell(),
    );
  }
}

/// 一个导航项。`index >= 0` 表示主页面（底部导航也能到），
/// `route` 表示从侧边栏推入的页面 —— 侧边栏也得有正经工作，不能只当「更多」的垃圾桶。
class _NavItem {
  const _NavItem({
    required this.labelKey,
    required this.icon,
    required this.selectedIcon,
    this.index,
    this.route,
  });

  final String labelKey;
  final IconData icon;
  final IconData selectedIcon;
  final int? index;
  final String? route;
}

class _NavGroup {
  const _NavGroup(this.labelKey, this.items);
  final String labelKey;
  final List<_NavItem> items;
}

const _mainDestinations = [
  (Icons.home_outlined, Icons.home, 'nav.home'),
  (Icons.grid_view_outlined, Icons.grid_view, 'nav.browse'),
  (Icons.bookmark_border, Icons.bookmark, 'nav.shelf'),
  (Icons.edit_note_outlined, Icons.edit_note, 'nav.post'),
  (Icons.diamond_outlined, Icons.diamond, 'nav.wallet'),
];

const _navGroups = [
  _NavGroup('nav.group.discover', [
    _NavItem(
      labelKey: 'nav.home',
      icon: Icons.home_outlined,
      selectedIcon: Icons.home,
      index: 0,
    ),
    _NavItem(
      labelKey: 'nav.browse',
      icon: Icons.grid_view_outlined,
      selectedIcon: Icons.grid_view,
      index: 1,
    ),
    _NavItem(
      labelKey: 'nav.ranking',
      icon: Icons.leaderboard_outlined,
      selectedIcon: Icons.leaderboard,
      route: 'ranking',
    ),
    _NavItem(
      labelKey: 'nav.carousel',
      icon: Icons.campaign_outlined,
      selectedIcon: Icons.campaign,
      route: 'carousel',
    ),
  ]),
  _NavGroup('nav.group.mine', [
    _NavItem(
      labelKey: 'nav.shelf',
      icon: Icons.bookmark_border,
      selectedIcon: Icons.bookmark,
      index: 2,
    ),
    _NavItem(
      labelKey: 'nav.post',
      icon: Icons.edit_note_outlined,
      selectedIcon: Icons.edit_note,
      index: 3,
    ),
    _NavItem(
      labelKey: 'nav.wallet',
      icon: Icons.diamond_outlined,
      selectedIcon: Icons.diamond,
      index: 4,
    ),
    _NavItem(
      labelKey: 'nav.about',
      icon: Icons.info_outline,
      selectedIcon: Icons.info,
      route: 'about',
    ),
  ]),
  _NavGroup('nav.group.community', [
    _NavItem(
      labelKey: 'nav.contests',
      icon: Icons.emoji_events_outlined,
      selectedIcon: Icons.emoji_events,
      route: 'contests',
    ),
    _NavItem(
      labelKey: 'nav.publishers',
      icon: Icons.business_outlined,
      selectedIcon: Icons.business,
      route: 'publishers',
    ),
  ]),
  _NavGroup('nav.group.system', [
    _NavItem(
      labelKey: 'nav.identity',
      icon: Icons.fingerprint,
      selectedIcon: Icons.fingerprint,
      route: 'identity',
    ),
    _NavItem(
      labelKey: 'nav.network',
      icon: Icons.hub_outlined,
      selectedIcon: Icons.hub,
      route: 'network',
    ),
    _NavItem(
      labelKey: 'nav.review',
      icon: Icons.shield_outlined,
      selectedIcon: Icons.shield,
      route: 'review',
    ),
    _NavItem(
      labelKey: 'nav.licenses',
      icon: Icons.gavel_outlined,
      selectedIcon: Icons.gavel,
      route: 'licenses',
    ),
    _NavItem(
      labelKey: 'nav.settings',
      icon: Icons.tune_outlined,
      selectedIcon: Icons.tune,
      route: 'settings',
    ),
  ]),
];

/// 主外壳：宽屏常驻侧边栏，窄屏用左侧抽屉。
///
/// 分类 / 搜索这类筛选态放在页面内部，不进路由 —— 否则每次改一个筛选条件
/// 都要重建一次页面，滚动位置与输入焦点都会丢；用户好不容易滚到的地方，
/// 不该被一个下拉框清空。
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final locale = state.locale;
    final pages = <Widget>[
      const HomePage(),
      const BrowsePage(),
      const ShelfPage(),
      const PostPage(),
      const WalletPage(),
    ];
    final wide = MediaQuery.sizeOf(context).width >= 980;

    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: Text(state.t(_mainDestinations[_index].$3)),
        actions: [
          if (state.error != null)
            IconButton(
              icon: const Icon(Icons.error_outline),
              tooltip: state.error,
              onPressed: () => showError(context, state.error!),
            ),
          IconButton(
            tooltip: state.t('nav.identity'),
            icon: const Icon(Icons.fingerprint),
            onPressed: () => _push('identity'),
          ),
          IconButton(
            tooltip: state.t('nav.settings'),
            icon: const Icon(Icons.tune),
            onPressed: () => _push('settings'),
          ),
          if (!wide)
            IconButton(
              icon: const Icon(Icons.menu),
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            ),
        ],
      ),
      drawer: wide
          ? null
          : _SideNav(locale: locale, index: _index, onSelect: _select),
      body: Row(
        children: [
          if (wide) ...[
            SizedBox(
              width: 248,
              child: _SideNav(
                locale: locale,
                index: _index,
                onSelect: _select,
                permanent: true,
              ),
            ),
            const VerticalDivider(width: 1),
          ],
          Expanded(child: pages[_index]),
        ],
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: _select,
              destinations: [
                for (final d in _mainDestinations)
                  NavigationDestination(
                    icon: Icon(d.$1),
                    selectedIcon: Icon(d.$2),
                    label: state.t(d.$3),
                  ),
              ],
            ),
    );
  }

  void _select(int index) {
    setState(() => _index = index);
    _scaffoldKey.currentState?.closeDrawer();
  }

  void _push(String route) {
    _scaffoldKey.currentState?.closeDrawer();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => switch (route) {
          'ranking' => const RankingPage(),
          'carousel' => const CarouselPage(),
          'about' => const AboutPage(),
          'contests' => const ContestsPage(),
          'publishers' => const PublishersPage(),
          'review' => const ReviewPage(),
          'licenses' => const LicensesPage(),
          'identity' => const IdentityPage(),
          'network' => const NetworkPage(),
          _ => const SettingsPage(),
        },
      ),
    );
  }
}

class _SideNav extends StatelessWidget {
  const _SideNav({
    required this.locale,
    required this.index,
    required this.onSelect,
    this.permanent = false,
  });

  final String locale;
  final int index;
  final ValueChanged<int> onSelect;
  final bool permanent;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final cs = Theme.of(context).colorScheme;
    final peer = state.identity?.peerId ?? '';
    return Drawer(
      shape: permanent ? const RoundedRectangleBorder() : null,
      width: permanent ? 248 : null,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.auto_stories,
                      color: cs.primary,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tr(locale, 'app.name'),
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 17,
                          ),
                        ),
                        Text(
                          peer.isEmpty
                              ? tr(locale, 'app.tagline')
                              : peer.length <= 10
                              ? peer
                              : peer.substring(peer.length - 10),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
                children: [
                  for (final group in _navGroups) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                      child: Text(
                        tr(locale, group.labelKey),
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                    for (final item in group.items)
                      _NavTile(
                        item: item,
                        selected: item.index == index,
                        onTap: () {
                          if (item.index != null) {
                            onSelect(item.index!);
                          } else if (item.route != null) {
                            final shell = context
                                .findAncestorStateOfType<_AppShellState>();
                            shell?._push(item.route!);
                          }
                        },
                      ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
              child: Text(
                'Alighieri by OpenMasons',
                style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final _NavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: selected ? cs.primaryContainer.withValues(alpha: 0.65) : null,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  selected ? item.selectedIcon : item.icon,
                  size: 19,
                  color: selected ? cs.primary : cs.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    state.t(item.labelKey),
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected ? cs.primary : cs.onSurface,
                    ),
                  ),
                ),
                if (item.route == 'network') _NetDot(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NetDot extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final ok = state.stats.netPeers.isNotEmpty;
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        color: ok
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.outlineVariant,
        shape: BoxShape.circle,
      ),
    );
  }
}
