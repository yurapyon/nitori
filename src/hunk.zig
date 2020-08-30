// based off of 'https://github.com/dbandstra/zig-hunk'

const std = @import("std");
const builtin = @import("builtin");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const vtable = @import("vtable.zig");

//;

const HunkSide = struct {
    const Self = @This();

    const VTable = struct {
        alloc: fn (*HunkSide, usize, u29) Allocator.Error![]u8,
        deinitMemory: fn (*HunkSide, usize) void,
    };

    vtable: *const VTable,
    allocator: Allocator,
    mark: usize,

    pub fn init(comptime SideType: type) Self {
        return .{
            .vtable = comptime vtable.populate(VTable, SideType),
            .allocator = .{
                .allocFn = allocFn,
                .resizeFn = resizeFn,
            },
            .mark = 0,
        };
    }

    pub fn getMark(self: *Self) usize {
        return self.mark;
    }

    pub fn freeToMark(self: *Self, mark: usize) void {
        assert(mark <= self.mark);
        if (mark == self.mark) return;
        if (builtin.mode == builtin.Mode.Debug) {
            self.vtable.deinitMemory(self, mark);
        }
        self.mark = mark;
    }

    fn allocFn(
        allocator: *Allocator,
        len: usize,
        ptr_align: u29,
        len_align: u29,
        ret_addr: usize,
    ) Allocator.Error![]u8 {
        const self = @fieldParentPtr(Self, "allocator", allocator);
        const real_len = if (len_align == 0) len else blk: {
            break :blk std.mem.alignBackwardAnyAlign(len, len_align);
        };
        return self.vtable.alloc(self, real_len, ptr_align);
    }

    // in place resize
    // return possible len that this allocation could be resized to
    fn resizeFn(
        allocator: *Allocator,
        buf: []u8,
        buf_align: u29,
        new_len: usize,
        len_align: u29,
        ret_addr: usize,
    ) Allocator.Error!usize {
        if (new_len == 0) {
            // free memory
            // in this case its a no-op and leaks memory
            return 0;
        } else if (new_len <= buf.len) {
            // TODO is this right to use?
            return std.mem.alignAllocLen(buf.len, new_len, len_align);
        } else {
            // TODO interesting idea would be to allow this if resizing the last allocation
            //  only works for low hunk
            //  but would allow for fast realloc of an ArrayList
            return error.OutOfMemory;
        }
    }
};

const Hunk = struct {
    const Self = @This();

    const Low = struct {
        pub fn alloc(side: *HunkSide, len: usize, ptr_align: u29) Allocator.Error![]u8 {
            const hunk = @fieldParentPtr(Hunk, "low", side);

            const buf_start = @ptrToInt(hunk.buffer.ptr);
            const adj_idx = std.mem.alignForward(buf_start + hunk.low.mark, ptr_align) - buf_start;
            const next_mark = adj_idx + len;
            if (next_mark > hunk.buffer.len - hunk.high.mark) {
                return error.OutOfMemory;
            }
            const ret = hunk.buffer[adj_idx..next_mark];
            hunk.low.mark += len;
            return ret;
        }

        pub fn deinitMemory(side: *HunkSide, mark: usize) void {
            const hunk = @fieldParentPtr(Hunk, "low", side);
            std.mem.set(u8, hunk.buffer[mark..side.mark], undefined);
        }
    };

    const High = struct {
        pub fn alloc(side: *HunkSide, len: usize, ptr_align: u29) Allocator.Error![]u8 {
            const hunk = @fieldParentPtr(Hunk, "high", side);

            const buf_start = @ptrToInt(hunk.buffer.ptr);
            const buf_end = buf_start + hunk.buffer.len;
            const adj_idx = std.mem.alignBackward(buf_end - hunk.high.mark, ptr_align) - buf_start;
            const next_mark = adj_idx - len;
            if (next_mark < hunk.low.mark) {
                return error.OutOfMemory;
            }
            const ret = hunk.buffer[next_mark..adj_idx];
            hunk.high.mark += len;
            return ret;
        }

        pub fn deinitMemory(side: *HunkSide, mark: usize) void {
            const hunk = @fieldParentPtr(Hunk, "high", side);
            const start = hunk.buffer.len - side.mark;
            const end = hunk.buffer.len - mark;
            std.mem.set(u8, hunk.buffer[start..end], undefined);
        }
    };

    buffer: []u8,
    low: HunkSide,
    high: HunkSide,

    pub fn init(buffer: []u8) Self {
        return .{
            .buffer = buffer,
            .low = HunkSide.init(Low),
            .high = HunkSide.init(High),
        };
    }
};

// tests ===

const testing = std.testing;

test "hunk" {
    // test a few random operations. very low coverage. write more later
    var buf: [100]u8 = undefined;
    var hunk = Hunk.init(buf[0..]);

    const high_mark = hunk.high.getMark();

    _ = try hunk.low.allocator.alloc(u8, 7);
    _ = try hunk.high.allocator.alloc(u8, 8);

    testing.expectEqual(@as(usize, 7), hunk.low.mark);
    testing.expectEqual(@as(usize, 8), hunk.high.mark);

    _ = try hunk.high.allocator.alloc(u8, 8);

    testing.expectEqual(@as(usize, 16), hunk.high.mark);

    const low_mark = hunk.low.getMark();

    _ = try hunk.low.allocator.alloc(u8, 100 - 7 - 16);

    testing.expectEqual(@as(usize, 100 - 16), hunk.low.mark);

    testing.expectError(error.OutOfMemory, hunk.high.allocator.alloc(u8, 1));

    hunk.low.freeToMark(low_mark);

    _ = try hunk.high.allocator.alloc(u8, 1);

    hunk.high.freeToMark(high_mark);

    testing.expectEqual(@as(usize, 0), hunk.high.mark);
}
