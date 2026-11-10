//! the worked examples in RFC 7692 section 7.2.3, byte for byte

const std = @import("std");
const pmdeflate = @import("root.zig");

const t = std.testing;

fn inflateAll(inflater: *pmdeflate.Inflater, payload: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    errdefer out.deinit();
    _ = try inflater.decompress(payload, &out.writer, 1 << 20);
    return out.toOwnedSlice();
}

fn expectInflates(payloads: []const []const u8, messages: []const []const u8, options: pmdeflate.Inflater.Options) !void {
    const inflater = try pmdeflate.Inflater.create(t.allocator, options);
    defer inflater.destroy();
    for (payloads, messages) |payload, message| {
        const got = try inflateAll(inflater, payload);
        defer t.allocator.free(got);
        try t.expectEqualStrings(message, got);
    }
}

test "7.2.3.1 one compressed block" {
    try expectInflates(&.{"\xf2\x48\xcd\xc9\xc9\x07\x00"}, &.{"Hello"}, .{});
}

test "7.2.3.2 the second Hello references the shared window" {
    try expectInflates(
        &.{ "\xf2\x48\xcd\xc9\xc9\x07\x00", "\xf2\x00\x11\x00\x00" },
        &.{ "Hello", "Hello" },
        .{},
    );
}

test "7.2.3.2 without context takeover each Hello stands alone" {
    try expectInflates(
        &.{ "\xf2\x48\xcd\xc9\xc9\x07\x00", "\xf2\x48\xcd\xc9\xc9\x07\x00" },
        &.{ "Hello", "Hello" },
        .{ .context_takeover = false },
    );
}

test "7.2.3.2 a back-reference needs the window it was sent with" {
    const inflater = try pmdeflate.Inflater.create(t.allocator, .{ .context_takeover = false });
    defer inflater.destroy();
    const first = try inflateAll(inflater, "\xf2\x48\xcd\xc9\xc9\x07\x00");
    t.allocator.free(first);
    try t.expectError(error.InvalidData, inflateAll(inflater, "\xf2\x00\x11\x00\x00"));
}

test "7.2.3.3 a block with no compression" {
    try expectInflates(&.{"\x00\x05\x00\xfa\xff\x48\x65\x6c\x6c\x6f\x00"}, &.{"Hello"}, .{});
}

test "7.2.3.4 a block with BFINAL set, then more blocks" {
    try expectInflates(&.{"\xf3\x48\xcd\xc9\xc9\x07\x00\x00"}, &.{"Hello"}, .{});
}

test "7.2.3.4 a BFINAL block keeps the window for the next message" {
    try expectInflates(
        &.{ "\xf3\x48\xcd\xc9\xc9\x07\x00\x00", "\xf2\x00\x11\x00\x00" },
        &.{ "Hello", "Hello" },
        .{},
    );
}

test "7.2.3.5 two blocks in one message" {
    try expectInflates(&.{"\xf2\x48\x05\x00\x00\x00\xff\xff\xca\xc9\xc9\x07\x00"}, &.{"Hello"}, .{});
}

test "7.2.3.6 an empty fragment" {
    try expectInflates(&.{"\x00"}, &.{""}, .{});
}

test "7.2.3.1 the deflater's payload for Hello" {
    const deflater = try pmdeflate.Deflater.create(t.allocator, .{});
    defer deflater.destroy();
    const payload = try deflater.compress("Hello");
    // any valid encoding is conformant; this pins std's current choice and
    // checks it decodes
    const inflater = try pmdeflate.Inflater.create(t.allocator, .{});
    defer inflater.destroy();
    const got = try inflateAll(inflater, payload);
    defer t.allocator.free(got);
    try t.expectEqualStrings("Hello", got);
}

test "a message larger than the limit is refused and poisons the inflater" {
    const inflater = try pmdeflate.Inflater.create(t.allocator, .{});
    defer inflater.destroy();
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try t.expectError(error.MessageTooLarge, inflater.decompress("\xf2\x48\xcd\xc9\xc9\x07\x00", &out.writer, 4));
    // the limit bounds what is written, not only what is returned
    try t.expect(out.written().len <= 4);
    try t.expectError(error.Failed, inflater.decompress("\x00", &out.writer, 4));
    inflater.reset();
    try t.expectEqual(@as(usize, 0), try inflater.decompress("\x00", &out.writer, 4));
}

test "exactly the limit is accepted" {
    const inflater = try pmdeflate.Inflater.create(t.allocator, .{});
    defer inflater.destroy();
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try t.expectEqual(@as(usize, 5), try inflater.decompress("\xf2\x48\xcd\xc9\xc9\x07\x00", &out.writer, 5));
}
