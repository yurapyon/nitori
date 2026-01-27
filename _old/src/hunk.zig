// based off of 'https://github.com/dbandstra/zig-hunk'

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const Allocator = std.mem.Allocator;

const interface = @import("interface.zig");

//;

const HunkSide = struct {
    const Self = @This();

    const VTable = struct {
        alloc: fn (*Self, usize, u29) Allocator.Error![]u8,
        deinitMemory: fn (*Self, usize) void,
    };

    impl: interface.Impl,
    vtable: *const VTable,

    hunk: *Hunk,
    allocator: Allocator,
    mark: usize,

    pub fn init(hunk: *Hunk, impl: interface.Impl, vtable: *const VTable) Self {
        return .{
            .impl = impl,
            .vtable = vtable,
            .hunk = hunk,
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

    fn resizeFn(
        allocator: *Allocator,
        buf: []u8,
        buf_align: u29,
        new_len: usize,
        len_align: u29,
        ret_addr: usize,
    ) Allocator.Error!usize {
        if (new_len == 0) {
            return 0;
        } else if (new_len <= buf.len) {
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
        fn alloc(side: *HunkSide, len: usize, ptr_align: u29) Allocator.Error![]u8 {
            const hunk = side.hunk;
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

        fn deinitMemory(side: *HunkSide, mark: usize) void {
            const hunk = side.hunk;
            std.mem.set(u8, hunk.buffer[mark..side.mark], undefined);
        }

        pub fn hunkSide(hunk: *Hunk) HunkSide {
            return HunkSide.init(
                hunk,
                interface.Impl.init(&Low{}),
                &comptime HunkSide.VTable{
                    .alloc = alloc,
                    .deinitMemory = deinitMemory,
                },
            );
        }
    };

    const High = struct {
        pub fn alloc(side: *HunkSide, len: usize, ptr_align: u29) Allocator.Error![]u8 {
            const hunk = side.hunk;
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
            const hunk = side.hunk;
            const start = hunk.buffer.len - side.mark;
            const end = hunk.buffer.len - mark;
            std.mem.set(u8, hunk.buffer[start..end], undefined);
        }

        pub fn hunkSide(hunk: *Hunk) HunkSide {
            return HunkSide.init(
                hunk,
                interface.Impl.init(&High{}),
                &comptime HunkSide.VTable{
                    .alloc = alloc,
                    .deinitMemory = deinitMemory,
                },
            );
        }
    };

    buffer: []u8,
    low: HunkSide,
    high: HunkSide,

    pub fn init(self: *Self, buffer: []u8) void {
        self.buffer = buffer;
        self.low = Low.hunkSide(self);
        self.high = High.hunkSide(self);
    }
};

// tests ===

const testing = std.testing;
const expect = testing.expect;

test "hunk" {
    var buffer: [20]u8 = undefined;
    var hunk: Hunk = undefined;
    hunk.init(buffer[0..]);

    {
        expect(hunk.high.getMark() == 0);

        _ = try hunk.high.allocator.alloc(u8, 3);
        expect(hunk.high.getMark() == 3);

        const mark = hunk.high.getMark();
        _ = try hunk.high.allocator.alloc(u8, 3);
        expect(hunk.high.getMark() == 6);

        hunk.high.freeToMark(mark);
        expect(hunk.high.getMark() == 3);
    }

    {
        expect(hunk.low.getMark() == 0);

        _ = try hunk.low.allocator.alloc(u8, 3);
        expect(hunk.low.getMark() == 3);

        const mark = hunk.low.getMark();
        _ = try hunk.low.allocator.alloc(u8, 3);
        expect(hunk.low.getMark() == 6);

        hunk.low.freeToMark(mark);
        expect(hunk.low.getMark() == 3);
    }

    hunk.low.freeToMark(0);
    hunk.high.freeToMark(0);

    {
        _ = try hunk.low.allocator.alloc(u8, 10);

        const mark = hunk.high.getMark();
        _ = try hunk.high.allocator.alloc(u8, 10);

        testing.expectError(error.OutOfMemory, hunk.high.allocator.alloc(u8, 1));
        testing.expectError(error.OutOfMemory, hunk.low.allocator.alloc(u8, 1));

        hunk.high.freeToMark(mark);
        _ = try hunk.high.allocator.alloc(u8, 1);
        _ = try hunk.low.allocator.alloc(u8, 1);
    }
}
