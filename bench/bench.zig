//! pmdeflate against zlib 1.3.2 on one message corpus, offline.
//!
//! usage: zig build bench -- [--frames path] [--trials n]
//!
//! `--frames` reads length-prefixed messages (u32 big-endian count, then a
//! u32 big-endian length before each message), the format of atproto-bench's
//! captured relay frames. without it, the deterministic test corpus is used.
//!
//! each trial runs every configuration once, in alternating order, so drift
//! on the machine affects both codecs alike. every payload is decoded by the
//! codec under test and checked against the message before timing counts.

const std = @import("std");
const pmdeflate = @import("pmdeflate");
const zlib = @import("zlib");
const corpus = @import("corpus");

const Codec = enum { pmdeflate, zlib };

const Config = struct { codec: Codec, level: u4, takeover: bool };

const configs = [_]Config{
    .{ .codec = .pmdeflate, .level = 1, .takeover = true },
    .{ .codec = .zlib, .level = 1, .takeover = true },
    .{ .codec = .pmdeflate, .level = 6, .takeover = true },
    .{ .codec = .zlib, .level = 6, .takeover = true },
    .{ .codec = .pmdeflate, .level = 6, .takeover = false },
    .{ .codec = .zlib, .level = 6, .takeover = false },
};

const Sample = struct { encode_ns: u64, decode_ns: u64, payload_bytes: u64 };

/// counts live and peak heap bytes, to report one connection's footprint
const Counting = struct {
    child: std.mem.Allocator,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn note(self: *Counting, grow: usize, shrink: usize) void {
        self.live = self.live + grow - shrink;
        self.peak = @max(self.peak, self.live);
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, a, ra) orelse return null;
        self.note(len, 0);
        return p;
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(m, a, n, ra)) return false;
        self.note(n, m.len);
        return true;
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(m, a, n, ra) orelse return null;
        self.note(n, m.len);
        return p;
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.child.rawFree(m, a, ra);
        self.note(0, m.len);
    }
};

fn now(io: std.Io) u64 {
    return @intCast(std.Io.Timestamp.now(io, .awake).toNanoseconds());
}

/// one pass: encode every message, then decode every payload; checks each
fn runPmdeflate(io: std.Io, gpa: std.mem.Allocator, messages: []const []const u8, config: Config, payloads: *std.ArrayList([]u8)) !Sample {
    const deflater = try pmdeflate.Deflater.create(gpa, .{ .level = config.level, .context_takeover = config.takeover });
    defer deflater.destroy();
    var payload_bytes: u64 = 0;
    const t0 = now(io);
    for (messages, payloads.items) |message, *slot| {
        const payload = try deflater.compress(message);
        payload_bytes += payload.len;
        slot.* = try gpa.realloc(slot.*, payload.len);
        @memcpy(slot.*, payload);
    }
    const t1 = now(io);
    const inflater = try pmdeflate.Inflater.create(gpa, .{ .context_takeover = config.takeover });
    defer inflater.destroy();
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 1 << 20);
    defer out.deinit();
    var decode_ns: u64 = 0;
    for (messages, payloads.items) |message, payload| {
        out.clearRetainingCapacity();
        const d0 = now(io);
        _ = try inflater.decompress(payload, &out.writer, message.len);
        decode_ns += now(io) - d0;
        if (!std.mem.eql(u8, message, out.written())) return error.Mismatch;
    }
    return .{ .encode_ns = t1 - t0, .decode_ns = decode_ns, .payload_bytes = payload_bytes };
}

fn runZlib(io: std.Io, gpa: std.mem.Allocator, messages: []const []const u8, config: Config, payloads: *std.ArrayList([]u8)) !Sample {
    const deflater = try zlib.Deflater.create(gpa, config.level, config.takeover);
    defer deflater.destroy(gpa);
    var payload_bytes: u64 = 0;
    const t0 = now(io);
    for (messages, payloads.items) |message, *slot| {
        const payload = try deflater.compress(gpa, message);
        payload_bytes += payload.len;
        slot.* = try gpa.realloc(slot.*, payload.len);
        @memcpy(slot.*, payload);
    }
    const t1 = now(io);
    const inflater = try zlib.Inflater.create(gpa, config.takeover);
    defer inflater.destroy(gpa);
    var out: std.ArrayList(u8) = try .initCapacity(gpa, 1 << 20);
    defer out.deinit(gpa);
    var decode_ns: u64 = 0;
    for (messages, payloads.items) |message, payload| {
        out.clearRetainingCapacity();
        const d0 = now(io);
        try inflater.decompress(gpa, payload, &out);
        decode_ns += now(io) - d0;
        if (!std.mem.eql(u8, message, out.items)) return error.Mismatch;
    }
    return .{ .encode_ns = t1 - t0, .decode_ns = decode_ns, .payload_bytes = payload_bytes };
}

/// heap bytes one connection's codec pair holds after its first message
fn footprint(gpa: std.mem.Allocator, config: Config, message: []const u8) !usize {
    var counting: Counting = .{ .child = gpa };
    const a = counting.allocator();
    switch (config.codec) {
        .pmdeflate => {
            const d = try pmdeflate.Deflater.create(a, .{ .level = config.level, .context_takeover = config.takeover });
            defer d.destroy();
            const i = try pmdeflate.Inflater.create(a, .{ .context_takeover = config.takeover });
            defer i.destroy();
            const payload = try d.compress(message);
            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            _ = try i.decompress(payload, &out.writer, message.len);
            return counting.live;
        },
        .zlib => {
            // zlib allocates with malloc, outside this allocator; count its
            // documented state sizes instead (zconf.h, windowBits 15,
            // memLevel 8): deflate (1 << 17) + (1 << 18), inflate 1 << 15,
            // plus the payload buffer this wrapper keeps
            const d = try zlib.Deflater.create(a, config.level, config.takeover);
            defer d.destroy(a);
            _ = try d.compress(a, message);
            return counting.live + (1 << 17) + (1 << 18) + (1 << 15);
        },
    }
}

fn median(values: []u64) u64 {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return values[values.len / 2];
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());

    var frames_path: ?[]const u8 = null;
    var trials: usize = 7;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--frames")) {
            i += 1;
            frames_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--trials")) {
            i += 1;
            trials = try std.fmt.parseInt(usize, args[i], 10);
        } else return error.UnknownArgument;
    }

    var test_corpus: ?corpus.Corpus = null;
    defer if (test_corpus) |*c| c.deinit();
    var messages: std.ArrayList([]const u8) = .empty;
    const label = if (frames_path) |path| blk: {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena.allocator(), .unlimited);
        const count = std.mem.readInt(u32, bytes[0..4], .big);
        var at: usize = 4;
        for (0..count) |_| {
            const len = std.mem.readInt(u32, bytes[at..][0..4], .big);
            at += 4;
            try messages.append(arena.allocator(), bytes[at..][0..len]);
            at += len;
        }
        break :blk path;
    } else blk: {
        test_corpus = try corpus.build(gpa);
        try messages.appendSlice(arena.allocator(), test_corpus.?.messages.items);
        break :blk "test/corpus.zig";
    };
    var raw_bytes: u64 = 0;
    for (messages.items) |m| raw_bytes += m.len;

    var payloads: std.ArrayList([]u8) = .empty;
    defer {
        for (payloads.items) |p| gpa.free(p);
        payloads.deinit(gpa);
    }
    for (messages.items) |_| try payloads.append(gpa, try gpa.alloc(u8, 0));

    var encode: [configs.len][]u64 = undefined;
    var decode: [configs.len][]u64 = undefined;
    var sizes: [configs.len]u64 = undefined;
    for (&encode, &decode) |*e, *d| {
        e.* = try arena.allocator().alloc(u64, trials);
        d.* = try arena.allocator().alloc(u64, trials);
    }
    // a warm-up pass of each, untimed
    for (configs) |config| _ = switch (config.codec) {
        .pmdeflate => try runPmdeflate(io, gpa, messages.items, config, &payloads),
        .zlib => try runZlib(io, gpa, messages.items, config, &payloads),
    };
    for (0..trials) |trial| {
        for (0..configs.len) |k| {
            const c = if (trial % 2 == 0) k else configs.len - 1 - k;
            const config = configs[c];
            const sample = switch (config.codec) {
                .pmdeflate => try runPmdeflate(io, gpa, messages.items, config, &payloads),
                .zlib => try runZlib(io, gpa, messages.items, config, &payloads),
            };
            encode[c][trial] = sample.encode_ns;
            decode[c][trial] = sample.decode_ns;
            sizes[c] = sample.payload_bytes;
        }
    }

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    const w = &stdout.interface;
    try w.print("corpus: {s}, {d} messages, {d} bytes; {d} trials, median shown\n\n", .{ label, messages.items.len, raw_bytes, trials });
    try w.print("| codec | level | takeover | payload / raw | encode MB/s | decode MB/s | heap per connection |\n", .{});
    try w.print("|---|---:|---|---:|---:|---:|---:|\n", .{});
    for (configs, 0..) |config, c| {
        const mbs = struct {
            fn f(bytes: u64, ns: u64) f64 {
                return @as(f64, @floatFromInt(bytes)) / 1e6 / (@as(f64, @floatFromInt(ns)) / 1e9);
            }
        }.f;
        try w.print("| {t} | {d} | {s} | {d:.4} | {d:.1} | {d:.1} | {d} KiB |\n", .{
            config.codec,
            config.level,
            if (config.takeover) "on" else "off",
            @as(f64, @floatFromInt(sizes[c])) / @as(f64, @floatFromInt(raw_bytes)),
            mbs(raw_bytes, median(encode[c])),
            mbs(raw_bytes, median(decode[c])),
            try footprint(gpa, config, messages.items[0]) / 1024,
        });
    }
    try w.flush();
}
