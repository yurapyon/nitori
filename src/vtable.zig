// based off of 'https://github.com/Hejsil/zig-interface'

// no restriction on params
//   vtable fns dont have to be methods
//   can work with ZSTs
// optional fns

// TODO figure out a way to have it soe some implementors can be ZSTs and some not

const std = @import("std");
const builtin = @import("builtin");
const TypeInfo = builtin.TypeInfo;

const assert = std.debug.assert;

//;

fn checkCompatibility(
    comptime VTable: type,
    comptime T: type,
    comptime expect: TypeInfo.Fn,
    comptime actual: TypeInfo.Fn,
) void {
    assert(!expect.is_generic);
    assert(!expect.is_var_args);

    assert(expect.calling_convention == actual.calling_convention);
    assert(expect.is_generic == actual.is_generic);
    assert(expect.is_var_args == actual.is_var_args);
    assert(expect.return_type.? == actual.return_type.?);
    assert(expect.args.len == actual.args.len);

    for (expect.args) |expect_arg, i| {
        const actual_arg = actual.args[i];
        assert(!expect_arg.is_generic);
        assert(expect_arg.is_generic == actual_arg.is_generic);
        assert(expect_arg.is_noalias == actual_arg.is_noalias);

        const expect_arg_info = @typeInfo(expect_arg.arg_type.?);
        if (i == 0 and
            expect_arg_info == .Pointer and
            @hasDecl(VTable, "Impl") and
            expect_arg_info.Pointer.child == VTable.Impl)
        {
            const expect_ptr = expect_arg_info.Pointer;
            const actual_ptr = @typeInfo(actual_arg.arg_type.?).Pointer;
            assert(expect_ptr.size == TypeInfo.Pointer.Size.One);
            assert(actual_ptr.child == T or
                actual_ptr.child == VTable.Impl);
            assert(expect_ptr.size == actual_ptr.size);
            assert(expect_ptr.is_const == actual_ptr.is_const);
            assert(expect_ptr.is_volatile == actual_ptr.is_volatile);
        } else {
            assert(expect_arg.arg_type.? == actual_arg.arg_type.?);
        }
    }
}

pub fn populate(comptime VTable: type, comptime T: type) *const VTable {
    const Global = struct {
        const vtable = blk: {
            var ret: VTable = undefined;
            inline for (@typeInfo(VTable).Struct.fields) |field_info| {
                // currently, accessing default values is a compiler bug
                //   see issue 'https://github.com/ziglang/zig/issues/5508'
                //   for now, use optionals instead
                const FieldType = field_info.field_type;
                switch (@typeInfo(FieldType)) {
                    .Fn => |expect| {
                        const field = @field(T, field_info.name);
                        const actual = @typeInfo(@TypeOf(field)).Fn;
                        checkCompatibility(VTable, T, expect, actual);
                        @field(ret, field_info.name) = @ptrCast(FieldType, field);
                    },
                    .Optional => |opt| {
                        const FnType = opt.child;
                        const expect = @typeInfo(FnType).Fn;

                        var found_impl_decl: ?TypeInfo.Declaration = null;
                        inline for (@typeInfo(T).Struct.decls) |impl_decl| {
                            if (std.mem.eql(u8, field_info.name, impl_decl.name)) {
                                found_impl_decl = impl_decl;
                            }
                        }

                        const field = if (found_impl_decl) |found|
                            @field(T, found.name)
                        else
                            @field(VTable, field_info.name);

                        const actual = @typeInfo(@TypeOf(field)).Fn;
                        checkCompatibility(VTable, T, expect, actual);
                        @field(ret, field_info.name) = @ptrCast(FnType, field);
                    },
                    else => {
                        assert(false);
                    },
                }
            }
            break :blk ret;
        };
    };
    return &Global.vtable;
}

// tests ===

const Obj = struct {
    const Self = @This();

    const VTable = struct {
        doSomething1: fn () void,
        doSomething2: ?fn (usize) usize,

        fn doSomething2(in: usize) usize {
            std.log.warn("default do something 2: {}\n", .{in + 2});
            return in + 2;
        }
    };

    vtable: *const VTable,

    fn init(obj: anytype) Obj {
        return .{
            .vtable = comptime populate(VTable, @TypeOf(obj).Child),
        };
    }

    fn doSomething1(self: *Self) void {
        self.vtable.doSomething1();
    }

    fn doSomething2(self: *Self, in: usize) usize {
        return self.vtable.doSomething2.?(in);
    }
};

// TODO make a better test

test "interface" {
    var o1 = Obj.init(&struct {
        fn doSomething1() void {
            std.log.warn("o1 do something 1\n", .{});
        }

        fn doSomething2(in: usize) usize {
            std.log.warn("o1 do something 2: {}\n", .{in + 3});
            return in + 3;
        }
    }{});

    var o2 = Obj.init(&struct {
        fn doSomething1() void {
            std.log.warn("o2 do something 1\n", .{});
        }
    }{});

    o1.doSomething1();
    _ = o1.doSomething2(10);
    o2.doSomething1();
    _ = o2.doSomething2(10);
}
