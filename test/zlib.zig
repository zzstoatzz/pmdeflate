//! zlib 1.3.2 as a permessage-deflate reference: the oracle for differential
//! tests and the baseline for benchmarks. never imported by the library.
//! bindings are hand-written for the calls used here; deflateInit2_ and
//! inflateInit2_ reject a mismatched version or z_stream size.

const std = @import("std");

const uInt = c_uint;
const uLong = c_ulong;

const version = "1.3.2";
const Z_SYNC_FLUSH = 2;
const Z_OK = 0;
const Z_STREAM_END = 1;
const Z_BUF_ERROR = -5;
const Z_DEFLATED = 8;
const Z_DEFAULT_STRATEGY = 0;

const z_stream = extern struct {
    next_in: ?[*]const u8 = null,
    avail_in: uInt = 0,
    total_in: uLong = 0,
    next_out: ?[*]u8 = null,
    avail_out: uInt = 0,
    total_out: uLong = 0,
    msg: ?[*:0]const u8 = null,
    state: ?*anyopaque = null,
    zalloc: ?*const fn (?*anyopaque, uInt, uInt) callconv(.c) ?*anyopaque = null,
    zfree: ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void = null,
    @"opaque": ?*anyopaque = null,
    data_type: c_int = 0,
    adler: uLong = 0,
    reserved: uLong = 0,
};

extern fn deflateInit2_(strm: *z_stream, level: c_int, method: c_int, window_bits: c_int, mem_level: c_int, strategy: c_int, version: [*:0]const u8, stream_size: c_int) c_int;
extern fn inflateInit2_(strm: *z_stream, window_bits: c_int, version: [*:0]const u8, stream_size: c_int) c_int;
extern fn deflate(strm: *z_stream, flush: c_int) c_int;
extern fn deflateEnd(strm: *z_stream) c_int;
extern fn deflateReset(strm: *z_stream) c_int;
extern fn inflate(strm: *z_stream, flush: c_int) c_int;
extern fn inflateEnd(strm: *z_stream) c_int;
extern fn inflateReset(strm: *z_stream) c_int;

pub const Deflater = struct {
    stream: z_stream = .{},
    context_takeover: bool,
    out: std.ArrayList(u8) = .empty,

    pub fn create(gpa: std.mem.Allocator, level: u4, context_takeover: bool) !*Deflater {
        const self = try gpa.create(Deflater);
        self.* = .{ .context_takeover = context_takeover };
        if (deflateInit2_(&self.stream, level, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, version, @sizeOf(z_stream)) != Z_OK)
            return error.ZlibInit;
        return self;
    }

    pub fn destroy(self: *Deflater, gpa: std.mem.Allocator) void {
        _ = deflateEnd(&self.stream);
        self.out.deinit(gpa);
        gpa.destroy(self);
    }

    /// the RFC 7692 payload: sync flush with 00 00 ff ff stripped
    pub fn compress(self: *Deflater, gpa: std.mem.Allocator, message: []const u8) ![]const u8 {
        if (!self.context_takeover and deflateReset(&self.stream) != Z_OK) return error.ZlibReset;
        self.out.clearRetainingCapacity();
        self.stream.next_in = message.ptr;
        self.stream.avail_in = @intCast(message.len);
        while (true) {
            try self.out.ensureUnusedCapacity(gpa, 4096);
            const room = self.out.unusedCapacitySlice();
            self.stream.next_out = room.ptr;
            self.stream.avail_out = @intCast(room.len);
            const rc = deflate(&self.stream, Z_SYNC_FLUSH);
            self.out.items.len += room.len - self.stream.avail_out;
            // Z_BUF_ERROR: the previous call's output exactly filled the buffer
            // and nothing was left to flush
            if (rc == Z_BUF_ERROR) break;
            if (rc != Z_OK) return error.ZlibDeflate;
            if (self.stream.avail_out != 0) break;
        }
        // an empty message right after a flush makes zlib emit nothing; RFC
        // 7692 7.2.3.6 sends the header of an empty stored block instead
        if (self.out.items.len == 0) return "\x00";
        if (!std.mem.endsWith(u8, self.out.items, "\x00\x00\xff\xff")) return error.ZlibTail;
        return self.out.items[0 .. self.out.items.len - 4];
    }
};

extern fn inflateSetDictionary(strm: *z_stream, dictionary: [*]const u8, dict_length: uInt) c_int;

/// zlib as a production codec drives it, for the bench: the payload and then
/// the tail go in as two inputs, zlib keeps its own window, and output lands
/// directly in `out`. it does not continue past a BFINAL block, which an
/// encoder's sync-flushed payloads never contain; the oracle below does.
pub const StreamInflater = struct {
    stream: z_stream = .{},
    context_takeover: bool,

    pub fn create(gpa: std.mem.Allocator, context_takeover: bool) !*StreamInflater {
        const self = try gpa.create(StreamInflater);
        self.* = .{ .context_takeover = context_takeover };
        if (inflateInit2_(&self.stream, -15, version, @sizeOf(z_stream)) != Z_OK) return error.ZlibInit;
        return self;
    }

    pub fn destroy(self: *StreamInflater, gpa: std.mem.Allocator) void {
        _ = inflateEnd(&self.stream);
        gpa.destroy(self);
    }

    pub fn decompress(self: *StreamInflater, gpa: std.mem.Allocator, payload: []const u8, out: *std.ArrayList(u8)) !void {
        if (!self.context_takeover and inflateReset(&self.stream) != Z_OK) return error.ZlibReset;
        for ([_][]const u8{ payload, "\x00\x00\xff\xff" }) |input| {
            self.stream.next_in = input.ptr;
            self.stream.avail_in = @intCast(input.len);
            while (true) {
                try out.ensureUnusedCapacity(gpa, 16 * 1024);
                const room = out.unusedCapacitySlice();
                self.stream.next_out = room.ptr;
                self.stream.avail_out = @intCast(room.len);
                const rc = inflate(&self.stream, Z_SYNC_FLUSH);
                out.items.len += room.len - self.stream.avail_out;
                switch (rc) {
                    Z_OK, Z_BUF_ERROR => {},
                    else => return error.ZlibInvalid,
                }
                if (self.stream.avail_in == 0 and self.stream.avail_out != 0) break;
            }
        }
    }
};

pub const Inflater = struct {
    stream: z_stream = .{},
    context_takeover: bool,
    /// the last 32 KiB of output, to continue past a BFINAL block
    history: std.ArrayList(u8) = .empty,

    pub fn create(gpa: std.mem.Allocator, context_takeover: bool) !*Inflater {
        const self = try gpa.create(Inflater);
        self.* = .{ .context_takeover = context_takeover };
        if (inflateInit2_(&self.stream, -15, version, @sizeOf(z_stream)) != Z_OK) return error.ZlibInit;
        return self;
    }

    pub fn destroy(self: *Inflater, gpa: std.mem.Allocator) void {
        _ = inflateEnd(&self.stream);
        self.history.deinit(gpa);
        gpa.destroy(self);
    }

    /// decode one payload and append the message to `out`. at a BFINAL
    /// block zlib ends the stream; RFC 7692 7.2.3.4 continues with the same
    /// window, so the oracle restarts with the history as its dictionary.
    pub fn decompress(self: *Inflater, gpa: std.mem.Allocator, payload: []const u8, out: *std.ArrayList(u8)) !void {
        if (!self.context_takeover) {
            if (inflateReset(&self.stream) != Z_OK) return error.ZlibReset;
            self.history.clearRetainingCapacity();
        }
        const start = out.items.len;
        const input = try std.mem.concat(gpa, u8, &.{ payload, "\x00\x00\xff\xff" });
        defer gpa.free(input);
        var ended = false;
        self.stream.next_in = input.ptr;
        self.stream.avail_in = @intCast(input.len);
        while (true) {
            try out.ensureUnusedCapacity(gpa, 16 * 1024);
            const room = out.unusedCapacitySlice();
            self.stream.next_out = room.ptr;
            self.stream.avail_out = @intCast(room.len);
            const rc = inflate(&self.stream, Z_SYNC_FLUSH);
            out.items.len += room.len - self.stream.avail_out;
            switch (rc) {
                Z_OK => {},
                Z_BUF_ERROR => if (self.stream.avail_in == 0) break,
                Z_STREAM_END => {
                    ended = true;
                    if (self.stream.avail_in == 0) break;
                    ended = false;
                    const dictionary = try self.window(gpa, out.items[start..]);
                    defer gpa.free(dictionary);
                    if (inflateReset(&self.stream) != Z_OK) return error.ZlibReset;
                    if (dictionary.len > 0 and inflateSetDictionary(&self.stream, dictionary.ptr, @intCast(dictionary.len)) != Z_OK)
                        return error.ZlibDictionary;
                    continue;
                },
                else => return error.ZlibInvalid,
            }
            if (self.stream.avail_in == 0 and self.stream.avail_out != 0) break;
        }
        // zlib streams: input that stops mid-block only waits for more. a
        // payload is complete when all of it is consumed at a block
        // boundary (data_type bit 128) or the stream ended there
        if (self.stream.avail_in != 0 or (!ended and self.stream.data_type & 128 == 0)) return error.ZlibIncomplete;
        const next = try self.window(gpa, out.items[start..]);
        defer gpa.free(next);
        self.history.clearRetainingCapacity();
        try self.history.appendSlice(gpa, next);
    }

    /// the last 32 KiB of the earlier messages followed by `produced`
    fn window(self: *const Inflater, gpa: std.mem.Allocator, produced: []const u8) ![]u8 {
        const joined = try std.mem.concat(gpa, u8, &.{ self.history.items, produced });
        defer gpa.free(joined);
        return gpa.dupe(u8, joined[joined.len - @min(joined.len, 32 * 1024) ..]);
    }
};
