const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;

const interface = @import("interface.zig");

//;

// is there a way to use command ids, less error prone
//   dont really like the "stringly typed" aspect
//   its not so bad, i think the alternatives are kindof complicated

// TODO maybe namespace Arg_ ?

// TODO maybe have more precice types, f32 f64, etc
pub const ArgValue = union(enum) {
    Symbol: []const u8,
    Int: i64,
    Float: f64,
    Boolean: bool,
};

pub const ArgType = @TagType(ArgValue);

pub const ArgDef = struct {
    ty: ArgType,
    name: []const u8,
    default: ?ArgValue = null,
};

pub const CommandDef = struct {
    name: []const u8,
    info: []const u8 = "",
    arg_defs: []const ArgDef,
    listener_ids: []const CommandLine.ListenerId,
};

pub const AliasDef = struct {
    name: []const u8,
    real_name: []const u8,
    // command_def: *const CommandDef,
};

pub const Listener = struct {
    pub const VTable = struct {
        listen: fn (Listener, []const u8, []const ArgValue) void,
    };

    impl: interface.Impl,
    vtable: *const VTable,

    pub fn init(impl: interface.Impl, vtable: *const VTable) Self {
        return .{
            .id = undefined,
            .impl = impl,
            .vtable = vtable,
        };
    }
};

pub const CommandLine = struct {
    pub const Self = @This();

    pub const Error = error{DuplicateName} || Allocator.Error;

    pub const ListenerId = usize;

    listeners: ArrayList(Listener),
    command_defs: StringHashMap(CommandDef),
    arg_values: ArrayList(ArgValue),

    pub fn init(allocator: *Allocator) Self {
        return .{
            .listeners = ArrayList(Listener).init(allocator),
            .command_defs = StringHashMap(CommandDef).init(allocator),
            .arg_values = ArrayList(ArgValue).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.arg_values.deinit();
        self.command_defs.deinit();
        self.listeners.deinit();
    }

    //;

    // TODO this autogenerates listener ids
    //   obviously less error prone, but is it as useful as being able to choose them yourself
    //   basically you cant create commands for listeners that dont exist yet
    pub fn addListener(self: *Self, listener: Listener) Allocator.Error!ListenerId {
        const id = self.listeners.items.len;
        try self.listeners.append(listener);
        return id;
    }

    pub fn addCommandDef(self: *Self, def: CommandDef) Error!void {
        if (self.command_defs.contains(def.name)) {
            return error.DuplicateName;
        }
        try self.command_defs.putNoClobber(def.name, def);
    }

    pub fn run(self: *Self, str: []const u8) !void {
        var iter = std.mem.tokenize(str, " ");
        const command = iter.next() orelse return error.InvalidCommand;
        const command_def = self.command_defs.get(command) orelse return error.CommandNotFound;

        self.arg_values.items.len = 0;

        for (command_def.arg_defs) |arg_def, i| {
            if (iter.next()) |token| {
                try self.arg_values.append(switch (arg_def.ty) {
                    .Symbol => .{ .Symbol = token },
                    .Int => .{ .Int = try std.fmt.parseInt(i64, token, 10) },
                    .Float => .{ .Float = try std.fmt.parseFloat(f64, token) },
                    .Boolean => .{
                        .Boolean = if (std.mem.eql(u8, token, "#t")) blk: {
                            break :blk true;
                        } else if (std.mem.eql(u8, token, "#f")) blk: {
                            break :blk false;
                        } else {
                            return error.InvalidValue;
                        },
                    },
                });
            } else {
                try self.arg_values.append(arg_def.default orelse return error.MissingValue);
            }
        }

        for (command_def.listener_ids) |id| {
            var listener = self.listeners.items[id];
            listener.vtable.listen(listener, command, self.arg_values.items);
        }
    }
};

// tests ===

const testing = std.testing;
const expect = testing.expect;

const Global = struct {
    const Self = @This();

    x: u8,
    y: bool,

    //;

    fn listener(self: *Self) Listener {
        return .{
            .impl = interface.Impl.init(self),
            .vtable = &comptime Listener.VTable{
                .listen = listen,
            },
        };
    }

    fn listen(
        l: Listener,
        msg: []const u8,
        args: []const ArgValue,
    ) void {
        var self = l.impl.cast(Self);

        if (std.mem.eql(u8, msg, "do-x")) {
            self.x = @intCast(u8, args[0].Int);
        }

        if (std.mem.eql(u8, msg, "do-y")) {
            self.y = args[0].Boolean;
        }
    }
};

test "cmd CommandLine" {
    var g: Global = .{
        .x = 0,
        .y = false,
    };

    var cmd = CommandLine.init(testing.allocator);
    defer cmd.deinit();

    const g_id = try cmd.addListener(g.listener());

    try cmd.addCommandDef(.{
        .name = "do-x",
        .arg_defs = &[_]ArgDef{
            .{
                .ty = .Int,
                .name = "number",
            },
        },
        .listener_ids = &[_]CommandLine.ListenerId{
            g_id,
        },
    });

    try cmd.addCommandDef(.{
        .name = "do-y",
        .arg_defs = &[_]ArgDef{
            .{
                .ty = .Boolean,
                .name = "t/f value",
            },
        },
        .listener_ids = &[_]CommandLine.ListenerId{
            g_id,
        },
    });

    expect(g.x == 0);
    try cmd.run("do-x 1");
    expect(g.x == 1);

    expect(!g.y);
    try cmd.run("do-y #t");
    expect(g.y);
}
