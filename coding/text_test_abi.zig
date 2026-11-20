//! Standalone native test module: imports DTOs only, not WebAssembly Host functions.
//! zig test --dep coding_abi -Mroot=coding/text.zig --dep types -Mcoding_abi=coding/text_test_abi.zig -Mtypes=coding_abi/types.zig
pub const types = @import("types");
