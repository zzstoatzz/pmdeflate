//! a deterministic message sequence for differential tests: shapes WebSocket
//! peers send, plus sizes around the 32 KiB window and the codec's 64 KiB
//! buffers

const std = @import("std");

pub const Corpus = struct {
    arena: std.heap.ArenaAllocator,
    messages: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *Corpus) void {
        self.arena.deinit();
    }
};

const event =
    \\{{"did":"did:plc:{s}","time_us":{d},"kind":"commit","commit":{{"rev":"3l{s}","operation":"create","collection":"app.bsky.feed.{s}","rkey":"3l{s}","record":{{"$type":"app.bsky.feed.{s}","createdAt":"2026-11-10T08:{d:0>2}:{d:0>2}.{d:0>3}Z","text":"{s}","langs":["en"]}},"cid":"bafyrei{s}"}}}}
;

const words = [_][]const u8{ "the", "relay", "posted", "a", "zig", "window", "deflate", "sync", "flush", "message", "takeover", "context" };

pub fn build(gpa: std.mem.Allocator) !Corpus {
    var c: Corpus = .{ .arena = .init(gpa) };
    errdefer c.deinit();
    const a = c.arena.allocator();
    var prng: std.Random.DefaultPrng = .init(0x7692);
    const r = prng.random();

    // jetstream-shaped JSON events: mostly shared structure, varying fields
    for (0..300) |i| {
        var did: [24]u8 = undefined;
        var tid: [11]u8 = undefined;
        var cid: [52]u8 = undefined;
        for (&did) |*ch| ch.* = "abcdefghijklmnopqrstuvwxyz234567"[r.uintLessThan(u8, 32)];
        for (&tid) |*ch| ch.* = "abcdefghijklmnopqrstuvwxyz234567"[r.uintLessThan(u8, 32)];
        for (&cid) |*ch| ch.* = "abcdefghijklmnopqrstuvwxyz234567"[r.uintLessThan(u8, 32)];
        var text: std.ArrayList(u8) = .empty;
        for (0..r.uintLessThan(usize, 40)) |w| {
            if (w > 0) try text.append(a, ' ');
            try text.appendSlice(a, words[r.uintLessThan(usize, words.len)]);
        }
        const kind = if (r.boolean()) "post" else "like";
        try c.messages.append(a, try std.fmt.allocPrint(a, event, .{
            &did, 1_762_000_000_000_000 + i * 997, &tid, kind, &tid, kind, i % 60, (i * 7) % 60, i % 1000, text.items, &cid,
        }));
    }

    // binary frames: CBOR-like headers with random bodies
    for (0..40) |_| {
        const m = try a.alloc(u8, 64 + r.uintLessThan(usize, 4096));
        const header = "\xa2atg#commitbop";
        @memcpy(m[0..header.len], header);
        r.bytes(m[header.len..]);
        try c.messages.append(a, m);
    }

    // edges: empty, one byte, long runs, incompressible, and sizes around
    // the window (32 KiB) and buffer (64 KiB) boundaries
    try c.messages.append(a, "");
    try c.messages.append(a, "x");
    for ([_]usize{ 32767, 32768, 32769, 65535, 65536, 65537, 200_000 }) |len| {
        const runs = try a.alloc(u8, len);
        for (runs, 0..) |*b, j| b.* = @truncate(j / 1000);
        try c.messages.append(a, runs);
        const noise = try a.alloc(u8, len);
        r.bytes(noise);
        try c.messages.append(a, noise);
    }
    // a repeat of earlier messages, so takeover has something to reference
    for (0..20) |i| try c.messages.append(a, c.messages.items[i]);
    return c;
}
