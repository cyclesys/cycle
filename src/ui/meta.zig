const std = @import("std");
pub usingnamespace @import("../meta.zig");

pub fn FieldType(comptime T: type, comptime name: []const u8) type {
    return std.meta.FieldType(T, @enumFromInt(
        std.meta.fieldIndex(T, name),
    ));
}
