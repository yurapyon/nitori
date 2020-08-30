const std = @import("std");

const Allocator = std.mem.Allocator;

const interface = @import("interface.zig");

//;

const HunkSide = struct {
    const Self = @This();

    const Interface = struct {
        const Impl = @Type(.Opaque);

        alloc: fn (*Impl, usize, u29) Allocator.Error![]u8,
        getMark: fn (*Impl) usize,
        freeToMark: fn (*Impl, usize) void,
    };

    interface: *const Interface,
    impl: *Interface.Impl,
    allocator: Allocator,

    pub fn init(hunk_side: anytype) Self {
        return .{
            .interface = comptime interface.populate(Interface, @TypeOf(hunk_side).Child),
            .impl = @ptrCast(*Interface.Impl, hunk_side),
            .allocator = .{
                .allocFn = allocFn,
                .resizeFn = resizeFn,
            },
        };
    }

    pub fn getMark(self: *Self) usize {
        return self.interface.getMark(self.impl);
    }

    pub fn freeToMark(self: *Self, mark: usize) void {
        return self.interface.freeToMark(self.impl, mark);
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
        return self.interface.alloc(self.impl, real_len, ptr_align);
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
};
