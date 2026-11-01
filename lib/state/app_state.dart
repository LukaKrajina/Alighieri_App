import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../local/local_library.dart';
import '../src/rust/api.dart';
import '../src/rust/domain/theme.dart';
import '../src/rust/domain/view.dart';
import '../src/rust/engine.dart';
import '../src/rust/store.dart';
import 'strings.dart';

/// 应用状态
/// --------
/// 界面不直接调 Rust：所有跨 FFI 的调用都收在这里，
/// 这样「改完要刷新哪些列表」只需记一处 —— 记忆这东西，越省越好。
class AppState extends ChangeNotifier {
  AppState() {
    // 本地书库是独立服务，但界面统一监听 AppState；
    // 把它的变更转发出去，书架页也少一层 Provider，少一笔「谁通知谁」的糊涂账。
    localLibrary.addListener(notifyListeners);
  }

  bool ready = false;
  String? error;

  String locale = 'zh';
  Settings settings = Settings(
    locale: 'zh',
    themeMode: 'light',
    hue: 152,
    sat: 64,
    glassLevel: 0.55,
    readerFontScale: 1.0,
    readerTheme: 'paper',
    readerLineHeight: 1.9,
    readerPageMode: 'scroll',
    readerAutoNext: true,
    reviewThreshold: 3,
    reviewTrustOnly: false,
    autoMerge: false,
    exempt: [],
    bootstrap: [],
    siteUrl: '',
    relays: [],
    bridgePeerId: '',
    bridgeApiUrl: '',
    bridgeContract: '',
    bridgeChainId: 1,
    bridgeSymbol: 'CALC',
    sponsorAlipay: '',
    sponsorWechat: '',
    sponsorUsdt: '',
    sponsorEth: '',
    sponsorNote: '',
  );
  Palette palette = Palette(
    background: '#ffffff',
    foreground: '#16241d',
    surface: '#f5faf7',
    surface2: '#eaf3ed',
    surface3: '#e0ebe4',
    border: '#dfeae3',
    borderStrong: '#bfd3c7',
    muted: '#6b8074',
    mutedStrong: '#3f5349',
    primary: '#229b62',
    primaryHover: '#1b8553',
    primaryStrong: '#156b43',
    primarySoft: '#e6f6ed',
    primarySoft2: '#cdefdd',
    primaryRing: '#229b6259',
    accent: '#f0a020',
    accentSoft: '#fdf3e2',
    danger: '#d94b4b',
    info: '#3b82c4',
    headerBg: '#ffffffdb',
    glassTint: '#dff1e7',
    glassEdge: '#9fc7b1',
    glassSpec: '#fffffff2',
  );

  IdentityInfo? identity;
  VaultStatus? vault;
  List<TrustEntryView> trustScores = [];
  AttestationStats? attestStats;
  NodeStats stats = NodeStats(
    peerId: '',
    ops: 0,
    novels: 0,
    chapters: 0,
    pendingGated: 0,
    oplogBytes: 0,
    listenPort: 0,
    peers: [],
    revision: 0,
    netState: 'local',
    netPeers: [],
    dhtPeers: 0,
    relayReservations: 0,
    listenAddrs: [],
    discoveryAttempts: 0,
    providersFound: 0,
    providersDialed: 0,
    lastNetError: '',
    netSource: 'builtin',
    siteFetched: false,
    siteNodes: 0,
    opsIn: 0,
    opsOut: 0,
    rejectedSigs: 0,
  );
  WalletSummary? walletSummary;
  CarouselStateView? carousel;

  List<NovelCard> latest = [];
  List<NovelCard> ranked = [];
  List<NovelCard> shelf = [];
  List<Genre> genres = [];
  List<ContestCard> contests = [];
  List<PublisherCard> publishers = [];
  List<ReportCard> reports = [];
  List<LicenseView> licenses = [];
  List<ContestKindView> contestKinds = [];
  List<RewardRuleView> rewardRules = [];

  /// 本地书库（TXT / EPUB / Markdown / HTML）。与 P2P 书架完全独立。
  final LocalLibrary localLibrary = LocalLibrary();

  String rankingPeriod = 'weekly';

  Timer? _pumpTimer;

  String t(String key, [Map<String, Object>? params]) =>
      tr(locale, key, params);

  /* ------------------------- 初始化：先摸清家底 ------------------------- */

  Future<void> init() async {
    try {
      final dir = await defaultDataDir();
      final report = await initApp(dataDir: dir);
      settings = await settings_();
      locale = settings.locale;
      palette = await palette_();
      identity = null;
      // 身份可能处于口令加密且未解锁：此时读不到身份是**预期**，不是事故
      // —— identity 页会据 vault 状态显示解锁入口。
      try {
        identity = await identityApi();
      } catch (_) {
        identity = null;
      }
      vault = await vaultStatus_();
      genres = await genres_();
      licenses = await licenses_();
      contestKinds = await contestKinds_();
      rewardRules = await rewardRules_();

      // 语言是唯一一个「从 Rust 读取」的设置：它与笔名一样属于本机偏好，
      // 放在 Rust 里是为了让三端共用一份默认值，而不是各翻译各的。
      final errs = await selfCheck();
      if (errs.isNotEmpty) {
        error = errs.join('\n');
      }

      try {
        await localLibrary.load();
      } catch (e) {
        debugPrint('[alighieri] 本地书库载入失败：$e');
      }

      await refresh();

      // 启动同步：端口 0 让系统分配，失败也不阻塞界面。
      // 引导 / 中继 / 站点清单都由 Rust 侧从 settings 读取。
      try {
        await startNetwork(port: 0, peers: const []);
      } catch (e) {
        debugPrint('[alighieri] 启动同步失败：$e');
      }

      _pumpTimer = Timer.periodic(const Duration(seconds: 3), (_) => pump());
      ready = true;
      if (report.opsLoaded > 0) {
        debugPrint('[alighieri] 已载入 ${report.opsLoaded} 条操作');
      }
      notifyListeners();
    } catch (e) {
      error = e.toString();
      ready = true;
      notifyListeners();
    }
  }

  static Future<String> defaultDataDir() async {
    // 三个平台各自的应用数据目录，Linux 下通常在 ~/.local/share/alighieri。
    // 找不到时退回一个相对目录 —— 起不来比路径不漂亮更糟。
    try {
      final base = await getApplicationSupportDirectory();
      return '${base.path}/alighieri';
    } catch (_) {
      return 'alighieri-data';
    }
  }

  /// 重新读取所有列表。任何写操作之后都要调一次。
  Future<void> refresh() async {
    latest = await listNovels(
      q: '',
      genre: '',
      status: '',
      tag: '',
      sort: 'update',
    );
    ranked = await ranking(period: rankingPeriod, genre: '');
    shelf = await shelfNovels();
    contests = await contests_();
    publishers = await publishers_();
    reports = await reports_();
    stats = await stats_();
    walletSummary = await wallet_();
    carousel = await carouselState_();
    vault = await vaultStatus_();
    trustScores = await myTrustScores();
    attestStats = await attestationStats();
    notifyListeners();
  }

  /// 轮播位的「现在还在不在展示」依赖当前时间，所以首页/购买页会定时重算。
  /// 只有派生结果真的变了才通知界面 —— 整页重建很贵，别拿来当心跳。
  Future<void> refreshCarousel({bool notify = true}) async {
    final next = await carouselState_();
    final before = _carouselSignature(carousel);
    carousel = next;
    if (notify && before != _carouselSignature(next)) notifyListeners();
  }

  String _carouselSignature(CarouselStateView? c) {
    if (c == null) return '';
    return [
      c.balance,
      c.blockReason,
      c.cooldownMs,
      c.spent,
      for (final x in c.active) '${x.id}:${x.startedAtMs}:${x.expiresAtMs}',
      for (final x in c.mine) '${x.id}:${x.expiresAtMs}',
    ].join('|');
  }

  Future<List<NovelCard>> shelfNovels() async {
    final all = await listNovels(
      q: '',
      genre: '',
      status: '',
      tag: '',
      sort: 'update',
    );
    return all.where((n) => n.inShelf).toList();
  }

  /// 自己的作品（按作者身份过滤，而不是按「本机有没有密码」）。
  Future<List<NovelCard>> myNovels() async {
    final peer = identity?.peerId ?? '';
    if (peer.isEmpty) return const [];
    final all = await listNovels(
      q: '',
      genre: '',
      status: '',
      tag: '',
      sort: 'update',
    );
    return all.where((n) => n.authorPeer == peer && !n.deleted).toList();
  }

  Future<NovelCard?> novelById(String id) => getNovel(novelId: id);

  Future<ProfileCard> myProfile() async {
    final peer = identity?.peerId ?? '';
    if (peer.isEmpty) {
      throw StateError('尚未创建身份');
    }
    return profile(peer: peer);
  }

  Future<void> pump() async {
    final got = await pump_();
    await refreshStats();
    if (got > 0) {
      debugPrint('[alighieri] 收到 $got 条操作');
      await refresh();
    }
  }

  Future<void> refreshStats() async {
    final next = await stats_();
    if (next != stats) {
      stats = next;
      notifyListeners();
    }
  }

  /// 手动重启 P2P 节点（改完站点地址 / 中继后不必退出应用）。
  Future<int> reconnectNetwork() async {
    final port = await startNetwork(port: 0, peers: const []);
    await refreshStats();
    notifyListeners();
    return port;
  }

  /* ------------------------- 设置 ------------------------- */

  Future<void> applySettings(Settings next) async {
    settings = next;
    locale = next.locale;
    await updateSettings(next: next);
    palette = await palette_();
    notifyListeners();
  }

  /// 以当前设置为底稿派生一份新设置，避免每加一个字段就漏改一处。
  Settings _derive({
    String? locale,
    String? themeMode,
    int? hue,
    int? sat,
    double? glassLevel,
    double? readerFontScale,
    String? readerTheme,
    double? readerLineHeight,
    String? readerPageMode,
    bool? readerAutoNext,
    int? reviewThreshold,
    bool? reviewTrustOnly,
    bool? autoMerge,
    List<String>? exempt,
    List<String>? bootstrap,
    String? siteUrl,
    List<String>? relays,
    String? bridgePeerId,
    String? bridgeApiUrl,
    String? bridgeContract,
    int? bridgeChainId,
    String? bridgeSymbol,
    String? sponsorAlipay,
    String? sponsorWechat,
    String? sponsorUsdt,
    String? sponsorEth,
    String? sponsorNote,
  }) {
    return Settings(
      locale: locale ?? settings.locale,
      themeMode: themeMode ?? settings.themeMode,
      hue: hue ?? settings.hue,
      sat: sat ?? settings.sat,
      glassLevel: glassLevel ?? settings.glassLevel,
      readerFontScale: readerFontScale ?? settings.readerFontScale,
      readerTheme: readerTheme ?? settings.readerTheme,
      readerLineHeight: readerLineHeight ?? settings.readerLineHeight,
      readerPageMode: readerPageMode ?? settings.readerPageMode,
      readerAutoNext: readerAutoNext ?? settings.readerAutoNext,
      reviewThreshold: reviewThreshold ?? settings.reviewThreshold,
      reviewTrustOnly: reviewTrustOnly ?? settings.reviewTrustOnly,
      autoMerge: autoMerge ?? settings.autoMerge,
      exempt: exempt ?? settings.exempt,
      bootstrap: bootstrap ?? settings.bootstrap,
      siteUrl: siteUrl ?? settings.siteUrl,
      relays: relays ?? settings.relays,
      bridgePeerId: bridgePeerId ?? settings.bridgePeerId,
      bridgeApiUrl: bridgeApiUrl ?? settings.bridgeApiUrl,
      bridgeContract: bridgeContract ?? settings.bridgeContract,
      bridgeChainId: bridgeChainId ?? settings.bridgeChainId,
      bridgeSymbol: bridgeSymbol ?? settings.bridgeSymbol,
      sponsorAlipay: sponsorAlipay ?? settings.sponsorAlipay,
      sponsorWechat: sponsorWechat ?? settings.sponsorWechat,
      sponsorUsdt: sponsorUsdt ?? settings.sponsorUsdt,
      sponsorEth: sponsorEth ?? settings.sponsorEth,
      sponsorNote: sponsorNote ?? settings.sponsorNote,
    );
  }

  Future<void> setLocale(String next) async {
    await applySettings(_derive(locale: next));
    // 笔名跟随界面语言派生：切换语言后刷新身份与列表，让当前页立刻换名。
    try {
      identity = await identityApi();
    } catch (_) {
      identity = null;
    }
    await refresh();
  }

  Future<void> setThemeMode(String mode) =>
      applySettings(_derive(themeMode: mode));

  Future<void> setBrand(int hue, int sat) =>
      applySettings(_derive(hue: hue, sat: sat));

  Future<void> setGlass(double level) =>
      applySettings(_derive(glassLevel: level));

  Future<void> setFontScale(double scale) =>
      applySettings(_derive(readerFontScale: scale));

  Future<void> setReaderLook({
    String? theme,
    double? lineHeight,
    String? pageMode,
    bool? autoNext,
  }) => applySettings(
    _derive(
      readerTheme: theme,
      readerLineHeight: lineHeight,
      readerPageMode: pageMode,
      readerAutoNext: autoNext,
    ),
  );

  Future<void> setThreshold(int threshold) =>
      applySettings(_derive(reviewThreshold: threshold));

  Future<void> setTrustOnly(bool enabled) =>
      applySettings(_derive(reviewTrustOnly: enabled));

  Future<void> setAutoMerge(bool enabled) =>
      applySettings(_derive(autoMerge: enabled));

  /// 站点清单 / 引导 / 中继。写完后需要重连网络才会生效。
  Future<void> setNetworkConfig({
    required String siteUrl,
    required List<String> bootstrap,
    required List<String> relays,
  }) => applySettings(
    _derive(siteUrl: siteUrl.trim(), bootstrap: bootstrap, relays: relays),
  );

  /// 桥接与赞助配置只落本机设置，不发 op —— 它们是「这台设备怎么用」，
  /// 不是作品或身份的一部分。
  Future<void> setBridgeConfig({
    required String peerId,
    required String apiUrl,
    required String contract,
    required int chainId,
    required String symbol,
  }) => applySettings(
    _derive(
      bridgePeerId: peerId.trim(),
      bridgeApiUrl: apiUrl.trim(),
      bridgeContract: contract.trim(),
      bridgeChainId: chainId,
      bridgeSymbol: symbol.trim().isEmpty ? 'CALC' : symbol.trim(),
    ),
  );

  Future<void> setSponsorConfig({
    required String alipay,
    required String wechat,
    required String usdt,
    required String eth,
    required String note,
  }) => applySettings(
    _derive(
      sponsorAlipay: alipay.trim(),
      sponsorWechat: wechat.trim(),
      sponsorUsdt: usdt.trim(),
      sponsorEth: eth.trim(),
      sponsorNote: note.trim(),
    ),
  );

  Future<void> setPeriod(String period) async {
    rankingPeriod = period;
    ranked = await ranking(period: period, genre: '');
    notifyListeners();
  }

  /* ------------------------- 身份保管（口令）：钥匙自己拿好 ------------------------- */

  Future<void> refreshVault() async {
    vault = await vaultStatus_();
    notifyListeners();
  }

  Future<void> vaultSetPassphrase(String passphrase) async {
    await setPassphrase(passphrase: passphrase);
    await refreshVault();
  }

  Future<IdentityInfo> vaultUnlock(String passphrase) async {
    final info = await unlockVault(passphrase: passphrase);
    identity = info;
    vault = await vaultStatus_();
    notifyListeners();
    return info;
  }

  Future<void> vaultLock() async {
    await lockVault();
    identity = null;
    vault = await vaultStatus_();
    notifyListeners();
  }

  Future<void> vaultRemovePassphrase() async {
    await removePassphrase();
    vault = await vaultStatus_();
    notifyListeners();
  }

  /* ------------------------- 信任网 ------------------------- */

  Future<void> attest(String targetPeer, String? note) async {
    await attestIdentity(targetPeer: targetPeer, note: note);
    await refresh();
  }

  Future<String> passStrength(String passphrase) =>
      passphraseStrength(passphrase: passphrase);

  @override
  void dispose() {
    _pumpTimer?.cancel();
    localLibrary.removeListener(notifyListeners);
    localLibrary.dispose();
    super.dispose();
  }
}

/// `settings` / `palette` / `wallet` / `stats` 与生成的函数名冲突时加下划线别名。
/// （生成的 Dart 顶层函数与 AppState 的同名方法并存，加个下划线，Dart 就不会认错人。）
Future<Settings> settings_() => settings();

/// `identity` 既是本页面里的字段又是生成函数，取个别名，免得它遮住自己
Future<IdentityInfo> identityApi() => identity();
Future<Palette> palette_() => palette();
Future<List<Genre>> genres_() => genres();
Future<List<ContestCard>> contests_() => contests();
Future<List<PublisherCard>> publishers_() => publishers();
Future<List<ReportCard>> reports_() => reports();
Future<List<LicenseView>> licenses_() => licenses();
Future<List<ContestKindView>> contestKinds_() => contestKinds();
Future<List<RewardRuleView>> rewardRules_() => rewardRules();
Future<NodeStats> stats_() => stats();
Future<WalletSummary> wallet_() => wallet();
Future<CarouselStateView> carouselState_() => carouselState();
Future<int> pump_() => pump().then((v) => v.toInt());
Future<VaultStatus> vaultStatus_() => vaultStatus();
Future<List<TrustEntryView>> myTrustScores_() => myTrustScores();
