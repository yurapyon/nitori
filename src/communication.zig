const std = @import("std");
const Allocator = std.mem.Allocator;

const assert = std.debug.assert;

//;

const Error = error{
    OutOfSpace,
    Empty,
};

/// SPSC, lock-free push and pop
/// allocation free, data is fixed size
pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: *Allocator,
        data: []T,
        write_pt: usize,
        read_pt: usize,

        fn next_idx(self: Self, idx: usize) usize {
            return (idx + 1) % self.data.len;
        }

        pub fn init(allocator: *Allocator, count: usize) !Self {
            return Self{
                .allocator = allocator,
                .data = try allocator.alloc(T, count),
                .write_pt = 0,
                .read_pt = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.data);
        }

        pub fn push(self: *Self, val: T) !void {
            const read_pt = @atomicLoad(@TypeOf(self.read_pt), &self.read_pt, .Monotonic);
            if (read_pt == self.next_idx(self.write_pt)) {
                return error.OutOfSpace;
            }
            self.data[self.write_pt] = val;
            @fence(.SeqCst);
            self.write_pt = self.next_idx(self.write_pt);
        }

        pub fn pop(self: *Self) !T {
            const write_pt = @atomicLoad(@TypeOf(self.write_pt), &self.write_pt, .Monotonic);
            if (write_pt == self.read_pt) {
                return error.Empty;
            }
            const ret = self.data[self.read_pt];
            @fence(.SeqCst);
            self.read_pt = self.next_idx(self.read_pt);
            return ret;
        }
    };
}

/// MPSC, lock-free pop, uses spin lock to protect pushes
/// allocation free, doesnt own data
pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Receiver = struct {
            channel: *Self,

            pub fn tryRecv(self: *Receiver) ?T {
                return self.channel.pop() catch null;
            }
        };

        pub const Sender = struct {
            channel: *Self,

            pub fn send(self: *Sender, val: T) !void {
                return self.channel.push(val);
            }
        };

        queue: Queue(T),
        write_lock: bool,

        pub fn init(allocator: *Allocator, count: usize) !Self {
            return Self{
                .write_lock = false,
                .queue = try Queue(T).init(allocator, count),
            };
        }

        pub fn deinit(self: *Self) void {
            self.queue.deinit();
        }

        pub fn push(self: *Self, val: T) !void {
            while (@atomicRmw(@TypeOf(self.write_lock), &self.write_lock, .Xchg, true, .SeqCst)) {}
            defer assert(@atomicRmw(@TypeOf(self.write_lock), &self.write_lock, .Xchg, false, .SeqCst));
            return self.queue.push(val);
        }

        pub fn pop(self: *Self) !T {
            return self.queue.pop();
        }

        pub fn makeSender(self: *Self) Sender {
            return .{ .channel = self };
        }

        pub fn makeReceiver(self: *Self) Receiver {
            return .{ .channel = self };
        }
    };
}

/// MPSC, lock-free pop, uses spin lock to protect pushes
/// allocation free, doesnt own data
/// timed-stamped messages
pub fn EventChannel(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Event = struct {
            timestamp: u64,
            data: T,
        };

        // TODO use channel.receiver and sender
        pub const Receiver = struct {
            event_channel: *EventChannel(T),
            last_event: ?Event,

            pub fn tryRecv(self: *Receiver, now: u64) ?Event {
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

        pub fn init(allocator: *Allocator, count: usize) !Self {
            return Self{
                .channel = try Channel(Event).init(allocator, count),
            };
        }

        pub fn deinit(self: *Self) void {
            self.channel.deinit();
        }

        pub fn makeSender(self: *Self) Sender {
            return .{ .event_channel = self };
        }

        pub fn makeReceiver(self: *Self) Receiver {
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
    var q = try Queue(u8).init(testing.allocator, 15);
    defer q.deinit();
    try q.push(1);
    try q.push(2);
    try q.push(3);

    expect((try q.pop()) == 1);
    expect((try q.pop()) == 2);
    expect((try q.pop()) == 3);
}

test "EventChannel: send recv" {
    const EnvChan = EventChannel(u8);

    var chan = try EnvChan.init(testing.allocator, 50);
    defer chan.deinit();

    var send = chan.makeSender();
    var recv = chan.makeReceiver();

    var tm = @import("timer.zig").Timer.start();

    try send.send(tm.now(), 0);
    try send.send(tm.now(), 1);
    try send.send(tm.now(), 2);

    expect(recv.tryRecv(tm.now()).?.data == 0);
    expect(recv.tryRecv(tm.now()).?.data == 1);
    expect(recv.tryRecv(tm.now()).?.data == 2);

    const time = tm.now();

    try send.send(time, 0);
    try send.send(time + 10, 1);
    try send.send(time + 20, 2);

    expect(recv.tryRecv(time).?.data == 0);
    expect(recv.tryRecv(time) == null);
    expect(recv.tryRecv(time + 9) == null);
    expect(recv.tryRecv(time + 10).?.data == 1);
    expect(recv.tryRecv(time + 15) == null);
    expect(recv.tryRecv(time + 25).?.data == 2);
}
