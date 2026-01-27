const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

// ===

// TODO maybe make it so ptrs hold offsets rather than pointers, and cant be invalidated by pool resizes
//  maybe make it so this thing can be easier resized?

// could further increase cache locality by doing a binary search to kill objects
//   or something
// some way of using the lowest offsets first so theyre all usually in one spot

pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Iter = struct {
            pool: *const Self,
            idx: usize,

            pub fn next(self: *Iter) ?*const T {
                if (self.idx >= self.pool.alive_ct) {
                    return null;
                } else {
                    const get = &self.pool.data.items[self.pool.offsets.items[self.idx]];
                    self.idx += 1;
                    return get;
                }
            }
        };

        pub const IterMut = struct {
            pool: *Self,
            idx: usize,

            pub fn next(self: *IterMut) ?*T {
                if (self.idx >= self.pool.alive_ct) {
                    return null;
                } else {
                    const get = &self.pool.data.items[self.pool.offsets.items[self.idx]];
                    self.idx += 1;
                    return get;
                }
            }
        };

        pub const Ptr = struct {
            pool: *Self,
            obj: *T,

            pub fn kill(self: *Ptr) void {
                self.pool.kill(self.obj);
            }

            // TODO
            pub fn killStable(self: *Ptr) void {
                _ = self;
            }
        };

        data: ArrayList(T),
        offsets: ArrayList(usize),
        alive_ct: usize,

        pub fn init(self: *@This(), allocator: Allocator, initial_size: usize) !void {
            var data = try ArrayList(T).initCapacity(allocator, initial_size);
            data.appendNTimesAssumeCapacity(undefined, initial_size);

            var offsets = try ArrayList(usize).initCapacity(allocator, initial_size);
            var i: usize = 0;
            while (i < initial_size) : (i += 1) {
                offsets.append(allocator, i) catch unreachable;
            }

            // TODO
            self.data = data;
            self.offsets = offsets;
            self.alive_ct = 0;
        }

        pub fn deinit(self: *@This(), allocator: Allocator) void {
            self.offsets.deinit(allocator);
            self.data.deinit(allocator);
        }

        //;

        // asserts pool isnt empty
        pub fn spawn(self: *@This()) *T {
            assert(!self.isEmpty());
            const at = self.alive_ct;
            self.alive_ct += 1;
            return &self.data.items[self.offsets.items[at]];
        }

        // TODO maybe return an error here instead
        //    if not, rename to maybeSpawn
        pub fn trySpawn(self: *@This()) ?*T {
            if (self.isEmpty()) return null;
            return self.spawn();
        }

        // TODO killStable
        // asserts this object is from this pool, and is alive
        pub fn kill(self: *@This(), obj: *T) void {
            // assert ptr is from this pool
            assert(blk: {
                const t = @intFromPtr(obj);
                const d = @intFromPtr(self.data.items.ptr);
                break :blk t >= d and t < (d + self.data.items.len * @sizeOf(T));
            });

            // assert ptr is alive
            assert(blk: {
                const t = @intFromPtr(obj);
                const d = @intFromPtr(self.data.items.ptr);
                const o = (t - d) / @sizeOf(T);
                var i: usize = 0;
                while (i < self.alive_ct) : (i += 1) {
                    if (self.offsets.items[i] == o) {
                        break :blk true;
                    }
                }
                break :blk false;
            });

            const obj_ptr = @intFromPtr(obj);
            const data_ptr = @intFromPtr(self.data.items.ptr);
            const offset = (obj_ptr - data_ptr) / @sizeOf(T);

            self.alive_ct -= 1;

            var i: usize = 0;
            while (i < self.alive_ct) : (i += 1) {
                if (self.offsets.items[i] == offset) {
                    std.mem.swap(
                        usize,
                        &self.offsets.items[self.alive_ct],
                        &self.offsets.items[i],
                    );
                }
            }
        }

        pub fn spawnPtr(self: *@This()) Ptr {
            return .{
                .pool = self,
                .obj = self.spawn(),
            };
        }

        //;

        // this function may invalidate pointers to objects in the pool
        //   if you plan to use this function it's recommended let the pool manage the memory for you,
        //     using iterators and reclaim
        pub fn pleaseSpawn(self: *@This(), allocator: Allocator) !*T {
            if (self.isEmpty()) {
                try self.offsets.append(
                    allocator,
                    self.data.items.len,
                );
                _ = try self.data.addOne(allocator);
            }
            return self.spawn();
        }

        pub fn iter(self: *const @This()) Iter {
            return .{
                .pool = self,
                .idx = 0,
            };
        }

        pub fn iterMut(self: *@This()) IterMut {
            return .{
                .pool = self,
                .idx = 0,
            };
        }

        pub fn reclaim(self: *@This(), killFn: fn (*T) bool) void {
            var len = self.alive_ct;
            var i: usize = 0;
            while (i < len) {
                if (killFn(&self.data.items[self.offsets.items[i]])) {
                    len -= 1;
                    std.mem.swap(
                        usize,
                        &self.offsets.items[i],
                        &self.offsets.items[len],
                    );
                }
                i += 1;
            }
            self.alive_ct = len;
        }

        pub fn reclaimStable(self: *@This(), killFn: fn (*T) bool) void {
            const len = self.alive_ct;
            var del: usize = 0;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                if (killFn(&self.data.items[self.offsets.items[i]])) {
                    del += 1;
                } else if (del > 0) {
                    std.mem.swap(
                        usize,
                        &self.offsets.items[i],
                        &self.offsets.items[i - del],
                    );
                }
            }
            self.alive_ct -= del;
        }

        //;

        // TODO
        //   attach
        //   detach
        //   sort the dead

        //;

        pub fn isEmpty(self: @This()) bool {
            return self.deadCount() == 0;
        }

        pub fn aliveCount(self: @This()) usize {
            return self.alive_ct;
        }

        pub fn deadCount(self: @This()) usize {
            return self.offsets.items.len - self.alive_ct;
        }

        pub fn capacity(self: @This()) usize {
            return self.offsets.items.len;
        }
    };
}

// tests ===

const testing = std.testing;
const expect = testing.expect;

fn killEven(value: *u8) bool {
    return value.* % 2 == 0;
}

fn kill3(value: *u8) bool {
    return value.* == 3;
}

test "Pool" {
    var pool: Pool(u8) = undefined;
    try pool.init(testing.allocator, 10);
    defer pool.deinit(testing.allocator);

    pool.trySpawn().?.* = 1;
    pool.trySpawn().?.* = 2;
    pool.trySpawn().?.* = 3;
    pool.trySpawn().?.* = 4;
    pool.trySpawn().?.* = 5;
    try expect(pool.aliveCount() == 5);

    var iter = pool.iter();

    // order is guaranteed in the order you spawned them
    try expect(iter.next().?.* == 1);
    try expect(iter.next().?.* == 2);
    try expect(iter.next().?.* == 3);
    try expect(iter.next().?.* == 4);
    try expect(iter.next().?.* == 5);
    try expect(iter.next() == null);

    // won't mess with order
    pool.reclaimStable(killEven);
    try expect(pool.aliveCount() == 3);

    iter = pool.iter();
    try expect(iter.next().?.* == 1);
    try expect(iter.next().?.* == 3);
    try expect(iter.next().?.* == 5);
    try expect(iter.next() == null);

    // may mess with the order
    pool.reclaim(kill3);
    try expect(pool.aliveCount() == 2);

    var found_one: bool = false;
    var found_five: bool = false;

    iter = pool.iter();
    while (iter.next()) |val| {
        if (val.* == 1) {
            try expect(!found_one);
            found_one = true;
        } else if (val.* == 5) {
            try expect(!found_five);
            found_five = true;
        }
    }

    try expect(found_one);
    try expect(found_five);

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        pool.trySpawn().?.* = 0;
    }

    try expect(pool.trySpawn() == null);

    _ = try pool.pleaseSpawn(testing.allocator);

    try expect(pool.capacity() == 11);
    try expect(pool.aliveCount() == 11);
    try expect(pool.isEmpty());
}

test "Pool kill" {
    var pool: Pool(u8) = undefined;
    try pool.init(testing.allocator, 10);
    defer pool.deinit(testing.allocator);

    const obj = pool.spawn();
    try expect(pool.aliveCount() == 1);
    pool.kill(obj);
    try expect(pool.aliveCount() == 0);
}
