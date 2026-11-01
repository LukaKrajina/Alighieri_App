//! 第二阶段协作 / 交易 / 证书 / 上链的端到端测试
//! --------------------------------------------
//! 这些路径涉及署名、分账和链上申领，不能只靠点界面验证 ——
//! 钱包相关的东西，手抖一次就够心疼。

use alighieri_core::domain::bridge;
use alighieri_core::domain::identity;
use alighieri_core::domain::model::PatchChapter;
use alighieri_core::domain::wallet::RewardAction;
use alighieri_core::engine;

fn tmp(tag: &str) -> String {
    let d = std::env::temp_dir().join(format!("alighieri-collab-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    d.to_string_lossy().to_string()
}

/// 两个引擎：A 是原作者，B 是协作者 / 出版社 / 背书人 —— 分工明确，互不抢戏。
fn pair(tag: &str) -> (engine::Engine, engine::Engine, String, String) {
    let dir_a = tmp(&format!("{tag}-a"));
    let dir_b = tmp(&format!("{tag}-b"));
    let mut a = engine::Engine::new();
    let mut b = engine::Engine::new();
    a.init(&dir_a).expect("init a");
    b.init(&dir_b).expect("init b");
    let id = a
        .publish_novel("协作测试", "一句话简介。", "daily", vec![], "ongoing", "")
        .expect("publish");
    a.publish_chapter(&id, 1, "第一话", vec!["作者写的第一话。".into()], None)
        .expect("chapter");
    b.ingest(a.all_ops());
    (a, b, dir_a, dir_b)
}

#[test]
fn patch_merge_promotes_the_contributor_and_graph_splits_by_words() {
    let (mut a, mut b, dir_a, dir_b) = pair("patch");
    let novel_id = a.novels(Default::default())[0].id.clone();

    // B 提案续写第二话
    let patch_id = b
        .put_patch(
            &novel_id,
            "续写第二话",
            "接续作者停更的地方。",
            vec![PatchChapter {
                no: 2,
                title: "第二话".into(),
                paragraphs: vec!["这是协作者续写的一话，字数明显更多。".into()],
                volume: None,
                words: 0,
                based_on: None,
                contributor: None,
            }],
        )
        .expect("put_patch");
    a.ingest(b.all_ops());
    let patches = a.patches(&novel_id);
    assert_eq!(patches.len(), 1);
    assert!(!patches[0].has_conflict, "新话不应算冲突");
    assert!(patches[0].can_merge, "原作者是维护者，应当能整合");

    a.merge_patch(&novel_id, &patch_id, "写得好").expect("merge");
    b.ingest(a.all_ops());
    assert_eq!(b.chapters(&novel_id).len(), 2, "整合后的章节要能被 B 看到");

    let contributors = b.contributors(&novel_id);
    assert_eq!(contributors.len(), 2, "作者 + 提案作者");
    assert!(contributors.iter().any(|c| c.is_author));
    assert!(contributors.iter().any(|c| c.peer == b.peer_id() && c.is_maintainer));

    let graph = b.contribution_graph(&novel_id);
    let sum: f64 = graph.shares.iter().map(|s| s.ratio).sum();
    // 没有译者 / 零散贡献者时，那部分池子没有可分配对象，
    // 但结算时余数仍会补给正典池里份额最大的人（与 Web 一致）—— 零头不落空。
    assert!(sum <= 1.0 + 1e-9, "份额合计不应超过 1，实际 {sum}");
    assert!(sum >= 0.79, "正典池应当占大头，实际 {sum}");
    assert!(graph.shares.iter().any(|s| s.peer == b.peer_id() && s.kind == "canon" && s.ratio > 0.0));

    let _ = std::fs::remove_dir_all(&dir_a);
    let _ = std::fs::remove_dir_all(&dir_b);
}

#[test]
fn issue_can_be_opened_and_closed_by_maintainer_only() {
    let (mut a, mut b, dir_a, dir_b) = pair("issue");
    let novel_id = a.novels(Default::default())[0].id.clone();
    let issue_id = b
        .put_issue(&novel_id, "这里有个设定问题", "第一话的时间线似乎对不上。")
        .expect("put_issue");
    a.ingest(b.all_ops());
    let issues = a.issues(&novel_id);
    assert_eq!(issues.len(), 1);
    assert!(issues[0].can_close, "原作者是维护者");
    a.close_issue(&novel_id, &issue_id, true).expect("close");
    b.ingest(a.all_ops());
    assert_eq!(b.issues(&novel_id)[0].state, "closed");

    // 局外人不能关闭
    let dir_c = tmp("issue-c");
    let mut c = engine::Engine::new();
    c.init(&dir_c).expect("init c");
    c.ingest(a.all_ops());
    assert!(c.close_issue(&novel_id, &issue_id, false).is_err());

    let _ = std::fs::remove_dir_all(&dir_a);
    let _ = std::fs::remove_dir_all(&dir_b);
    let _ = std::fs::remove_dir_all(&dir_c);
}

#[test]
fn deal_moves_through_the_state_machine_and_pays_by_graph() {
    let (mut a, mut b, dir_a, dir_b) = pair("deal");
    let novel_id = a.novels(Default::default())[0].id.clone();

    // B 入驻出版社并获得一笔可用余额
    b.put_publisher("测试出版社", "只做测试", "", vec!["daily".into()])
        .expect("publisher");
    b.grant(RewardAction::Publish, "seed", Some(100)).expect("seed");
    let deal_id = b
        .offer_deal(&novel_id, "manga", 30, "漫画改编，署名原作者。")
        .expect("offer");

    a.ingest(b.all_ops());
    let deals = a.my_deals();
    assert_eq!(deals.len(), 1);
    assert!(deals[0].can_respond);
    a.respond_deal(&deal_id, true).expect("accept");

    b.ingest(a.all_ops());
    let deals = b.my_deals();
    assert_eq!(deals[0].status, "accepted");
    assert!(deals[0].can_settle);
    b.settle_deal(&deal_id, true).expect("pay");

    a.ingest(b.all_ops());
    let paid = a.deals_for_novel(&novel_id);
    assert_eq!(paid[0].status, "paid");
    assert!(paid[0].paid_on_ledger, "账本里必须有 adaptation 转账");
    assert!(a.wallet().balance >= 30, "作者应收到按图谱拆分的报酬");

    let _ = std::fs::remove_dir_all(&dir_a);
    let _ = std::fs::remove_dir_all(&dir_b);
}

#[test]
fn certificate_must_be_issued_by_someone_else_and_is_signature_verified() {
    let (mut a, mut b, dir_a, dir_b) = pair("cert");
    let peer_a = a.peer_id();
    assert!(a
        .put_certificate(&peer_a, "self", "2020-01-01", 3.0, "书", 100, 2024)
        .is_err(), "不能自授证书");

    b.put_certificate(
        &peer_a,
        "我读过 TA 的作品",
        "2021-01-01",
        3.0,
        "协作测试",
        1234,
        2024,
    )
    .expect("endorse");
    a.ingest(b.all_ops());
    let certs = a.certificates(&peer_a);
    assert_eq!(certs.len(), 1);
    assert!(certs[0].issuer_verified, "证书 op 的签名应当可验证");
    assert_eq!(certs[0].peak_work_clicks, 1234);

    let _ = std::fs::remove_dir_all(&dir_a);
    let _ = std::fs::remove_dir_all(&dir_b);
}

#[test]
fn wrap_request_is_signed_and_wrap_record_locks_the_ops() {
    let dir = tmp("wrap");
    let mut e = engine::Engine::new();
    e.init(&dir).expect("init");
    e.publish_novel("上链测试", "简介。", "daily", vec![], "ongoing", "")
        .expect("publish");
    assert!(e.wallet().balance > 0, "发布奖励应当到账");

    // 默认不配置桥接：不显示入口，也不能申领 —— 没配好就别摆按钮
    let cov = e.wrap_coverage();
    assert!(!cov.configured);
    assert!(cov.config_errors.is_empty());
    assert!(e.build_wrap_request(1, "0x0000000000000000000000000000000000000001").is_err());

    e.settings.bridge_peer_id = "12D3KooWbridge".into();
    e.settings.bridge_api_url = "https://bridge.example.com".into();
    e.settings.bridge_contract = "0x0000000000000000000000000000000000000002".into();
    e.settings.bridge_chain_id = 11155111;
    let request = e
        .build_wrap_request(10, "0x0000000000000000000000000000000000000001")
        .expect("build request");
    let claim = bridge::WrapClaim {
        peer_id: request.peer_id.clone(),
        amount: request.amount,
        op_ids: request.op_ids.clone(),
        to_address: request.to_address.clone(),
        nonce: request.nonce.clone(),
    };
    assert_eq!(request.hash, bridge::hash_wrap_payload(&claim));
    assert!(identity::verify_signature(
        &request.peer_id,
        &bridge::canonical_wrap_payload(&claim),
        &request.signature
    ));

    e.record_wrap(
        10,
        request.op_ids.clone(),
        &request.to_address,
        11155111,
        "0xabc",
        "claim-1",
    )
    .expect("record");
    let cov = e.wrap_coverage();
    assert_eq!(cov.wrapped, e.wallet().ledger.iter().filter(|l| l.wrapped).map(|l| l.amount).sum::<i64>());
    assert_eq!(e.wrap_cards().len(), 1);

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn sponsor_methods_are_honestly_unconfigured_until_the_operator_sets_them() {
    let dir = tmp("sponsor");
    let mut e = engine::Engine::new();
    e.init(&dir).expect("init");
    assert!(e.sponsor_methods().iter().all(|m| !m.configured));
    e.settings.sponsor_alipay = "https://qr.alipay.com/example".into();
    let methods = e.sponsor_methods();
    assert!(methods.iter().find(|m| m.id == "alipay").unwrap().configured);
    assert!(!methods.iter().find(|m| m.id == "wechat").unwrap().configured);
    // 图片路径不是收款码内容 —— 扫不出来的图，不算码
    e.settings.sponsor_wechat = "/sponsor/wechat.png".into();
    assert!(!e.sponsor_methods().iter().find(|m| m.id == "wechat").unwrap().configured);
    let _ = std::fs::remove_dir_all(&dir);
}
