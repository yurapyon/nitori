const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Iter = struct {
            pool: *Self,
            idx: usize,

            pub fn next(self: *Iter) ?*T {
                if (self.idx >= self.pool.alive_ct) {
                    return null;
                } else {
                    const get = &self.pool.data.items[self.pool.offsets.items[self.idx]];
                    self.idx += 1;
                    return get;
                }
            }
        };

        data: ArrayList(T),
        offsets: ArrayList(usize),
        alive_ct: usize,

        pub fn init(allocator: *Allocator, initial_size: usize) !Self {
            var data = try ArrayList(T).initCapacity(allocator, initial_size);
            data.appendNTimesAssumeCapacity(undefined, initial_size);

            var offsets = try ArrayList(usize).initCapacity(allocator, initial_size);
            var i: usize = 0;
            while (i < initial_size) : (i += 1) {
                offsets.append(i) catch unreachable;
            }

            return Self{
                .data = data,
                .offsets = offsets,
                .alive_ct = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.offsets.deinit();
            self.data.deinit();
        }

        //;

        // undefined behavior if pool has no available objects
        pub fn spawn(self: *Self) *T {
            const at = self.alive_ct;
            self.alive_ct += 1;
            return &self.data.items[self.offsets.items[at]];
        }

        pub fn trySpawn(self: *Self) ?*T {
            if (self.isEmpty()) return null;

            const at = self.alive_ct;
            self.alive_ct += 1;
            return &self.data.items[self.offsets.items[at]];
        }

        // may invalidate old pointers,
        //   for this reason, its not a good idea to save pointers returned by spawn
        //   let the pool manage the memory for you, use iterators and reclaim
        pub fn pleaseSpawn(self: *Self) !*T {
            if (self.isEmpty()) {
                try self.offsets.append(self.data.items.len);
                _ = try self.data.addOne();
            }
            return self.spawn();
        }

        pub fn iter(self: *Self) Iter {
            return .{
                .pool = self,
                .idx = 0,
            };
        }

        pub fn reclaim(self: *Self, killFn: fn (*T) bool) void {
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

        pub fn reclaimStable(self: *Self, killFn: fn (*T) bool) void {
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

        //;

        pub fn isEmpty(self: Self) bool {
            return self.deadCount() == 0;
        }

        pub fn aliveCount(self: Self) usize {
            return self.alive_ct;
        }

        pub fn deadCount(self: Self) usize {
            return self.offsets.items.len - self.alive_ct;
        }

        pub fn capacity(self: Self) usize {
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
    var pool = try Pool(u8).init(testing.allocator, 10);
    defer pool.deinit();

    pool.trySpawn().?.* = 1;
    pool.trySpawn().?.* = 2;
    pool.trySpawn().?.* = 3;
    pool.trySpawn().?.* = 4;
    pool.trySpawn().?.* = 5;
    expect(pool.aliveCount() == 5);

    var iter = pool.iter();

    // order is guaranteed in the order you spawned them
    expect(iter.next().?.* == 1);
    expect(iter.next().?.* == 2);
    expect(iter.next().?.* == 3);
    expect(iter.next().?.* == 4);
    expect(iter.next().?.* == 5);
    expect(iter.next() == null);

    // won't mess with order
    pool.reclaimStable(killEven);
    expect(pool.aliveCount() == 3);

    iter = pool.iter();
    expect(iter.next().?.* == 1);
    expect(iter.next().?.* == 3);
    expect(iter.next().?.* == 5);
    expect(iter.next() == null);

    // may mess with the order
    pool.reclaim(kill3);
    expect(pool.aliveCount() == 2);

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        pool.trySpawn().?.* = 0;
    }

    expect(pool.trySpawn() == null);

    _ = try pool.pleaseSpawn();

    expect(pool.capacity() == 11);
    expect(pool.aliveCount() == 11);
    expect(pool.isEmpty());
}
