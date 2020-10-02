const std = @import("std");

const _Timer = std.time.Timer;

pub const Timer = struct {
    const Self = @This();

    tm: _Timer,
    last_now: u64,

    pub fn start() _Timer.Error!Self {
        return Self{
            .tm = try _Timer.start(),
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
    var tm = try Timer.start();
    const first = tm.now();

    expect(tm.now() > first);
    expect(tm.now() > first);
    expect(tm.now() > first);
}
