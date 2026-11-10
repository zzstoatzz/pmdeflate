//! a tiny C ABI surface so `zig build targets` compiles and links the codec
//! for each target, instead of only type-checking it

const std = @import("std");
const pmdeflate = @import("pmdeflate");

const gpa = if (@import("builtin").cpu.arch.isWasm()) std.heap.wasm_allocator else std.heap.page_allocator;

/// compress `len` bytes and write the payload length to `out_len`; returns
/// the payload, owned by a process-wide deflater, or null on failure
export fn pmdeflate_compress(ptr: [*]const u8, len: usize, out_len: *usize) ?[*]const u8 {
    const State = struct {
        var deflater: ?*pmdeflate.Deflater = null;
    };
    const deflater = State.deflater orelse blk: {
        State.deflater = pmdeflate.Deflater.create(gpa, .{}) catch return null;
        break :blk State.deflater.?;
    };
    const payload = deflater.compress(ptr[0..len]) catch return null;
    out_len.* = payload.len;
    return payload.ptr;
}

/// decompress a payload into `out`; returns the message length, or -1
export fn pmdeflate_decompress(ptr: [*]const u8, len: usize, out: [*]u8, out_cap: usize) isize {
    const State = struct {
        var inflater: ?*pmdeflate.Inflater = null;
    };
    const inflater = State.inflater orelse blk: {
        State.inflater = pmdeflate.Inflater.create(gpa, .{}) catch return -1;
        break :blk State.inflater.?;
    };
    var writer: std.Io.Writer = .fixed(out[0..out_cap]);
    const n = inflater.decompress(ptr[0..len], &writer, out_cap) catch return -1;
    return @intCast(n);
}
