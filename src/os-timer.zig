const std = @import("std");

// ===

const ZigTimer = std.time.Timer;

pub const OSTimer = struct {
    tm: ZigTimer,
    last_now: u64,

    pub fn start() !@This() {
        return .{
            .tm = try ZigTimer.start(),
            .last_now = 0,
        };
    }

    pub fn now(self: *@This()) u64 {
        const time = self.tm.read();
        _ = @atomicRmw(
            @TypeOf(self.last_now),
            &self.last_now,
            .Max,
            time,
            .monotonic,
        );
        return self.last_now;
    }
};

// tests ===

const expect = std.testing.expect;

test "OSTimer" {
    var tm = try OSTimer.start();
    const first = tm.now();

    try expect(tm.now() > first);
    try expect(tm.now() > first);
    try expect(tm.now() > first);
}
