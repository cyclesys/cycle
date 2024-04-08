//! A Cycle type definition.
tag: []const Tag,
data: []const Data,
ident: []const u8,

pub const Tag = enum {
    void,

    i8,
    i16,
    i32,
    i64,
    i128,

    u8,
    u16,
    u32,
    u64,
    u128,

    f16,
    f32,
    f64,
    f128,

    bool,
    str,
    ref,

    opt,
    array,
    list,
    map,

    @"struct",
    tuple,
    @"enum",
    @"union",

    field,
    ident,
};

pub const Data = packed struct(u64) {
    lhs: u32,
    rhs: u32,
};

pub const Index = u32;

// Used in constructing `Type`s.
pub const NodeList = std.MultiArrayList(Node);
pub const Node = struct {
    tag: Tag,
    data: Data,
};
pub const IdentList = std.ArrayListUnmanaged(u8);

const std = @import("std");
const Type = @This();

pub fn deinit(self: *Type, allocator: std.mem.Allocator) void {
    allocator.free(self.tag);
    allocator.free(self.data);
    allocator.free(self.ident);
    self.* = undefined;
}
