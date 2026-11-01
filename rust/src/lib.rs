//! Alighieri 核心库
//! ================
//! 一个运行在 P2P 之上的轻小说连载与阅读客户端的**核心域层**。
//! 没有中心服务器：每个设备都是一个独立节点，作品、书架、评论、
//! 奖励币都以 CRDT 操作的形式在读者之间互相复制 —— 谁也不用先连上谁。
//!
//! 本 crate 不含任何平台特定的代码，Flutter（Linux / Windows / Android）
//! 通过 flutter_rust_bridge 调用 `api` 模块暴露的门面。

pub mod domain;
pub mod engine;
pub mod net;
pub mod store;
pub mod vault;

// flutter_rust_bridge 的生成物在 `cargo build` 之前由 codegen 写入这两个文件。
// 手改没有用，下次 codegen 会原样收走。
pub mod api;
pub mod frb_generated;

/// 供集成测试与命令行自检使用的最小入口
pub fn self_check() -> Vec<String> {
    let mut errs = domain::bridge::check_golden_vector();
    if domain::licenses::get_license(None).id != domain::licenses::DEFAULT_LICENSE {
        errs.push("默认许可证解析错误".into());
    }
    errs
}