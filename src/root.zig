//! permessage-deflate (RFC 7692) in pure Zig, on `std.compress.flate`.
//!
//! `Deflater` compresses each message to a payload: DEFLATE blocks ending in
//! a sync flush, with the trailing `00 00 ff ff` removed. `Inflater` reverses
//! it. Both keep the LZ77 window between messages unless context takeover is
//! off, as negotiated by `client_no_context_takeover` and
//! `server_no_context_takeover`.
//!
//! Window sizes: an `Inflater` decodes with a 32 KiB window, which accepts
//! every `*_max_window_bits` a peer may use. A `Deflater` may reference up to
//! 32 KiB back, so it only satisfies a negotiated `max_window_bits` of 15;
//! decline offers that require less.

const std = @import("std");
const flate = std.compress.flate;
const inflate = @import("inflate.zig");
const Allocator = std.mem.Allocator;

/// the LZ77 window both ends keep under context takeover (2^15 bytes)
pub const window_len = flate.history_len;

/// the only `max_window_bits` a `Deflater` can honor
pub const deflater_window_bits = 15;

pub const Deflater = struct {
    gpa: Allocator,
    options: Options,
    out: std.Io.Writer.Allocating,
    history: []u8,
    compressor: flate.Compress,

    pub const Options = struct {
        /// zlib-style level, 1 (fastest) to 9 (smallest)
        level: u4 = 6,
        /// keep the window between messages. turn off when the peer asked
        /// for `*_no_context_takeover` on this direction.
        context_takeover: bool = true,
    };

    pub const Error = Allocator.Error;

    /// heap-allocated because the compressor holds a pointer into it
    pub fn create(gpa: Allocator, options: Options) Error!*Deflater {
        std.debug.assert(options.level >= 1 and options.level <= 9);
        const self = try gpa.create(Deflater);
        errdefer gpa.destroy(self);
        const history = try gpa.alloc(u8, flate.max_window_len);
        errdefer gpa.free(history);
        self.* = .{
            .gpa = gpa,
            .options = options,
            .out = try .initCapacity(gpa, 16 * 1024),
            .history = history,
            .compressor = undefined,
        };
        errdefer self.out.deinit();
        try self.restart();
        return self;
    }

    pub fn destroy(self: *Deflater) void {
        const gpa = self.gpa;
        self.out.deinit();
        gpa.free(self.history);
        gpa.destroy(self);
    }

    /// forget the window, as if no message had been compressed
    pub fn reset(self: *Deflater) Error!void {
        try self.restart();
    }

    /// compress one message. the returned payload is owned by the deflater
    /// and valid until the next call.
    pub fn compress(self: *Deflater, message: []const u8) Error![]const u8 {
        if (!self.options.context_takeover) try self.restart();
        self.out.clearRetainingCapacity();
        self.compressor.writer.writeAll(message) catch return error.OutOfMemory;
        self.compressor.writer.flush() catch return error.OutOfMemory;
        const sync = "\x00\x00\xff\xff";
        if (std.mem.endsWith(u8, self.out.written(), sync)) {
            // the flush ended with an empty stored block: strip its LEN/NLEN
            self.out.shrinkRetainingCapacity(self.out.written().len - sync.len);
        } else {
            // the flush aligned with empty fixed blocks. append the header of
            // an empty stored block; its LEN/NLEN are the stripped tail.
            self.out.writer.writeByte(0x00) catch return error.OutOfMemory;
        }
        return self.out.written();
    }

    fn restart(self: *Deflater) Error!void {
        self.out.clearRetainingCapacity();
        self.compressor = flate.Compress.init(&self.out.writer, self.history, .raw, levelOptions(self.options.level)) catch
            return error.OutOfMemory;
    }

    fn levelOptions(level: u4) flate.Compress.Options {
        return switch (level) {
            1 => .level_1,
            2 => .level_2,
            3 => .level_3,
            4 => .level_4,
            5 => .level_5,
            6 => .level_6,
            7 => .level_7,
            8 => .level_8,
            else => .level_9,
        };
    }
};

pub const Inflater = struct {
    gpa: Allocator,
    options: Options,
    decoder: *inflate.Decoder,
    /// the window from earlier messages, then the message being decoded
    output: inflate.Output = .{},
    failed: bool = false,

    pub const Options = struct {
        /// decode with the previous message's window. turn off only when
        /// `*_no_context_takeover` was agreed for this direction.
        context_takeover: bool = true,
    };

    pub const Error = Allocator.Error || std.Io.Writer.Error || error{
        /// the payload is not valid DEFLATE data
        InvalidData,
        /// the message would decompress past `max_len`
        MessageTooLarge,
        /// an earlier message failed; the window is unknown
        Failed,
    };

    /// history kept before the window is moved to the front
    const compact_at = 128 * 1024;
    /// past this, compaction also gives memory back
    const retained_capacity = 256 * 1024;

    pub fn create(gpa: Allocator, options: Options) Allocator.Error!*Inflater {
        const self = try gpa.create(Inflater);
        errdefer gpa.destroy(self);
        const decoder = try gpa.create(inflate.Decoder);
        decoder.init();
        self.* = .{ .gpa = gpa, .options = options, .decoder = decoder };
        return self;
    }

    pub fn destroy(self: *Inflater) void {
        const gpa = self.gpa;
        self.output.buf.deinit(gpa);
        gpa.destroy(self.decoder);
        gpa.destroy(self);
    }

    /// forget the window and any earlier failure
    pub fn reset(self: *Inflater) void {
        self.output.buf.clearRetainingCapacity();
        self.failed = false;
    }

    /// decompress one message's payload into `out`, writing at most
    /// `max_len` bytes. returns the message length. after an error the
    /// window is unknown and every later call fails until `reset`.
    pub fn decompress(self: *Inflater, payload: []const u8, out: *std.Io.Writer, max_len: usize) Error!usize {
        if (self.failed) return error.Failed;
        self.failed = true;
        if (!self.options.context_takeover) self.output.buf.clearRetainingCapacity();

        const output = &self.output;
        output.window_end = output.buf.items.len;
        output.limit = max_len;
        // RFC 7692 7.2.2: the payload followed by the sync-flush tail the sender
        // stripped. a payload may hold blocks with BFINAL set (7.2.3.4); each
        // ends a DEFLATE stream, and the next continues with the same window
        try self.decoder.decodeAll(self.gpa, payload, "\x00\x00\xff\xff", output);
        const message = output.buf.items[output.window_end..];
        try out.writeAll(message);

        // the history stays in place for the next message. once it passes
        // `compact_at`, only the last window moves to the front, so small
        // messages do not each pay for moving 32 KiB
        const decoded = output.buf.items;
        if (decoded.len > compact_at) {
            const keep = @min(decoded.len, window_len);
            std.mem.copyForwards(u8, decoded[0..keep], decoded[decoded.len - keep ..]);
            output.buf.shrinkRetainingCapacity(keep);
            if (output.buf.capacity > retained_capacity) output.buf.shrinkAndFree(self.gpa, keep);
        }
        self.failed = false;
        return message.len;
    }
};

test {
    _ = @import("rfc7692_test.zig");
    _ = @import("review_test.zig");
    _ = @import("inflate.zig");
}
