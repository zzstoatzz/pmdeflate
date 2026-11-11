//! a raw DEFLATE (RFC 1951) decoder for whole payloads in memory. the input
//! is one contiguous slice, so a 64-bit bit buffer refills without a reader,
//! and output goes into one contiguous buffer that also holds the window, so
//! literals and matches are written without per-byte checks.
//!
//! it rejects what zlib's inflate rejects: over-subscribed or incomplete code
//! tables (except a single one-bit code), a literal/length table without an
//! end-of-block code, more than 286 length or 30 distance symbols, a stored
//! block whose NLEN is not ~LEN, and a distance past the decoded history.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error || error{ InvalidData, MessageTooLarge };

const max_bits = 15;
const max_match = 258;

/// Huffman decode table: the next `fast_bits` input bits index `fast`
/// directly; longer codes take the canonical slow path.
fn Table(comptime symbols_max: usize, comptime fast_bits: u4) type {
    return struct {
        const Self = @This();
        /// symbol in the low 16 bits, code length in the next 8; 0 = slow path
        fast: [1 << fast_bits]u32,
        counts: [max_bits + 1]u16,
        symbols: [symbols_max]u16,
        /// no codes at all: any decode is invalid
        empty: bool,

        fn build(self: *Self, lengths: []const u8, codelen_table: bool) error{InvalidData}!void {
            @memset(&self.counts, 0);
            for (lengths) |len| self.counts[len] += 1;
            self.counts[0] = 0;
            var max: usize = 0;
            for (1..max_bits + 1) |len| {
                if (self.counts[len] != 0) max = len;
            }
            @memset(&self.fast, 0);
            self.empty = max == 0;
            if (self.empty) return;

            var left: i32 = 1;
            for (1..max_bits + 1) |len| {
                left <<= 1;
                left -= self.counts[len];
                if (left < 0) return error.InvalidData; // over-subscribed
            }
            if (left > 0 and (codelen_table or max != 1)) return error.InvalidData; // incomplete

            var offsets: [max_bits + 2]u16 = undefined;
            offsets[1] = 0;
            for (1..max_bits + 1) |len| offsets[len + 1] = offsets[len] + self.counts[len];
            for (lengths, 0..) |len, symbol| {
                if (len == 0) continue;
                self.symbols[offsets[len]] = @intCast(symbol);
                offsets[len] += 1;
            }

            // canonical codes, bit-reversed into LSB-first fast-table indexes
            var code: u32 = 0;
            var index: usize = 0;
            for (1..max_bits + 1) |len| {
                for (0..self.counts[len]) |_| {
                    if (len <= fast_bits) {
                        const reversed = @bitReverse(@as(u16, @intCast(code))) >> @intCast(16 - len);
                        const entry = @as(u32, self.symbols[index]) | (@as(u32, @intCast(len)) << 16);
                        var fill: u32 = reversed;
                        while (fill < self.fast.len) : (fill += @as(u32, 1) << @intCast(len)) self.fast[fill] = entry;
                    }
                    code += 1;
                    index += 1;
                }
                code <<= 1;
            }
        }
    };
}

const LitLen = Table(288, 10);
const Dist = Table(32, 8);
const CodeLen = Table(19, 7);

const length_base = [29]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const length_extra = [29]u4{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const dist_base = [30]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const dist_extra = [30]u4{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };
const codelen_order = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

/// reads the payload in place, then `tail` as if it followed: RFC 7692 has the
/// receiver append the 00 00 ff ff the sender stripped, and reading it
/// virtually spares a copy of every payload
const Bits = struct {
    payload: []const u8,
    tail: []const u8,
    pos: usize = 0,
    buf: u64 = 0,
    count: u7 = 0,

    /// make at least 56 bits available, or every remaining input bit.
    /// reading past the end of input is an error at `need`.
    inline fn refill(self: *Bits) void {
        if (self.pos + 8 <= self.payload.len) {
            const word = std.mem.readInt(u64, self.payload[self.pos..][0..8], .little);
            self.buf |= word << @intCast(self.count);
            self.pos += (63 - @as(usize, self.count)) >> 3;
            self.count |= 56;
            return;
        }
        while (self.count <= 56 and self.pos < self.size()) {
            self.buf |= @as(u64, self.byteAt(self.pos)) << @intCast(self.count);
            self.pos += 1;
            self.count += 8;
        }
    }

    inline fn size(self: *const Bits) usize {
        return self.payload.len + self.tail.len;
    }

    inline fn byteAt(self: *const Bits, i: usize) u8 {
        return if (i < self.payload.len) self.payload[i] else self.tail[i - self.payload.len];
    }

    /// all input consumed at a block boundary: the end of a complete message
    inline fn done(self: *const Bits) bool {
        return self.count == 0 and self.pos == self.size();
    }

    inline fn need(self: *Bits, n: u7) error{InvalidData}!void {
        if (self.count < n) {
            self.refill();
            if (self.count < n) return error.InvalidData;
        }
    }

    inline fn take(self: *Bits, n: u6) u32 {
        const value: u32 = @intCast(self.buf & ((@as(u64, 1) << n) - 1));
        self.buf >>= n;
        self.count -= n;
        return value;
    }

    inline fn bits(self: *Bits, n: u6) error{InvalidData}!u32 {
        if (n == 0) return 0;
        try self.need(n);
        return self.take(n);
    }

    /// drop to the next byte boundary and return whole unread bytes to input
    fn alignToByte(self: *Bits) void {
        const drop: u6 = @intCast(self.count % 8);
        self.buf >>= drop;
        self.count -= drop;
        self.pos -= self.count / 8;
        self.buf = 0;
        self.count = 0;
    }

    /// the fast table answers when the code fits in its bits and enough bits
    /// are buffered; otherwise the slow path reads more as it goes
    inline fn decode(self: *Bits, table: anytype) error{InvalidData}!u16 {
        const entry = table.fast[@intCast(self.buf & (table.fast.len - 1))];
        const len: u7 = @intCast(entry >> 16);
        if (len != 0 and len <= self.count) {
            self.buf >>= @intCast(len);
            self.count -= len;
            return @truncate(entry);
        }
        return self.decodeSlow(table);
    }

    noinline fn decodeSlow(self: *Bits, table: anytype) error{InvalidData}!u16 {
        // canonical decode one bit at a time (RFC 1951's MSB-first codes)
        var code: i32 = 0;
        var first: i32 = 0;
        var index: i32 = 0;
        for (1..max_bits + 1) |l| {
            code |= @intCast(try self.bits(1));
            const count: i32 = table.counts[l];
            if (code - count < first) return table.symbols[@intCast(index + (code - first))];
            index += count;
            first += count;
            first <<= 1;
            code <<= 1;
        }
        return error.InvalidData;
    }
};

/// the decoded history and output. `window_end` bytes are the window from
/// earlier messages; everything after is this message so far.
pub const Output = struct {
    buf: std.ArrayList(u8) = .empty,
    window_end: usize = 0,
    /// most message bytes allowed, plus the window before them
    limit: usize = 0,

    fn reserve(self: *Output, gpa: Allocator, n: usize) Allocator.Error!void {
        try self.buf.ensureUnusedCapacity(gpa, @max(n, 32 * 1024));
    }

    inline fn room(self: *const Output) usize {
        return self.limit -| (self.buf.items.len - self.window_end);
    }
};

const Tables = struct {
    litlen: LitLen,
    dist: Dist,
    codelen: CodeLen,
    fixed_litlen: LitLen,
    fixed_dist: Dist,

    pub fn init(self: *Tables) void {
        var lengths: [288]u8 = undefined;
        @memset(lengths[0..144], 8);
        @memset(lengths[144..256], 9);
        @memset(lengths[256..280], 7);
        @memset(lengths[280..288], 8);
        self.fixed_litlen.build(&lengths, false) catch unreachable;
        var dist_lengths: [32]u8 = @splat(5);
        self.fixed_dist.build(&dist_lengths, false) catch unreachable;
    }
};

pub const Decoder = struct {
    tables: Tables,

    pub fn init(self: *Decoder) void {
        self.tables.init();
    }

    /// decode `payload` followed by `tail` into `out`, after its window. the
    /// input must end exactly at a block boundary; a BFINAL block ends one
    /// DEFLATE stream and the next byte starts another with the same window.
    pub fn decodeAll(self: *Decoder, gpa: Allocator, payload: []const u8, tail: []const u8, out: *Output) Error!void {
        var bits: Bits = .{ .payload = payload, .tail = tail };
        while (!bits.done()) {
            try bits.need(3);
            const final = bits.take(1) == 1;
            switch (bits.take(2)) {
                0 => try stored(gpa, &bits, out),
                1 => try huffman(gpa, &bits, out, &self.tables.fixed_litlen, &self.tables.fixed_dist),
                2 => {
                    try self.dynamicTables(&bits);
                    try huffman(gpa, &bits, out, &self.tables.litlen, &self.tables.dist);
                },
                else => return error.InvalidData,
            }
            if (final) bits.alignToByte();
        }
    }

    fn dynamicTables(self: *Decoder, bits: *Bits) Error!void {
        const nlen = try bits.bits(5) + 257;
        const ndist = try bits.bits(5) + 1;
        const ncode = try bits.bits(4) + 4;
        if (nlen > 286 or ndist > 30) return error.InvalidData;

        var codelen_lengths: [19]u8 = @splat(0);
        for (codelen_order[0..ncode]) |symbol| codelen_lengths[symbol] = @intCast(try bits.bits(3));
        try self.tables.codelen.build(&codelen_lengths, true);

        var lengths: [288 + 32]u8 = @splat(0);
        var i: usize = 0;
        while (i < nlen + ndist) {
            const symbol = try bits.decode(&self.tables.codelen);
            if (symbol < 16) {
                lengths[i] = @intCast(symbol);
                i += 1;
                continue;
            }
            var repeat: usize = undefined;
            var value: u8 = 0;
            switch (symbol) {
                16 => {
                    if (i == 0) return error.InvalidData;
                    value = lengths[i - 1];
                    repeat = 3 + try bits.bits(2);
                },
                17 => repeat = 3 + try bits.bits(3),
                else => repeat = 11 + try bits.bits(7),
            }
            if (i + repeat > nlen + ndist) return error.InvalidData;
            @memset(lengths[i..][0..repeat], value);
            i += repeat;
        }
        if (lengths[256] == 0) return error.InvalidData; // no end-of-block code
        try self.tables.litlen.build(lengths[0..nlen], false);
        try self.tables.dist.build(lengths[nlen..][0..ndist], false);
    }
};

fn stored(gpa: Allocator, bits: *Bits, out: *Output) Error!void {
    bits.alignToByte();
    if (bits.pos + 4 > bits.size()) return error.InvalidData;
    const p = bits.pos;
    const len = @as(u16, bits.byteAt(p)) | @as(u16, bits.byteAt(p + 1)) << 8;
    const nlen = @as(u16, bits.byteAt(p + 2)) | @as(u16, bits.byteAt(p + 3)) << 8;
    if (len != ~nlen) return error.InvalidData;
    bits.pos += 4;
    if (bits.pos + len > bits.size()) return error.InvalidData;
    if (len > out.room()) return error.MessageTooLarge;
    // the data may run from the payload into the tail
    const in_payload = bits.payload[@min(bits.pos, bits.payload.len)..@min(bits.pos + len, bits.payload.len)];
    try out.buf.appendSlice(gpa, in_payload);
    for (bits.pos + in_payload.len..bits.pos + len) |i| try out.buf.append(gpa, bits.byteAt(i));
    bits.pos += len;
}

/// bytes a match copy may write past its end: copies move whole 8-byte words
const copy_slack = 16;

/// decodes symbols while the next word of input is in the payload and the
/// output has room for an iteration's writes plus `copy_slack`. 56 buffered
/// bits cover a literal/length code, its extra bits, a distance code and its
/// extra bits, so one branchless refill per iteration is enough. the message
/// limit is checked per symbol before its bits are consumed, so a symbol that
/// would pass it is left for the careful path, which reports it. returns true
/// at end of block, false when the careful path must take the next symbol.
fn huffmanFast(bits: *Bits, out: *Output, litlen: *const LitLen, dist: *const Dist, end: usize) error{InvalidData}!bool {
    const in = bits.payload;
    var pos = bits.pos;
    var buf = bits.buf;
    var count = bits.count;
    const ptr = out.buf.items.ptr;
    var len = out.buf.items.len;
    const cap = out.buf.capacity;
    // one iteration writes at most two literals and a match
    const most = 2 + max_match;
    const result: bool = while (pos + 8 <= in.len and cap - len >= most + copy_slack) {
        buf |= std.mem.readInt(u64, in[pos..][0..8], .little) << @intCast(count);
        pos += (63 - @as(usize, count)) >> 3;
        count |= 56;

        var entry = litlen.fast[@intCast(buf & (litlen.fast.len - 1))];
        // up to two literals before the general case. after two 10-bit codes,
        // 36 bits remain: a length code and its extra bits (15) and a distance
        // code and its extra bits (21)
        inline for (0..2) |_| {
            if (entry >> 16 != 0 and @as(u16, @truncate(entry)) < 256 and len < end) {
                const lit_len: u6 = @intCast(entry >> 16);
                buf >>= lit_len;
                count -= lit_len;
                ptr[len] = @truncate(entry);
                len += 1;
                entry = litlen.fast[@intCast(buf & (litlen.fast.len - 1))];
            }
        }
        const code_len: u6 = @intCast(entry >> 16);
        if (code_len == 0) break false;
        const symbol: u16 = @truncate(entry);
        if (symbol < 256) {
            if (len >= end) break false;
            buf >>= code_len;
            count -= code_len;
            ptr[len] = @intCast(symbol);
            len += 1;
            continue;
        }
        if (symbol == 256) {
            buf >>= code_len;
            count -= code_len;
            break true;
        }
        const li = symbol - 257;
        if (li >= length_base.len) return error.InvalidData;
        const length_bits = length_extra[li];
        const length: usize = length_base[li] + @as(usize, @intCast((buf >> code_len) & ((@as(u64, 1) << length_bits) - 1)));
        if (length > end -| len) break false;
        buf >>= code_len;
        count -= code_len;
        buf >>= length_bits;
        count -= length_bits;

        const dentry = dist.fast[@intCast(buf & (dist.fast.len - 1))];
        const dcode_len: u6 = @intCast(dentry >> 16);
        if (dcode_len == 0) {
            // a distance code longer than the fast table: rare, so take the
            // canonical decode through the struct
            bits.* = .{ .payload = bits.payload, .tail = bits.tail, .pos = pos, .buf = buf, .count = count };
            out.buf.items.len = len;
            return huffmanSlowDistance(bits, out, dist, length);
        }
        buf >>= dcode_len;
        count -= dcode_len;
        const ds: u16 = @truncate(dentry);
        if (ds >= dist_base.len) return error.InvalidData;
        const dist_bits = dist_extra[ds];
        const distance: usize = dist_base[ds] + @as(usize, @intCast(buf & ((@as(u64, 1) << dist_bits) - 1)));
        buf >>= dist_bits;
        count -= dist_bits;
        if (distance > len) return error.InvalidData;
        copyMatch(ptr, len, distance, length);
        len += length;
    } else false;
    bits.pos = pos;
    bits.buf = buf;
    bits.count = count;
    out.buf.items.len = len;
    return result;
}

/// finishes a match whose distance code missed the fast table, then hands
/// back to the caller's loop
noinline fn huffmanSlowDistance(bits: *Bits, out: *Output, dist: *const Dist, length: usize) error{InvalidData}!bool {
    const ds = try bits.decode(dist);
    if (ds >= dist_base.len) return error.InvalidData;
    const distance: usize = dist_base[ds] + try bits.bits(dist_extra[ds]);
    const have = out.buf.items.len;
    if (distance > have) return error.InvalidData;
    copyMatch(out.buf.items.ptr, have, distance, length);
    out.buf.items.len += length;
    return false;
}

/// copies `length` bytes from `distance` back. may write up to `copy_slack`
/// bytes past the end, which the caller has room for.
inline fn copyMatch(ptr: [*]u8, at: usize, distance: usize, length: usize) void {
    const dst = ptr + at;
    const src = dst - distance;
    if (distance >= 8) {
        // each word read lies wholly before the bytes this copy writes next
        var i: usize = 0;
        while (i < length) : (i += 8) {
            const word: u64 = @as(*align(1) const u64, @ptrCast(src + i)).*;
            @as(*align(1) u64, @ptrCast(dst + i)).* = word;
        }
    } else if (distance == 1) {
        const word: u64 = @as(u64, src[0]) * 0x0101010101010101;
        var i: usize = 0;
        while (i < length) : (i += 8) @as(*align(1) u64, @ptrCast(dst + i)).* = word;
    } else {
        for (0..length) |k| dst[k] = src[k];
    }
}

fn huffman(gpa: Allocator, bits: *Bits, out: *Output, litlen: *const LitLen, dist: *const Dist) Error!void {
    // the message may not grow past this absolute length
    const end = std.math.add(usize, out.window_end, out.limit) catch std.math.maxInt(usize);
    while (true) {
        if (out.buf.capacity - out.buf.items.len < 2 + max_match + copy_slack) try out.reserve(gpa, 2 + max_match + copy_slack);
        if (try huffmanFast(bits, out, litlen, dist, end)) return;
        // the fast loop may have stopped for want of room: the careful
        // symbol below writes up to a whole match
        if (out.buf.capacity - out.buf.items.len < 2 + max_match + copy_slack) try out.reserve(gpa, 2 + max_match + copy_slack);
        // 48 bits cover a code, length extra, distance code and distance extra
        if (bits.count < 48) bits.refill();
        const symbol = try bits.decode(litlen);
        if (symbol < 256) {
            if (out.buf.items.len >= end) return error.MessageTooLarge;
            out.buf.items.ptr[out.buf.items.len] = @intCast(symbol);
            out.buf.items.len += 1;
            continue;
        }
        if (symbol == 256) return;
        const li = symbol - 257;
        if (li >= length_base.len) return error.InvalidData;
        const length: usize = length_base[li] + try bits.bits(length_extra[li]);
        const ds = try bits.decode(dist);
        if (ds >= dist_base.len) return error.InvalidData;
        const distance: usize = dist_base[ds] + try bits.bits(dist_extra[ds]);
        const have = out.buf.items.len;
        if (distance > have) return error.InvalidData;
        if (length > out.room()) return error.MessageTooLarge;
        const buf = out.buf.items.ptr;
        const src = have - distance;
        if (distance >= length) {
            @memcpy(buf[have..][0..length], buf[src..][0..length]);
        } else {
            // overlapping: repeats the last `distance` bytes
            for (0..length) |k| buf[have + k] = buf[src + k];
        }
        out.buf.items.len += length;
    }
}
