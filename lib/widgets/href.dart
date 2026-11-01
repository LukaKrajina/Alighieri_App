import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../pages/author_page.dart';
import '../pages/browse_page.dart';
import '../pages/carousel_page.dart';
import '../pages/contest_detail_page.dart';
import '../pages/contests_page.dart';
import '../pages/identity_page.dart';
import '../pages/licenses_page.dart';
import '../pages/network_page.dart';
import '../pages/novel_page.dart';
import '../pages/post_page.dart';
import '../pages/publisher_detail_page.dart';
import '../pages/publishers_page.dart';
import '../pages/ranking_page.dart';
import '../pages/reader_page.dart';
import '../pages/review_page.dart';
import '../pages/settings_page.dart';
import '../pages/shelf_page.dart';
import '../pages/about_page.dart';
import '../pages/wallet_page.dart';
import '../state/strings.dart';
import 'widgets.dart';

/// 打开一条站内路径或站外链接。
///
/// 轮播位的 `href` 在 Rust 侧已经校验过（只允许单个 `/` 开头的站内路径，
/// 或 `https://` 链接）。这里只负责把已知路径翻译成 Flutter 页面：
/// 认不出的站内路径不猜，直接提示 —— 乱跳首页只会让人以为自己点错了。
Future<void> openCarouselHref(BuildContext context, String href) async {
  final raw = href.trim();
  if (raw.isEmpty) return;

  if (raw.startsWith('https://')) {
    final ok = await launchUrl(
      Uri.parse(raw),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && context.mounted) showError(context, raw);
    return;
  }

  if (!raw.startsWith('/') || raw.startsWith('//') || raw.contains('\\')) {
    return;
  }

  final uri = Uri.tryParse(raw);
  if (uri == null) return;
  final id = uri.queryParameters['id'] ?? '';
  final chapter = int.tryParse(uri.queryParameters['chapter'] ?? '');

  Widget? page;
  switch (uri.path) {
    case '/novel':
      if (id.isNotEmpty) {
        page = chapter != null && chapter > 0
            ? ReaderPage(novelId: id, chapterNo: chapter)
            : NovelPage(novelId: id);
      }
    case '/author':
      if (id.isNotEmpty) page = AuthorPage(peer: id);
    case '/publisher':
      if (id.isNotEmpty) page = PublisherDetailPage(publisherId: id);
    case '/contest':
      if (id.isNotEmpty) page = ContestDetailPage(contestId: id);
    case '/carousel':
      page = const CarouselPage();
    case '/contests':
      page = const ContestsPage();
    case '/publishers':
      page = const PublishersPage();
    case '/ranking':
      page = const RankingPage();
    case '/browse':
      page = const _ShellPage(titleKey: 'nav.browse', child: BrowsePage());
    case '/shelf':
      page = const _ShellPage(titleKey: 'nav.shelf', child: ShelfPage());
    case '/post':
      page = const _ShellPage(titleKey: 'nav.post', child: PostPage());
    case '/wallet':
      page = const _ShellPage(titleKey: 'nav.wallet', child: WalletPage());
    case '/about':
      page = const AboutPage();
    case '/review':
      page = const ReviewPage();
    case '/licenses':
      page = const LicensesPage();
    case '/identity':
      page = const IdentityPage();
    case '/network':
      page = const NetworkPage();
    case '/settings':
      page = const SettingsPage();
  }

  if (page == null) {
    if (context.mounted) showError(context, raw);
    return;
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page!));
}

/// 主页面（底部导航里的那几个）没有自己的 Scaffold，单独推入时补一个。
class _ShellPage extends StatelessWidget {
  const _ShellPage({required this.titleKey, required this.child});

  final String titleKey;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).languageCode;
    return Scaffold(
      appBar: AppBar(title: Text(tr(locale, titleKey))),
      body: child,
    );
  }
}
