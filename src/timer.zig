const std = @import("std");

pub const Timer = struct {
    const Self = @This();

    tm: std.time.Timer,
    last_now: u64,

    pub fn start() Self {
        return .{
            // TODO what to do with error
            .tm = std.time.Timer.start() catch unreachable,
            .last_now = 0,
        };
    }

    pub fn now(self: *Self) u64 {
        const time = self.tm.read();
        _ = @atomicRmw(@TypeOf(self.last_now), &self.last_now, .Max, time, .Monotonic);
        return self.last_now;
    }
};

// tests ===

const expect = std.testing.expect;

test "Timer" {
    var tm = Timer.start();
    const first = tm.now();

    expect(tm.now() > first);
    expect(tm.now() > first);
    expect(tm.now() > first);
}
