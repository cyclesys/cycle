//! A Cycle type definition.
tag: []const Tag,
data: []const Data,
ident: []const u8,

pub const Tag = enum(u8) {
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

pub fn identStr(self: Type, start: Index) []const u8 {
    return std.mem.sliceTo(self.ident[start..], 0);
}

pub fn eql(left: Type, right: Type) bool {
    if (left.tag.len != right.tag.len or
        left.ident.len != right.ident.len)
    {
        return false;
    }

    return nodeEql(left, 0, right, 0);
}

fn nodeEql(left: Type, left_node: Index, right: Type, right_node: Index) bool {
    if (left.tag[left_node] != right.tag[right_node]) {
        return false;
    }

    switch (left.tag[left_node]) {
        .void,

        .i8,
        .i16,
        .i32,
        .i64,
        .i128,

        .u8,
        .u16,
        .u32,
        .u64,
        .u128,

        .f16,
        .f32,
        .f64,
        .f128,

        .bool,
        .str,
        .ref,
        => {
            return true;
        },

        .opt, .list => {
            const left_child = left.data[left_node].lhs;
            const right_child = right.data[right_node].lhs;
            return nodeEql(left, left_child, right, right_child);
        },

        .array => {
            const left_size = left.data[left_node].rhs;
            const right_size = right.data[right_node].rhs;
            if (left_size != right_size) {
                return false;
            }

            const left_child = left.data[left_node].lhs;
            const right_child = right.data[right_node].lhs;
            return nodeEql(left, left_child, right, right_child);
        },

        .@"struct" => {
            return nodeFieldsEql(left, left_node, right, right_node, nodeFieldIdentAndTypeEql);
        },

        .tuple => {
            return nodeFieldsEql(left, left_node, right, right_node, nodeFieldTypeEql);
        },

        .@"enum" => {
            const left_tag = left.data[left_node].rhs;
            const right_tag = right.data[right_node].rhs;
            if (!nodeEql(left, left_tag, right, right_tag)) {
                return false;
            }

            return nodeFieldsEql(left, left_node, right, right_node, nodeFieldIdentEql);
        },

        .@"union" => {
            const left_tag = left.data[left_node].rhs;
            const right_tag = left.data[right_node].rhs;
            if (left_tag != 0) {
                if (right_tag == 0 or !nodeEql(left, left_tag, right, right_tag)) {
                    return false;
                }
            } else if (right_tag != 0) {
                return false;
            }

            return nodeFieldsEql(left, left_node, right, right_node, nodeFieldIdentAndTypeEql);
        },

        .field, .ident => unreachable,
    }
}

const EqlFn = fn (left: Type, left_node: Index, right: Type, right_node: Index) bool;

fn nodeFieldsEql(left: Type, left_node: Index, right: Type, right_node: Index, comptime fieldEqlFn: EqlFn) bool {
    var left_tail: Index = left.data[left_node].lhs;
    var right_tail: Index = right.data[right_node].lhs;
    while (left_tail != 0) {
        if (right_tail == 0 or !fieldEqlFn(left, left_tail, right, right_tail)) {
            return false;
        }
        left_tail = left.data[left_tail].rhs;
        right_tail = right.data[right_tail].rhs;
    }
    return right_tail == 0;
}

fn nodeFieldIdentAndTypeEql(left: Type, left_node: Index, right: Type, right_node: Index) bool {
    const left_ident = left.data[left_node].lhs;
    const right_ident = right.data[right_node].lhs;
    return nodeFieldIdentEql(left, left_node, right, right_node) and
        nodeFieldTypeEql(left, left_ident, right, right_ident);
}

fn nodeFieldIdentEql(left: Type, left_node: Index, right: Type, right_node: Index) bool {
    const left_ident = left.data[left_node].lhs;
    const right_ident = right.data[right_node].lhs;
    return std.mem.eql(
        u8,
        left.identStr(left.data[left_ident].rhs),
        right.identStr(right.data[right_ident].rhs),
    );
}

fn nodeFieldTypeEql(left: Type, left_node: Index, right: Type, right_node: Index) bool {
    const left_field_type = left.data[left_node].lhs;
    const right_field_type = right.data[right_node].lhs;
    return nodeEql(left, left_field_type, right, right_field_type);
}

test "primitives eql" {
    try expectTypeEql(void);

    try expectTypeEql(i8);
    try expectTypeEql(i16);
    try expectTypeEql(i32);
    try expectTypeEql(i64);
    try expectTypeEql(i128);

    try expectTypeEql(u8);
    try expectTypeEql(u16);
    try expectTypeEql(u32);
    try expectTypeEql(u64);
    try expectTypeEql(u128);

    try expectTypeEql(f16);
    try expectTypeEql(f32);
    try expectTypeEql(f64);
    try expectTypeEql(f128);

    try expectTypeEql(bool);
    try expectTypeEql(zig.Str);
    try expectTypeEql(zig.Ref);
}

test "opt eql" {
    try expectTypeEql(?u8);
}

test "array eql" {
    try expectTypeEql([8]u8);
}

test "list eql" {
    try expectTypeEql(zig.List(u8));
}

test "struct eql" {
    try expectTypeEql(struct {
        f1: u8,
        f2: ?u16,
        f3: [10]u32,
        f4: zig.List(u64),
    });
}

test "tuple eql" {
    try expectTypeEql(struct {
        u8,
        ?u16,
        [10]u32,
        zig.List(u64),
    });
}

test "enum eql" {
    try expectTypeEql(enum {
        f1,
        f2,
        f3,
        f4,
    });
}

test "untagged union eql" {
    try expectTypeEql(union {
        f1: u8,
        f2: ?u16,
        f3: [10]u32,
        f4: zig.List(u64),
    });
}

test "tagged union eql" {
    try expectTypeEql(union(enum) {
        f1: u8,
        f2: ?u16,
        f3: [10]u32,
        f4: zig.List(u64),
    });
}

test "complex type eql" {
    try expectTypeEql(struct {
        f1: ?u32,
        f2: [16]u16,
        f3: struct {
            void,
            struct {
                u16,
            },
        },
        f4: enum {
            f1,
            f2,
            f3,
        },
        f5: union {
            f1: struct {
                u16,
            },
            f2: union(enum) {
                f1: zig.List(u16),
            },
        },
        f6: union(enum) {
            f1: void,
            f2: enum {
                f1,
                f2,
            },
        },
    });
}

test "structs not eql" {
    try expectTypesNotEql(
        struct {
            f1: ?u32,
            f2: [16]u16,
        },
        struct {
            f1: ?u32,
            f2: [8]u16,
        },
    );
}

test "enums not eql" {
    try expectTypesNotEql(
        enum {
            f1,
            f2,
            f3,
        },
        enum {
            f1,
            f2,
            f4,
        },
    );
}

test "unions not eql" {
    try expectTypesNotEql(
        union {
            f1: void,
            f2: u8,
        },
        union(enum) {
            f1: void,
            f2: u8,
        },
    );
}

const zig = @import("zig.zig");

// expects that a type equals itself
fn expectTypeEql(comptime T: type) !void {
    var ty = try zig.initType(std.testing.allocator, T);
    defer ty.deinit(std.testing.allocator);

    try std.testing.expect(ty.eql(ty));
}

fn expectTypesNotEql(comptime Left: type, comptime Right: type) !void {
    var left = try zig.initType(std.testing.allocator, Left);
    defer left.deinit(std.testing.allocator);

    var right = try zig.initType(std.testing.allocator, Right);
    defer right.deinit(std.testing.allocator);

    try std.testing.expect(!left.eql(right));
}
