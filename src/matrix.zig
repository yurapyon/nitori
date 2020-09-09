const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn Matrix(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: *Allocator,
        data: []T,
        width: usize,
        height: usize,

        pub fn init(allocator: *Allocator, width: usize, height: usize) !Self {
            const data = try allocator.alloc(T, width * height);
            return Self{
                .allocator = allocator,
                .data = data,
                .width = width,
                .height = height,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.data);
        }

        pub fn get(self: Self, x: usize, y: usize) *const T {
            return &self.data[y * self.width + x];
        }

        pub fn get_mut(self: *Self, x: usize, y: usize) *T {
            return &self.data[y * self.width + x];
        }
    };
}

// tests ===

const expect = std.testing.expect;

test "matrix Matrix" {
    var matr = try Matrix(u8).init(std.testing.allocator, 10, 5);
    defer matr.deinit();
}
