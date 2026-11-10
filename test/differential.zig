//! pmdeflate against zlib, both directions, on a deterministic corpus:
//! zlib must decode what pmdeflate encodes and pmdeflate must decode what
//! zlib encodes, message by message, with and without context takeover.

const std = @import("std");
const pmdeflate = @import("pmdeflate");
const zlib = @import("zlib");
const corpus = @import("corpus");

const t = std.testing;
const gpa = t.allocator;

fn pmdeflateToZlib(messages: []const []const u8, level: u4, takeover: bool) !void {
    const deflater = try pmdeflate.Deflater.create(gpa, .{ .level = level, .context_takeover = takeover });
    defer deflater.destroy();
    const inflater = try zlib.Inflater.create(gpa, takeover);
    defer inflater.destroy(gpa);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (messages, 0..) |message, i| {
        const payload = try deflater.compress(message);
        out.clearRetainingCapacity();
        inflater.decompress(gpa, payload, &out) catch |err| {
            std.debug.print("message {d} ({d} bytes, level {d}, takeover {}): zlib {t}\n", .{ i, message.len, level, takeover, err });
            return err;
        };
        try t.expectEqualSlices(u8, message, out.items);
    }
}

fn zlibToPmdeflate(messages: []const []const u8, level: u4, takeover: bool) !void {
    const deflater = try zlib.Deflater.create(gpa, level, takeover);
    defer deflater.destroy(gpa);
    const inflater = try pmdeflate.Inflater.create(gpa, .{ .context_takeover = takeover });
    defer inflater.destroy();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (messages, 0..) |message, i| {
        const payload = try deflater.compress(gpa, message);
        out.clearRetainingCapacity();
        const n = inflater.decompress(payload, &out.writer, message.len) catch |err| {
            std.debug.print("message {d} ({d} bytes, level {d}, takeover {}): pmdeflate {t}\n", .{ i, message.len, level, takeover, err });
            return err;
        };
        try t.expectEqual(message.len, n);
        try t.expectEqualSlices(u8, message, out.written());
    }
}

test "pmdeflate encodes, zlib decodes" {
    var c = try corpus.build(gpa);
    defer c.deinit();
    for ([_]u4{ 1, 6, 9 }) |level| for ([_]bool{ true, false }) |takeover| {
        try pmdeflateToZlib(c.messages.items, level, takeover);
    };
}

test "zlib encodes, pmdeflate decodes" {
    var c = try corpus.build(gpa);
    defer c.deinit();
    for ([_]u4{ 1, 6, 9 }) |level| for ([_]bool{ true, false }) |takeover| {
        try zlibToPmdeflate(c.messages.items, level, takeover);
    };
}

test "a decoder without the window refuses a takeover stream" {
    var c = try corpus.build(gpa);
    defer c.deinit();
    const deflater = try zlib.Deflater.create(gpa, 6, true);
    defer deflater.destroy(gpa);
    const inflater = try pmdeflate.Inflater.create(gpa, .{ .context_takeover = false });
    defer inflater.destroy();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var refused = false;
    for (c.messages.items) |message| {
        const payload = try deflater.compress(gpa, message);
        out.clearRetainingCapacity();
        _ = inflater.decompress(payload, &out.writer, 1 << 24) catch {
            refused = true;
            break;
        };
    }
    try t.expect(refused);
}
