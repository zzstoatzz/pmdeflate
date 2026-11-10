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

pub const Inflater = struct {
    stream: z_stream = .{},
    context_takeover: bool,

    pub fn create(gpa: std.mem.Allocator, context_takeover: bool) !*Inflater {
        const self = try gpa.create(Inflater);
        self.* = .{ .context_takeover = context_takeover };
        if (inflateInit2_(&self.stream, -15, version, @sizeOf(z_stream)) != Z_OK) return error.ZlibInit;
        return self;
    }

    pub fn destroy(self: *Inflater, gpa: std.mem.Allocator) void {
        _ = inflateEnd(&self.stream);
        gpa.destroy(self);
    }

    /// decode a payload that holds no BFINAL block (zlib ends the stream
    /// there); appends the message to `out`
    pub fn decompress(self: *Inflater, gpa: std.mem.Allocator, payload: []const u8, out: *std.ArrayList(u8)) !void {
        if (!self.context_takeover and inflateReset(&self.stream) != Z_OK) return error.ZlibReset;
        for ([_][]const u8{ payload, "\x00\x00\xff\xff" }) |chunk| {
            self.stream.next_in = chunk.ptr;
            self.stream.avail_in = @intCast(chunk.len);
            while (self.stream.avail_in > 0) {
                try out.ensureUnusedCapacity(gpa, 16 * 1024);
                const room = out.unusedCapacitySlice();
                self.stream.next_out = room.ptr;
                self.stream.avail_out = @intCast(room.len);
                const rc = inflate(&self.stream, Z_SYNC_FLUSH);
                out.items.len += room.len - self.stream.avail_out;
                switch (rc) {
                    Z_OK => {},
                    Z_BUF_ERROR => if (self.stream.avail_out != 0) break,
                    Z_STREAM_END => return error.ZlibStreamEnd,
                    else => return error.ZlibInvalid,
                }
            }
        }
        // drain output still held after the input is consumed
        while (true) {
            try out.ensureUnusedCapacity(gpa, 16 * 1024);
            const room = out.unusedCapacitySlice();
            self.stream.next_out = room.ptr;
            self.stream.avail_out = @intCast(room.len);
            const rc = inflate(&self.stream, Z_SYNC_FLUSH);
            out.items.len += room.len - self.stream.avail_out;
            if (rc == Z_BUF_ERROR or self.stream.avail_out != 0) break;
            if (rc != Z_OK) return error.ZlibInvalid;
        }
    }
};
