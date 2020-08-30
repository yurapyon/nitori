pub const chunks = @import("chunks.zig");
pub const hunk = @import("hunk.zig");
pub const vtable = @import("vtable.zig");

test "" {
    _ = @import("chunks.zig");
    _ = @import("hunk.zig");
    _ = @import("vtable.zig");
}
