const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;

// make sure this supports adding new commands at runtime
// aliases
// dont have a fixed buffer of array values, just use ArrayList
// completion? spell check?

// no internal command for 'help'

// DefaultCommandLine
//   maybe have a history controller thing
//   built in text buffer
//   help command

// could associate commandDefs with data, like a fake closure

//  defaults can only come at the end of the args list

pub const ArgType = enum {
    Symbol,
    Int,
    Float,
    Boolean,
};

// TODO maybe have more precice types, f32 f64, etc
pub const ArgValue = union {
    Symbol: []const u8,
    Int: i64,
    Float: f64,
    Boolean: bool,
};

pub const ArgDef = struct {
    ty: ArgType,
    name: []const u8,
    default: ?ArgValue,
};

pub fn CommandLine(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const CommandDef = struct {
            name: []const u8,
            info: []const u8,
            args: []const ArgDef,
            func: fn (global_data: *T, args: []const ArgValue) void,

            // TODO maybe do this on init
            //        have init fn that takes an allocator
            //      makes things kinda complicated in general, but makes sense
            //        usage doesnt change
            //      just generate usage for argdefs, dont attach this commands name to it
            //        can be reused by alias
            pub fn generateUsage(self: CommandDef, allocator: *Allocator) []u8 {
                //;
            }
        };

        pub const AliasDef = struct {
            name: []const u8,
            command_def: *CommandDef,

            pub fn generateUsage(self: CommandDef, allocator: *Allocator) []u8 {
                //;
            }
        };

        allocator: *Allocator,
        command_defs: StringHashMap(CommandDef),
        history: ArrayList([]u8),
        // TODO make this an array list
        //    but resize based on command that surrently can take the most args
        temp_args: [256]ArgValue,

        pub fn init(allocator: *Allocator) Self {
            return Self{
                .allocator = allocator,
                .command_defs = StringHashMap(CommandDef).init(allocator),
                .history = ArrayList([]u8).init(allocator),
                .temp_args = undefined,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.history.items) |*str| {
                self.allocator.free(str.*);
            }
            self.history.deinit();
            self.command_defs.deinit();
        }

        //;

        pub fn addCommandDef(self: *Self, def: CommandDef) !void {
            if (self.command_defs.contains(def.name)) {
                return error.DuplicateName;
            }
            return self.command_defs.putNoClobber(def.name, def);
        }

        // TODO
        //   ability to run a command with a command struct and args, not only strings
        //     or at least command name and args
        pub fn run(self: *Self, str: []const u8, global_data: *T) !void {
            try self.history.append(try self.allocator.dupe(u8, str));

            var iter = std.mem.tokenize(str, " ");
            const command = iter.next() orelse return error.InvalidCommand;
            const command_def = self.command_defs.get(command) orelse return error.CommandNotFound;

            // TODO just slice self.temp_args,
            //   but dont do this and actually use an array list you append to
            var arg_values: []ArgValue = undefined;
            arg_values.ptr = &self.temp_args;
            arg_values.len = command_def.args.len;

            for (command_def.args) |arg_def, i| {
                if (iter.next()) |token| {
                    self.temp_args[i] = switch (arg_def.ty) {
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
                    };
                } else {
                    self.temp_args[i] = arg_def.default orelse return error.MissingValue;
                }
            }

            command_def.func(global_data, arg_values);
        }
    };
}

// tests ===

const testing = std.testing;
const expect = testing.expect;

const Global = struct {
    x: u8,
    y: bool,

    fn doX(self: *Global, args: []const ArgValue) void {
        self.x = @intCast(u8, args[0].Int);
    }

    fn doY(self: *Global, args: []const ArgValue) void {
        self.y = args[0].Boolean;
    }
};

test "cmd CommandLine" {
    var g: Global = .{
        .x = 0,
        .y = false,
    };
    var cmd = CommandLine(Global).init(testing.allocator);
    defer cmd.deinit();
    try cmd.addCommandDef(.{
        .name = "do-x",
        .info = "do something to x",
        .args = &[_]ArgDef{
            .{
                .ty = .Int,
                .name = "number",
                .default = null,
            },
        },
        .func = Global.doX,
    });
    try cmd.addCommandDef(.{
        .name = "do-y",
        .info = "do something to y",
        .args = &[_]ArgDef{
            .{
                .ty = .Boolean,
                .name = "t/f value",
                .default = null,
            },
        },
        .func = Global.doY,
    });
    expect(g.x == 0);
    try cmd.run("do-x 1", &g);
    expect(g.x == 1);

    expect(!g.y);
    try cmd.run("do-y #t", &g);
    expect(g.y);
}
