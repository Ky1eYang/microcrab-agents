#![cfg(feature = "wasm")]

use std::sync::Arc;

use microcrab_session::{
    SessionState,
    runtime::{
        execution::ToolOutput,
        tool::ToolContext,
        wasm::{WasmAgent, WasmLimits},
    },
};
use serde_json::json;
use tokio_util::sync::CancellationToken;

use crate::typed_agent_fixture::{InitializedTool, final_text};

#[tokio::test]
async fn canonical_zig_component_uses_runtime_and_constrained_local_host() {
    let component_path = std::env::var_os("MICROCRAB_Z1_ABI_PROBE").expect("probe component path");
    let bytes = std::fs::read(component_path).expect("read probe component");
    let root = tempfile::tempdir().expect("create controlled root");
    std::fs::write(root.path().join("probe.txt"), "hello Zig Ω\n").expect("write test file");
    let host = Arc::new(
        microcrab_host_local::LocalHost::new(root.path(), Default::default())
            .expect("construct constrained local host"),
    );
    let agent = WasmAgent::load(&bytes, WasmLimits::default(), host).expect("load ABI component");
    let tools = agent.tools();
    assert_eq!(tools.len(), 1);
    let tool = &tools[0];
    let context = || {
        ToolContext::detached(
            SessionState::new(Default::default()),
            CancellationToken::new(),
        )
    };
    let output = tool
        .execute_initialized(json!({"path": "probe.txt"}), context())
        .await
        .expect("typed read under Runtime initialization and invocation admission");
    assert!(final_text(output).contains("hello Zig Ω"));
    match tool
        .execute_initialized(json!({"path": "../outside.txt"}), context())
        .await
    {
        Err(_) => {}
        Ok(ToolOutput::Final(output)) => assert!(output.failure.is_some()),
        Ok(output) => panic!("outside-root path returned an unexpected result: {output:?}"),
    }
    let buffered = tool
        .execute_initialized(json!({"path": "probe.txt", "buffered": true}), context())
        .await
        .expect("owned buffer handoff into Runtime");
    let ToolOutput::Buffered(buffered) = buffered else {
        panic!("expected runtime-owned buffer, got {buffered:?}");
    };
    let text = tokio::time::timeout(std::time::Duration::from_secs(3), async {
        loop {
            let output = buffered.snapshot(4096).expect("read runtime-owned output");
            let text = output
                .chunks
                .iter()
                .map(|chunk| chunk.content.as_str())
                .collect::<String>();
            if output.closed {
                break text;
            }
            buffered
                .wait_for_change(output.revision, CancellationToken::new())
                .await
                .expect("wait for Runtime continuation output");
        }
    })
    .await
    .expect("Runtime drove Zig continuation to completion");
    assert_eq!(text, "initial:.......hello Zig Ω\n");
}
