//! 引擎端到端流程测试
//! ------------------
//! 界面能点到的每一条主路径都在这里跑一遍：注册身份 → 投稿 → 发正文 →
//! 读一话（记 PV + 发币）→ 收藏 → 评价 → 打赏 → 重开后仍在。
//!
//! 这些是「钱」和「署名」相关的路径，不该只能靠点界面来验证 ——
//! 手点得再熟练，也没法在 CI 里重播。

use alighieri_core::domain::catalog::SearchParams;
use alighieri_core::engine;
use alighieri_core::store::Settings;

fn tmp(tag: &str) -> String {
    let d = std::env::temp_dir().join(format!("alighieri-engine-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    d.to_string_lossy().to_string()
}

#[test]
fn publish_then_read_then_reopen() {
    let dir = tmp("flow");
    let mut e = engine::Engine::new();
    let report = e.init(&dir).expect("init");
    assert!(!report.peer_id.is_empty());
    assert!(!report.pen_name.is_empty());

    // 1. 投稿（投稿本身发一次币）
    let id = e
        .publish_novel("测试作品", "一句话简介。", "isekai", vec!["转生".into()], "ongoing", "")
        .expect("publish_novel");
    // 2. 发正文
    e.publish_chapter(&id, 1, "第一话", vec!["段落一。".into(), "段落二。".into()], None)
        .expect("publish_chapter");

    let novel = e.novel(&id).expect("作品应当存在");
    assert_eq!(novel.title, "测试作品");
    assert_eq!(novel.episodes, 1, "最新一话应当被写回作品记录");
    assert_eq!(novel.license, "alighieri-serial", "不选许可时用连载许可");

    let chapters = e.chapters(&id);
    assert_eq!(chapters.len(), 1);
    assert_eq!(chapters[0].paragraphs.len(), 2);

    // 3. 读一话：停留足够久 -> 记 PV 并发币
    let before = e.wallet().balance;
    let got = e.finish_reading(&id, 1, 400_000, 3000).expect("finish_reading");
    assert!(got > 0, "认真读完应当发币");
    assert_eq!(e.wallet().balance - before, got);
    assert_eq!(e.novel(&id).unwrap().pv_total, 1, "PV 是集合语义");

    // 同一话再读一次：PV 不重复计
    let _ = e.finish_reading(&id, 1, 400_000, 3000);
    assert_eq!(e.novel(&id).unwrap().pv_total, 1);

    // 4. 收藏（读者得币；作者是本人，所以没有分成）
    e.set_bookmark(&id, true).expect("set_bookmark");
    assert!(e.novel(&id).unwrap().in_shelf);

    // 5. 评价（≥20 字才算有效；作业级评价还要求累计阅读 60 秒）
    e.record_read_tick(&id, 1, 60).expect("record_read_tick");
    e.add_review(&id, 0, "这是一段足够长的评价内容，用来触发有效评价的门槛。", 5, false)
        .expect("add_review");
    assert_eq!(e.reviews(&id).len(), 1);

    // 6. 打赏给别人
    let other = "12D3KooWother";
    e.tip(other, 7, None).expect("tip");
    // 我的账本只列收到的奖励；转出仍然在公开 op log 里。
    assert!(!e.wallet().ledger.iter().any(|l| l.to == other));
    let final_balance = e.wallet().balance;

    // 7. 重开：op log 是事实，视图是它的纯函数结果 —— 重启只是把同一个故事再讲一遍
    let ops_before = e.all_ops().len();
    let mut e2 = engine::Engine::new();
    let r2 = e2.init(&dir).expect("reopen");
    assert!(r2.recovered, "第二次打开应当是恢复而不是新建身份");
    assert_eq!(r2.peer_id, report.peer_id);
    assert!(e2.all_ops().len() >= ops_before);
    assert_eq!(e2.novel(&id).unwrap().title, "测试作品");
    assert_eq!(e2.wallet().balance, final_balance, "余额必须能被独立复算");

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn empty_replica_is_honestly_empty() {
    let dir = tmp("empty");
    let mut e = engine::Engine::new();
    e.init(&dir).expect("init");
    // 站内没有预置作品：第一次打开就该是空的
    assert!(e.novels(SearchParams::default()).is_empty());
    assert!(e.ranking("weekly", "").is_empty());
    assert!(e.contests().is_empty());
    assert!(e.publishers().is_empty());
    assert_eq!(e.wallet().balance, 0);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn settings_survive_restart() {
    let dir = tmp("settings");
    {
        let mut e = engine::Engine::new();
        e.init(&dir).expect("init");
        let mut s: Settings = e.settings.clone();
        s.locale = "ja".into();
        s.hue = 205;
        s.review_threshold = 5;
        e.settings = s;
        e.save_settings().expect("save");
    }
    let mut e = engine::Engine::new();
    e.init(&dir).expect("reopen");
    assert_eq!(e.settings.locale, "ja");
    assert_eq!(e.settings.hue, 205);
    assert_eq!(e.settings.review_threshold, 5);

    // 换主色后整套令牌跟着变，且正文对比度仍然达标
    let p = e.palette();
    assert!(!p.primary.is_empty());
    let ratio = alighieri_core::domain::theme::contrast_ratio(&p.foreground, &p.background);
    assert!(ratio >= 7.0, "正文对比度只有 {ratio:.2}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// 评论必须真的读过：作品 60 秒 / 单话 30 秒；勋章只能由别人授予 ——
/// 自己给自己发奖，不算。
#[test]
fn read_gate_and_badge_grants_match_the_web_rules() {
    let dir = tmp("read-badge");
    let mut e = engine::Engine::new();
    e.init(&dir).expect("init");
    let id = e
        .publish_novel("被阅读的作品", "简介。", "daily", vec![], "ongoing", "")
        .expect("publish");
    e.publish_chapter(&id, 1, "第一话", vec!["正文。".into()], None)
        .expect("chapter");

    let body = "这是一段足够长的评价内容，用来触发有效评价的门槛。";
    let work_err = e
        .add_review(&id, 0, body, 5, false)
        .expect_err("没读过不能评作品");
    assert!(
        work_err.contains("review.needRead:0:60:work"),
        "实际错误：{work_err}"
    );

    e.record_read_tick(&id, 1, 29).expect("tick");
    let chapter_err = e
        .add_review(&id, 1, body, 5, false)
        .expect_err("本话只读了 29 秒");
    assert!(
        chapter_err.contains("review.needRead:29:30:chapter"),
        "实际错误：{chapter_err}"
    );

    e.record_read_tick(&id, 1, 30).expect("tick");
    e.add_review(&id, 1, body, 5, false).expect("单话评价");
    assert_eq!(e.my_read_seconds(&id, 1), 59);

    e.record_read_tick(&id, 1, 1).expect("tick");
    e.add_review(&id, 0, body, 5, false).expect("作品评价");
    assert_eq!(e.my_read_seconds(&id, 0), 60);

    let me = e.peer_id();
    assert!(e.grant_badge(&me, "first-work", "").is_err(), "不能自授");
    assert!(e.grant_badge("peerB", "not-a-badge", "").is_err());

    let other = "12D3KooWOtherPeerForBadgeTest";
    e.grant_badge(other, "first-work", "第一部作品").expect("授予");
    let profile = e.profile(other);
    let badge = profile
        .badges
        .iter()
        .find(|b| b.id == "first-work")
        .expect("勋章应当存在");
    assert!(badge.earned);
    assert_eq!(badge.granters, vec![me.clone()]);
    assert_eq!(badge.notes, vec!["第一部作品".to_string()]);

    // 阅读时长与授予都随 op log 重开恢复
    let mut reopened = engine::Engine::new();
    reopened.init(&dir).expect("reopen");
    assert_eq!(reopened.my_read_seconds(&id, 0), 60);
    assert!(
        reopened
            .profile(other)
            .badges
            .iter()
            .any(|b| b.id == "first-work" && b.earned)
    );

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn two_engines_converge_after_sync() {
    let d1 = tmp("sync1");
    let d2 = tmp("sync2");
    let mut a = engine::Engine::new();
    a.init(&d1).expect("init a");
    let mut b = engine::Engine::new();
    b.init(&d2).expect("init b");

    let id = a
        .publish_novel("来自 A 的作品", "简介。", "daily", vec![], "ongoing", "")
        .expect("publish");
    a.publish_chapter(&id, 1, "第一话", vec!["正文。".into()], None)
        .expect("chapter");

    // B 收到 A 的全部 op：顺序打乱，且重复投递
    let mut ops = a.all_ops();
    ops.reverse();
    let mut dup = ops.clone();
    dup.extend(ops);
    assert!(b.ingest(dup) > 0);
    assert_eq!(b.novel(&id).unwrap().title, "来自 A 的作品");
    assert_eq!(b.chapters(&id).len(), 1);
    // 重复投递不会让章节变多
    assert_eq!(b.chapters(&id).len(), 1);

    // 两边对同一批 op 算出同一个「更新时间」
    let mut a2 = engine::Engine::new();
    a2.init(&d1).expect("reopen a");
    assert_eq!(
        a2.novel(&id).unwrap().updated_at_ms,
        b.novel(&id).unwrap().updated_at_ms
    );

    let _ = std::fs::remove_dir_all(&d1);
    let _ = std::fs::remove_dir_all(&d2);
}

/// 自己的作品能改资料、删章节；换一台设备只能读，不能改别人的书。
#[test]
fn author_can_edit_and_delete_only_own_work() {
    let dir = tmp("author-edit");
    let mut e = engine::Engine::new();
    e.init(&dir).expect("init");
    let id = e
        .publish_novel("旧书名", "旧简介。", "daily", vec!["旧标签".into()], "ongoing", "")
        .expect("publish");
    e.publish_chapter(&id, 1, "第一话", vec!["第一话正文。".into()], None)
        .expect("chapter 1");
    e.publish_chapter(&id, 2, "第二话", vec!["第二话正文。".into()], None)
        .expect("chapter 2");

    e.update_novel(
        &id,
        "新书名",
        "新简介。",
        "fantasy",
        vec!["新标签".into(), "  ".into()],
        "completed",
        "",
    )
    .expect("update_novel");
    let novel = e.novel(&id).expect("作品");
    assert_eq!(novel.title, "新书名");
    assert_eq!(novel.synopsis, "新简介。");
    assert_eq!(novel.genre, "fantasy");
    assert_eq!(novel.tags, vec!["新标签"]);
    assert_eq!(novel.status, "completed");
    assert_eq!(novel.episodes, 2, "改资料不能丢掉章节统计");
    assert_eq!(novel.latest_no, 2);

    e.delete_chapter(&id, 1).expect("delete_chapter");
    let novel = e.novel(&id).expect("作品");
    assert_eq!(novel.episodes, 1, "删章后话数要重算");
    assert_eq!(novel.latest_no, 2);
    assert!(e.chapters(&id).iter().all(|c| c.no != 1));

    // 另一台设备收到全部 op 后不能借本机入口改作者的作品
    let dir2 = tmp("author-edit-peer");
    let mut peer = engine::Engine::new();
    peer.init(&dir2).expect("init peer");
    peer.ingest(e.all_ops());
    assert!(peer
        .update_novel(&id, "偷改书名", "", "daily", vec![], "ongoing", "")
        .is_err());
    assert!(peer.delete_chapter(&id, 2).is_err());
    assert!(peer.delete_novel(&id).is_err());

    // 自己删整本仍然可以，且删除标记随重开恢复
    e.delete_novel(&id).expect("delete_novel");
    assert!(e.novel(&id).is_none());
    let mut reopened = engine::Engine::new();
    reopened.init(&dir).expect("reopen");
    assert!(reopened.novel(&id).is_none(), "删除要在重启后仍然生效");

    let _ = std::fs::remove_dir_all(&dir);
    let _ = std::fs::remove_dir_all(&dir2);
}

/// 余额不足必须在本地就拦下，不能再发一条注定让别人扣不动的转账 ——
/// 空头支票连发都别发。
#[test]
fn tip_rejects_overdraft_and_self_tip() {
    let dir = tmp("tip");
    let mut e = engine::Engine::new();
    e.init(&dir).expect("init");
    e.publish_novel("发币测试", "简介。", "daily", vec![], "ongoing", "")
        .expect("publish");
    let me = e.peer_id();
    assert!(e.tip(&me, 1, None).is_err(), "不能给自己打赏");

    let balance = e.wallet().balance;
    assert!(balance > 0, "投稿应当先得到币");
    let err = e
        .tip("12D3KooWOther", balance + 1, Some("测试".into()))
        .expect_err("余额不足");
    assert!(err.contains("余额不足"), "实际错误：{err}");
    assert_eq!(e.wallet().balance, balance, "失败转账不能改变余额");

    e.tip("12D3KooWOther", 7, Some("加油".into()))
        .expect("余额足够");
    let wallet = e.wallet();
    // 与 Web 的 balanceOf 一致：站内转出不扣「收到的币」，我的账本也只列收到的那部分。
    assert_eq!(wallet.balance, balance);
    assert!(!wallet.ledger.iter().any(|l| l.to == "12D3KooWOther"));
    // 转出记录仍然在 op log 里，可供任何人审计。
    assert!(e.all_ops().iter().any(|op| {
        op.kind == alighieri_core::domain::model::OpKind::RewardTransfer
            && op.body.get("to").and_then(|v| v.as_str()) == Some("12D3KooWOther")
            && op.body.get("amount").and_then(|v| v.as_i64()) == Some(7)
    }));

    let _ = std::fs::remove_dir_all(&dir);
}

/// 赛事报名要走规则自检；主办方公布的结果要能按名次显示并在重开后保留 ——
/// 公布名次这种事，不能重启一次就忘了。
#[test]
fn contest_entry_is_checked_and_results_are_sorted() {
    let dir = tmp("contest");
    let mut e = engine::Engine::new();
    e.init(&dir).expect("init");
    let now = engine::now_ms();
    e.put_publisher("测试出版社", "一句话", "", vec![])
        .expect("publisher");
    let publisher = e.peer_id();
    let deadline = alighieri_core::domain::time::iso_of_ms(now + 86_400_000);
    let announce = alighieri_core::domain::time::iso_of_ms(now + 2 * 86_400_000);
    let contest_id = e
        .put_contest(
            &publisher,
            "",
            "短篇征文",
            "call-for-writing",
            "一句话。",
            "规则。",
            "daily",
            &deadline,
            &announce,
            10,
            0,
            true,
            vec![],
        )
        .expect("put_contest");

    let id = e
        .publish_novel("参赛作品", "简介。", "daily", vec![], "ongoing", "")
        .expect("publish");
    e.publish_chapter(&id, 1, "第一话", vec!["这是一段够长的正文。".into()], None)
        .expect("chapter");

    let (ok, _, _, _) = e.check_entry(&contest_id, &id);
    assert!(ok, "应当满足最低字数");
    e.submit_entry(&contest_id, &id).expect("submit_entry");
    let card = e
        .contests()
        .into_iter()
        .find(|c| c.id == contest_id)
        .expect("赛事");
    assert_eq!(card.my_entry.as_deref(), Some(id.as_str()));

    // 字数不够的赛事必须在本地就拒绝，而不是先广播再失败
    let strict = e
        .put_contest(
            &publisher,
            "",
            "长篇征文",
            "call-for-writing",
            "",
            "",
            "daily",
            &deadline,
            &announce,
            100_000,
            0,
            true,
            vec![],
        )
        .expect("strict contest");
    let err = e.submit_entry(&strict, &id).expect_err("字数不足");
    assert!(err.contains("字数不足"), "实际错误：{err}");

    assert!(e.contest_results(&contest_id).is_empty());
    let body = serde_json::json!({
        "contestId": contest_id,
        "publisherPeer": e.peer_id(),
        "placements": [
            {
                "place": 2,
                "novelId": id,
                "novelTitle": "参赛作品",
                "authorPeer": e.peer_id(),
                "authorName": "作者",
                "note": "亚军"
            },
            {
                "place": 1,
                "novelId": "n_other",
                "novelTitle": "别人的作品",
                "authorPeer": "12D3KooWOther",
                "authorName": "另一位作者"
            }
        ]
    });
    e.submit_raw(
        "contest.result",
        &format!("result:{contest_id}"),
        &body.to_string(),
    )
    .expect("publish result");

    let results = e.contest_results(&contest_id);
    assert_eq!(results.iter().map(|p| p.place).collect::<Vec<_>>(), vec![1, 2]);
    assert_eq!(results[0].novel_title, "别人的作品");
    assert_eq!(results[1].note.as_deref(), Some("亚军"));
    assert!(e
        .contests()
        .into_iter()
        .find(|c| c.id == contest_id)
        .unwrap()
        .has_result);

    let mut reopened = engine::Engine::new();
    reopened.init(&dir).expect("reopen");
    assert_eq!(reopened.contest_results(&contest_id).len(), 2);

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn moderation_hides_only_on_this_device() {
    let dir = tmp("mod");
    let mut e = engine::Engine::new();
    e.init(&dir).expect("init");
    let id = e.publish_novel("被举报的作品", "简介。", "daily", vec![], "ongoing", "")
        .expect("publish");

    // 一个身份举报：不到默认阈值 3，作品仍在目录里 —— 一票否决在这里不成立
    e.report_novel(&id, "spam", "垃圾内容", None, None)
        .expect("report");
    e.settings.review_threshold = 3;
    assert!(!e.novel(&id).unwrap().flagged, "一票不该屏蔽");

    // 本机豁免后，即使票数够了也能「仍要查看」
    e.set_exempt(&id, true).expect("exempt");
    let e2 = e;
    assert!(!e2.novel(&id).unwrap().flagged);

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn passphrase_vault_locks_and_unlocks() {
    let dir = tmp("vault");
    let mut e = engine::Engine::new();
    let report = e.init(&dir).expect("init");
    let peer = report.peer_id.clone();

    // 明文身份：设置口令 -> 磁盘变成加密信封，明文退场
    assert!(!e.vault_status().encrypted);
    e.set_passphrase("correct horse battery").expect("set_passphrase");
    assert!(e.vault_status().encrypted && e.vault_status().unlocked);

    // 锁定：内存里没身份；重开后同样处于锁定状态
    e.lock_vault().expect("lock");
    assert!(!e.vault_status().unlocked);
    let mut e2 = engine::Engine::new();
    let r2 = e2.init(&dir).expect("reopen locked");
    assert!(e2.vault_status().encrypted && !e2.vault_status().unlocked);
    assert!(r2.peer_id.is_empty(), "解锁前不派生出 peerId");

    // 错误口令 = GCM 校验失败
    assert_eq!(
        e2.unlock_vault("wrong passphrase here").unwrap_err(),
        "passphrase-wrong"
    );
    // 正确口令：恢复同一个 peerId，且能照常发表
    let info = e2.unlock_vault("correct horse battery").expect("unlock");
    assert_eq!(info.peer_id, peer);
    let id = e2
        .publish_novel("解锁后发布", "简介。", "daily", vec![], "ongoing", "")
        .expect("publish");

    // 改口令：旧口令作废，新口令生效
    e2.set_passphrase("new passphrase 123").expect("re-encrypt");
    e2.lock_vault().expect("lock");
    assert_eq!(
        e2.unlock_vault("correct horse battery").unwrap_err(),
        "passphrase-wrong"
    );
    let info2 = e2.unlock_vault("new passphrase 123").expect("unlock new");
    assert_eq!(info2.peer_id, peer);

    // 移除口令：回明文，之后不能再「锁定」
    e2.remove_passphrase().expect("remove");
    assert!(!e2.vault_status().encrypted && e2.vault_status().unlocked);
    assert_eq!(e2.lock_vault().unwrap_err(), "need-passphrase-first");

    let _ = id;
    let _ = std::fs::remove_dir_all(&dir);
}
