const std = @import("std");

pub const Impl = struct {
    const Self = @This();
    const Ptr = opaque {};

    ptr: ?*Ptr,

    pub fn initEmpty() Self {
        return .{ .ptr = null };
    }

    pub fn init(ptr: anytype) Self {
        const T = @typeInfo(@TypeOf(ptr)).Pointer.child;
        return if (@sizeOf(T) == 0)
            .{ .ptr = null }
        else
            .{ .ptr = @ptrCast(*Ptr, ptr) };
    }

    pub fn cast(self: *const Self, comptime T: type) *T {
        comptime std.debug.assert(@sizeOf(T) != 0);
        return @ptrCast(*T, @alignCast(@alignOf(T), self.ptr));
    }
};

// testing ===

const Ret = enum {
    Default, ZeroSized, Sized
};

const Interface = struct {
    const Self = @This();

    const VTable = struct {
        method: fn (self: Self) Ret = _method,
        fn _method(self: Self) Ret {
            return Ret.Default;
        }
    };

    impl: Impl,
    vtable: *const VTable,

    fn method(self: Self) Ret {
        return self.vtable.method(self);
    }
};

const ZeroSized = struct {
    const Self = @This();

    fn interface(self: *Self) Interface {
        return .{
            .impl = Impl.init(self),
            .vtable = &comptime Interface.VTable{
                .method = method,
            },
        };
    }

    fn method(i: Interface) Ret {
        return Ret.ZeroSized;
    }
};

const Sized = struct {
    const Self = @This();

    val: Ret = Ret.Sized,

    fn interface(self: *Self) Interface {
        return .{
            .impl = Impl.init(self),
            .vtable = &comptime Interface.VTable{
                .method = method,
            },
        };
    }

    fn method(i: Interface) Ret {
        var self = i.impl.cast(Self);
        return self.val;
    }
};

test "interface" {
    var z = ZeroSized{};
    var s = Sized{};

    std.testing.expectEqual(z.interface().method(), Ret.ZeroSized);
    std.testing.expectEqual(s.interface().method(), Ret.Sized);
}
