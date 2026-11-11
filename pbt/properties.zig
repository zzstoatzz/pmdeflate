//! hegel property campaigns. zlib 1.3.2 is the oracle: it decodes everything
//! pmdeflate encodes, and encodes what pmdeflate decodes. a case is a
//! connection: one direction's codec pair, a level and a takeover mode, then
//! a generated history of messages, resets and corruptions.
//!
//! budget with HEGEL_TEST_CASES; replay a failure with HEGEL_ZIG_REPLAY.

const std = @import("std");
const hegel = @import("hegel");
const pmdeflate = @import("pmdeflate");
const zlib = @import("zlib");

const gpa = std.testing.allocator;

/// the largest message a case may draw; past 2 windows and the 64 KiB buffers
const max_message = 80 * 1024;

const Shape = enum { json, run, noise, text, repeat, empty, window_edge };

/// copy `out.len` bytes starting `back` bytes before the end of the history
/// (the messages concatenated); false when the history is shorter
fn copyBack(history: []const []const u8, back: usize, out: []u8) bool {
    var total: usize = 0;
    for (history) |m| total += m.len;
    if (total < back or back < out.len) return false;
    var skip = total - back;
    var filled: usize = 0;
    for (history) |m| {
        if (skip >= m.len) {
            skip -= m.len;
            continue;
        }
        const take = @min(m.len - skip, out.len - filled);
        @memcpy(out[filled..][0..take], m[skip..][0..take]);
        filled += take;
        skip = 0;
        if (filled == out.len) return true;
    }
    return false;
}

/// a message drawn by shape and size bucket, so large messages and repeats
/// of earlier ones are common instead of rare
fn drawMessage(case: *hegel.TestCase, buf: []u8, history: []const []const u8) ![]const u8 {
    const shape: Shape = @fromBackingInt(@intCast(try case.index(std.meta.tags(Shape).len)));
    const len = switch (try case.index(5)) {
        0 => try case.int(usize, 0, 64),
        1 => try case.int(usize, 0, 2048),
        2 => try case.int(usize, 32 * 1024 - 64, 32 * 1024 + 64),
        // large messages fill the inflater's history past where it compacts
        3 => try case.int(usize, max_message - 16 * 1024, max_message),
        else => try case.int(usize, 0, max_message),
    };
    switch (shape) {
        .empty => return buf[0..0],
        .noise => return case.bytes(buf, 0, @min(len, 4096)),
        .run => {
            @memset(buf[0..len], @intCast(try case.int(u8, 0, 255)));
            return buf[0..len];
        },
        .text => {
            const alphabet = "abc \"{}:,";
            const seed = try case.int(u32, 0, std.math.maxInt(u32));
            var prng: std.Random.DefaultPrng = .init(seed);
            for (buf[0..len]) |*b| b.* = alphabet[prng.random().uintLessThan(usize, alphabet.len)];
            return buf[0..len];
        },
        .json => {
            const id = try case.int(u32, 0, 1000);
            var w: std.Io.Writer = .fixed(buf);
            while (w.end + 200 < @max(len, 200) and w.end + 200 < buf.len) {
                w.print("{{\"did\":\"did:plc:{d}\",\"kind\":\"commit\",\"time_us\":{d}}}", .{ id, w.end }) catch break;
            }
            return w.buffered();
        },
        .repeat => {
            if (history.len == 0) return buf[0..0];
            case.event("repeats an earlier message");
            const earlier = history[try case.index(history.len)];
            @memcpy(buf[0..earlier.len], earlier);
            if (earlier.len > 0 and try case.boolean()) buf[try case.index(earlier.len)] ^= 0x20;
            return buf[0..earlier.len];
        },
        .window_edge => {
            // bytes from exactly one window back. over unique content, the
            // only match an encoder can use is at the maximum distance, which
            // a decoder keeping one byte too little of the window gets wrong.
            const n = try case.int(usize, 3, 258);
            if (copyBack(history, pmdeflate.window_len, buf[0..n])) {
                case.event("references exactly one window back");
                return buf[0..n];
            }
            // too little history: send a window of unique bytes to reference
            const seed = try case.int(u32, 0, std.math.maxInt(u32));
            var prng: std.Random.DefaultPrng = .init(seed);
            prng.random().bytes(buf[0..pmdeflate.window_len]);
            return buf[0..pmdeflate.window_len];
        },
    }
}

const History = struct {
    arena: std.heap.ArenaAllocator = .init(gpa),
    messages: std.ArrayList([]const u8) = .empty,

    fn add(self: *History, message: []const u8) !void {
        try self.messages.append(self.arena.allocator(), try self.arena.allocator().dupe(u8, message));
    }

    fn deinit(self: *History) void {
        self.arena.deinit();
    }
};

const EncodeRule = enum { send, reset };
var encode_tally: hegel.Tally(EncodeRule) = .{};

/// pmdeflate encodes; pmdeflate and zlib both decode every payload exactly
fn pmdeflateEncodes(_: void, case: *hegel.TestCase) !void {
    encode_tally.case();
    const level: u4 = @intCast(try case.int(u8, 1, 9));
    const takeover = try case.boolean();
    case.note("level {d}, context takeover {}", .{ level, takeover });

    const deflater = try pmdeflate.Deflater.create(gpa, .{ .level = level, .context_takeover = takeover });
    defer deflater.destroy();
    const inflater = try pmdeflate.Inflater.create(gpa, .{ .context_takeover = takeover });
    defer inflater.destroy();
    var oracle = try zlib.Inflater.create(gpa, takeover);
    defer oracle.destroy(gpa);

    const buf = try gpa.alloc(u8, max_message);
    defer gpa.free(buf);
    var history: History = .{};
    defer history.deinit();
    var decoded: std.Io.Writer.Allocating = .init(gpa);
    defer decoded.deinit();
    var oracle_out: std.ArrayList(u8) = .empty;
    defer oracle_out.deinit(gpa);

    var machine = try case.machine(EncodeRule, &.{ 8, 1 }, 24);
    defer machine.deinit();
    var sent: u64 = 0;
    while (try machine.next()) |rule| {
        encode_tally.step(rule);
        switch (rule) {
            .send => {
                const message = try drawMessage(case, buf, history.messages.items);
                case.note("send {d} bytes", .{message.len});
                if (message.len > flate_window) case.event("a message longer than the window");
                // RFC 7692 7.2.3.4: a sender may end its DEFLATE data with a
                // BFINAL block, and a stream may follow it in the same
                // payload. the decoder must start a new stream with the same
                // window. `zlib_parts` are what zlib, which stops at BFINAL,
                // decodes instead to stay in step.
                var parts: [2][]const u8 = .{ message, message[message.len..] };
                const form = try case.index(3);
                if (form == 2 and message.len >= 2) {
                    const k = try case.int(usize, 1, message.len - 1);
                    parts = .{ message[0..k], message[k..] };
                }
                var first: std.ArrayList(u8) = .empty;
                defer first.deinit(gpa);
                try first.appendSlice(gpa, try deflater.compress(parts[0]));
                const second = if (parts[1].len > 0) try deflater.compress(parts[1]) else "";
                const final_block = "\x00\x00\xff\xff" ++ "\x03\x00";
                var ours: std.ArrayList(u8) = .empty;
                defer ours.deinit(gpa);
                try ours.appendSlice(gpa, first.items);
                switch (form) {
                    0 => {},
                    1 => {
                        case.event("payload ends with a BFINAL block");
                        try ours.appendSlice(gpa, final_block ++ "\x00");
                    },
                    else => if (parts[1].len > 0) {
                        case.event("message data follows a BFINAL block");
                        try ours.appendSlice(gpa, final_block);
                        try ours.appendSlice(gpa, second);
                    },
                }

                decoded.clearRetainingCapacity();
                const n = inflater.decompress(ours.items, &decoded.writer, message.len) catch |err| {
                    case.note("pmdeflate: {t}", .{err});
                    return case.fail("pmdeflate refuses its own payload");
                };
                if (n != message.len or !std.mem.eql(u8, message, decoded.written()))
                    return case.fail("pmdeflate decodes its own payload differently");

                oracle_out.clearRetainingCapacity();
                oracle.decompress(gpa, ours.items, &oracle_out) catch |err| {
                    case.note("zlib: {t}", .{err});
                    return case.fail("zlib refuses a pmdeflate payload");
                };
                if (!std.mem.eql(u8, message, oracle_out.items))
                    return case.fail("zlib decodes a pmdeflate payload differently");
                try history.add(message);
                sent += 1;
            },
            .reset => {
                // both ends forget the window together, as a fresh connection
                case.note("reset", .{});
                if (sent > 0) case.event("reset after a message");
                try deflater.reset();
                inflater.reset();
                oracle.destroy(gpa);
                oracle = try zlib.Inflater.create(gpa, takeover);
                history.messages.clearRetainingCapacity();
            },
        }
    }
    encode_tally.finish(sent);
}

const flate_window = pmdeflate.window_len;

/// zlib encodes; pmdeflate decodes every payload exactly
fn zlibEncodes(_: void, case: *hegel.TestCase) !void {
    const level: u4 = @intCast(try case.int(u8, 1, 9));
    const takeover = try case.boolean();
    case.note("level {d}, context takeover {}", .{ level, takeover });
    const oracle = try zlib.Deflater.create(gpa, level, takeover);
    defer oracle.destroy(gpa);
    const inflater = try pmdeflate.Inflater.create(gpa, .{ .context_takeover = takeover });
    defer inflater.destroy();
    const buf = try gpa.alloc(u8, max_message);
    defer gpa.free(buf);
    var history: History = .{};
    defer history.deinit();
    var decoded: std.Io.Writer.Allocating = .init(gpa);
    defer decoded.deinit();

    var steps = try case.steps(1, 24);
    while (try steps.next()) {
        const message = try drawMessage(case, buf, history.messages.items);
        case.note("send {d} bytes", .{message.len});
        const payload = try oracle.compress(gpa, message);
        decoded.clearRetainingCapacity();
        const n = inflater.decompress(payload, &decoded.writer, message.len) catch |err| {
            case.note("pmdeflate: {t}", .{err});
            return case.fail("pmdeflate refuses a zlib payload");
        };
        if (n != message.len or !std.mem.eql(u8, message, decoded.written()))
            return case.fail("pmdeflate decodes a zlib payload differently");
        try history.add(message);
    }
}

const Corruption = enum { none, flip_bit, truncate, append, splice_noise, replace };

/// a corrupted payload is refused or decoded within the limit; never a crash.
/// when both decoders accept it, they agree. an inflater that refused a
/// message refuses every later one until reset.
fn corruptedPayloads(_: void, case: *hegel.TestCase) !void {
    const takeover = try case.boolean();
    const deflater = try pmdeflate.Deflater.create(gpa, .{ .context_takeover = takeover });
    defer deflater.destroy();
    const inflater = try pmdeflate.Inflater.create(gpa, .{ .context_takeover = takeover });
    defer inflater.destroy();
    const oracle = try zlib.Inflater.create(gpa, takeover);
    defer oracle.destroy(gpa);
    const buf = try gpa.alloc(u8, max_message);
    defer gpa.free(buf);
    var history: History = .{};
    defer history.deinit();
    var decoded: std.Io.Writer.Allocating = .init(gpa);
    defer decoded.deinit();
    var oracle_out: std.ArrayList(u8) = .empty;
    defer oracle_out.deinit(gpa);

    // a healthy prefix, so corruption lands on a connection with a window
    var steps = try case.steps(0, 6);
    while (try steps.next()) {
        const message = try drawMessage(case, buf, history.messages.items);
        const payload = try deflater.compress(message);
        decoded.clearRetainingCapacity();
        _ = try inflater.decompress(payload, &decoded.writer, message.len);
        oracle_out.clearRetainingCapacity();
        try oracle.decompress(gpa, payload, &oracle_out);
        try history.add(message);
    }

    const message = try drawMessage(case, buf, history.messages.items);
    var corrupt: std.ArrayList(u8) = .empty;
    defer corrupt.deinit(gpa);
    try corrupt.appendSlice(gpa, try deflater.compress(message));
    const how: Corruption = @fromBackingInt(@intCast(try case.index(std.meta.tags(Corruption).len)));
    var noise: [64]u8 = undefined;
    switch (how) {
        .none => {},
        .flip_bit => if (corrupt.items.len > 0) {
            corrupt.items[try case.index(corrupt.items.len)] ^= @as(u8, 1) << @intCast(try case.int(u3, 0, 7));
        },
        .truncate => corrupt.shrinkRetainingCapacity(try case.index(corrupt.items.len + 1)),
        .append => try corrupt.appendSlice(gpa, try case.bytes(&noise, 1, noise.len)),
        .splice_noise => {
            const at = try case.index(corrupt.items.len + 1);
            try corrupt.insertSlice(gpa, at, try case.bytes(&noise, 1, noise.len));
        },
        .replace => {
            corrupt.clearRetainingCapacity();
            try corrupt.appendSlice(gpa, try case.bytes(&noise, 0, noise.len));
        },
    }
    case.note("{t} -> {d} payload bytes", .{ how, corrupt.items.len });

    // limits around the message length are where an off-by-one hides
    const limit = switch (try case.index(5)) {
        0 => message.len -| 1,
        1 => message.len,
        2 => message.len -| try case.int(usize, 2, 3),
        3 => message.len + try case.int(usize, 1, 2),
        else => try case.int(usize, 0, max_message),
    };
    decoded.clearRetainingCapacity();
    const ours = inflater.decompress(corrupt.items, &decoded.writer, limit);
    if (decoded.written().len > limit) return case.fail("wrote past the limit");
    // zlib decodes without a limit; pmdeflate must accept exactly what zlib
    // accepts within the limit, and produce the same message
    oracle_out.clearRetainingCapacity();
    const zlib_ok = if (oracle.decompress(gpa, corrupt.items, &oracle_out)) true else |_| false;
    const zlib_accepts = zlib_ok and oracle_out.items.len <= limit;
    if (ours) |n| {
        case.event("pmdeflate accepted the payload");
        if (n != decoded.written().len) return case.fail("returned length differs from bytes written");
        if (!zlib_ok) return case.fail("pmdeflate accepts a payload zlib refuses");
        if (!zlib_accepts) return case.fail("accepts a message larger than the limit");
        if (!std.mem.eql(u8, oracle_out.items, decoded.written()))
            return case.fail("pmdeflate and zlib accept a payload but disagree on its message");
    } else |err| {
        case.event("pmdeflate refused the payload");
        case.note("pmdeflate: {t}", .{err});
        if (zlib_accepts) return case.fail("pmdeflate refuses a payload zlib accepts within the limit");
        if (how == .none and (err != error.MessageTooLarge or message.len <= limit))
            return case.fail("refuses an intact payload");
        decoded.clearRetainingCapacity();
        if (inflater.decompress("\x00", &decoded.writer, 0)) |_|
            return case.fail("a failed inflater accepts the next message")
        else |next| if (next != error.Failed) return case.fail("a failed inflater reports something other than Failed");
    }
}

test "pmdeflate encodes, both decoders agree" {
    try hegel.run(.{ .key = "pmdeflate-encodes" }, {}, pmdeflateEncodes);
    encode_tally.print();
}

test "zlib encodes, pmdeflate decodes" {
    try hegel.run(.{ .key = "zlib-encodes" }, {}, zlibEncodes);
}

test "corrupted payloads are refused or bounded" {
    try hegel.run(.{ .key = "corrupted-payloads" }, {}, corruptedPayloads);
}

/// writes DEFLATE bits least-significant first, as RFC 1951 packs them
const BitWriter = struct {
    bytes: std.ArrayList(u8) = .empty,
    acc: u64 = 0,
    count: u6 = 0,

    fn put(self: *BitWriter, value: u32, n: u6) !void {
        self.acc |= @as(u64, value) << self.count;
        self.count += n;
        while (self.count >= 8) {
            try self.bytes.append(gpa, @truncate(self.acc));
            self.acc >>= 8;
            self.count -= 8;
        }
    }

    /// Huffman codes are packed starting from their most significant bit
    fn putCode(self: *BitWriter, code: u32, len: u6) !void {
        const reversed = @bitReverse(@as(u16, @intCast(code))) >> @intCast(16 - @as(u7, len));
        try self.put(reversed, len);
    }

    fn finish(self: *BitWriter) !void {
        if (self.count > 0) try self.put(0, 8 - (self.count % 8));
    }
};

const Header = enum { valid, incomplete, oversubscribed, no_end_of_block, too_many_lengths, too_many_distances, stored, stored_bad_nlen };

/// canonical Huffman codes (RFC 1951 3.2.2) for `lengths`
fn canonicalCodes(lengths: []const u8, codes: []u32) void {
    var counts: [16]u32 = @splat(0);
    for (lengths) |len| counts[len] += 1;
    counts[0] = 0;
    var next: [16]u32 = undefined;
    var code: u32 = 0;
    for (1..16) |bits| {
        code = (code + counts[bits - 1]) << 1;
        next[bits] = code;
    }
    for (lengths, 0..) |len, symbol| {
        if (len == 0) continue;
        codes[symbol] = next[len];
        next[len] += 1;
    }
}

/// a block built from RFC 1951 rather than by an encoder: a dynamic
/// Huffman block that is valid or has one table defect, or a stored block
/// with a good or broken NLEN. the data is coded with the block's own
/// tables, so only the defect can make a decoder refuse it. pmdeflate and
/// zlib must agree on whether it decodes, and on the message when it does.
fn generatedBlocks(_: void, case: *hegel.TestCase) !void {
    const header: Header = @fromBackingInt(@intCast(try case.index(std.meta.tags(Header).len)));
    case.note("{t}", .{header});

    var w: BitWriter = .{};
    defer w.bytes.deinit(gpa);
    var message: [24]u8 = undefined;
    var message_len: usize = 0;

    if (header == .stored or header == .stored_bad_nlen) {
        message_len = try case.int(usize, 0, message.len);
        for (message[0..message_len]) |*byte| byte.* = try case.int(u8, 0, 255);
        try w.put(0, 3); // not final, stored
        try w.finish();
        const len: u16 = @intCast(message_len);
        var nlen: u16 = ~len;
        if (header == .stored_bad_nlen) nlen ^= @as(u16, 1) << @intCast(try case.int(u4, 0, 15));
        try w.put(len, 16);
        try w.put(nlen, 16);
        for (message[0..message_len]) |byte| try w.put(byte, 8);
    } else {
        // literal/length lengths: 0..254 take 8 bits, 255 and end-of-block
        // 9, a complete code. the defect variants change one thing.
        var lengths: [288 + 32]u8 = @splat(0);
        @memset(lengths[0..255], 8);
        lengths[255] = 9;
        lengths[256] = 9;
        var nlen: u32 = 257;
        switch (header) {
            .incomplete => lengths[try case.int(usize, 0, 254)] = 0,
            .oversubscribed => lengths[255] = 8,
            .no_end_of_block => {
                lengths[255] = 8;
                lengths[256] = 0;
            },
            .too_many_lengths => nlen = try case.int(u32, 287, 288),
            else => {},
        }
        // distances: one one-bit code (incomplete, which RFC 1951 decoders
        // allow for a single code) or two
        var ndist: u32 = try case.int(u32, 1, 2);
        if (header == .too_many_distances) ndist = try case.int(u32, 31, 32);
        for (0..@min(ndist, 2)) |d| lengths[nlen + d] = 1;

        try w.put(0, 1); // not final
        try w.put(2, 2); // dynamic Huffman
        try w.put(nlen - 257, 5);
        try w.put(ndist - 1, 5);
        try w.put(19 - 4, 4);
        // code-length code: symbols 0..15 at four bits each, a complete code
        const order = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
        for (order) |symbol| try w.put(if (symbol < 16) 4 else 0, 3);
        for (lengths[0 .. nlen + ndist]) |len| try w.putCode(len, 4);

        var codes: [288]u32 = @splat(0);
        canonicalCodes(lengths[0..nlen], codes[0..nlen]);
        const count = try case.int(usize, 0, message.len);
        for (0..count) |_| {
            const byte = try case.int(u8, 0, 254);
            if (lengths[byte] == 0) continue;
            message[message_len] = byte;
            message_len += 1;
            try w.putCode(codes[byte], @intCast(lengths[byte]));
        }
        if (lengths[256] != 0) try w.putCode(codes[256], @intCast(lengths[256]));
    }
    try w.put(0, 3); // the empty stored block the receiver's tail completes
    try w.finish();

    const inflater = try pmdeflate.Inflater.create(gpa, .{});
    defer inflater.destroy();
    const oracle = try zlib.Inflater.create(gpa, true);
    defer oracle.destroy(gpa);
    var decoded: std.Io.Writer.Allocating = .init(gpa);
    defer decoded.deinit();
    var oracle_out: std.ArrayList(u8) = .empty;
    defer oracle_out.deinit(gpa);

    const zlib_ok = if (oracle.decompress(gpa, w.bytes.items, &oracle_out)) true else |_| false;
    const ours = inflater.decompress(w.bytes.items, &decoded.writer, 1 << 16);
    const sound = header == .valid or header == .stored;
    if (sound and !zlib_ok) return case.fail("zlib refuses a valid generated block");
    if (ours) |_| {
        case.event("pmdeflate accepted the block");
        if (!zlib_ok) return case.fail("pmdeflate accepts a block zlib refuses");
        if (!std.mem.eql(u8, oracle_out.items, decoded.written()))
            return case.fail("pmdeflate and zlib accept a block but disagree on its message");
        if (sound and !std.mem.eql(u8, message[0..message_len], decoded.written()))
            return case.fail("a valid block decodes to the wrong message");
    } else |err| {
        case.event("pmdeflate refused the block");
        case.note("pmdeflate: {t}", .{err});
        if (zlib_ok) return case.fail("pmdeflate refuses a block zlib accepts");
    }
}

test "generated blocks decode exactly when zlib's do" {
    try hegel.run(.{ .key = "generated-blocks" }, {}, generatedBlocks);
}
