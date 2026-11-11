//! regressions for defects an adversarial review found

const std = @import("std");
const pmdeflate = @import("root.zig");

const t = std.testing;

test "a stored block cut short is refused, not filled from the receiver's tail" {
    // a final stored block claiming 9 bytes that the payload does not carry.
    // reading on into the appended 00 00 ff ff must not complete it.
    const inflater = try pmdeflate.Inflater.create(t.allocator, .{});
    defer inflater.destroy();
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try t.expectError(error.InvalidData, inflater.decompress("\x01\x09\x00\xf6\xff", &out.writer, 1 << 16));
    try t.expectEqual(@as(usize, 0), out.written().len);
}

/// the stored-block payload of an incompressible message `len` bytes long
fn storedPayload(gpa: std.mem.Allocator, len: usize) ![]u8 {
    const deflater = try pmdeflate.Deflater.create(gpa, .{});
    defer deflater.destroy();
    const message = try gpa.alloc(u8, len);
    defer gpa.free(message);
    var prng: std.Random.DefaultPrng = .init(7);
    prng.random().bytes(message);
    return gpa.dupe(u8, try deflater.compress(message));
}

/// counts live heap bytes, to see what an inflater keeps between messages
const Counting = struct {
    child: std.mem.Allocator,
    live: usize = 0,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, a, ra) orelse return null;
        self.live += len;
        return p;
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(m, a, n, ra)) return false;
        self.live = self.live + n - m.len;
        return true;
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(m, a, n, ra) orelse return null;
        self.live = self.live + n - m.len;
        return p;
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.child.rawFree(m, a, ra);
        self.live -= m.len;
    }
};

/// what an idle inflater may keep: its tables plus the retained window
const idle_bound = 512 * 1024;

test "a refused large payload leaves no payload-sized buffer behind" {
    const payload = try storedPayload(t.allocator, 4 << 20);
    defer t.allocator.free(payload);
    var counting: Counting = .{ .child = t.allocator };
    const inflater = try pmdeflate.Inflater.create(counting.allocator(), .{});
    defer inflater.destroy();
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try t.expectError(error.MessageTooLarge, inflater.decompress(payload, &out.writer, 16));
    inflater.reset();
    try t.expect(counting.live <= idle_bound);
}

