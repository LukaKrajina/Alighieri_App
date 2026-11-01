//! 应用引擎
//! --------
//! 把「域层纯函数」和「本机副作用」（落盘、时钟、网络）接起来。
//! 界面只跟它对话，不直接碰归约器 —— 顺序要求（写入必须先落盘再广播）
//! 只需要在一处写对，而不是在每个按钮的回调里各猜一次。

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::domain::badges::{badge_def, granted_badges, BADGES};
use crate::domain::bridge;
use crate::domain::carousel::{
    normalize_href, CAROUSEL_FEE, CAROUSEL_MAX_NAME, CAROUSEL_MAX_SUBTITLE, CAROUSEL_MAX_TITLE,
    CAROUSEL_SLOTS, CAROUSEL_WINDOW_MS,
};
use crate::domain::catalog::{self, RankingPeriod, SearchParams};
use crate::domain::contest;
use crate::domain::hlc::{compare_hlts, HybridClock};
use crate::domain::identity::Identity;
use crate::domain::keys::*;
use crate::domain::licenses;
use crate::domain::model::*;
use crate::domain::penname;
use crate::domain::reducer::{apply_one, apply_ops};
use crate::domain::selectors;
use crate::domain::signature;
use crate::domain::state::{CarouselRecord, DealRecord, ReplicaState};
use crate::domain::theme::{self, BrandColor, Palette, ThemeMode};
use crate::domain::time::iso_of_ms;
use crate::domain::view::*;
use crate::domain::wallet::{self, RewardAction};
use crate::net::Net;
use crate::store::{IdentityFile, Settings, Store};
use crate::vault::{self, EncryptedIdentity};

pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// 评价门槛（与 Web 版 `review-panel.tsx` 一致）：
/// 对整部作品写评价需要累计阅读 60 秒，对单话写评价需要该话累计 30 秒。
/// 先读后评，顺序不能反。
pub const MIN_REVIEW_SECONDS_WORK: u64 = 60;
pub const MIN_REVIEW_SECONDS_CHAPTER: u64 = 30;

/* ------------------------- 对外结构（跨 FFI 的门面） ------------------------- */

#[derive(Debug, Clone, Default)]
pub struct InitReport {
    pub peer_id: String,
    pub pen_name: String,
    pub ops_loaded: u64,
    pub novels: u64,
    pub data_dir: String,
    pub recovered: bool,
}

#[derive(Debug, Clone, Default)]
pub struct WalletSummary {
    pub balance: i64,
    pub total_issued: i64,
    pub locked: i64,
    /// 已花在首页轮播位上的奖励币（过期也不退还）
    pub carousel_spent: i64,
    pub symbol: String,
    pub ledger: Vec<LedgerEntry>,
    /// 本机副本里算出的前 10 名持仓（按收到奖励累计，与 Web 一致）
    pub holders: Vec<WalletHolder>,
    /// 本机收到的奖励按行为聚合，金额从高到低
    pub income: Vec<WalletIncome>,
    /// 页面上的示例算式结果
    pub examples: RewardExampleView,
}

#[derive(Debug, Clone, Default)]
pub struct NetPeer {
    pub peer_id: String,
    pub addr: String,
    pub direction: String,
    pub subscribed: bool,
    pub agent: String,
}

#[derive(Debug, Clone, Default)]
pub struct NodeStats {
    pub peer_id: String,
    pub ops: u64,
    pub novels: u64,
    pub chapters: u64,
    pub pending_gated: u64,
    pub oplog_bytes: u64,
    pub listen_port: u32,
    pub peers: Vec<String>,
    pub revision: u64,
    /* -------- 网络诊断：界面要能说出「卡在哪一环」 -------- */
    pub net_state: String,
    pub net_peers: Vec<NetPeer>,
    pub dht_peers: u64,
    pub relay_reservations: u64,
    pub listen_addrs: Vec<String>,
    pub discovery_attempts: u64,
    pub providers_found: u64,
    pub providers_dialed: u64,
    pub last_net_error: String,
    pub net_source: String,
    pub site_fetched: bool,
    pub site_nodes: u64,
    pub ops_in: u64,
    pub ops_out: u64,
    pub rejected_sigs: u64,
}

#[derive(Debug, Clone, Default)]
pub struct IdentityInfo {
    pub peer_id: String,
    pub pen_name: String,
    pub bio: String,
    pub recovery_phrase: String,
    pub created_at_ms: u64,
}

/// 身份保管现状（口令加密 / 会话解锁状态）。
#[derive(Debug, Clone, Default, PartialEq)]
pub struct VaultStatus {
    /// 磁盘上有没有身份（明文或加密都算「有」）
    pub has_identity: bool,
    /// 磁盘上是否是口令加密形态
    pub encrypted: bool,
    /// 本会话是否已解锁（能签名、能发布）
    pub unlocked: bool,
}

/// 信任网里的一位（我视角的分数）。
#[derive(Debug, Clone, Default)]
pub struct TrustEntryView {
    pub peer: String,
    pub name: String,
    pub score: f64,
}

/// 信任网统计。
#[derive(Debug, Clone, Default)]
pub struct AttestationStats {
    /// 本机收到的背书条数（含单向）
    pub total_edges: u64,
    /// 互证边数（互证才参与信任传播）
    pub mutual_edges: u64,
}

/* ------------------------- 引擎本体 ------------------------- */

pub struct Engine {
    pub identity: Option<Identity>,
    /// 磁盘上的加密身份信封。`Some` 表示身份以口令加密形态落盘；
    /// 与 `identity` 同时存在 = 已解锁；只有它一个 = 上锁（等口令）。
    pub identity_box: Option<EncryptedIdentity>,
    clock: HybridClock,
    pub state: ReplicaState,
    store: Option<Store>,
    pub settings: Settings,
    ops: Vec<Op>,
    /// 与后台网络线程共享的 op 快照。
    /// 网络线程不能持有 `&Engine`（它活在锁里），所以给它一份可以自己读的副本。
    /// 各看各的副本，不必隔着锁干瞪眼。
    shared_ops: Arc<Mutex<Vec<Op>>>,
    seen: BTreeSet<String>,
    net: Option<Net>,
    inbox: Arc<Mutex<Vec<Op>>>,
    listen_port: u16,
    /// 网络来的、验签失败的记录数（诊断用）
    rejected_sigs: u64,
}

impl Engine {
    pub fn new() -> Engine {
        Engine {
            identity: None,
            identity_box: None,
            clock: HybridClock::new("--------", None),
            state: ReplicaState::new(),
            store: None,
            settings: Settings::defaults(),
            ops: Vec::new(),
            shared_ops: Arc::new(Mutex::new(Vec::new())),
            seen: BTreeSet::new(),
            net: None,
            inbox: Arc::new(Mutex::new(Vec::new())),
            listen_port: 0,
            rejected_sigs: 0,
        }
    }

    /* -------- 生命周期：先和磁盘打好招呼 -------- */

    pub fn init(&mut self, data_dir: &str) -> Result<InitReport, String> {
        let store = Store::open(data_dir)?;
        self.settings = store.load_settings()?;
        // 派生笔名跟随界面语言：先设置当前线程语言，后续所有派生都按它取词库。
        penname::set_locale(&self.settings.locale);

        let mut recovered = false;
        match store.load_identity()? {
            IdentityFile::Plain { seed, created_ms } => {
                if let Some(id) = Identity::from_recovery_phrase(&seed, created_ms) {
                    self.identity = Some(id);
                    recovered = true;
                }
            }
            IdentityFile::Encrypted(boxed) => {
                // 保持上锁：拿到口令之前连 peerId 都不暴露给界面之外。
                self.identity_box = Some(boxed);
            }
            IdentityFile::Missing => {}
        }
        if self.identity.is_none() && self.identity_box.is_none() {
            let id = Identity::generate(now_ms());
            store.save_identity(&id.recovery_phrase(), id.created_at_ms)?;
            self.identity = Some(id);
        }

        let ops = store.load_ops()?;
        let loaded = ops.len();
        self.ops = ops;
        self.state = ReplicaState::new();
        apply_ops(&mut self.state, &self.ops, &iso_of_ms(now_ms()));
        for op in &self.ops {
            self.seen.insert(op.id.clone());
        }
        self.clock = HybridClock::new(
            self.identity.as_ref().map(|i| i.peer_id.as_str()).unwrap_or("--------"),
            self.ops.iter().map(|o| o.hlts.clone()).max_by(|a, b| compare_hlts(a, b)).as_deref(),
        );

        self.store = Some(store);
        let dir = self.store.as_ref().map(|s| s.dir().display().to_string()).unwrap_or_default();
        // 与 Web 一致：重放完存量后，如果开了自动整合，把积压的无冲突提案处理掉。
        self.auto_merge_all();

        Ok(InitReport {
            peer_id: self.peer_id(),
            pen_name: self.pen_name(),
            ops_loaded: loaded as u64,
            novels: self.state.novels.len() as u64,
            data_dir: dir,
            recovered,
        })
    }

    pub fn peer_id(&self) -> String {
        self.identity.as_ref().map(|i| i.peer_id.clone()).unwrap_or_default()
    }

    pub fn pen_name(&self) -> String {
        match &self.identity {
            Some(i) => match self.state.profiles.get(&i.peer_id) {
                Some(p) if !p.name.is_empty() => p.name.clone(),
                _ => i.pen_name(),
            },
            None => String::new(),
        }
    }

    fn actor(&self) -> Result<String, String> {
        match &self.identity {
            Some(i) => Ok(i.peer_id.clone()),
            None => Err("还没有身份：请先初始化".into()),
        }
    }

    fn store(&self) -> Result<&Store, String> {
        self.store.as_ref().ok_or_else(|| "存储尚未初始化".into())
    }

    /* -------- 写入：顺序比速度要紧 -------- */

    /// 造一条 op：推进 HLC、打上 actor、落盘、归约、广播。
    ///
    /// 顺序是刻意的：**先落盘再广播**。反过来（先广播后落盘）
    /// 遇到崩溃就会得到一条「别人都收到了、自己却没有」的操作 ——
    /// 面子上过不去，日志里也查不到。
    fn new_op(&mut self, kind: OpKind, key: &str, body: serde_json::Value) -> Result<Op, String> {
        let actor = self.actor()?;
        let hlts = self.clock.now(now_ms());
        let mut op = Op {
            id: format!("{actor}:{hlts}:{}", random_suffix()),
            actor,
            hlts,
            kind,
            key: key.to_string(),
            body,
            cid: None,
            v: 1,
            sig: None,
        };
        // 先签名，再落盘/广播。签名失败不阻塞本地写入（与 Web 版一致），
        // 但这条记录到了别的节点会被按「无法验证」丢弃。
        if let Some(identity) = &self.identity {
            signature::sign_op(identity, &mut op);
        }
        self.commit(op.clone())?;
        Ok(op)
    }

    pub fn commit(&mut self, op: Op) -> Result<(), String> {
        if self.seen.contains(&op.id) {
            return Ok(());
        }
        self.seen.insert(op.id.clone());
        self.ops.push(op.clone());
        self.shared_ops.lock().unwrap().push(op.clone());
        let received = iso_of_ms(now_ms());
        apply_one(&mut self.state, &op, &received);
        self.store()?.append_op(&op)?;
        // 落盘之后才广播：崩溃时不会出现「别人收到了、自己却没有」的尴尬。
        if let Some(net) = &self.net {
            net.broadcast(vec![op]);
        }
        Ok(())
    }

    /// 收到远端 op：验签 + 归约 + 落盘（去重靠 op.id）。
    ///
    /// 网络来的记录必须有有效签名：只要无签名可放行，伪造者不签就绕过了校验，
    /// 等于门没锁还挂着「请勿推门」。
    /// 本机历史（`init` 里的重放）不走这里，因此升级前的老 op 仍能读。
    pub fn ingest(&mut self, ops: Vec<Op>) -> usize {
        let mut fresh = Vec::new();
        let mut rejected = 0u64;
        for op in ops {
            if op.actor.is_empty() || self.seen.contains(&op.id) {
                continue;
            }
            match signature::verify_op(&op) {
                Some(true) => {}
                _ => {
                    rejected += 1;
                    continue;
                }
            }
            self.seen.insert(op.id.clone());
            fresh.push(op);
        }
        self.rejected_sigs += rejected;
        let n = fresh.len();
        if n == 0 {
            return 0;
        }
        // 推进本地时钟：远端的操作可能比本地时钟还新
        for op in &fresh {
            self.clock.observe(&op.hlts, now_ms());
        }
        let received = iso_of_ms(now_ms());
        apply_ops(&mut self.state, &fresh, &received);
        self.ops.extend(fresh.iter().cloned());
        self.shared_ops.lock().unwrap().extend(fresh.iter().cloned());
        if let Some(s) = &self.store {
            if let Err(e) = s.append_ops(&fresh) {
                eprintln!("[alighieri] 落盘失败：{e}");
            }
        }
        // 与 Web 一致：收到新提案后，本机若是维护者且开了自动整合，立刻处理。
        let patch_targets: Vec<(String, String)> = fresh
            .iter()
            .filter(|op| op.kind == OpKind::PatchPut)
            .filter_map(|op| {
                let b: PatchBody = serde_json::from_value(op.body.clone()).ok()?;
                Some((b.novel_id, b.patch_id))
            })
            .collect();
        self.auto_merge_targets(&patch_targets);
        n
    }

    /// 自动整合：设置打开后，本机代替维护者把**无冲突**的提案整合掉。
    ///
    /// 只处理「我是维护者」的作品；有冲突的留给人工判断 ——
    /// 机器只做它确定的那一半。
    fn auto_merge_targets(&mut self, targets: &[(String, String)]) {
        if !self.settings.auto_merge {
            return;
        }
        let actor = match &self.identity {
            Some(i) => i.peer_id.clone(),
            None => return,
        };
        let mut ready: Vec<(String, String)> = Vec::new();
        for (novel_id, patch_id) in targets {
            let Some(patch) = self.state.patches.get(&patch_key(novel_id, patch_id)) else {
                continue;
            };
            if !matches!(patch.state, PatchState::Open) {
                continue;
            }
            if self.state.merges.contains_key(&merge_key(novel_id, patch_id)) {
                continue;
            }
            if !crate::domain::reducer::is_maintainer(&self.state, novel_id, &actor) {
                continue;
            }
            if selectors::patch_has_conflict(&self.state, patch) {
                continue;
            }
            ready.push((novel_id.clone(), patch_id.clone()));
        }
        for (novel_id, patch_id) in ready {
            if let Err(e) = self.merge_patch(&novel_id, &patch_id, "") {
                eprintln!("[alighieri] 自动整合失败：{e}");
            }
        }
    }

    /// 打开自动整合后立即扫一遍存量提案（设置页触发）。
    pub fn auto_merge_now(&mut self) {
        self.auto_merge_all();
    }

    /// 扫描全部存量提案（启动后 / 打开开关时）。
    fn auto_merge_all(&mut self) {
        if !self.settings.auto_merge {
            return;
        }
        let targets: Vec<(String, String)> = self
            .state
            .patches
            .values()
            .map(|p| (p.novel_id.clone(), p.patch_id.clone()))
            .collect();
        self.auto_merge_targets(&targets);
    }

    /// 把后台线程收到的 op 收进来
    pub fn pump(&mut self) -> usize {
        let batch: Vec<Op> = std::mem::take(&mut *self.inbox.lock().unwrap());
        self.ingest(batch)
    }

    pub fn all_ops(&self) -> Vec<Op> {
        self.ops.clone()
    }

    /* -------- 身份 -------- */

    pub fn identity_info(&self) -> Result<IdentityInfo, String> {
        let id = self.identity.as_ref().ok_or("还没有身份")?;
        Ok(IdentityInfo {
            peer_id: id.peer_id.clone(),
            pen_name: self.pen_name(),
            bio: self
                .state
                .profiles
                .get(&id.peer_id)
                .map(|p| p.bio.clone())
                .filter(|b| !b.is_empty())
                .unwrap_or_else(|| id.default_bio().to_string()),
            recovery_phrase: id.recovery_phrase(),
            created_at_ms: id.created_at_ms,
        })
    }

    pub fn import_identity(&mut self, phrase: &str) -> Result<IdentityInfo, String> {
        let id = Identity::from_recovery_phrase(phrase, now_ms()).ok_or("恢复短语无法解析")?;
        self.store()?.save_identity(&id.recovery_phrase(), id.created_at_ms)?;
        let peer = id.peer_id.clone();
        self.identity = Some(id);
        // 导入即换身份：旧信封一并作废（新身份先以明文落盘，随后可再设口令）。
        self.identity_box = None;
        self.clock = HybridClock::new(&peer, None);
        self.identity_info()
    }

    /* -------- 身份保管：口令来，明文走 -------- */

    pub fn vault_status(&self) -> VaultStatus {
        VaultStatus {
            has_identity: self.identity.is_some() || self.identity_box.is_some(),
            encrypted: self.identity_box.is_some(),
            unlocked: self.identity.is_some(),
        }
    }

    /// 设置（或修改）口令：把种子用新 salt/nonce 加密后覆盖落盘，
    /// 明文当场消失。本会话保持解锁，不要求重输。
    pub fn set_passphrase(&mut self, passphrase: &str) -> Result<(), String> {
        let id = self.identity.as_ref().ok_or("passphrase-needs-unlock")?;
        if passphrase.chars().count() < vault::MIN_PASSPHRASE_LEN {
            return Err("passphrase-too-short".into());
        }
        // 明文 = 自描述的种子载荷；只有解开信封才能读回身份。
        let payload = serde_json::json!({
            "seed": hex::encode(&id.seed),
            "createdAtMs": id.created_at_ms,
        })
        .to_string();
        let boxed = vault::seal(payload.as_bytes(), passphrase)?;
        self.store()?.save_encrypted_identity(&boxed)?;
        self.identity_box = Some(boxed);
        Ok(())
    }

    /// 用口令解锁。口令错误 = GCM 校验失败，返回可读错误而不是乱码身份。
    pub fn unlock_vault(&mut self, passphrase: &str) -> Result<IdentityInfo, String> {
        let boxed = self
            .identity_box
            .clone()
            .ok_or("没有加密身份")?;
        let plain = vault::open(&boxed, passphrase)?;
        let payload: serde_json::Value =
            serde_json::from_slice(&plain).map_err(|_| "密钥内容损坏".to_string())?;
        let seed = payload
            .get("seed")
            .and_then(|x| x.as_str())
            .ok_or("密钥内容损坏")?;
        let created = payload
            .get("createdAtMs")
            .and_then(|x| x.as_u64())
            .unwrap_or(0);
        let id = Identity::from_recovery_phrase(seed, created).ok_or("密钥内容损坏")?;
        self.identity = Some(id);
        // 解锁后 HLC 的 node 字节恢复成身份 —— 同一批 op 的定序回到预期。
        let max_hlts = self
            .ops
            .iter()
            .map(|o| o.hlts.clone())
            .max_by(|a, b| compare_hlts(a, b));
        self.clock = HybridClock::new(&self.peer_id(), max_hlts.as_deref());
        self.identity_info()
    }

    /// 锁定：丢弃内存里的私钥，本会话内不再能签名。
    /// 只对加密身份有意义；明文身份没有可锁定之物。
    pub fn lock_vault(&mut self) -> Result<(), String> {
        if self.identity_box.is_none() {
            return Err("need-passphrase-first".into());
        }
        self.identity = None;
        self.clock = HybridClock::new("--------", None);
        Ok(())
    }

    /// 移除口令：把身份改回明文落盘。需要先解锁。
    pub fn remove_passphrase(&mut self) -> Result<(), String> {
        let id = self.identity.as_ref().ok_or("passphrase-needs-unlock")?;
        if self.identity_box.is_none() {
            return Err("身份本来就是明文".into());
        }
        self.store()?
            .save_identity(&hex::encode(&id.seed), id.created_at_ms)?;
        self.identity_box = None;
        Ok(())
    }

    /* -------- 发布：先落盘，再让全世界知道 -------- */

    pub fn publish_novel(
        &mut self,
        title: &str,
        synopsis: &str,
        genre: &str,
        tags: Vec<String>,
        status: &str,
        license: &str,
    ) -> Result<String, String> {
        self.publish_novel_with_fork(title, synopsis, genre, tags, status, license, None)
    }

    fn publish_novel_with_fork(
        &mut self,
        title: &str,
        synopsis: &str,
        genre: &str,
        tags: Vec<String>,
        status: &str,
        license: &str,
        fork_of: Option<String>,
    ) -> Result<String, String> {
        let title = title.trim();
        if title.is_empty() {
            return Err("书名不能为空".into());
        }
        let actor = self.actor()?;
        let id = format!("n_{}", random_suffix());
        let now = iso_of_ms(now_ms());
        let lic = if license.is_empty() {
            licenses::DEFAULT_LICENSE.to_string()
        } else {
            license.to_string()
        };
        let body = NovelBody {
            title: title.to_string(),
            author_name: Some(self.pen_name()),
            author_peer: Some(actor.clone()),
            genre: Some(if genre.is_empty() { "daily" } else { genre }.to_string()),
            genre_name: Some(catalog::get_genre_name(genre).to_string()),
            tags: tags.into_iter().take(8).collect(),
            synopsis: synopsis.to_string(),
            status: Some(NovelStatus::parse(status)),
            episodes: 0,
            words: 0,
            latest: None,
            first_published_at: Some(now),
            awards: vec![],
            license: Some(lic),
            fork_of,
        };
        self.new_op(
            OpKind::NovelPut,
            &novel_key(&id),
            serde_json::to_value(body).map_err(|e| e.to_string())?,
        )?;
        // 投稿发布也算一次可验证行为
        let _ = self.grant(RewardAction::Publish, &format!("novel:{id}"), None);
        Ok(id)
    }

    /// 以别人的作品为源头开自己的连载。
    ///
    /// 只记溯源关系，不复制对方的 op log —— 章节由衍生作者自己发布，
    /// 这样「衍生」不是一键盗版，而是一部署了名的新作品；
    /// 署名比复制麻烦，但更像回事。
    pub fn publish_fork(
        &mut self,
        source_id: &str,
        title: &str,
        synopsis: &str,
        genre: &str,
        tags: Vec<String>,
        status: &str,
        license: &str,
    ) -> Result<String, String> {
        let source = self
            .state
            .novels
            .get(source_id)
            .cloned()
            .ok_or_else(|| "源头作品不存在".to_string())?;
        let actor = self.actor()?;
        if source.author_peer == actor {
            return Err("自己的作品不需要衍生，继续写就好".into());
        }
        let id = self.publish_novel_with_fork(
            title,
            synopsis,
            genre,
            tags,
            status,
            license,
            Some(source_id.to_string()),
        )?;
        let body = ForkBody {
            novel_id: id.clone(),
            source_id: source_id.to_string(),
            source_title: source.title.clone(),
            source_peer: source.author_peer.clone(),
            by: Some(actor),
            by_name: self.pen_name(),
            note: None,
        };
        self.new_op(
            OpKind::ForkPut,
            &fork_key(&id),
            serde_json::to_value(body).map_err(|e| e.to_string())?,
        )?;
        Ok(id)
    }

    pub fn publish_chapter(
        &mut self,
        novel_id: &str,
        no: u32,
        title: &str,
        paragraphs: Vec<String>,
        volume: Option<String>,
    ) -> Result<(), String> {
        if paragraphs.iter().all(|p| p.trim().is_empty()) {
            return Err("正文不能是空的".into());
        }
        let words = catalog::count_words(&paragraphs);
        let chapter_title = if title.trim().is_empty() {
            format!("第{no}话")
        } else {
            title.trim().to_string()
        };
        let body = ChapterBody {
            novel_id: novel_id.to_string(),
            no,
            title: chapter_title.clone(),
            paragraphs,
            words,
            published_at: iso_of_ms(now_ms()),
            volume,
            contributor: None,
        };
        self.new_op(
            OpKind::ChapterPut,
            &chapter_key(novel_id, no),
            serde_json::to_value(body).map_err(|e| e.to_string())?,
        )?;
        self.refresh_novel_stats(novel_id)
    }

    /// 根据章节正文重算作品缓存字段（话数 / 字数 / 最新一话）。
    ///
    /// 这是一条独立的 op：作品元数据本身是 LWW-Register，
    /// 不能靠「读出来改一改再写回」那种读改写（并发下会丢更新）——
    /// 两个人同时动手时，总有一个人的努力会悄悄消失。
    /// 视图层不信任这些缓存字段 —— `selectors` 永远从章节重新算 ——
    /// 但 Web 版与其它客户端仍会读它们，所以写侧要保持同步。
    fn refresh_novel_stats(&mut self, novel_id: &str) -> Result<(), String> {
        let Some(novel) = self.state.novels.get(novel_id).cloned() else {
            return Ok(());
        };
        let chapters = selectors::chapters_of(&self.state, novel_id);
        let episodes = chapters.len() as u32;
        let words: u64 = chapters.iter().map(|c| c.words).sum();
        let latest = chapters
            .iter()
            .max_by_key(|c| c.no)
            .map(|c| NovelLatest {
                no: c.no,
                title: c.title.clone(),
                at: c.published_at.clone(),
            })
            .unwrap_or_else(|| novel.latest.clone());
        let body = NovelBody {
            title: novel.title.clone(),
            author_name: Some(novel.author_name.clone()),
            author_peer: Some(novel.author_peer.clone()),
            genre: Some(novel.genre.clone()),
            genre_name: Some(novel.genre_name.clone()),
            tags: novel.tags.clone(),
            synopsis: novel.synopsis.clone(),
            status: Some(novel.status),
            episodes,
            words,
            latest: Some(latest),
            first_published_at: Some(novel.first_published_at.clone()),
            awards: novel.awards.clone(),
            license: Some(novel.license.clone()),
            fork_of: novel.fork_of.clone(),
        };
        self.new_op(
            OpKind::NovelPut,
            &novel_key(novel_id),
            serde_json::to_value(body).map_err(|e| e.to_string())?,
        )?;
        Ok(())
    }

    /// 修改自己的作品资料。只允许作者本人操作 —— 归约器仍是 LWW，
    /// 但本机入口不该给「改别人的书」提供按钮。
    pub fn update_novel(
        &mut self,
        novel_id: &str,
        title: &str,
        synopsis: &str,
        genre: &str,
        tags: Vec<String>,
        status: &str,
        license: &str,
    ) -> Result<(), String> {
        let title = title.trim();
        if title.is_empty() {
            return Err("书名不能为空".into());
        }
        let actor = self.actor()?;
        let Some(novel) = self.state.novels.get(novel_id).cloned() else {
            return Err("作品不存在".into());
        };
        if novel.author_peer != actor {
            return Err("只能修改自己的作品".into());
        }
        let chapters = selectors::chapters_of(&self.state, novel_id);
        let episodes = chapters.len() as u32;
        let words: u64 = chapters.iter().map(|c| c.words).sum();
        let genre = if genre.is_empty() { "daily" } else { genre };
        let body = NovelBody {
            title: title.to_string(),
            author_name: Some(self.pen_name()),
            author_peer: Some(actor),
            genre: Some(genre.to_string()),
            genre_name: Some(catalog::get_genre_name(genre).to_string()),
            tags: tags
                .into_iter()
                .map(|t| t.trim().to_string())
                .filter(|t| !t.is_empty())
                .take(8)
                .collect(),
            synopsis: synopsis.trim().to_string(),
            status: Some(NovelStatus::parse(status)),
            episodes,
            words,
            latest: Some(novel.latest.clone()),
            first_published_at: Some(novel.first_published_at.clone()),
            awards: novel.awards.clone(),
            license: Some(if license.is_empty() { novel.license.clone() } else { license.to_string() }),
            fork_of: novel.fork_of.clone(),
        };
        self.new_op(
            OpKind::NovelPut,
            &novel_key(novel_id),
            serde_json::to_value(body).map_err(|e| e.to_string())?,
        )?;
        Ok(())
    }

    /// 删除自己作品里的一话（本机入口；归约器仍是 tombstone 语义）。
    pub fn delete_chapter(&mut self, novel_id: &str, no: u32) -> Result<(), String> {
        let actor = self.actor()?;
        let Some(novel) = self.state.novels.get(novel_id) else {
            return Err("作品不存在".into());
        };
        if novel.author_peer != actor {
            return Err("只能删除自己作品的章节".into());
        }
        if !self.state.chapters.contains_key(&chapter_key(novel_id, no)) {
            return Err("这一话不存在".into());
        }
        self.new_op(OpKind::ChapterDel, &chapter_key(novel_id, no), serde_json::json!({}))?;
        self.refresh_novel_stats(novel_id)
    }

    pub fn delete_novel(&mut self, novel_id: &str) -> Result<(), String> {
        let actor = self.actor()?;
        let Some(novel) = self.state.novels.get(novel_id) else {
            return Err("作品不存在".into());
        };
        if novel.author_peer != actor {
            return Err("只能删除自己的作品".into());
        }
        self.new_op(OpKind::NovelDel, &novel_key(novel_id), serde_json::json!({}))?;
        Ok(())
    }

    /* -------- 阅读 / 互动：先读够时间，再谈感想 -------- */

    pub fn set_bookmark(&mut self, novel_id: &str, on: bool) -> Result<(), String> {
        let actor = self.actor()?;
        self.new_op(
            OpKind::BookmarkSet,
            &bookmark_key(&actor, novel_id),
            serde_json::json!({ "on": on }),
        )?;
        if on {
            // 与 Web 版同一 target：`bookmark:<novelId>`。
            // Web 不再额外发作者收藏分成，这里也保持只发一次收藏奖励。
            let _ = self.grant(RewardAction::Bookmark, &format!("bookmark:{novel_id}"), None);
        }
        Ok(())
    }

    pub fn add_review(
        &mut self,
        novel_id: &str,
        chapter_no: u32,
        body: &str,
        rating: u8,
        spoiler: bool,
    ) -> Result<(), String> {
        let body = body.trim();
        if body.is_empty() {
            return Err("评价不能是空的".into());
        }
        let actor = self.actor()?;
        // 评价门槛看的是**本机观察到的**阅读时长，而不是一个可以随便填的数字。
        // 作业级（chapter_no = 0）要 60 秒，单话要 30 秒，与 Web 版一致。
        // 想靠手填蒙混过关，先过本机这关。
        let required = if chapter_no > 0 { MIN_REVIEW_SECONDS_CHAPTER } else { MIN_REVIEW_SECONDS_WORK };
        let have = self.read_seconds_of(&actor, novel_id, chapter_no);
        if have < required {
            return Err(format!(
                "review.needRead:{}:{}:{}",
                have,
                required,
                if chapter_no > 0 { "chapter" } else { "work" }
            ));
        }
        let nonce = random_suffix();
        let b = ReviewBody {
            novel_id: novel_id.to_string(),
            chapter_no,
            body: body.to_string(),
            rating: rating.clamp(0, 5),
            spoiler,
        };
        self.new_op(
            OpKind::ReviewPut,
            &review_key(&actor, novel_id, chapter_no, &nonce),
            serde_json::to_value(b).map_err(|e| e.to_string())?,
        )?;
        // 有效评价（≥20 字）才算一次可验证行为
        if body.chars().count() >= 20 {
            // 与 Web 版同一 target：作品 id（不含章节号）。
            let _ = self.grant(RewardAction::Review, novel_id, None);
        }
        Ok(())
    }

    pub fn add_reaction(&mut self, novel_id: &str, kind: &str) -> Result<(), String> {
        let actor = self.actor()?;
        let kind = match kind {
            "insightful" => ReactionKind::Insightful,
            "cry" => ReactionKind::Cry,
            _ => ReactionKind::Like,
        };
        let b = ReactionBody { novel_id: novel_id.to_string(), kind };
        self.new_op(
            OpKind::ReactionAdd,
            &reaction_key(&actor, novel_id, kind.as_str()),
            serde_json::to_value(b).map_err(|e| e.to_string())?,
        )?;
        // Web 版三种表情都发 like 奖励，target 带具体种类。
        let _ = self.grant(
            RewardAction::Like,
            &format!("{novel_id}:{}", kind.as_str()),
            None,
        );
        Ok(())
    }

    pub fn set_progress(&mut self, novel_id: &str, chapter_no: u32) -> Result<(), String> {
        let actor = self.actor()?;
        let b = ProgressBody {
            novel_id: novel_id.to_string(),
            chapter_no,
            at: iso_of_ms(now_ms()),
        };
        self.new_op(
            OpKind::ProgressSet,
            &progress_key(&actor, novel_id),
            serde_json::to_value(b).map_err(|e| e.to_string())?,
        )
        .map(|_| ())
    }

    /// 读完一话：记录 PV（集合语义）+ 按停留时长发币。
    ///
    /// PV 与奖励币共用「停留 2.5 秒」这个门槛：防误触也防刷量 ——
    /// 手快不算本事，坐得住才算。
    pub fn finish_reading(
        &mut self,
        novel_id: &str,
        chapter_no: u32,
        dwell_ms: u64,
        words: u64,
    ) -> Result<i64, String> {
        let b = ViewBody { novel_id: novel_id.to_string(), chapter_no };
        let actor = self.actor()?;
        self.new_op(
            OpKind::ViewAdd,
            &view_key(&actor, novel_id, chapter_no),
            serde_json::to_value(b).map_err(|e| e.to_string())?,
        )?;
        let amount = wallet::reading_reward(dwell_ms, words);
        if amount > 0 {
            // 与 Web 版同一 target：`<novelId>:<chapterNo>`
            self.grant(RewardAction::ReadChapter, &format!("{novel_id}:{chapter_no}"), Some(amount))?;
        }
        Ok(amount)
    }

    /// 记一次阅读时长事件。
    ///
    /// 时长不是可累加的计数器（那会让归约依赖到达顺序），而是一串离散事件；
    /// 总时长 = 所有事件秒数之和。阅读器每累计 30 秒记一条。
    /// 秒数上限 120：伪造一个天文数字也不会把门槛一次性刷穿 ——
    /// 除非你真的一口气坐了两分钟。
    pub fn record_read_tick(&mut self, novel_id: &str, chapter_no: u32, seconds: u32) -> Result<(), String> {
        let seconds = seconds.min(120);
        if novel_id.is_empty() || seconds == 0 {
            return Ok(());
        }
        let actor = self.actor()?;
        let seq = random_suffix();
        let body = ReadTickBody {
            novel_id: novel_id.to_string(),
            chapter_no,
            seconds,
        };
        self.new_op(
            OpKind::ReadTick,
            &read_tick_key(&actor, novel_id, chapter_no, &seq),
            serde_json::to_value(body).map_err(|e| e.to_string())?,
        )
        .map(|_| ())
    }

    /// 某身份在某部作品上的累计阅读秒数。
    /// `chapter_no = 0` 表示整部作品（各话累加）。
    pub fn read_seconds_of(&self, peer: &str, novel_id: &str, chapter_no: u32) -> u64 {
        if peer.is_empty() {
            return 0;
        }
        self.state
            .read_ticks
            .values()
            .filter(|t| t.actor == peer && t.novel_id == novel_id)
            .filter(|t| chapter_no == 0 || t.chapter_no == chapter_no)
            .map(|t| t.seconds as u64)
            .sum()
    }

    /// 本机身份在某部作品上的累计阅读秒数。
    pub fn my_read_seconds(&self, novel_id: &str, chapter_no: u32) -> u64 {
        let me = self.peer_id();
        self.read_seconds_of(&me, novel_id, chapter_no)
    }

    /// 某身份在某部作品上读过的章节数（去重）。
    pub fn read_chapters_of(&self, peer: &str, novel_id: &str) -> u64 {
        self.state
            .read_ticks
            .values()
            .filter(|t| t.actor == peer && t.novel_id == novel_id)
            .map(|t| t.chapter_no)
            .collect::<BTreeSet<_>>()
            .len() as u64
    }

    /* -------- 社区授予勋章 -------- */

    /// 授予一枚勋章。自授无效；勋章目录之外的 id 直接拒绝。
    pub fn grant_badge(&mut self, target_peer: &str, badge_id: &str, note: &str) -> Result<(), String> {
        let actor = self.actor()?;
        if target_peer.is_empty() {
            return Err("授予对象不能为空".into());
        }
        if target_peer == actor {
            return Err("不能给自己授予勋章".into());
        }
        if badge_def(badge_id).is_none() {
            return Err(format!("未知的勋章：{badge_id}"));
        }
        let note = note.trim();
        let body = BadgeGrantBody {
            target_peer: target_peer.to_string(),
            badge_id: badge_id.to_string(),
            note: if note.is_empty() { None } else { Some(note.to_string()) },
            granter_name: Some(self.pen_name()),
        };
        self.new_op(
            OpKind::BadgeGrant,
            &badge_grant_key(target_peer, badge_id, &actor),
            serde_json::to_value(body).map_err(|e| e.to_string())?,
        )
        .map(|_| ())
    }

    /// 零散贡献声明（校对 / 评审 / 插图 / 资料）。
    ///
    /// 签名只能证明「这条声明是这个人发的」，证明不了数量；
    /// 所以它不参与按量加权，界面也只按类别展示。
    pub fn put_contribution(
        &mut self,
        novel_id: &str,
        kind: &str,
        items: u32,
        scope: &str,
        note: &str,
    ) -> Result<(), String> {
        if novel_id.is_empty() {
            return Err("作品不能为空".into());
        }
        if self.state.novels.get(novel_id).is_none() {
            return Err("作品不存在".into());
        }
        let kind = match kind {
            "proofread" | "review" | "illustration" => kind,
            _ => "research",
        };
        let actor = self.actor()?;
        let body = ContributionBody {
            novel_id: novel_id.to_string(),
            kind: kind.to_string(),
            items: items.min(100_000),
            scope: Some(scope.trim().to_string()).filter(|s| !s.is_empty()),
            note: Some(note.trim().to_string()).filter(|s| !s.is_empty()),
            contributor_name: Some(self.pen_name()),
        };
        self.new_op(
            OpKind::ContribPut,
            &contrib_key(novel_id, &actor),
            serde_json::to_value(body).map_err(|e| e.to_string())?,
        )
        .map(|_| ())
    }

    pub fn set_profile(&mut self, name: &str, bio: &str) -> Result<(), String> {
        let actor = self.actor()?;
        let prev = self.state.profiles.get(&actor);
        let derived = self.identity.as_ref().map(|i| i.pen_name()).unwrap_or_default();
        let name_changed_at = if !name.is_empty() && name != derived && prev.map(|p| p.name.as_str()) != Some(name) {
            Some(now_ms() as i64)
        } else {
            prev.map(|p| p.name_changed_at)
        };
        let b = ProfileBody {
            id: actor.clone(),
            name: if name.is_empty() { derived } else { name.to_string() },
            bio: bio.to_string(),
            avatar_seed: prev.and_then(|p| p.avatar_seed.clone()),
            links: prev.map(|p| p.links.clone()).unwrap_or_default(),
            name_changed_at,
        };
        self.new_op(
            OpKind::ProfilePut,
            &profile_key(&actor),
            serde_json::to_value(b).map_err(|e| e.to_string())?,
        )
        .map(|_| ())
    }

    /// 保存站外链接。name / bio / 改名时间原样保留，
    /// 否则只改链接会把资料写成空串（与 Web 版 `links.tsx` 的注释同源）。
    pub fn set_profile_links(&mut self, links: Vec<ProfileLink>) -> Result<(), String> {
        let actor = self.actor()?;
        let prev = self.state.profiles.get(&actor);
        let derived = self.identity.as_ref().map(|i| i.pen_name()).unwrap_or_default();
        let b = ProfileBody {
            id: actor.clone(),
            name: prev
                .map(|p| p.name.clone())
                .filter(|n| !n.is_empty())
                .unwrap_or(derived),
            bio: prev.map(|p| p.bio.clone()).unwrap_or_default(),
            avatar_seed: prev.and_then(|p| p.avatar_seed.clone()),
            links,
            name_changed_at: prev.map(|p| p.name_changed_at),
        };
        self.new_op(
            OpKind::ProfilePut,
            &profile_key(&actor),
            serde_json::to_value(b).map_err(|e| e.to_string())?,
        )
        .map(|_| ())
    }

    pub fn set_star(&mut self, novel_id: &str, on: bool) -> Result<(), String> {
        let actor = self.actor()?;
        let b = StarBody { novel_id: novel_id.to_string(), on };
        self.new_op(
            OpKind::StarAdd,
            &star_key(&actor, novel_id),
            serde_json::to_value(b).map_err(|e| e.to_string())?,
        )
        .map(|_| ())
    }

    pub fn put_translation(
        &mut self,
        novel_id: &str,
        chapter_no: u32,
        lang: &str,
        paragraphs: Vec<String>,
        note: Option<String>,
        translator: Option<String>,
    ) -> Result<(), String> {
        if paragraphs.is_empty() {
            return Err("译文段落不能为空".into());
        }
        let actor = self.actor()?;
        let note = note.and_then(|n| {
            let n = n.trim().to_string();
            (!n.is_empty()).then_some(n)
        });
        let translator = translator.and_then(|t| {
            let t = t.trim().to_string();
            (!t.is_empty()).then_some(t)
        });
        let b = TranslationBody {
            novel_id: novel_id.to_string(),
            chapter_no,
            lang: lang.to_string(),
            paragraphs,
            note,
            translator: Some(translator.unwrap_or_else(|| self.pen_name())),
        };
        self.new_op(
            OpKind::TranslationPut,
            // 与 Web 版同一 key 形状：同一 (章节, 语言, 译者) 才互相覆盖，
            // 少了 actor 会让后发的译本覆盖前一位译者的作品。
            &format!("translation:{novel_id}:{chapter_no}:{lang}:{actor}"),
            serde_json::to_value(b).map_err(|e| e.to_string())?,
        )
        .map(|_| ())
    }

    /* -------- 奖励币：算得清，才敢发 -------- */

    /// 发一笔奖励。幂等键由「身份 + 行为 + 目标 + 日桶」决定，
    /// 所以同一天重复做同一件事不会重复发币 —— 勤快可以，贪心不行。
    pub fn grant(
        &mut self,
        action: RewardAction,
        target: &str,
        amount: Option<i64>,
    ) -> Result<(), String> {
        let actor = self.actor()?;
        let key = wallet::reward_key(&actor, action, target, now_ms());
        self.grant_with_key(&actor, amount.unwrap_or(action.rate()), action, target, key)
    }

    fn grant_with_key(
        &mut self,
        to: &str,
        amount: i64,
        action: RewardAction,
        target: &str,
        key: String,
    ) -> Result<(), String> {
        if amount <= 0 {
            return Ok(());
        }
        // 日上限只在写入侧拦：归约器必须是纯函数，不能读「今天」
        if let Some(cap) = action.daily_cap() {
            let today: i64 = self
                .state
                .rewards
                .values()
                .filter(|r| r.to == to && r.action == action.as_str() && r.key.ends_with(&day_bucket()))
                .map(|r| r.amount)
                .sum();
            if today + amount > cap {
                return Ok(());
            }
        }
        let b = RewardBody {
            idempotency_key: key.clone(),
            to: to.to_string(),
            amount,
            action: action.as_str().to_string(),
            target: Some(target.to_string()),
            reason: None,
        };
        self.new_op(OpKind::RewardGrant, &key, serde_json::to_value(b).map_err(|e| e.to_string())?)?;
        Ok(())
    }

    /// 打赏：复用 `reward.transfer`，每一笔的 from 都记在账本里，
    /// 所以「这家出版社累计发了多少」可以被任何人核对 —— 慷慨也留痕。
    pub fn tip(&mut self, to_peer: &str, amount: i64, reason: Option<String>) -> Result<(), String> {
        if to_peer.is_empty() || amount <= 0 {
            return Err("打赏对象或金额不合法".into());
        }
        let actor = self.actor()?;
        if actor == to_peer {
            return Err("不能给自己打赏".into());
        }
        // 与 Web 版一致：余额不足时在界面上明确说不够，而不是先广播再失败。
        let balance = selectors::balance_of(&self.state, &actor);
        if amount > balance {
            return Err(format!("余额不足（当前 {balance}）"));
        }
        let key = format!("tip:{actor}:{to_peer}:{}", random_suffix());
        let b = RewardBody {
            idempotency_key: key.clone(),
            to: to_peer.to_string(),
            amount,
            action: "tip".to_string(),
            target: None,
            reason,
        };
        self.new_op(OpKind::RewardTransfer, &key, serde_json::to_value(b).map_err(|e| e.to_string())?)?;
        Ok(())
    }

    pub fn wallet(&self) -> WalletSummary {
        let me = self.peer_id();
        let wrapped = selectors::wrapped_op_ids(&self.state);
        let locked: i64 = self
            .state
            .rewards
            .values()
            .filter(|r| r.to == me && wrapped.contains(&r.op_id))
            .map(|r| r.amount)
            .sum();
        let ledger: Vec<LedgerEntry> = selectors::ledger_of(&self.state, &me)
            .into_iter()
            .map(|r| LedgerEntry {
                key: r.key.clone(),
                op_id: r.op_id.clone(),
                from: r.from.clone(),
                from_name: self.name_of(&r.from),
                to: r.to.clone(),
                amount: if r.to == me { r.amount } else { -r.amount },
                action: r.action.clone(),
                action_label_key: action_label_key(&r.action).to_string(),
                target: r.target.clone(),
                reason: r.reason.clone(),
                at: r.at.clone(),
                at_ms: crate::domain::hlc::wall_of(&r.at),
                wrapped: wrapped.contains(&r.op_id),
            })
            .collect();
        let mut holder_map: BTreeMap<String, i64> = BTreeMap::new();
        for r in self.state.rewards.values() {
            *holder_map.entry(r.to.clone()).or_insert(0) += r.amount;
        }
        let mut holders: Vec<WalletHolder> = holder_map
            .into_iter()
            .map(|(peer, coins)| WalletHolder {
                name: self.name_of(&peer),
                peer,
                coins,
            })
            .collect();
        holders.sort_by(|a, b| b.coins.cmp(&a.coins).then_with(|| a.peer.cmp(&b.peer)));
        holders.truncate(10);

        let mut income_map: BTreeMap<String, i64> = BTreeMap::new();
        for e in &ledger {
            *income_map.entry(e.action.clone()).or_insert(0_i64) += e.amount;
        }
        let mut income: Vec<WalletIncome> = income_map
            .into_iter()
            .map(|(action, amount)| WalletIncome {
                label_key: action_label_key(&action).to_string(),
                action,
                amount,
            })
            .collect();
        income.sort_by(|a, b| b.amount.cmp(&a.amount).then_with(|| a.action.cmp(&b.action)));

        WalletSummary {
            balance: selectors::balance_of(&self.state, &me),
            total_issued: selectors::total_issued(&self.state),
            locked,
            carousel_spent: selectors::carousel_spent_of(&self.state, &me),
            symbol: wallet::COIN_SYMBOL.to_string(),
            ledger,
            holders,
            income,
            examples: RewardExampleView {
                author_share_rate: RewardAction::AuthorBookmarkShare.rate(),
                author_example: wallet::author_reward(1000, 5000, None),
                read_example: wallet::reading_reward(180_000, 3000),
                idle_example: wallet::reading_reward(5_000, 3000),
            },
        }
    }

    /* -------- 首页轮播位 -------- */

    fn carousel_view(&self, c: &CarouselRecord, me: &str) -> CarouselView {
        CarouselView {
            id: c.id.clone(),
            title: c.title.clone(),
            subtitle: c.subtitle.clone(),
            kind: c.kind.as_str().to_string(),
            target_id: c.target_id.clone(),
            href: c.href.clone(),
            by: c.by.clone(),
            by_name: c.by_name.clone(),
            started_at_ms: c.started_at.max(0) as u64,
            expires_at_ms: c.expires_at.max(0) as u64,
            fee: c.fee,
            mine: !me.is_empty() && c.by == me,
        }
    }

    /// 轮播位页面需要的全部派生状态。`now` 只在读取侧使用，不写回记录。
    pub fn carousel_state(&self) -> CarouselStateView {
        let me = self.peer_id();
        let now = now_ms() as i64;
        let active = selectors::active_carousels(&self.state, now)
            .into_iter()
            .map(|c| self.carousel_view(c, &me))
            .collect();
        let mut mine: Vec<&CarouselRecord> = self
            .state
            .carousels
            .values()
            .filter(|c| !me.is_empty() && c.by == me)
            .collect();
        mine.sort_by(|a, b| {
            b.started_at
                .cmp(&a.started_at)
                .then_with(|| compare_hlts(&b.at, &a.at))
                .then_with(|| b.id.cmp(&a.id))
        });
        CarouselStateView {
            active,
            mine: mine
                .into_iter()
                .map(|c| self.carousel_view(c, &me))
                .collect(),
            block_reason: selectors::carousel_block_reason(&self.state, &me, now).to_string(),
            balance: selectors::balance_of(&self.state, &me),
            fee: CAROUSEL_FEE,
            slots: CAROUSEL_SLOTS as u32,
            window_days: (CAROUSEL_WINDOW_MS / (24 * 60 * 60 * 1000)) as u32,
            spent: selectors::carousel_spent_of(&self.state, &me),
            cooldown_ms: selectors::carousel_cooldown_remaining(&self.state, &me, now) as u64,
            peer_id: me,
        }
    }

    /// 购买首页轮播位。
    ///
    /// 费用不走 `reward.transfer`：那条路径只增加收款方余额，用它「付款」
    /// 等于凭空造币。费用由 `carousel.put` 记录，`balance_of` 派生余额时扣除，
    /// 醒目可以，印钞不行。
    pub fn submit_carousel(
        &mut self,
        title: &str,
        subtitle: &str,
        kind: &str,
        target_id: &str,
        href: &str,
        by_name: &str,
    ) -> Result<String, String> {
        let actor = self.actor()?;
        let title = title.trim();
        if title.is_empty() {
            return Err("carousel-title".into());
        }
        let Some(href) = normalize_href(href) else {
            return Err("carousel-href".into());
        };
        let now = now_ms() as i64;
        let reason = selectors::carousel_block_reason(&self.state, &actor, now);
        if reason != "none" {
            return Err(format!("carousel-{reason}"));
        }
        let suffix = actor
            .chars()
            .rev()
            .take(6)
            .collect::<String>()
            .chars()
            .rev()
            .collect::<String>();
        let id = format!(
            "car-{suffix}-{:x}-{}",
            now_ms(),
            &random_suffix()[..4]
        );
        let by_name = if by_name.trim().is_empty() {
            self.pen_name()
        } else {
            by_name.trim().to_string()
        };
        let b = CarouselBody {
            title: crate::domain::carousel::truncate_chars(title, CAROUSEL_MAX_TITLE),
            subtitle: crate::domain::carousel::truncate_chars(
                subtitle.trim(),
                CAROUSEL_MAX_SUBTITLE,
            ),
            kind: CarouselKind::parse(kind),
            target_id: {
                let t = target_id.trim();
                if t.is_empty() {
                    None
                } else {
                    Some(crate::domain::carousel::truncate_chars(t, 200))
                }
            },
            href,
            by_name: crate::domain::carousel::truncate_chars(&by_name, CAROUSEL_MAX_NAME),
        };
        self.new_op(
            OpKind::CarouselPut,
            &carousel_key(&id),
            serde_json::to_value(b).map_err(|e| e.to_string())?,
        )?;
        Ok(id)
    }

    /* -------- 出版社 / 赛事 -------- */

    pub fn put_publisher(
        &mut self,
        name: &str,
        tagline: &str,
        about: &str,
        genres: Vec<String>,
    ) -> Result<String, String> {
        if name.trim().is_empty() {
            return Err("出版社名称不能为空".into());
        }
        let actor = self.actor()?;
        let id = actor.clone();
        let b = PublisherBody {
            name: name.trim().to_string(),
            tagline: tagline.to_string(),
            about: about.to_string(),
            genres,
            verified: false,
        };
        self.new_op(
            OpKind::PublisherPut,
            &publisher_key(&id),
            serde_json::to_value(b).map_err(|e| e.to_string())?,
        )?;
        Ok(id)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn put_contest(
        &mut self,
        publisher_peer: &str,
        theme: &str,
        title: &str,
        kind: &str,
        tagline: &str,
        rules: &str,
        genre: &str,
        deadline: &str,
        announce_at: &str,
        min_words: u64,
        max_words: u64,
        allow_ongoing: bool,
        prizes: Vec<ContestPrize>,
    ) -> Result<String, String> {
        // 与 Web 的 start-contest 表单同一套校验。
        if title.trim().chars().count() < 4 {
            return Err("大赛名称至少 4 个字符".into());
        }
        if max_words > 0 && max_words <= min_words {
            return Err("字数上限必须大于下限".into());
        }
        let actor = self.actor()?;
        let publisher_peer = if publisher_peer.trim().is_empty() {
            actor.as_str()
        } else {
            publisher_peer.trim()
        };
        if publisher_peer != actor {
            return Err("只能以自己的出版社名义举办赛事".into());
        }
        let Some(publisher) = self.state.publishers.get(publisher_peer) else {
            return Err("请先在出版社页入驻，再举办赛事".into());
        };
        let publisher_name = publisher.name.clone();
        let theme = theme.trim();
        let id = format!("c_{}", random_suffix());
        let b = ContestBody {
            publisher_peer: publisher_peer.to_string(),
            publisher_name,
            kind: ContestKind::parse(kind),
            title: title.trim().to_string(),
            tagline: tagline.to_string(),
            rules: rules.to_string(),
            theme: (!theme.is_empty()).then(|| theme.to_string()),
            genre: if genre.is_empty() { "daily" } else { genre }.to_string(),
            deadline: deadline.to_string(),
            announce_at: if announce_at.is_empty() { deadline.to_string() } else { announce_at.to_string() },
            min_words,
            max_words,
            allow_ongoing,
            prizes: prizes
                .into_iter()
                .filter(|p| p.coins > 0 || !p.extras.trim().is_empty())
                .take(10)
                .map(|p| ContestPrize {
                    place: if p.place.trim().is_empty() {
                        "1".to_string()
                    } else {
                        p.place.trim().to_string()
                    },
                    coins: p.coins.max(0),
                    extras: p.extras.trim().to_string(),
                })
                .collect(),
        };
        self.new_op(
            OpKind::ContestPut,
            &contest_key(&id),
            serde_json::to_value(b).map_err(|e| e.to_string())?,
        )?;
        Ok(id)
    }

    pub fn submit_entry(&mut self, contest_id: &str, novel_id: &str) -> Result<(), String> {
        let actor = self.actor()?;
        let Some(novel) = self.state.novels.get(novel_id) else {
            return Err("作品不存在".into());
        };
        if novel.author_peer != actor {
            return Err("只能拿自己的作品报名".into());
        }
        let (ok, reason_key, need, have) = self.check_entry(contest_id, novel_id);
        if !ok {
            return Err(match reason_key.as_str() {
                "contest.check.unknown" => "赛事或作品不存在".into(),
                "contest.check.already" => "这部作品已经报过名了".into(),
                "contest.check.closed" => "赛事已经截止报名".into(),
                "contest.check.deadline" => "已过报名截止时间".into(),
                "contest.check.needCompleted" => "这场赛事只收完结作品".into(),
                "contest.check.wordsShort" => format!("字数不足：至少 {need} 字，当前 {have} 字"),
                "contest.check.wordsOver" => format!("字数超出：最多 {need} 字，当前 {have} 字"),
                _ => "不满足赛事报名条件".into(),
            });
        }
        let b = EntryBody { contest_id: contest_id.to_string(), novel_id: novel_id.to_string(), note: None };
        self.new_op(
            OpKind::EntrySubmit,
            &format!("entry:{contest_id}:{novel_id}"),
            serde_json::to_value(b).map_err(|e| e.to_string())?,
        )
        .map(|_| ())
    }

    /* -------- 联邦审查：屏蔽只在本机生效 -------- */

    pub fn report_novel(
        &mut self,
        novel_id: &str,
        category: &str,
        note: &str,
        chapter_no: Option<u32>,
        reporter_name: Option<String>,
    ) -> Result<(), String> {
        let actor = self.actor()?;
        let reporter_name = reporter_name
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| self.pen_name());
        let b = ReportBody {
            novel_id: novel_id.to_string(),
            chapter_no: chapter_no.filter(|n| *n > 0),
            category: ReportCategory::parse(category),
            note: note.to_string(),
            reporter_name: Some(reporter_name),
        };
        self.new_op(
            OpKind::ReportPut,
            &report_key(novel_id, &actor),
            serde_json::to_value(b).map_err(|e| e.to_string())?,
        )
        .map(|_| ())
    }

    pub fn respond_to_report(&mut self, novel_id: &str, body: &str) -> Result<(), String> {
        let b = RespondBody { novel_id: novel_id.to_string(), body: body.to_string() };
        self.new_op(
            OpKind::ReportRespond,
            &respond_key(novel_id),
            serde_json::to_value(b).map_err(|e| e.to_string())?,
        )
        .map(|_| ())
    }

    pub fn set_exempt(&mut self, novel_id: &str, exempt: bool) -> Result<(), String> {
        if exempt {
            if !self.settings.exempt.contains(&novel_id.to_string()) {
                self.settings.exempt.push(novel_id.to_string());
            }
        } else {
            self.settings.exempt.retain(|x| x != novel_id);
        }
        self.save_settings()
    }

    /* -------- 通用写入口（语义方法还没覆盖的角落） -------- */

    /// 直接提交一条 op（供尚未封装成语义方法的操作使用）
    pub fn submit_raw(&mut self, kind: &str, key: &str, body_json: &str) -> Result<String, String> {
        let kind = parse_op_kind(kind).ok_or_else(|| format!("未知的操作类型：{kind}"))?;
        let body: serde_json::Value = if body_json.trim().is_empty() {
            serde_json::json!({})
        } else {
            serde_json::from_str(body_json).map_err(|e| format!("负载不是合法 JSON：{e}"))?
        };
        let op = self.new_op(kind, key, body)?;
        Ok(op.id)
    }


    /* -------- 协作：议题 -------- */

    /// 开一个议题。任何身份都能开；议题 id 由本机生成。
    pub fn put_issue(&mut self, novel_id: &str, title: &str, body: &str) -> Result<String, String> {
        if title.trim().is_empty() {
            return Err("议题标题不能为空".into());
        }
        if self.state.novels.get(novel_id).is_none() {
            return Err("作品不存在".into());
        }
        let actor = self.actor()?;
        let issue_id = format!("i_{}", random_suffix());
        let b = IssueBody {
            novel_id: novel_id.to_string(),
            issue_id: issue_id.clone(),
            title: title.trim().to_string(),
            body: body.trim().to_string(),
            author_peer: actor,
            author_name: self.pen_name(),
            state: IssueState::Open,
        };
        self.new_op(
            OpKind::IssuePut,
            &issue_key(novel_id, &issue_id),
            serde_json::to_value(b).map_err(|e| e.to_string())?,
        )?;
        Ok(issue_id)
    }

    /// 关闭 / 重开议题：议题作者或作品维护者。
    pub fn close_issue(&mut self, novel_id: &str, issue_id: &str, closed: bool) -> Result<(), String> {
        let key = issue_key(novel_id, issue_id);
        let issue = self
            .state
            .issues
            .get(&key)
            .cloned()
            .ok_or_else(|| "议题不存在".to_string())?;
        let actor = self.actor()?;
        if actor != issue.author_peer && !crate::domain::reducer::is_maintainer(&self.state, novel_id, &actor) {
            return Err("只有议题作者或作品维护者能关闭议题".into());
        }
        let b = IssueCloseBody {
            novel_id: novel_id.to_string(),
            issue_id: issue_id.to_string(),
            state: if closed { IssueState::Closed } else { IssueState::Open },
        };
        self.new_op(
            OpKind::IssueClose,
            &key,
            serde_json::to_value(b).map_err(|e| e.to_string())?,
        )
        .map(|_| ())
    }

    /* -------- 协作：提案与整合 -------- */

    /// 提交一份章节增改提案。基线版本由本机按当前章节自动记下，
    /// 之后章节被改过时界面会标出冲突 —— 冲突不阻止维护者人工整合。
    pub fn put_patch(
        &mut self,
        novel_id: &str,
        title: &str,
        body: &str,
        mut chapters: Vec<PatchChapter>,
    ) -> Result<String, String> {
        if title.trim().is_empty() {
            return Err("提案标题不能为空".into());
        }
        if self.state.novels.get(novel_id).is_none() {
            return Err("作品不存在".into());
        }
        for c in &mut chapters {
            if c.no < 1 {
                return Err("章节号必须从 1 开始".into());
            }
            if let Some(cur) = self.state.chapters.get(&chapter_key(novel_id, c.no)) {
                if !cur.deleted {
                    c.based_on = Some(cur.published_at.clone());
                }
            }
            if c.title.trim().is_empty() {
                c.title = format!("第{}话", c.no);
            }
            if c.words == 0 {
                c.words = c
                    .paragraphs
                    .join("")
                    .chars()
                    .filter(|ch| !ch.is_whitespace())
                    .count() as u64;
            }
            c.contributor = None;
        }
        let chapters = crate::domain::reducer::normalize_patch_chapters(&chapters);
        if chapters.is_empty() {
            return Err("提案里至少要有 1 话有效正文".into());
        }
        let actor = self.actor()?;
        let patch_id = format!("p_{}", random_suffix());
        let b = PatchBody {
            novel_id: novel_id.to_string(),
            patch_id: patch_id.clone(),
            title: title.trim().to_string(),
            body: body.trim().to_string(),
            author_peer: actor,
            author_name: self.pen_name(),
            state: PatchState::Open,
            chapters,
        };
        self.new_op(
            OpKind::PatchPut,
            &patch_key(novel_id, &patch_id),
            serde_json::to_value(b).map_err(|e| e.to_string())?,
        )?;
        Ok(patch_id)
    }

    /// 整合提案。只有维护者（原作者 + 已整合贡献者）能整合。
    pub fn merge_patch(&mut self, novel_id: &str, patch_id: &str, note: &str) -> Result<(), String> {
        let actor = self.actor()?;
        if !crate::domain::reducer::is_maintainer(&self.state, novel_id, &actor) {
            return Err("只有作品维护者能整合提案".into());
        }
        let patch = self
            .state
            .patches
            .get(&patch_key(novel_id, patch_id))
            .cloned()
            .ok_or_else(|| "提案不存在".to_string())?;
        if !matches!(patch.state, PatchState::Open) {
            return Err("提案已经关闭".into());
        }
        if self.state.merges.contains_key(&merge_key(novel_id, patch_id)) {
            return Err("这份提案已经整合过了".into());
        }
        let b = MergeBody {
            novel_id: novel_id.to_string(),
            patch_id: patch_id.to_string(),
            author: patch.author_peer.clone(),
            by: actor,
            chapters: patch.chapters,
            note: Some(note.trim().to_string()).filter(|s| !s.is_empty()),
        };
        self.new_op(
            OpKind::PatchMerge,
            &merge_key(novel_id, patch_id),
            serde_json::to_value(b).map_err(|e| e.to_string())?,
        )?;
        let _ = self.refresh_novel_stats(novel_id);
        Ok(())
    }

    pub fn close_patch(&mut self, novel_id: &str, patch_id: &str, closed: bool) -> Result<(), String> {
        let key = patch_key(novel_id, patch_id);
        let patch = self
            .state
            .patches
            .get(&key)
            .cloned()
            .ok_or_else(|| "提案不存在".to_string())?;
        let actor = self.actor()?;
        if actor != patch.author_peer && !crate::domain::reducer::is_maintainer(&self.state, novel_id, &actor) {
            return Err("只有提案作者或作品维护者能关闭提案".into());
        }
        let b = PatchCloseBody {
            novel_id: novel_id.to_string(),
            patch_id: patch_id.to_string(),
            state: if closed { PatchState::Closed } else { PatchState::Open },
        };
        self.new_op(
            OpKind::PatchClose,
            &key,
            serde_json::to_value(b).map_err(|e| e.to_string())?,
        )
        .map(|_| ())
    }

    /// 给编辑组命名。只有维护者能命名，而且同一个组只能成功命名一次。
    pub fn rename_group(&mut self, novel_id: &str, name: &str) -> Result<(), String> {
        let actor = self.actor()?;
        if !crate::domain::reducer::is_maintainer(&self.state, novel_id, &actor) {
            return Err("只有作品维护者能给编辑组命名".into());
        }
        if self
            .state
            .groups
            .get(&group_key(novel_id))
            .and_then(|g| g.name.as_ref())
            .is_some()
        {
            return Err("编辑组已经命名过了，组名只能改一次".into());
        }
        let name = name.trim();
        if name.is_empty() {
            return Err("组名不能为空".into());
        }
        let b = GroupBody {
            novel_id: Some(novel_id.to_string()),
            name: Some(name.chars().take(40).collect()),
        };
        self.new_op(
            OpKind::GroupPut,
            &group_key(novel_id),
            serde_json::to_value(b).map_err(|e| e.to_string())?,
        )
        .map(|_| ())
    }

    /* -------- 出版社：交易 -------- */

    fn deal_body(record: &DealRecord, status: DealStatus) -> DealBody {
        DealBody {
            deal_id: record.deal_id.clone(),
            novel_id: record.novel_id.clone(),
            novel_title: record.novel_title.clone(),
            author_peer: record.author_peer.clone(),
            author_name: record.author_name.clone(),
            publisher_peer: record.publisher_peer.clone(),
            publisher_name: record.publisher_name.clone(),
            kind: record.kind,
            amount: record.amount,
            terms: record.terms.clone(),
            status,
        }
    }

    /// 出版社发出改编 / 封面赞助要约。
    pub fn offer_deal(
        &mut self,
        novel_id: &str,
        kind: &str,
        amount: i64,
        terms: &str,
    ) -> Result<String, String> {
        if amount < 0 {
            return Err("交易金额不能为负".into());
        }
        let novel = self
            .state
            .novels
            .get(novel_id)
            .cloned()
            .ok_or_else(|| "作品不存在".to_string())?;
        let actor = self.actor()?;
        if actor == novel.author_peer {
            return Err("不能给自己的作品发要约".into());
        }
        // 与 Web 一致：不强制先在出版社页入驻。有出版社记录就用记录里的名字，
        // 没有就用当前笔名 —— 0 金额的封面赞助等场景不应被入驻流程挡住。
        let publisher_name = self
            .state
            .publishers
            .get(&actor)
            .map(|p| p.name.clone())
            .unwrap_or_else(|| self.pen_name());
        let deal_id = format!("d_{}", random_suffix());
        let b = DealBody {
            deal_id: deal_id.clone(),
            novel_id: novel.id.clone(),
            novel_title: novel.title.clone(),
            author_peer: novel.author_peer.clone(),
            author_name: novel.author_name.clone(),
            publisher_peer: actor,
            publisher_name,
            kind: DealKind::parse(kind),
            amount,
            terms: terms.trim().to_string(),
            status: DealStatus::Offered,
        };
        self.new_op(
            OpKind::DealPut,
            &deal_key(&deal_id),
            serde_json::to_value(b).map_err(|e| e.to_string())?,
        )?;
        Ok(deal_id)
    }

    /// 作者接受 / 拒绝要约。
    pub fn respond_deal(&mut self, deal_id: &str, accept: bool) -> Result<(), String> {
        let key = deal_key(deal_id);
        let deal = self
            .state
            .deals
            .get(&key)
            .cloned()
            .ok_or_else(|| "交易不存在".to_string())?;
        let actor = self.actor()?;
        if actor != deal.author_peer {
            return Err("只有原作者能回应这份要约".into());
        }
        if !matches!(deal.status, DealStatus::Offered) {
            return Err("这份要约已经回应过了".into());
        }
        let status = if accept { DealStatus::Accepted } else { DealStatus::Declined };
        let b = Self::deal_body(&deal, status);
        self.new_op(
            OpKind::DealPut,
            &key,
            serde_json::to_value(b).map_err(|e| e.to_string())?,
        )
        .map(|_| ())
    }

    /// 出版社确认付款（按贡献图谱拆账）或取消交易。
    pub fn settle_deal(&mut self, deal_id: &str, pay: bool) -> Result<(), String> {
        let key = deal_key(deal_id);
        let deal = self
            .state
            .deals
            .get(&key)
            .cloned()
            .ok_or_else(|| "交易不存在".to_string())?;
        let actor = self.actor()?;
        if actor != deal.publisher_peer {
            return Err("只有发要约的出版社能结算这份交易".into());
        }
        // 与 Web 一致：付款只允许在作者接受之后；取消允许 offered / accepted。
        // 已经付款或已取消的终态不再处理。
        if pay {
            if !matches!(deal.status, DealStatus::Accepted) {
                return Err("只有作者已接受的交易才能付款".into());
            }
        } else if !matches!(deal.status, DealStatus::Offered | DealStatus::Accepted) {
            return Err("这份交易已经结束，不能再取消".into());
        }
        if pay {
            let balance = selectors::balance_of(&self.state, &actor);
            if deal.amount > balance {
                return Err(format!("余额不足：这份交易需要 {}，当前 {}", deal.amount, balance));
            }
            let graph = selectors::contribution_graph(&self.state, &deal.novel_id);
            let mut parts: Vec<(String, i64, String)> = graph
                .shares
                .iter()
                .map(|s| {
                    (
                        s.peer.clone(),
                        (deal.amount as f64 * s.ratio).floor() as i64,
                        s.kind.clone(),
                    )
                })
                .collect();
            if parts.is_empty() {
                parts.push((deal.author_peer.clone(), deal.amount, "canon".into()));
            }
            let mut allocated: i64 = parts.iter().map(|p| p.1).sum();
            if allocated < deal.amount {
                // 与 Web 的 splitAmount 一致：尾数给正典池里**份额最大**的人，
                // 而不是简单地给第一个正典贡献者。
                let idx = graph
                    .shares
                    .iter()
                    .enumerate()
                    .filter(|(_, s)| s.kind == "canon")
                    .max_by(|(_, a), (_, b)| {
                        a.ratio
                            .partial_cmp(&b.ratio)
                            .unwrap_or(std::cmp::Ordering::Equal)
                            .then(b.peer.cmp(&a.peer))
                    })
                    .map(|(i, _)| i)
                    .unwrap_or(0);
                if let Some(p) = parts.get_mut(idx) {
                    p.1 += deal.amount - allocated;
                    allocated = deal.amount;
                }
            }
            let _ = allocated;
            for (i, (peer, amount, kind)) in parts.iter().enumerate() {
                if *amount <= 0 {
                    continue;
                }
                let rk = format!(
                    "reward:{actor}:adaptation:{deal_id}:{i}:{}",
                    random_suffix()
                );
                let b = RewardBody {
                    idempotency_key: rk.clone(),
                    to: peer.clone(),
                    amount: *amount,
                    action: "adaptation".into(),
                    target: Some(format!("deal:{deal_id}")),
                    reason: Some(format!("改编/赞助报酬·{kind}")),
                };
                self.new_op(
                    OpKind::RewardTransfer,
                    &rk,
                    serde_json::to_value(b).map_err(|e| e.to_string())?,
                )?;
            }
        }
        let status = if pay { DealStatus::Paid } else { DealStatus::Cancelled };
        let b = Self::deal_body(&deal, status);
        self.new_op(
            OpKind::DealPut,
            &key,
            serde_json::to_value(b).map_err(|e| e.to_string())?,
        )
        .map(|_| ())
    }

    /* -------- 证书 / 赛事结果 -------- */

    /// 给别人背书一张作家能力证书。不能自授 —— 证书的价值来自「谁给你背书」。
    pub fn put_certificate(
        &mut self,
        target_peer: &str,
        note: &str,
        started_at: &str,
        years_writing: f64,
        peak_work_title: &str,
        peak_work_clicks: u64,
        peak_year: i32,
    ) -> Result<(), String> {
        let actor = self.actor()?;
        if target_peer.is_empty() {
            return Err("背书对象不能为空".into());
        }
        if target_peer == actor {
            return Err("不能给自己背书证书".into());
        }
        if years_writing < 0.0 || peak_work_clicks == 0 || peak_year <= 0 {
            return Err("证据字段必须包含真实的写作年数与点击量".into());
        }
        let b = CertificateBody {
            target_peer: target_peer.to_string(),
            kind: CertificateKind::AlighieriWriter,
            note: note.trim().to_string(),
            evidence: CertificateEvidence {
                started_at: started_at.to_string(),
                years_writing,
                peak_work_title: peak_work_title.to_string(),
                peak_work_clicks,
                peak_year,
            },
        };
        self.new_op(
            OpKind::CertificatePut,
            &certificate_id(target_peer, &actor),
            serde_json::to_value(b).map_err(|e| e.to_string())?,
        )
        .map(|_| ())
    }

    /// 公布赛事名次。只有主办方能公布；作品标题与作者从本机副本补全。
    pub fn publish_contest_result(
        &mut self,
        contest_id: &str,
        placements: Vec<(u32, String, Option<String>)>,
    ) -> Result<(), String> {
        let contest = self
            .state
            .contests
            .get(contest_id)
            .cloned()
            .ok_or_else(|| "赛事不存在".to_string())?;
        let actor = self.actor()?;
        if actor != contest.publisher_peer {
            return Err("只有赛事主办方能公布结果".into());
        }
        let mut out: Vec<ContestPlacement> = Vec::new();
        for (place, novel_id, note) in placements.into_iter().take(10) {
            if place < 1 || place > 99 || novel_id.is_empty() {
                continue;
            }
            let Some(novel) = self.state.novels.get(&novel_id) else {
                continue;
            };
            out.push(ContestPlacement {
                place,
                novel_id: novel.id.clone(),
                novel_title: novel.title.clone(),
                author_peer: novel.author_peer.clone(),
                author_name: novel.author_name.clone(),
                note: note.map(|s| s.trim().to_string()).filter(|s| !s.is_empty()),
            });
        }
        if out.is_empty() {
            return Err("至少要有 1 部有效作品".into());
        }
        out.sort_by_key(|p| p.place);
        let b = ContestResultBody {
            contest_id: contest_id.to_string(),
            publisher_peer: actor,
            placements: out,
        };
        self.new_op(
            OpKind::ContestResult,
            &contest_result_key(contest_id),
            serde_json::to_value(b).map_err(|e| e.to_string())?,
        )
        .map(|_| ())
    }

    /// 发赛事奖金：金额来自**主办方当初公布的奖项**，不允许界面临时改数。
    /// 只有主办方能发；已发过的不再重复发（同一赛事 + 作品只发一次）。
    pub fn pay_contest_prize(&mut self, contest_id: &str, novel_id: &str) -> Result<(), String> {
        let contest = self
            .state
            .contests
            .get(contest_id)
            .cloned()
            .ok_or_else(|| "赛事不存在".to_string())?;
        let actor = self.actor()?;
        if actor != contest.publisher_peer {
            return Err("只有赛事主办方能发放奖金".into());
        }
        let result = self
            .state
            .contest_results
            .get(&contest_result_key(contest_id))
            .cloned()
            .ok_or_else(|| "名次尚未公布".to_string())?;
        let placement = result
            .placements
            .iter()
            .find(|p| p.novel_id == novel_id)
            .ok_or_else(|| "这部作品不在公布的名次里".to_string())?;
        let prize = contest
            .prizes
            .iter()
            .find(|p| p.place == placement.place.to_string())
            .ok_or_else(|| "这场赛事没有为该名次设置奖金".to_string())?;
        if prize.coins <= 0 {
            return Err("该名次只有附加权益，没有奖金".into());
        }
        if selectors::contest_prize_paid(
            &self.state,
            contest_id,
            &placement.author_peer,
            &actor,
        ) {
            return Err("这笔奖金已经发过了".into());
        }
        let balance = selectors::balance_of(&self.state, &actor);
        if prize.coins > balance {
            return Err(format!("余额不足（当前 {balance}）"));
        }
        let marker = format!("prize:{contest_id}:{novel_id}");
        let key = format!("prize:{actor}:{novel_id}:{}", random_suffix());
        let b = RewardBody {
            idempotency_key: key.clone(),
            to: placement.author_peer.clone(),
            amount: prize.coins,
            action: "prize".to_string(),
            target: Some(novel_id.to_string()),
            reason: Some(marker),
        };
        self.new_op(
            OpKind::RewardTransfer,
            &key,
            serde_json::to_value(b).map_err(|e| e.to_string())?,
        )?;
        Ok(())
    }

    /* -------- 上链：覆盖率 / 申领 -------- */

    /// 本地账本里还能上链的 op（先花最旧的）。
    fn wrappable_ledger(&self) -> (i64, i64, Vec<(String, i64, String)>) {
        let me = self.peer_id();
        if me.is_empty() {
            return (0, 0, Vec::new());
        }
        let wrapped = selectors::wrapped_op_ids(&self.state);
        let mut ledger: Vec<(String, i64, String)> = self
            .state
            .rewards
            .values()
            .filter(|r| r.to == me && !wrapped.contains(&r.op_id))
            .map(|r| (r.op_id.clone(), r.amount, r.at.clone()))
            .collect();
        ledger.sort_by(|a, b| a.2.cmp(&b.2).then(a.0.cmp(&b.0)));
        let available = ledger.iter().map(|x| x.1).sum();
        let locked: i64 = self
            .state
            .rewards
            .values()
            .filter(|r| r.to == me && wrapped.contains(&r.op_id))
            .map(|r| r.amount)
            .sum();
        (available, locked, ledger)
    }

    pub fn wrap_coverage(&self) -> WrapCoverageView {
        let (available, locked, ledger) = self.wrappable_ledger();
        let me = self.peer_id();
        let config_errors = bridge_config_errors(&self.settings);
        let configured = bridge_configured(&self.settings) && config_errors.is_empty();
        let ops = ledger
            .iter()
            .filter_map(|(op_id, amount, _)| {
                self.state
                    .rewards
                    .values()
                    .find(|r| r.op_id == *op_id)
                    .map(|r| WrappableOpView {
                        op_id: op_id.clone(),
                        amount: *amount,
                        action: r.action.clone(),
                        action_label_key: action_label_key(&r.action).to_string(),
                        reason: r.reason.clone(),
                        at_ms: crate::domain::hlc::wall_of(&r.at),
                    })
            })
            .collect();
        WrapCoverageView {
            configured,
            config_errors,
            peer_id: me.clone(),
            balance: selectors::balance_of(&self.state, &me),
            wrapped: locked,
            available,
            pending: 0,
            node_reachable: false,
            node_total: 0,
            node_available: 0,
            node_wrapped: 0,
            ops,
        }
    }

    /// 构造并签名一次上链申领。挑 op 与校验都在 Rust 侧做，
    /// 网络请求由 Dart 侧发出（签名不能离开本机）。
    pub fn build_wrap_request(&self, amount: i64, to_address: &str) -> Result<WrapRequestView, String> {
        if amount <= 0 || amount > bridge::MAX_WRAP_PER_CLAIM {
            return Err("申领数量不合法".into());
        }
        if !bridge::is_evm_address(to_address) {
            return Err("收款地址不是合法的 EVM 地址".into());
        }
        if !bridge_configured(&self.settings) {
            return Err("上链桥接尚未配置".into());
        }
        let errors = bridge_config_errors(&self.settings);
        if !errors.is_empty() {
            return Err(errors.join("；"));
        }
        let me = self.peer_id();
        let (_, _, ledger) = self.wrappable_ledger();
        let available: Vec<(String, i64)> = ledger.iter().map(|x| (x.0.clone(), x.1)).collect();
        let op_ids = bridge::select_wrappable_ops(&available, amount)
            .ok_or_else(|| "可上链额度不足".to_string())?;
        let claim = bridge::WrapClaim {
            peer_id: me,
            amount,
            op_ids,
            to_address: to_address.to_lowercase(),
            nonce: format!("{}{}", random_suffix(), random_suffix()),
        };
        let hash = bridge::hash_wrap_payload(&claim);
        let payload = bridge::canonical_wrap_payload(&claim);
        let signature = self
            .identity
            .as_ref()
            .and_then(|i| i.sign_base64(&payload))
            .ok_or_else(|| "身份私钥不可用，无法签名".to_string())?;
        Ok(WrapRequestView {
            peer_id: claim.peer_id,
            amount: claim.amount,
            op_ids: claim.op_ids,
            to_address: claim.to_address,
            nonce: claim.nonce,
            hash,
            signature,
        })
    }

    /// 桥接节点成功铸币后，把这次上链固化进本机账本。
    pub fn record_wrap(
        &mut self,
        amount: i64,
        op_ids: Vec<String>,
        to_address: &str,
        chain_id: u64,
        tx_hash: &str,
        onchain_id: &str,
    ) -> Result<(), String> {
        if amount <= 0 || op_ids.is_empty() {
            return Err("上链记录不完整".into());
        }
        let key = bridge::wrap_id_for(&op_ids);
        if self.state.wraps.contains_key(&key) {
            return Ok(());
        }
        let b = WrapBody {
            idempotency_key: key.clone(),
            from: self.peer_id(),
            amount,
            op_ids,
            to_address: to_address.to_lowercase(),
            chain_id,
            tx_hash: tx_hash.to_string(),
            onchain_id: onchain_id.to_string(),
        };
        self.new_op(
            OpKind::RewardWrap,
            &key,
            serde_json::to_value(b).map_err(|e| e.to_string())?,
        )
        .map(|_| ())
    }

    /* -------- 查询（只读，不碰副本） -------- */

    pub fn novels(&self, params: SearchParams) -> Vec<NovelCard> {
        let policy = self.review_policy();
        let cards = selectors::build_novel_cards(
            &self.state,
            Some(&self.peer_id()),
            &policy,
            now_ms(),
        );
        catalog::search_novels(&cards, &params)
    }

    pub fn ranking(&self, period: &str, genre: &str) -> Vec<NovelCard> {
        let policy = self.review_policy();
        let cards = selectors::build_novel_cards(&self.state, Some(&self.peer_id()), &policy, now_ms());
        let filtered: Vec<NovelCard> = if genre.is_empty() || genre == "all" {
            cards
        } else {
            cards.into_iter().filter(|c| c.genre == genre).collect()
        };
        catalog::rank_novels(&filtered, RankingPeriod::parse(period), now_ms())
    }

    pub fn novel(&self, id: &str) -> Option<NovelCard> {
        let policy = self.review_policy();
        selectors::build_novel_cards(&self.state, Some(&self.peer_id()), &policy, now_ms())
            .into_iter()
            .find(|c| c.id == id)
    }

    pub fn chapters(&self, novel_id: &str) -> Vec<ChapterView> {
        selectors::build_chapter_views(&self.state, novel_id)
    }

    pub fn reviews(&self, novel_id: &str) -> Vec<ReviewView> {
        selectors::reviews_of(&self.state, novel_id)
            .into_iter()
            .map(|r| ReviewView {
                id: r.id.clone(),
                actor: r.actor.clone(),
                author_name: self.name_of(&r.actor),
                novel_id: r.novel_id.clone(),
                chapter_no: r.chapter_no,
                body: r.body.clone(),
                rating: r.rating,
                spoiler: r.spoiler,
                created_at: r.created_at.clone(),
                created_at_ms: crate::domain::hlc::wall_of(&r.created_at),
            })
            .collect()
    }

    pub fn translations(&self, novel_id: &str, chapter_no: u32, lang: &str) -> Vec<TranslationView> {
        let mut out: Vec<TranslationView> = self
            .state
            .translations
            .values()
            .filter(|t| t.novel_id == novel_id && t.chapter_no == chapter_no && (lang.is_empty() || t.lang == lang))
            .map(|t| TranslationView {
                novel_id: t.novel_id.clone(),
                chapter_no: t.chapter_no,
                lang: t.lang.clone(),
                actor: t.actor.clone(),
                translator: t.translator.clone(),
                paragraphs: t.paragraphs.clone(),
                note: t.note.clone(),
                at_ms: crate::domain::hlc::wall_of(&t.at),
            })
            .collect();
        out.sort_by(|a, b| b.at_ms.cmp(&a.at_ms));
        out
    }

    pub fn contests(&self) -> Vec<ContestCard> {
        let now = now_ms();
        let me = self.peer_id();
        self.state
            .contests
            .values()
            .map(|c| {
                let status = contest::contest_status(&c.deadline, &c.announce_at, now);
                let entries = self.state.entries.values().filter(|e| e.contest_id == c.id).count() as u64;
                ContestCard {
                    id: c.id.clone(),
                    publisher_peer: c.publisher_peer.clone(),
                    publisher_name: c.publisher_name.clone(),
                    kind: c.kind.as_str().to_string(),
                    title: c.title.clone(),
                    tagline: c.tagline.clone(),
                    rules: c.rules.clone(),
                    theme: c.theme.clone(),
                    genre: c.genre.clone(),
                    deadline: c.deadline.clone(),
                    announce_at: c.announce_at.clone(),
                    min_words: c.min_words,
                    max_words: c.max_words,
                    allow_ongoing: c.allow_ongoing,
                    status: status.as_str().to_string(),
                    days_left: crate::domain::time::days_left(&c.deadline, now),
                    entries,
                    my_entry: self
                        .state
                        .entries
                        .values()
                        .find(|e| e.contest_id == c.id && e.actor == me)
                        .map(|e| e.novel_id.clone()),
                    has_result: self.state.contest_results.contains_key(&contest_result_key(&c.id)),
                    prizes: c
                        .prizes
                        .iter()
                        .map(|p| ContestPrizeView {
                            place: p.place.clone(),
                            coins: p.coins,
                            extras: p.extras.clone(),
                        })
                        .collect(),
                }
            })
            .collect()
    }

    /// 某场赛事的报名列表。主办方公布名次、读者核对参赛作品都看这份数据。
    pub fn contest_entries(&self, contest_id: &str) -> Vec<ContestEntryView> {
        let mut out: Vec<ContestEntryView> = self
            .state
            .entries
            .values()
            .filter(|e| e.contest_id == contest_id)
            .map(|e| {
                let novel = self.state.novels.get(&e.novel_id);
                ContestEntryView {
                    contest_id: e.contest_id.clone(),
                    novel_id: e.novel_id.clone(),
                    novel_title: novel
                        .map(|n| n.title.clone())
                        .unwrap_or_else(|| e.novel_id.clone()),
                    author_peer: novel
                        .map(|n| n.author_peer.clone())
                        .unwrap_or_else(|| e.actor.clone()),
                    author_name: novel
                        .map(|n| n.author_name.clone())
                        .unwrap_or_default(),
                    at_ms: crate::domain::hlc::wall_of(&e.at),
                }
            })
            .collect();
        out.sort_by(|a, b| a.at_ms.cmp(&b.at_ms).then(a.novel_id.cmp(&b.novel_id)));
        out
    }

    /// 某场赛事的公布结果。按名次排序；未公布时返回空列表。
    pub fn contest_results(&self, contest_id: &str) -> Vec<ContestPlacementView> {        let Some(record) = self.state.contest_results.get(&contest_result_key(contest_id)) else {
            return Vec::new();
        };
        let mut out: Vec<ContestPlacementView> = record
            .placements
            .iter()
            .map(|p| ContestPlacementView {
                place: p.place,
                novel_id: p.novel_id.clone(),
                novel_title: p.novel_title.clone(),
                author_peer: p.author_peer.clone(),
                author_name: p.author_name.clone(),
                note: p.note.clone(),
                prize_paid: selectors::contest_prize_paid(
                    &self.state,
                    contest_id,
                    &p.author_peer,
                    &record.publisher_peer,
                ),
            })
            .collect();
        out.sort_by_key(|p| p.place);
        out
    }

    /// 报名前的规则自检：给出具体差距，而不是让作者白忙一场
    pub fn check_entry(&self, contest_id: &str, novel_id: &str) -> (bool, String, i64, i64) {
        let now = now_ms();
        let Some(c) = self.state.contests.get(contest_id) else {
            return (false, "contest.check.unknown".into(), 0, 0);
        };
        let status = contest::contest_status(&c.deadline, &c.announce_at, now);
        let Some(n) = self.state.novels.get(novel_id) else {
            return (false, "contest.check.unknown".into(), 0, 0);
        };
        let already = self
            .state
            .entries
            .values()
            .any(|e| e.contest_id == contest_id && e.actor == self.peer_id());
        let r = contest::check_entry(
            status,
            &c.deadline,
            c.min_words,
            c.max_words,
            c.allow_ongoing,
            n.words,
            n.status.as_str(),
            already,
            now,
        );
        (r.ok, r.reason_key, r.need, r.have)
    }

    pub fn publishers(&self) -> Vec<PublisherCard> {
        let now = now_ms();
        self.state
            .publishers
            .values()
            .map(|p| {
                // 与 Web 的 publishers-client 一致：作品按作者身份归属出版社。
                let works: Vec<&crate::domain::model::ReplicaNovel> = self
                    .state
                    .novels
                    .values()
                    .filter(|n| n.author_peer == p.peer && !n.deleted)
                    .collect();
                let authors: BTreeSet<&str> =
                    works.iter().map(|n| n.author_peer.as_str()).collect();
                let contests: Vec<_> = self
                    .state
                    .contests
                    .values()
                    .filter(|c| c.publisher_peer == p.peer)
                    .collect();
                let open_contests = contests
                    .iter()
                    .filter(|c| {
                        contest::contest_status(&c.deadline, &c.announce_at, now)
                            == contest::ContestStatus::Open
                    })
                    .count() as u64;
                let rewards_paid: i64 = self
                    .state
                    .rewards
                    .values()
                    .filter(|r| r.from == p.peer && r.action == "prize")
                    .map(|r| r.amount)
                    .sum();
                PublisherCard {
                    id: p.id.clone(),
                    peer: p.peer.clone(),
                    name: p.name.clone(),
                    tagline: p.tagline.clone(),
                    about: p.about.clone(),
                    genres: p.genres.clone(),
                    verified: p.verified,
                    contests: contests.len() as u64,
                    open_contests,
                    works: works.len() as u64,
                    authors: authors.len() as u64,
                    rewards_paid,
                    deals: self
                        .state
                        .deals
                        .values()
                        .filter(|d| d.publisher_peer == p.peer)
                        .count() as u64,
                    updated_at_ms: crate::domain::hlc::wall_of(&p.updated_at),
                }
            })
            .collect()
    }

    pub fn reports(&self) -> Vec<ReportCard> {
        self.state
            .reports
            .values()
            .map(|r| ReportCard {
                id: r.id.clone(),
                novel_id: r.novel_id.clone(),
                novel_title: self
                    .state
                    .novels
                    .get(&r.novel_id)
                    .map(|n| n.title.clone())
                    .unwrap_or_default(),
                reporter: r.reporter.clone(),
                reporter_name: r.reporter_name.clone(),
                chapter_no: r.chapter_no,
                category: r.category.as_str().to_string(),
                note: r.note.clone(),
                at_ms: crate::domain::hlc::wall_of(&r.at),
                response: self
                    .state
                    .responses
                    .get(&respond_key(&r.novel_id))
                    .map(|x| x.body.clone()),
            })
            .collect()
    }


    /* -------- 协作 / 贡献 / 交易查询 -------- */

    pub fn issues(&self, novel_id: &str) -> Vec<IssueCard> {
        selectors::issue_cards(&self.state, novel_id, &self.peer_id())
    }

    pub fn patches(&self, novel_id: &str) -> Vec<PatchCard> {
        selectors::patch_cards(&self.state, novel_id, &self.peer_id())
    }

    pub fn merges(&self, novel_id: &str) -> Vec<MergeCard> {
        selectors::merge_cards(&self.state, novel_id)
    }

    pub fn contributors(&self, novel_id: &str) -> Vec<ContributorCard> {
        selectors::contributor_cards(&self.state, novel_id)
    }

    pub fn contribution_graph(&self, novel_id: &str) -> ContributionGraphView {
        selectors::contribution_graph(&self.state, novel_id)
    }

    pub fn group(&self, novel_id: &str) -> GroupCard {
        selectors::group_card(&self.state, novel_id)
    }

    pub fn forks_of(&self, novel_id: &str) -> Vec<ForkCard> {
        selectors::forks_of(&self.state, novel_id)
    }

    pub fn fork_source(&self, novel_id: &str) -> Option<ForkCard> {
        selectors::fork_source(&self.state, novel_id)
    }

    pub fn awards(&self, novel_id: &str) -> Vec<AwardCard> {
        selectors::award_cards(&self.state, novel_id)
    }

    fn deal_card(&self, d: &DealRecord) -> DealCard {
        let me = self.peer_id();
        DealCard {
            id: d.id.clone(),
            deal_id: d.deal_id.clone(),
            novel_id: d.novel_id.clone(),
            novel_title: d.novel_title.clone(),
            author_peer: d.author_peer.clone(),
            author_name: display_or(&d.author_name, self.name_of(&d.author_peer)),
            publisher_peer: d.publisher_peer.clone(),
            publisher_name: display_or(&d.publisher_name, self.name_of(&d.publisher_peer)),
            kind: d.kind.as_str().to_string(),
            amount: d.amount,
            terms: d.terms.clone(),
            status: d.status.as_str().to_string(),
            at_ms: crate::domain::hlc::wall_of(&d.at),
            paid_on_ledger: selectors::deal_paid_on_ledger(&self.state, d),
            is_author: !me.is_empty() && me == d.author_peer,
            is_publisher: !me.is_empty() && me == d.publisher_peer,
            can_respond: !me.is_empty()
                && me == d.author_peer
                && matches!(d.status, DealStatus::Offered),
            can_settle: !me.is_empty()
                && me == d.publisher_peer
                && matches!(d.status, DealStatus::Accepted),
        }
    }

    pub fn deals_for_novel(&self, novel_id: &str) -> Vec<DealCard> {
        let mut out: Vec<DealCard> = self
            .state
            .deals
            .values()
            .filter(|d| d.novel_id == novel_id)
            .map(|d| self.deal_card(d))
            .collect();
        out.sort_by(|a, b| b.at_ms.cmp(&a.at_ms));
        out
    }

    /// 与我有关的交易（我是作者或出版社）
    pub fn my_deals(&self) -> Vec<DealCard> {
        let me = self.peer_id();
        if me.is_empty() {
            return Vec::new();
        }
        let mut out: Vec<DealCard> = self
            .state
            .deals
            .values()
            .filter(|d| d.author_peer == me || d.publisher_peer == me)
            .map(|d| self.deal_card(d))
            .collect();
        out.sort_by(|a, b| b.at_ms.cmp(&a.at_ms));
        out
    }

    pub fn certificates(&self, peer: &str) -> Vec<CertificateCard> {
        let target = if peer.is_empty() { self.peer_id() } else { peer.to_string() };
        let mut out: Vec<CertificateCard> = self
            .state
            .certificates
            .values()
            .filter(|c| c.target_peer == target)
            .map(|c| {
                let key = certificate_id(&c.target_peer, &c.issuer_peer);
                let verified = self
                    .ops
                    .iter()
                    .rev()
                    .find(|op| op.key == key && matches!(op.kind, OpKind::CertificatePut))
                    .and_then(signature::verify_op)
                    .unwrap_or(false);
                CertificateCard {
                    id: c.id.clone(),
                    kind: match c.kind {
                        CertificateKind::AlighieriWriter => "alighieri-writer".into(),
                    },
                    target_peer: c.target_peer.clone(),
                    target_name: self.name_of(&c.target_peer),
                    issuer_peer: c.issuer_peer.clone(),
                    issuer_name: display_or(&c.issuer_name, self.name_of(&c.issuer_peer)),
                    note: c.note.clone(),
                    peak_work_title: c.evidence.peak_work_title.clone(),
                    peak_work_clicks: c.evidence.peak_work_clicks,
                    peak_year: c.evidence.peak_year,
                    years_writing: c.evidence.years_writing,
                    at_ms: crate::domain::hlc::wall_of(&c.at),
                    issuer_verified: verified,
                }
            })
            .collect();
        out.sort_by(|a, b| b.at_ms.cmp(&a.at_ms));
        out
    }

    /// 本机可见的「是否够格申请证书」——只是提示，不构成审核。
    pub fn certificate_eligibility(&self, peer: &str) -> CertificateEligibilityView {
        let target = if peer.is_empty() { self.peer_id() } else { peer.to_string() };
        let works = selectors::novels_by_author(&self.state, &target);
        let mut years: BTreeSet<i32> = BTreeSet::new();
        let mut started_at: Option<String> = None;
        let mut peak: Option<(String, String, u64, i32)> = None;
        for n in &works {
            if let Some(y) = year_of_timestamp(&n.first_published_at) {
                years.insert(y);
            }
            if !n.first_published_at.is_empty() {
                started_at = Some(match started_at {
                    Some(prev) if prev < n.first_published_at => prev,
                    _ => n.first_published_at.clone(),
                });
            }
            for c in selectors::chapters_of(&self.state, &n.id) {
                if let Some(y) = year_of_timestamp(&c.published_at) {
                    years.insert(y);
                }
            }
            let tally = selectors::reactions_of(&self.state, &n.id);
            let bookmarks = self
                .state
                .shelf
                .values()
                .filter(|s| s.novel_id == n.id)
                .count() as u64;
            let reviews = selectors::reviews_of(&self.state, &n.id).len() as u64;
            let clicks = selectors::estimate_clicks(
                tally.like + tally.insightful + tally.cry,
                bookmarks,
                reviews,
            );
            if clicks > 0 {
                let year = year_of_timestamp(&n.first_published_at).unwrap_or(0);
                let better = peak
                    .as_ref()
                    .map(|p| clicks > p.2 || (clicks == p.2 && year > p.3))
                    .unwrap_or(true);
                if better {
                    peak = Some((n.id.clone(), n.title.clone(), clicks, year));
                }
            }
        }
        let mut best_run = 0;
        let mut run = 0;
        let mut prev: Option<i32> = None;
        for y in &years {
            run = if prev.map(|p| *y == p + 1).unwrap_or(false) { run + 1 } else { 1 };
            best_run = best_run.max(run);
            prev = Some(*y);
        }
        let (peak_id, peak_title, peak_clicks, peak_year) = peak
            .map(|(id, title, clicks, year)| (Some(id), title, clicks, year))
            .unwrap_or((None, String::new(), 0, 0));
        let years_ok = best_run >= 3;
        let peak_ok = peak_clicks > 0 && peak_id.is_some();
        CertificateEligibilityView {
            years_writing: best_run as u32,
            years_ok,
            started_at,
            peak_novel_id: peak_id,
            peak_work_title: peak_title,
            peak_work_clicks: peak_clicks,
            peak_year,
            peak_ok,
            eligible: years_ok && peak_ok,
        }
    }

    pub fn wrap_cards(&self) -> Vec<WrapCard> {
        let mut out: Vec<WrapCard> = self
            .state
            .wraps
            .values()
            .map(|w| WrapCard {
                id: w.key.clone(),
                from_peer: w.from.clone(),
                from_name: self.name_of(&w.from),
                amount: w.amount,
                op_ids: w.op_ids.clone(),
                to_address: w.to_address.clone(),
                chain_id: w.chain_id,
                tx_hash: w.tx_hash.clone(),
                onchain_id: w.onchain_id.clone(),
                at_ms: crate::domain::hlc::wall_of(&w.at),
            })
            .collect();
        out.sort_by(|a, b| b.at_ms.cmp(&a.at_ms));
        out
    }

    /// 赞助方式完全来自站长设置；默认全空时界面必须显示「待配置」，
    /// 不生成任何假收款码 —— 宁可空着，也不摆一个扫不出来的码。
    pub fn sponsor_methods(&self) -> Vec<SponsorMethodView> {
        let mut out = Vec::new();
        for (id, name_key, hint_key, code, presets, unit, chain) in [
            ("alipay", "sponsor.alipay", "sponsor.alipay.hint", self.settings.sponsor_alipay.clone(), vec![10, 50, 100], "¥", 0u64),
            ("wechat", "sponsor.wechat", "sponsor.wechat.hint", self.settings.sponsor_wechat.clone(), vec![10, 50, 100], "¥", 0u64),
            ("usdt", "sponsor.usdt", "sponsor.usdt.hint", self.settings.sponsor_usdt.clone(), Vec::new(), "USDT", 1u64),
            ("ethereum", "sponsor.ethereum", "sponsor.ethereum.hint", self.settings.sponsor_eth.clone(), Vec::new(), "ETH", 1u64),
        ] {
            out.push(SponsorMethodView {
                id: id.into(),
                name_key: name_key.into(),
                hint_key: hint_key.into(),
                configured: sponsor_code_ok(&code) && (id != "usdt" && id != "ethereum" || bridge::is_evm_address(code.trim())),
                code: code.trim().to_string(),
                presets,
                unit: unit.into(),
                chain_id: chain,
                contract: if id == "usdt" {
                    "0xdAC17F958D2ee523a2206206994597C13D831ec7".into()
                } else {
                    String::new()
                },
            });
        }
        out
    }

    pub fn profile(&self, peer: &str) -> ProfileCard {
        let me = self.peer_id();
        let target = if peer.is_empty() { me.clone() } else { peer.to_string() };
        let works = selectors::novels_by_author(&self.state, &target);
        let derived = penname::pen_name_from(&target);
        let profile = self.state.profiles.get(&target);
        let name = profile
            .map(|p| p.name.clone())
            .filter(|n| !n.is_empty())
            .unwrap_or_else(|| derived.clone());

        let badges = self.badge_cards(&target);

        let mut links_platform = Vec::new();
        let mut links_url = Vec::new();
        let mut links_label = Vec::new();
        if let Some(p) = profile {
            for l in &p.links {
                links_platform.push(platform_str(l.platform).to_string());
                links_url.push(l.url.clone());
                links_label.push(l.label.clone().unwrap_or_default());
            }
        }

        let name_changed_at = profile.map(|p| p.name_changed_at).unwrap_or(0);
        let can_rename = name_changed_at <= 0 || now_ms() as i64 - name_changed_at >= 30 * 86_400_000;

        /* ---- 作者主页统计（全部由副本事实派生，与 Web author-client 对齐） ---- */
        let chapter_count: u64 = works
            .iter()
            .map(|n| {
                let actual = selectors::chapters_of(&self.state, &n.id).len() as u64;
                if actual > 0 { actual } else { n.episodes as u64 }
            })
            .sum();
        let mut clicks: u64 = 0;
        for n in &works {
            let r = selectors::reactions_of(&self.state, &n.id);
            let bookmarks = self.state.shelf.values().filter(|s| s.novel_id == n.id).count() as u64;
            let reviews = selectors::reviews_of(&self.state, &n.id).len() as u64;
            clicks += selectors::estimate_clicks(r.like + r.insightful + r.cry, bookmarks, reviews);
        }

        let reviews_from_others = self
            .state
            .reviews
            .values()
            .filter(|rv| !rv.novel_id.starts_with("__"))
            .filter(|rv| rv.actor != target)
            .filter(|rv| {
                self.state
                    .novels
                    .get(&rv.novel_id)
                    .map(|n| n.author_peer == target)
                    .unwrap_or(false)
            })
            .count() as u64;

        let mut tips_from_others = 0u64;
        let mut tips_total = 0i64;
        for r in self.state.rewards.values() {
            if r.action == "tip" && r.to == target && r.from != target {
                tips_from_others += 1;
                tips_total += r.amount;
            }
        }

        let contest_entries = self
            .state
            .entries
            .values()
            .filter(|e| e.actor == target)
            .count() as u64;
        let translations = self
            .state
            .translations
            .values()
            .filter(|t| t.actor == target)
            .count() as u64;

        // 有过实际产出的年份（章节发表年份 + 作品首次发表年份）。
        let mut active_years: BTreeSet<i64> = BTreeSet::new();
        let year_of_ms = |ms: u64| -> i64 {
            crate::domain::time::civil_from_days((ms / 1000 / 86_400) as i64).0
        };
        for c in self.state.chapters.values() {
            if c.deleted {
                continue;
            }
            if let Some(contributor) = &c.contributor {
                if contributor != &target {
                    continue;
                }
            }
            let Some(novel) = self.state.novels.get(&c.novel_id) else {
                continue;
            };
            if novel.author_peer != target {
                continue;
            }
            active_years.insert(year_of_ms(crate::domain::hlc::wall_of(&c.published_at)));
        }
        for n in &works {
            if let Some(ms) = crate::domain::time::parse_iso_ms(&n.first_published_at) {
                active_years.insert(year_of_ms(ms));
            }
        }
        let continuous_years = {
            let mut best = 0u32;
            let mut run = 0u32;
            let mut prev: Option<i64> = None;
            for y in &active_years {
                run = if prev.map(|p| *y == p + 1).unwrap_or(false) {
                    run + 1
                } else {
                    1
                };
                best = best.max(run);
                prev = Some(*y);
            }
            best
        };

        let contributions = self
            .state
            .merges
            .values()
            .filter(|m| m.author == target)
            .count() as u64;
        let group_memberships = self
            .state
            .novels
            .values()
            .filter(|n| !n.deleted)
            .filter(|n| {
                crate::domain::reducer::maintainers_of(&self.state, &n.id)
                    .iter()
                    .any(|p| p == &target)
            })
            .filter(|n| selectors::group_card(&self.state, &n.id).exists)
            .count() as u64;
        let contest_wins = works
            .iter()
            .filter(|n| !selectors::awards_of(&self.state, &n.id).is_empty())
            .count() as u64;
        let accepted_deals = self
            .state
            .deals
            .values()
            .filter(|d| d.author_peer == target)
            .filter(|d| matches!(d.status, DealStatus::Accepted | DealStatus::Paid))
            .count() as u64;

        let joined_at = works
            .iter()
            .map(|n| n.first_published_at.clone())
            .filter(|s| crate::domain::time::parse_iso_ms(s).is_some())
            .min();
        let joined_ms = joined_at
            .as_deref()
            .and_then(crate::domain::time::parse_iso_ms);
        let latest_ms = works
            .iter()
            .map(|n| crate::domain::hlc::wall_of(&n.updated_at))
            .max();
        let tenure_days = joined_ms
            .map(|j| now_ms().saturating_sub(j) / 86_400_000)
            .unwrap_or(0);
        let span_days = match (joined_ms, latest_ms) {
            (Some(a), Some(b)) if b > a => (b - a) / 86_400_000,
            _ => 0,
        };

        ProfileCard {
            peer_id: target.clone(),
            name: name.clone(),
            derived_name: penname::is_derived(&target, &name),
            bio: profile
                .map(|p| p.bio.clone())
                .filter(|b| !b.is_empty())
                .unwrap_or_else(|| penname::default_bio(&target).to_string()),
            avatar_seed: profile.and_then(|p| p.avatar_seed.clone()),
            works: works.len() as u64,
            total_words: works.iter().map(|n| n.words).sum(),
            chapters: chapter_count,
            clicks,
            reviews_from_others,
            tips_from_others,
            tips_total,
            contest_entries,
            translations,
            tenure_days,
            span_days,
            continuous_years,
            contributions,
            group_memberships,
            contest_wins,
            accepted_deals,
            joined_at,
            badges,
            link_platform: links_platform,
            link_url: links_url,
            link_label: links_label,
            can_rename,
            next_rename_at_ms: if name_changed_at > 0 { name_changed_at + 30 * 86_400_000 } else { 0 },
        }
    }

    /// 全部勋章（含未获得），已获得的排在前面。
    ///
    /// 与 Web 版 `grantedBadges()` 一样，界面既需要「已获得」，
    /// 也需要「还能授予什么」；只返回已获得的话，授予面板就得另开一个接口 ——
    /// 多一个接口，就多一处忘了同步的地方。
    fn badge_cards(&self, peer: &str) -> Vec<BadgeCard> {
        use std::collections::BTreeMap;
        let (earned, _pending) = granted_badges(&self.state, peer);
        let mut by_id: BTreeMap<&str, &crate::domain::badges::EarnedBadge> = BTreeMap::new();
        for e in &earned {
            by_id.insert(e.def.id, e);
        }
        let mut out = Vec::with_capacity(BADGES.len());
        for def in BADGES.iter() {
            match by_id.get(def.id) {
                Some(e) => out.push(BadgeCard {
                    id: def.id.to_string(),
                    earned: true,
                    earned_at: e.earned_at.clone(),
                    granters: e.granters.clone(),
                    notes: e.notes.clone(),
                }),
                None => out.push(BadgeCard {
                    id: def.id.to_string(),
                    earned: false,
                    earned_at: String::new(),
                    granters: Vec::new(),
                    notes: Vec::new(),
                }),
            }
        }
        // 已获得的排前面；同一组内保持目录顺序（BTreeMap 的 key 已是 id 排序，
        // 但视觉上连续更重要）。
        out.sort_by(|a, b| b.earned.cmp(&a.earned));
        out
    }

    pub fn stats(&self) -> NodeStats {
        let ns = self.net.as_ref().map(|n| n.status()).unwrap_or_default();
        NodeStats {
            peer_id: self.peer_id(),
            ops: self.ops.len() as u64,
            novels: self.state.novels.values().filter(|n| !n.deleted).count() as u64,
            chapters: self.state.chapters.values().filter(|c| !c.deleted).count() as u64,
            pending_gated: self.state.pending_gated.len() as u64,
            oplog_bytes: self.store.as_ref().map(|s| s.oplog_bytes()).unwrap_or(0),
            listen_port: self.listen_port as u32,
            peers: ns.peers.iter().map(|p| p.peer_id.clone()).collect(),
            revision: self.state.revision,
            net_state: if self.net.is_some() { ns.state } else { "local".into() },
            net_peers: ns
                .peers
                .into_iter()
                .map(|p| NetPeer {
                    peer_id: p.peer_id,
                    addr: p.addr,
                    direction: p.direction,
                    subscribed: p.subscribed,
                    agent: p.agent,
                })
                .collect(),
            dht_peers: ns.dht_peers,
            relay_reservations: ns.relay_reservations,
            listen_addrs: ns.listen_addrs,
            discovery_attempts: ns.discovery_attempts,
            providers_found: ns.providers_found,
            providers_dialed: ns.providers_dialed,
            last_net_error: ns.last_net_error,
            net_source: ns.net_source,
            site_fetched: ns.site_fetched,
            site_nodes: ns.site_nodes,
            ops_in: ns.ops_in,
            ops_out: ns.ops_out,
            rejected_sigs: self.rejected_sigs,
        }
    }

    /* -------- 设置 -------- */

    pub fn save_settings(&mut self) -> Result<(), String> {
        let s = self.settings.clone();
        self.store()?.save_settings(&s)
    }

    pub fn palette(&self) -> Palette {
        theme::build_palette(
            BrandColor { hue: self.settings.hue, sat: self.settings.sat },
            ThemeMode::parse(&self.settings.theme_mode),
        )
    }

    pub fn review_policy(&self) -> selectors::ReviewPolicy {
        selectors::ReviewPolicy {
            threshold: self.settings.review_threshold,
            exempt: self.settings.exempt.iter().cloned().collect(),
            trust_me: if self.settings.review_trust_only {
                self.identity.as_ref().map(|i| i.peer_id.clone())
            } else {
                None
            },
        }
    }

    /* -------- 信任网（女巫抵抗的界面入口） -------- */

    /// 给我视角的信任网排序（分数降序；不含我自己）。
    pub fn my_trust_view(&self) -> Vec<TrustEntryView> {
        let me = self.peer_id();
        if me.is_empty() {
            return Vec::new();
        }
        let trust = selectors::my_trust(&self.state, &me);
        let mut out: Vec<TrustEntryView> = trust
            .into_iter()
            .filter(|(p, _)| *p != me)
            .map(|(peer, score)| TrustEntryView {
                peer: peer.clone(),
                name: self.name_of(&peer),
                score,
            })
            .collect();
        out.sort_by(|a, b| {
            b.score
                .partial_cmp(&a.score)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.peer.cmp(&b.peer))
        });
        out
    }

    /// 信任网统计：背书总条数 / 互证边数（互证才传播）。
    pub fn attestation_stats(&self) -> AttestationStats {
        let mut seen: BTreeSet<(String, String)> = BTreeSet::new();
        let mut mutual = 0u64;
        for r in self.state.attestations.values() {
            if r.actor == r.target {
                continue;
            }
            if seen.contains(&(r.actor.clone(), r.target.clone())) {
                continue;
            }
            seen.insert((r.actor.clone(), r.target.clone()));
            if self
                .state
                .attestations
                .contains_key(&attest_key(&r.target, &r.actor))
            {
                mutual += 1;
            }
        }
        AttestationStats {
            total_edges: self.state.attestations.len() as u64,
            mutual_edges: mutual,
        }
    }

    /// 给另一个身份背书（互证后进入彼此的信任网）。自证无效。
    pub fn attest_identity(&mut self, target: &str, note: Option<&str>) -> Result<(), String> {
        let me = self.actor()?;
        let target = target.trim();
        if target.is_empty() {
            return Err("目标身份为空".into());
        }
        if target == me {
            return Err("attest-self".into());
        }
        if !crate::domain::identity::public_key_from_peer_id(target).is_some() {
            return Err("目标不是有效的内联公钥身份".into());
        }
        let note = note.map(|s| s.trim().to_string()).filter(|s| !s.is_empty());
        let body = serde_json::json!({ "weight": 1, "note": note });
        self.new_op(OpKind::AttestPut, &attest_key(&me, target), body)?;
        Ok(())
    }

    /* -------- 网络：断网也照常读写 -------- */

    pub fn start_network(&mut self, port: u16, peers: Vec<String>) -> Result<u16, String> {
        let peer_id = self.peer_id();
        if peer_id.is_empty() {
            return Err("还没有身份".into());
        }
        // 允许在设置页改完引导 / 中继后直接重连：先干净地停掉旧节点。
        if let Some(previous) = self.net.take() {
            previous.stop();
        }
        let seed = self
            .identity
            .as_ref()
            .map(|i| i.seed.clone())
            .filter(|s| s.len() == 32)
            .ok_or_else(|| "身份种子不完整".to_string())?;
        let shared = self.shared_ops.clone();
        let ops_provider = Arc::new(move || shared.lock().unwrap().clone()) as crate::net::OpsProvider;
        let inbox = self.inbox.clone();
        let sink = Arc::new(move |ops: Vec<Op>| {
            inbox.lock().unwrap().extend(ops);
        }) as crate::net::OpsSink;

        let mut config = crate::net::NetConfig {
            port,
            site_url: self.settings.site_url.clone(),
            relays: self.settings.relays.clone(),
            ..crate::net::NetConfig::default()
        };
        config.bootstrap.extend(peers);
        config.bootstrap.extend(self.settings.bootstrap.iter().cloned());

        let mut net = Net::new(peer_id, seed, ops_provider, sink, config);
        let actual = net.start()?;
        self.listen_port = actual;
        self.net = Some(net);
        Ok(actual)
    }

    pub fn sync_with(&mut self, addr: &str) -> Result<usize, String> {
        match &self.net {
            Some(n) => n.sync_with(addr),
            None => Err("网络尚未启动".into()),
        }
    }

    pub fn add_peer(&mut self, addr: &str) {
        if let Some(n) = &self.net {
            n.add_peer(addr);
        }
    }

    pub fn retry_discovery(&self) {
        if let Some(n) = &self.net {
            n.retry_discovery();
        }
    }

    pub fn trim(&mut self, keep: usize) -> Result<usize, String> {
        let removed = self.store()?.trim_ops(keep)?;
        let ops = self.store()?.load_ops()?;
        self.ops = ops.clone();
        *self.shared_ops.lock().unwrap() = ops;
        Ok(removed)
    }

    pub fn wipe(&mut self) -> Result<(), String> {
        if let Some(n) = &self.net {
            n.stop();
        }
        self.net = None;
        self.listen_port = 0;
        self.rejected_sigs = 0;
        let s = self.store.take().ok_or_else(|| "存储尚未初始化".to_string())?;
        s.wipe()?;
        self.store = Some(s);
        self.state = ReplicaState::new();
        self.shared_ops.lock().unwrap().clear();
        self.ops.clear();
        self.seen.clear();
        self.identity = None;
        self.identity_box = None;
        self.settings = Settings::defaults();
        Ok(())
    }

    /* -------- 辅助 -------- */

    pub fn name_of(&self, peer: &str) -> String {
        if let Some(p) = self.state.profiles.get(peer) {
            if !p.name.is_empty() {
                return p.name.clone();
            }
        }
        penname::pen_name_from(peer)
    }

    pub fn genres(&self) -> Vec<(String, String, String)> {
        catalog::GENRES
            .iter()
            .map(|g| (g.slug.to_string(), g.name.to_string(), g.desc.to_string()))
            .collect()
    }
}

fn display_or(value: &str, fallback: String) -> String {
    if value.trim().is_empty() {
        fallback
    } else {
        value.to_string()
    }
}

/// 从 ISO 时间或 HLC 里取年份。
fn year_of_timestamp(s: &str) -> Option<i32> {
    let s = s.trim();
    if s.len() >= 4 && s.as_bytes()[..4].iter().all(|b| b.is_ascii_digit()) {
        return s[..4].parse().ok();
    }
    let wall = s.split(':').next()?.parse::<u64>().ok()?;
    iso_of_ms(wall).get(..4)?.parse().ok()
}

/// 桥接三项都填了才算配置（与 Web 的 bridgeConfigured 一致）。
fn bridge_configured(settings: &Settings) -> bool {
    !settings.bridge_peer_id.trim().is_empty()
        && !settings.bridge_api_url.trim().is_empty()
        && !settings.bridge_contract.trim().is_empty()
}

/// 配置自检：默认全空时返回空（不显示上链入口）；配了一半或配错时如实报错。
fn bridge_config_errors(settings: &Settings) -> Vec<String> {
    let peer = settings.bridge_peer_id.trim();
    let api = settings.bridge_api_url.trim();
    let contract = settings.bridge_contract.trim();
    if peer.is_empty() && api.is_empty() && contract.is_empty() {
        return Vec::new();
    }
    let mut errs = Vec::new();
    if peer.is_empty() || api.is_empty() || contract.is_empty() {
        errs.push("桥接配置不完整：需要 peerId、https API 与合约地址三项".into());
    }
    if !contract.is_empty() && !bridge::is_evm_address(contract) {
        errs.push(format!("contract 不是合法的 EVM 地址：{contract}"));
    }
    if !api.is_empty() && !api.starts_with("https://") {
        errs.push(format!("apiUrl 必须是 https（当前 {api}）"));
    }
    if settings.bridge_chain_id != 1 && settings.bridge_chain_id != 11155111 {
        errs.push(format!(
            "chainId 只支持以太坊主网(1) 或 Sepolia(11155111)，当前 {}",
            settings.bridge_chain_id
        ));
    }
    errs
}

/// 收款码内容必须真的能用：空串、图片路径、零地址都不算配置好。
fn sponsor_code_ok(code: &str) -> bool {
    let c = code.trim();
    if c.is_empty() {
        return false;
    }
    let lower = c.to_ascii_lowercase();
    if lower.contains("/sponsor/") {
        return false;
    }
    if ["png", "jpg", "jpeg", "gif", "webp", "svg"]
        .iter()
        .any(|ext| lower.ends_with(&format!(".{ext}")))
    {
        return false;
    }
    if lower.starts_with("0x") && lower[2..].chars().all(|ch| ch == '0') {
        return false;
    }
    true
}

fn day_bucket() -> String {
    (now_ms() / 86_400_000).to_string()
}

fn action_label_key(action: &str) -> &'static str {
    match action {
        "readChapter" => RewardAction::ReadChapter.label_key(),
        "finishNovel" => RewardAction::FinishNovel.label_key(),
        "like" => RewardAction::Like.label_key(),
        "bookmark" => RewardAction::Bookmark.label_key(),
        "review" => RewardAction::Review.label_key(),
        "publish" => RewardAction::Publish.label_key(),
        "authorBookmarkShare" => RewardAction::AuthorBookmarkShare.label_key(),
        "tip" => "wallet.rules.tip",
        _ => "wallet.rules.other",
    }
}

fn platform_str(p: LinkPlatform) -> &'static str {
    match p {
        LinkPlatform::X => "x",
        LinkPlatform::Bilibili => "bilibili",
        LinkPlatform::Tiktok => "tiktok",
        LinkPlatform::Youtube => "youtube",
        LinkPlatform::Github => "github",
        LinkPlatform::Weibo => "weibo",
        LinkPlatform::Discord => "discord",
        LinkPlatform::Website => "website",
        LinkPlatform::Email => "email",
        LinkPlatform::Other => "other",
    }
}

fn random_suffix() -> String {
    let bytes: [u8; 8] = rand::random();
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

pub fn parse_op_kind(s: &str) -> Option<OpKind> {
    let all = [
        OpKind::NovelPut, OpKind::NovelDel, OpKind::ChapterPut, OpKind::ChapterDel,
        OpKind::BookmarkSet, OpKind::ReviewPut, OpKind::ReactionAdd, OpKind::ProfilePut,
        OpKind::ProgressSet, OpKind::RewardGrant, OpKind::RewardTransfer, OpKind::RewardWrap,
        OpKind::PublisherPut, OpKind::ContestPut, OpKind::EntrySubmit, OpKind::TranslationPut,
        OpKind::CertificatePut, OpKind::RelayAnnounce, OpKind::StarAdd, OpKind::ForkPut,
        OpKind::IssuePut, OpKind::IssueClose, OpKind::PatchPut, OpKind::PatchMerge,
        OpKind::PatchClose, OpKind::GroupPut, OpKind::ContestResult, OpKind::DealPut,
        OpKind::ReportPut, OpKind::ReportRespond, OpKind::ViewAdd,
        OpKind::ContribPut, OpKind::ReadTick, OpKind::BadgeGrant, OpKind::CarouselPut,
    ];
    all.into_iter().find(|k| k.as_str() == s)
}

/* ------------------------- 全局单例（FRB 唯一的入口） ------------------------- */

static ENGINE: OnceLock<Mutex<Engine>> = OnceLock::new();

pub fn engine() -> &'static Mutex<Engine> {
    ENGINE.get_or_init(|| Mutex::new(Engine::new()))
}

pub fn with<T>(f: impl FnOnce(&mut Engine) -> T) -> T {
    let mut e = engine().lock().unwrap();
    // 界面语言属于本机设置：每次跨 FFI 调用前同步给笔名派生器。
    penname::set_locale(&e.settings.locale);
    f(&mut e)
}

pub fn with_ref<T>(f: impl FnOnce(&Engine) -> T) -> T {
    let e = engine().lock().unwrap();
    penname::set_locale(&e.settings.locale);
    f(&e)
}

/// 供测试与自检：造一台干净的引擎
pub fn fresh_for_test(dir: &str) -> Engine {
    let mut e = Engine::new();
    e.init(dir).expect("init");
    e
}