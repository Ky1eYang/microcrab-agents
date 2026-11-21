//! Standalone native test module: imports DTOs only, not WebAssembly Host functions.
//! From the Coding package: zig test --dep coding_abi -Mroot=src/text.zig
//! --dep types -Mcoding_abi=src/text_test_abi.zig -Mtypes=abi/types.zig
pub const types = @import("types");
