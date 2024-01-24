const std = @import("std");
const lib = @import("lib");

const Self = @This();

pub fn init(allocator: std.mem.Allocator) Self {
    _ = allocator;
}
