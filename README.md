# Alighieri · 桌面与移动端 App

一个运行在 P2P 之上的免费轻小说连载与阅读客户端，**没有中心服务器**：
每个设备都是一个独立节点，作品、书架、评论、奖励币都以 CRDT 操作的形式
在读者之间互相复制。

这是 Web 版的原生移植：
**Flutter** 负责桌面 / 移动端 UI，**Rust** 负责全部核心域逻辑；
编辑器端（VS Code / Obsidian）把同一份 Web 客户端与本地书架挂在本机。

| 平台       | 状态                                                                                   |
| -------- | ------------------------------------------------------------------------------------ |
| Linux    | `flutter build linux --release` 已验证                                                  |
| Android  | `flutter build apk --release --split-per-abi` 已验证（arm64-v8a / armeabi-v7a / x86\_64） |
| Windows  | `flutter build windows --release` 已验证（VS 2022 C++ 工具链）                               |
| VS Code  | `dist/Alighieri-0.1.2-vscode.vsix` —— 完整网络客户端 + 本地书架                                 |
| Obsidian | `dist/Alighieri-0.1.2-obsidian.zip` —— 同一套功能，桌面端专用                                   |

三端与两个编辑器端的图标统一为同一枚羽毛：Windows `.ico` 由
`linux/runner/resources/app_icon_512.png` 生成，Android 使用自适应图标，
插件使用同一份 SVG / PNG。

```bash
# 环境
rustup stable            # Rust 1.99+
flutter 3.47 / Dart 3.13

# 一次跑起来（Linux）
flutter pub get
flutter_rust_bridge_codegen generate     # 改过 rust/src/api.rs 才需要
flutter run -d linux
```

***

## 构建与打包

### Android APK

需要 Android SDK（本机为 `~/Android/Sdk`）、NDK `28.2.13676358`、JDK 17+
和三个 Rust target：

```bash
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android

# Flutter 会优先使用 Android Studio 自带 JDK；命令行构建时显式指定更稳
export ANDROID_HOME="$HOME/Android/Sdk"
export JAVA_HOME=/opt/android-studio/jbr

flutter build apk --release --split-per-abi
# -> build/app/outputs/flutter-apk/app-<abi>-release.apk

adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
adb shell am start -n app.alighieri.alighieri/.MainActivity
```

`android/app/build.gradle.kts` 会在每个 `preBuild` 里调 cargo，为三个 ABI
生成 `libalighieri_core.so`，并用 `sdk.dir` / NDK 自动注入 clang 链接器。
命令行手工编译可用：

```bash
scripts/build-rust.sh android
```

### Windows

Linux 上可以交叉编译 **Rust 核心**（MinGW，位于
`~/.local/opt/mingw-w64`，无需 root）：

```bash
source scripts/windows-env.sh
cd rust && cargo build --release --target x86_64-pc-windows-gnu
# -> rust/target/x86_64-pc-windows-gnu/release/alighieri_core.dll
```

Flutter 的 Windows 桌面壳必须在 Windows 主机上构建：

```powershell
flutter build windows --release
# -> build/windows/x64/runner/Release/alighieri.exe
```

Windows 上首次构建需要允许创建符号链接（Flutter 用它挂接插件）：
在「设置 → 系统 → 开发者选项」打开开发者模式，或用管理员终端执行构建。
`windows/CMakeLists.txt` 会在构建时调用同一份 Rust 源码生成
`alighieri_core.dll`。

### 编辑器插件（VS Code / Obsidian）

两个插件端共用 `extensions/shared/`：一个只监听 `127.0.0.1` 的本地服务，
同时提供随包携带的 Alighieri Web 客户端、本地书架页面与本地书库 API。
因此网络端的功能（P2P、投稿、钱包、赛事、出版社、审查、同步状态…）
与网站版完全一致，无需第二套实现。

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build-extensions.ps1
# -> dist/Alighieri-0.1.2-vscode.vsix
# -> dist/Alighieri-0.1.2-obsidian.zip
```

- VS Code：`code --install-extension dist/Alighieri-0.1.2-vscode.vsix`
- Obsidian：把 zip 解压到 `<vault>/.obsidian/plugins/`（包内已含 `alighieri/`
  目录），在设置里启用「Alighieri」；命令面板与左侧丝带图标都能打开客户端 /
  本地书架。
- 本地服务端口被占用时会自动向后找空闲端口；页面里显示的是实际端口。

### 本地书架

「书架 → 本地」与站内 P2P 书架刻意分开：本地书只保存在这台设备，
不产生任何 op，也不会上传。支持 TXT（UTF-8 / UTF-16 / GBK / Big5）、
EPUB 2/3、Markdown 与 HTML；解析、自动分章、阅读进度都在本机完成。
桌面 / 移动端在 `lib/local/`，编辑器插件在 `extensions/shared/local-library.js`，
两边使用同一套 `library.json + books/<id>.json + sources/<id>.<ext>` 布局。

### 阅读器译文

人工译文是一条 `translation.put`，随 op log 同步、带译者署名；
机器译文走 MyMemory 的公开接口，只在本机显示、**不自动触发**，
逐段翻译且失败段落保留原文。界面上先说明「正文会发给第三方」，
再把结果作为一份可选译文放进同一个切换器 —— 不把机器译文冒充人工署名。

### 私钥口令加密

与 Web 版 `lib/p2p/keyvault.ts` 同一套参数（身份页设置：

- PBKDF2-SHA256（**310,000 轮**，OWASP 2023 建议值）派生 AES-256-GCM 密钥；
- 每次加密新的 16 字节 salt / 12 字节 nonce，同样口令得到不同密文；
- GCM 自带完整性校验：口令错了解密失败，而不是解出乱码身份；
- 加密后磁盘上的明文**当场消失**（`store::IdentityFile::Encrypted`）；
- 解锁只在本会话有效，锁定/重启后要重新输入；**没有找回口令** ——
  没有服务器持有它，也不存在后门；
- 已解锁时可直接改口令、锁定、或改回明文（分别有确认与诚实提示）。

### 信任网（女巫抵抗）

批量生成新身份的问题没有「杜绝」级答案 —— 无服务器就没有裁定
「是不是同一个人」的权威。采用的是**主观信任网**（Phase 1，已实现）：

- 一条新 op `attest.put`：身份 A 为身份 B 背书（weight 1..=3，
  自证无效，LWW），随 op log 同步；
- 只有**互证**（A↔B 双向）边才传播信任，从「我自己」出发
  max-product 传播、每跳 ×0.8 衰减，纯函数、跨设备确定；
- 女巫互相背书只在集群内打转 —— 没有真人给它们互证，
  图里根本没有通到你的边，分数恒为 0；
- 落地：审查页可选「只统计信任圈内的举报票」（默认关），
  圈外批量身份的举报潮在你的视野里无效；
- 发币衰减（Phase 2）会破坏「同批 op 同视图」，
  要等全部客户端协调升级，见 [docs/SYBIL-RESEARCH.md](docs/SYBIL-RESEARCH.md)
  的完整调研（SybilGuard/Limit/Rank、BrightID、PoH、Idena 等对比与
  诚实边界）。

### 许可证（ANPL 1.0 / ANPL 2.0）

连载作品的两张内置许可改用 **ANPL** 命名（Alighieri Network Public License）：

- **ANPL 1.0**（原「Alighieri 连载许可」）—— 允许站内免费连载与转载全文，
  禁止 AI 训练与未经授权的商业改编；
- **ANPL 2.0**（原「Alighieri 2.0 两阶段授权」，推荐）—— 连载期禁止
  AI 训练、改编与商用；完结后允许全文转载与 AI 训练。平台授权放宽，
  但**不得因外部因素改稿**；对出版社或其他平台，作者与作者组可
  **无条件终止授权**。

条款正文仍然只有中文（法律措辞以原文为准），界面标注「以下为原文」；
许可证 id / SPDX / 分池表保持不变（`alighieri-2.0` / `alighieri-serial`），
因此已经发布的作品与 Web 版仍能按同一 id 解析。

***

## 为什么是 Flutter + Rust

这个项目有三件事不能出错，它们恰好都是**纯计算**：

1. **CRDT 归约** —— 同一组 op 必须在任何设备上算出同一视图，否则「去中心化」就没意义；
2. **奖励币** —— 任何人都要能拿同一批 op 独立复算出同一个余额；
3. **上链申领** —— 规范化载荷必须与桥接节点逐字节一致，否则签名永远验不过。

这三件事放在 Rust 里，就能脱离界面做单元测试（本项目 **100 个测试**，
包括「乱序 + 重复投递后指纹一致」这类收敛性断言，以及两个真实 libp2p
节点的 loopback 对账 / gossipsub 广播）。Flutter 只负责渲染，
不持有一份可能与之跑偏的第二实现。

三端共用同一份域逻辑，也顺带消灭了「Web 版和 App 版规则不一样」的可能。

***

## 目录

```
rust/src/
  domain/            核心域层（纯函数，无 IO、无平台依赖）
    hlc.rs           混合逻辑时钟：wall → counter → node 字节序 定序
    keys.rs          op key 的构造与解析（前缀约定集中在此）
    model.rs         Op / 33 种操作 / 各负载 / 副本记录
    reducer.rs       CRDT 归约器（LWW / 幂等集合 / 状态机 / 门控）
    selectors.rs     派生统计：PV、余额、表情计数、审查屏蔽
    state.rs         ReplicaState（全部用 BTreeMap/BTreeSet，保证确定性）
    wallet.rs        奖励币发放规则与公式
    penname.rs       peerId → 笔名（确定性派生）
    catalog.rs       分类表 / 排序 / 检索 / 榜单半衰期
    contest.rs       赛事状态派生、报名自检
    licenses.rs      许可证登记表
    badges.rs        社区授予的 13 枚里程碑勋章
    signature.rs     op 级 Ed25519 签名与规范化 JSON（与 Web 版逐字节一致）
    theme.rs         配色引擎（色相 + 饱和度 → 整套设计令牌）
    identity.rs      Ed25519 身份、peerId、恢复短语、验签
    bridge.rs        ALC→CALC 申领的规范化载荷与覆盖率
    time.rs          毫秒 ⇄ ISO-8601（纯函数，不读时区）
  store.rs           op log（只追加 JSONL）+ 身份 + 设置的落盘
  net.rs             原生 libp2p：TCP/DNS/WebSocket、Circuit Relay v2、
                     dcutr、Kademlia provider 发现、gossipsub、定向对账
  engine.rs          把域层与本机副作用接起来（写操作的顺序只有一处正确）
  api.rs             flutter_rust_bridge 门面

lib/
  main.dart / app.dart       入口与主外壳
  state/app_state.dart        跨 FFI 调用都收在这里
  state/strings.dart          五语言字典（zh 是真相来源）
  theme/app_theme.dart        Palette → ThemeData
  widgets/widgets.dart        Panel / EmptyState / 作品卡片
  pages/                      首页 / 分类 / 榜单 / 书架 / 投稿 / 作品 /
                              阅读器 / 钱包 / 大赛 / 出版社 / 审查 /
                              条款 / 身份 / 同步 / 设置 / 作者
  src/rust/                   flutter_rust_bridge 生成物（勿手改）
```

***

## 三条移植时守住的硬性约束

### 1. 归约必须是纯函数

记录里**不能存任何依赖「当前时间」的字段**。赛事状态（征稿中 / 评审中 /
已结束）由 `deadline`/`announceAt` 与当前时间在**读取时**派生，不进 CRDT；
笔名 30 天改名冷却期同理，判定只在界面层。

`rust/src/domain/state.rs` 里所有容器都是 `BTreeMap` / `BTreeSet`：
Rust 的默认 `HashMap` 用随机种子，迭代顺序在不同进程间不确定，
而收敛性要求连遍历顺序都一致。

### 2. 门控未通过必须挂起，不能丢弃

`issue.close` / `patch.merge` / `contest.result` / `report.respond` 这类操作的
合法性取决于**当时**的其它记录（维护者名单、赛事主办方），而那些记录本身也是 op，
到达顺序任意。所以 `apply_ops` 分两遍：先落非门控 op 建立前提，
再按 HLC 顺序应用门控 op；前提未就绪的进 `pending_gated`，每批结束后重试。
直接丢弃会让「先收到整合、后收到授权」的节点和顺序相反的节点留下不同视图。

### 3. 钱按 op 逐笔消费，不做余额减法

`reward.grant` / `reward.transfer` 只增，`reward.wrap` 是唯一扣减。
余额永远是算出来的（收到的 − 转出的 − 已上链锁定的）。
幂等键由「身份 + 行为 + 目标 + UTC 日桶」决定，重复广播不会重复发币。

***

## P2P 网络（与 Web 版同一张网）

App 不在 Dart 里重写网络，而是在 Rust 侧跑一个原生 libp2p 节点（Tokio 线程），
Flutter 只轮询状态快照。协议常量与 Web 版 `lib/p2p/config.ts` 完全一致：

| 用途             | 值                                                 |
| -------------- | ------------------------------------------------- |
| gossipsub 主题   | `alighieri/ops/v1`                                |
| 广播信封           | `{v:"alighieri/1.0.0", net:"alighieri", ops:[…]}` |
| DHT provider 键 | multihash(`sha256("/alighieri/peers/v1")`)        |
| App 定向对账协议     | `/alighieri/ops/1.0.0`（request-response，JSON）     |
| 每条 op          | Ed25519 签名，签名对象是除 `sig` 外的规范化 JSON                |

四层连通性：

1. **引导** —— 内置公共引导 / WSS 兜底、设置里手填的 multiaddr、
   `https://<站点>/.well-known/libp2p` 清单，以及站点域名的 `/dnsaddr`。
2. **NAT 穿透** —— 主动向 Circuit Relay v2 中继预约；在已建立的中继连接上
   由 dcutr 自动打洞，成功后转为直连。
3. **发现** —— Kademlia DHT 的 provider 记录；找到 peerId 后再做一次
   `findPeer`（对应 Web 版 `dht.findPeer`）取对方地址，优先直拨，同时把
   自己的中继与对方记录里的 `/p2p-circuit` 电路放进同一次拨号并发尝试。
   浏览器给出的 `/webrtc` 地址会被过滤，只保留 TCP / DNS / 中继电路。
4. **复制** —— gossipsub 实时广播；App ↔ App 连接建立后自动跑一轮
   request-response 对账补齐断线期间的差量。Web 节点不认识该协议，
   会自然回退到 gossipsub / 本地重播。

网络页显示节点状态、同伴（方向 / 是否订阅 / agent / 同步）、DHT 与中继数量、
发现进度、签名拒收数、监听地址与最近错误。设置页可编辑站点地址、引导与中继
节点，并在改完后「重新连接」，不需要重启应用。

评论门槛看**本机观察到的阅读时长**：作品评论 60 秒，单话评论 30 秒。
阅读器每 30 秒记一条 `read.tick`（单条上限 120 秒，切后台 / 锁屏不计时），
单话评论区与作品评论区都会实时解锁。勋章改为社区授予的 13 枚里程碑，
一条 `badge.grant` 带授予者署名与可选理由；自授无效，多人授予同一枚只算一枚。

***

## ⚠️ 这一版刻意留下的边界

与原站 README 的「已知不足」同源，界面上也都写明了：

1. **私钥默认仍以明文存本地** —— 已实现口令派生加密
   （PBKDF2-SHA256 310,000 轮 + AES-256-GCM，参数与 Web 版 `keyvault.ts`
   一致，见「私钥口令加密」一节），但和 Web 版一样**默认关闭**：强制设口令
   会把「打开就能写」变成「先过一道门槛」。未接系统钥匙串 / WebAuthn。
2. **公共引导 / 中继不保证可达** —— 内置的 IPFS 公共节点是兜底，可能被墙、
   限流或下线。它们不可达时节点仍能本地工作，但「陌生人自动找到彼此」
   会退化成「只连得上已知地址或同一局域网」。界面在网络页如实显示
   同伴数、DHT 数、中继预约与最近错误，不假装在线。
3. **浏览器节点的 WebRTC 无法从原生 App 直接拨号** —— App 走 TCP / DNS /
   WebSocket / 中继电路；浏览器节点通常同时预约公共中继，所以仍可通过
   `/p2p-circuit` 互通。没有可用中继时，浏览器与 App 之间可能只能单向发现。
4. **DHT 发现共用公共 IPFS Kademlia 网络** —— 本站节点以
   `/alighieri/peers/v1` 的 multihash 作为 provider key 互相发现。
   公共 DHT 不保证记录长期存在，也不阻止别人写同名 provider 记录。
5. **阅读时长是本机观察，不是密码学证明** —— 门槛挡住的是普通误触与灌水，
   挡不住改过的客户端。`read.tick` 上限 120 秒/条，且评论门槛只影响
   该身份自己能否评价；勋章授予也只看谁愿意署名，不自动核验条件。
6. **没有内容下架流程** —— `novel.del` 只是本机视图上的覆盖，
   删不掉别人设备上已收到的副本。联邦审查（举报 + 本机阈值）只改变本机可见性。
7. **奖励币挡不住女巫攻击** —— 批量生成新身份刷币在理论上可行。
   已实现「信任网」把批量造号对**审查视野**的攻击压到无效（互证背书 +
   圈内过滤，默认关），但发币衰减（Phase 2）需要全部客户端协调升级，
   见 [docs/SYBIL-RESEARCH.md](docs/SYBIL-RESEARCH.md)。
8. **笔名必然可能重复** —— 界面始终同时展示笔名与身份标识。
9. **排行榜只排本机收到的内容** —— 没有服务器能统计全站。
10. **出版社入驻无需审核** —— 任何节点都能自称出版社。

***

## 与原 Web 版对照时发现的两处不一致

这里按**代码**（它是引擎）为准，并记录如下：

1. **笔名字表数量**：`lib/p2p/penname.ts` 的注释写「68 种前缀 × 68 种后缀」，
   实际数组是 56 项前缀 + 38 项后缀。派生只依赖数组内容，所以两边笔名仍然一致，
   只是注释里的 3.7 万应为约 1.7 万。
2. **默认绿**：`app/globals.css` 硬编码的 `--primary: #16a06a` 与
   `build_palette(DEFAULT_BRAND, light)` 算出的 `#229b62` 对不上 ——
   前者反推是 h≈156.5 / s≈76% / l≈35.7%，而 `DEFAULT_BRAND` 是 152/64。
   即 CSS 里那份是先于配色引擎手写的残留值。

另外，原站把「第一话」这个**界面词**写进了章节记录（`latest.title` 的缺省值）。
本移植改成存哨兵 `__first__` / `__chapter__:N`，由界面按语言渲染 ——
与项目自己总结的「`__unvolumed__` 教训」是同一个道理。

***

## 测试

```bash
cd rust && cargo test --release   # 100 个：域层单元测试 + 引擎端到端 + 双节点网络
flutter analyze                   # 无 error / warning
flutter test                      # 7 个：本地书库解析（TXT / GBK / Markdown / HTML / EPUB）
node scripts/smoke-extensions.mjs # 插件端：解析器 + 本地服务 + API
```

其中值得单独看的几条：

- `domain::reducer::converges_regardless_of_order` —— 乱序 + 每条形重复三遍，
  指纹必须一致；
- `domain::reducer::read_ticks_sum_and_clamp_seconds` —— 阅读时长是事件之和，
  单条超过 120 秒会被压回上限；
- `net::two_nodes_sync_and_gossip_over_loopback` —— 两个真实 libp2p 节点
  在 loopback 上拨通、自动对账，再由 gossipsub 送达新广播；
- `tests/engine_flow.rs::read_gate_and_badge_grants_match_the_web_rules` ——
  60 / 30 秒评论门槛、自授无效、勋章可跨重启恢复；
- `domain::theme::body_contrast_is_aaa_for_every_hue` —— 360° 全色相下
  正文与玻璃底对比度均 ≥ 7:1（WCAG AAA）；
- `domain::bridge::golden_vector_matches_the_web_implementation` ——
  上链申领的规范化载荷与 Web 版/桥接节点逐字节一致；
- `tests/engine_flow.rs` —— 投稿 → 发正文 → 读一话 → 收藏 → 评价 → 打赏 →
  重开后余额可被独立复算。

***

## License

MIT © 2026 **OpenMasons** —— 完整条款见 [LICENSE](LICENSE)。
各端界面底部已统一标注 **Alighieri by OpenMasons**。
