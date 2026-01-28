const std = @import("std");
const Allocator = std.mem.Allocator;

const assert = std.debug.assert;

// ===

/// SPSC, lock-free push and pop
/// allocation free, data is fixed size
pub fn Queue(comptime T: type) type {
    return struct {
        allocator: Allocator,
        data: []T,
        write_pt: usize,
        read_pt: usize,

        fn nextIndex(self: @This(), idx: usize) usize {
            return (idx + 1) % self.data.len;
        }

        pub fn init(self: *@This(), allocator: Allocator, count: usize) !void {
            self.allocator = allocator;
            self.data = try allocator.alloc(T, count);
            self.write_pt = 0;
            self.read_pt = 0;
        }

        pub fn deinit(self: *@This()) void {
            self.allocator.free(self.data);
        }

        pub fn push(self: *@This(), val: T) !void {
            const read_pt = @atomicLoad(
                @TypeOf(self.read_pt),
                &self.read_pt,
                .monotonic,
            );
            if (read_pt == self.nextIndex(self.write_pt)) {
                return error.Overflow;
            }
            self.data[self.write_pt] = val;
            self.write_pt = self.nextIndex(self.write_pt);
        }

        pub fn pop(self: *@This()) !T {
            const write_pt = @atomicLoad(
                @TypeOf(self.write_pt),
                &self.write_pt,
                .monotonic,
            );
            if (write_pt == self.read_pt) {
                return error.Underflow;
            }
            const ret = self.data[self.read_pt];
            self.read_pt = self.nextIndex(self.read_pt);
            return ret;
        }
    };
}

/// MPSC, lock-free pop, uses spin lock to protect pushes
/// allocation free, doesnt own data
pub fn Channel(comptime T: type) type {
    return struct {
        pub const Receiver = struct {
            channel: *Channel(T),

            pub fn recieve(self: *Receiver) ?T {
                return self.channel.pop() catch null;
            }
        };

        pub const Sender = struct {
            channel: *Channel(T),

            pub fn send(self: *Sender, val: T) !void {
                return self.channel.push(val);
            }
        };

        queue: Queue(T),
        write_lock: bool,

        pub fn init(self: *@This(), allocator: Allocator, count: usize) !void {
            self.write_lock = false;
            try self.queue.init(allocator, count);
        }

        pub fn deinit(self: *@This()) void {
            self.queue.deinit();
        }

        pub fn push(self: *@This(), val: T) !void {
            while (@atomicRmw(
                @TypeOf(self.write_lock),
                &self.write_lock,
                .Xchg,
                true,
                .seq_cst,
            )) {}
            defer assert(@atomicRmw(
                @TypeOf(self.write_lock),
                &self.write_lock,
                .Xchg,
                false,
                .seq_cst,
            ));

            return self.queue.push(val);
        }

        pub fn pop(self: *@This()) !T {
            return self.queue.pop();
        }

        pub fn makeSender(self: *@This()) Sender {
            return .{ .channel = self };
        }

        pub fn makeReceiver(self: *@This()) Receiver {
            return .{ .channel = self };
        }
    };
}

/// MPSC, lock-free pop, uses spin lock to protect pushes
/// allocation free, doesnt own data
/// timed-stamped messages
pub fn EventChannel(comptime T: type) type {
    return struct {
        // TODO this could probably have its own timer and send all messages with tm.now() ?

        pub const Event = struct {
            timestamp: u64,
            data: T,
        };

        // TODO use channel.receiver and sender
        pub const Receiver = struct {
            event_channel: *EventChannel(T),
            last_event: ?Event,

            pub fn recieve(self: *Receiver, now: u64) ?Event {
                if (self.last_event) |ev| {
                    if (ev.timestamp <= now) {
                        self.last_event = null;
                        return ev;
                    } else {
                        return null;
                    }
                } else {
                    const get = self.event_channel.channel.pop() catch {
                        return null;
                    };

                    if (get.timestamp <= now) {
                        return get;
                    } else {
                        self.last_event = get;
                        return null;
                    }
                }
            }
        };

        pub const Sender = struct {
            event_channel: *EventChannel(T),

            pub fn send(self: *Sender, timestamp: u64, data: T) !void {
                // TODO make sure this timestamp isnt before the last one pushed
                // invalid timestamp error
                return self.event_channel.channel.push(.{
                    .timestamp = timestamp,
                    .data = data,
                });
            }
        };

        channel: Channel(Event),

        pub fn init(self: *@This(), allocator: Allocator, count: usize) !void {
            try self.channel.init(allocator, count);
        }

        pub fn deinit(self: *@This()) void {
            self.channel.deinit();
        }

        pub fn makeSender(self: *@This()) Sender {
            return .{ .event_channel = self };
        }

        pub fn makeReceiver(self: *@This()) Receiver {
            return .{
                .event_channel = self,
                .last_event = null,
            };
        }
    };
}

// tests ===

const testing = std.testing;
const expect = testing.expect;

test "Queue: push pop" {
    var q: Queue(u8) = undefined;

    try q.init(testing.allocator, 15);
    defer q.deinit();

    try q.push(1);
    try q.push(2);
    try q.push(3);

    try expect((try q.pop()) == 1);
    try expect((try q.pop()) == 2);
    try expect((try q.pop()) == 3);
}

test "EventChannel: send recv" {
    var chan: EventChannel(u8) = undefined;

    try chan.init(testing.allocator, 50);
    defer chan.deinit();

    var send = chan.makeSender();
    var recv = chan.makeReceiver();

    var tm = try @import("os-timer.zig").OSTimer.start();

    try send.send(tm.now(), 0);
    try send.send(tm.now(), 1);
    try send.send(tm.now(), 2);

    try expect(recv.recieve(tm.now()).?.data == 0);
    try expect(recv.recieve(tm.now()).?.data == 1);
    try expect(recv.recieve(tm.now()).?.data == 2);

    const time = tm.now();

    try send.send(time, 0);
    try send.send(time + 10, 1);
    try send.send(time + 20, 2);

    try expect(recv.recieve(time).?.data == 0);
    try expect(recv.recieve(time) == null);
    try expect(recv.recieve(time + 9) == null);
    try expect(recv.recieve(time + 10).?.data == 1);
    try expect(recv.recieve(time + 15) == null);
    try expect(recv.recieve(time + 25).?.data == 2);
}
