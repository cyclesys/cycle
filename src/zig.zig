//! Functianality for interacting with the Cycle runtime using Zig.
//! Used internally by the system module, and lang module.
const std = @import("std");
const Type = @import("Type.zig");

const DefKind = enum {
    str,
    ref,
    list,
    map,
};

/// Defines a Cycle string type.
pub const Str = struct {
    pub const def_kind = DefKind.str;
};

/// Defines Cycle object reference type.
pub const Ref = struct {
    pub const def_kind = DefKind.ref;
};

/// Defines a Cycle list type.
pub fn List(comptime Child: type) type {
    return struct {
        pub const def_kind = DefKind.list;
        pub const child = Child;
    };
}

/// Defines a Cycle map type.
pub fn Map(comptime Key: type, comptime Value: type) type {
    return struct {
        pub const def_kind = DefKind.map;
        pub const key = Key;
        pub const value = Value;
    };
}

/// Initializes Cycle type equivalent of the given Zig type.
pub fn initType(allocator: std.mem.Allocator, comptime T: type) !Type {
    var s = InitType{
        .allocator = allocator,
        .nodes = .{},
        .idents = .{},
    };
    _ = try appendType(&s, T);

    var nodes = s.nodes.toOwnedSlice();
    defer nodes.deinit(allocator);

    const tag = try allocator.dupe(Type.Tag, nodes.items(.tag));
    const data = try allocator.dupe(Type.Data, nodes.items(.data));
    const ident = try s.idents.toOwnedSlice(allocator);

    return Type{
        .tag = tag,
        .data = data,
        .ident = ident,
    };
}

const InitType = struct {
    allocator: std.mem.Allocator,
    nodes: Type.NodeList,
    idents: Type.IdentList,
};

fn appendType(s: *InitType, comptime T: type) !Type.Index {
    switch (@typeInfo(T)) {
        .Void => {
            return try appendNode(s, .void);
        },
        .Bool => {
            return try appendNode(s, .bool);
        },
        .Int => |int| {
            const tag: Type.Tag = switch (int.signedness) {
                .signed => switch (int.bits) {
                    8 => .i8,
                    16 => .i16,
                    32 => .i32,
                    64 => .i64,
                    128 => .i128,
                    else => @compileError("unsupported"),
                },
                .unsigned => switch (int.bits) {
                    8 => .u8,
                    16 => .u16,
                    32 => .u32,
                    64 => .u64,
                    128 => .u128,
                    else => @compileError("unsupported"),
                },
            };
            return try appendNode(s, tag);
        },
        .Float => |float| {
            const tag: Type.Tag = switch (float.bits) {
                8 => .f8,
                16 => .f16,
                32 => .f32,
                64 => .f64,
                128 => .f128,
                else => @compileError("unsupported"),
            };
            return try appendNode(s, tag);
        },
        .Optional => |opt| {
            const node = try appendNode(s, .opt);
            setLhs(s, node, try appendType(s, opt.child));
            return node;
        },
        .Array => |arr| {
            if (arr.sentinel != null) {
                @compileError("unsupported");
            }

            const node = try appendNode(s, .array);
            setLhs(s, node, try appendType(s, arr.child));
            setRhs(s, node, arr.len);
            return node;
        },
        .Struct => |info| {
            if (info.backing_integer != null or info.layout != .Auto) {
                @compileError("unsupported");
            }

            if (@hasDecl(T, "def_kind")) {
                switch (T.def_kind) {
                    DefKind.str => {
                        return try appendNode(s, .str);
                    },
                    DefKind.ref => {
                        return try appendNode(s, .ref);
                    },
                    DefKind.list => {
                        const node = try appendNode(s, .list);
                        setLhs(s, node, try appendType(s, T.child));
                        return node;
                    },
                    DefKind.map => {
                        const node = try appendNode(s, .map);
                        setLhs(s, node, try appendType(s, T.key));
                        setRhs(s, node, try appendType(s, T.value));
                        return node;
                    },
                }
            }

            if (info.is_tuple) {
                const node = try appendNode(s, .tuple);

                var tail: Type.Index = 0;
                inline for (info.fields) |field| {
                    if (field.is_comptime or field.default_value != null) {
                        @compileError("unsupported");
                    }

                    const field_node = try appendNode(s, .field);
                    setLhs(s, field_node, try appendType(s, field.type));
                    setRhs(s, field_node, 0);
                    appendChild(s, node, tail, field_node);
                    tail = field_node;
                }

                return node;
            }

            const node = try appendNode(s, .@"struct");

            var tail: Type.Index = 0;
            inline for (info.fields) |field| {
                if (field.is_comptime or field.default_value != null) {
                    @compileError("unsupported");
                }

                const field_node = try appendNode(s, .field);
                setRhs(s, field_node, 0);

                const field_ident = try appendIdent(s, field.name);
                setLhs(s, field_ident, try appendType(s, field.type));

                setLhs(s, field_node, field_ident);
                appendChild(s, node, tail, field_node);
                tail = field_node;
            }

            return node;
        },
        .Enum => |info| {
            const node = try appendNode(s, .@"enum");

            // give the tag a uniform size and alignment.
            const EnumTag = std.meta.Int(.unsigned, @sizeOf(info.tag_type) * 8);
            setRhs(s, node, try appendType(s, EnumTag));

            var tail: Type.Index = 0;
            inline for (info.fields) |field| {
                const field_node = try appendNode(s, .field);
                setLhs(s, field_node, try appendIdent(s, field.name));
                setRhs(s, field_node, 0);
                appendChild(s, node, tail, field_node);
                tail = field_node;
            }

            return node;
        },
        .Union => |info| {
            const node = try appendNode(s, .@"union");

            if (info.tag_type) |tag_type| {
                const tag_info = @typeInfo(tag_type).Enum;

                // union tag types can be zero-sized if the union only has one field.
                const UnionTag = if (@sizeOf(tag_info.tag_type) == 0)
                    // union tags must be at least 1 byte
                    u8
                else
                    // give the tag a uniform size and alignment
                    std.meta.Int(.unsigned, @sizeOf(tag_info.tag_type) * 8);

                setRhs(s, node, try appendType(s, UnionTag));
            }

            var tail: Type.Index = 0;
            inline for (info.fields) |field| {
                const field_node = try appendNode(s, .field);
                setRhs(s, field_node, 0);

                const field_ident = try appendIdent(s, field.name);
                setLhs(s, field_ident, try appendType(s, field.type));

                setLhs(s, field_node, field_ident);
                appendChild(s, node, tail, field_node);
                tail = field_node;
            }
            return node;
        },
        else => @compileError("unsupported"),
    }
}

fn appendIdent(s: *InitType, comptime ident: []const u8) !Type.Index {
    const index: Type.Index = @intCast(s.idents.items.len);
    try s.idents.appendSlice(s.allocator, ident);
    try s.idents.append(s.allocator, 0);

    const node = try appendNode(s, .ident);
    setRhs(s, node, index);
    return node;
}

fn appendNode(s: *InitType, tag: Type.Tag) !Type.Index {
    const index: Type.Index = @intCast(s.nodes.len);
    try s.nodes.append(s.allocator, Type.Node{
        .tag = tag,
        .data = Type.Data{
            .lhs = 0,
            .rhs = 0,
        },
    });
    return index;
}

inline fn appendChild(s: *const InitType, node: Type.Index, tail: Type.Index, child: Type.Index) void {
    if (tail == 0) {
        setLhs(s, node, child);
    } else {
        setRhs(s, tail, child);
    }
}

inline fn setLhs(s: *const InitType, index: Type.Index, lhs: u32) void {
    s.nodes.items(.data)[index].lhs = lhs;
}

inline fn setRhs(s: *const InitType, index: Type.Index, rhs: u32) void {
    s.nodes.items(.data)[index].rhs = rhs;
}

test "init primitive types" {
    try expectType(void, .{ .tag = .void });

    try expectType(i8, .{ .tag = .i8 });
    try expectType(i16, .{ .tag = .i16 });
    try expectType(i32, .{ .tag = .i32 });
    try expectType(i64, .{ .tag = .i64 });
    try expectType(i128, .{ .tag = .i128 });

    try expectType(u8, .{ .tag = .u8 });
    try expectType(u16, .{ .tag = .u16 });
    try expectType(u32, .{ .tag = .u32 });
    try expectType(u64, .{ .tag = .u64 });
    try expectType(u128, .{ .tag = .u128 });

    try expectType(f16, .{ .tag = .f16 });
    try expectType(f32, .{ .tag = .f32 });
    try expectType(f64, .{ .tag = .f64 });
    try expectType(f128, .{ .tag = .f128 });

    try expectType(bool, .{ .tag = .bool });
    try expectType(Str, .{ .tag = .str });
    try expectType(Ref, .{ .tag = .ref });
}

test "init optional" {
    try expectType(?u32, .{
        .tag = .opt,
        .lhs_child = &.{ .tag = .u32 },
    });
}

test "init list" {
    try expectType(List(u32), .{
        .tag = .list,
        .lhs_child = &.{ .tag = .u32 },
    });
}

test "init array" {
    try expectType([16]u32, .{
        .tag = .array,
        .lhs_child = &.{ .tag = .u32 },
        .rhs_value = 16,
    });
}

test "init map" {
    try expectType(Map(u32, u64), .{
        .tag = .map,
        .lhs_child = &.{ .tag = .u32 },
        .rhs_child = &.{ .tag = .u64 },
    });
}

test "init struct" {
    try expectType(struct {
        field0: i32,
        field1: Str,
        field2: List(u8),
    }, .{
        .tag = .@"struct",
        .lhs_children = &.{
            .{
                .tag = .field,
                .lhs_child = &.{
                    .tag = .ident,
                    .lhs_child = &.{ .tag = .i32 },
                    .rhs_ident = "field0",
                },
            },
            .{
                .tag = .field,
                .lhs_child = &.{
                    .tag = .ident,
                    .lhs_child = &.{ .tag = .str },
                    .rhs_ident = "field1",
                },
            },
            .{
                .tag = .field,
                .lhs_child = &.{
                    .tag = .ident,
                    .lhs_child = &.{
                        .tag = .list,
                        .lhs_child = &.{ .tag = .u8 },
                    },
                    .rhs_ident = "field2",
                },
            },
        },
    });
}

test "init tuple" {
    try expectType(struct {
        i32,
        Str,
        List(u8),
    }, .{
        .tag = .tuple,
        .lhs_children = &.{
            .{
                .tag = .field,
                .lhs_child = &.{ .tag = .i32 },
            },
            .{
                .tag = .field,
                .lhs_child = &.{ .tag = .str },
            },
            .{
                .tag = .field,
                .lhs_child = &.{
                    .tag = .list,
                    .lhs_child = &.{ .tag = .u8 },
                },
            },
        },
    });
}

test "init enum" {
    try expectType(enum {
        field0,
        field1,
        field2,
    }, .{
        .tag = .@"enum",
        .lhs_children = &.{
            .{
                .tag = .field,
                .lhs_child = &.{
                    .tag = .ident,
                    .rhs_ident = "field0",
                },
            },
            .{
                .tag = .field,
                .lhs_child = &.{
                    .tag = .ident,
                    .rhs_ident = "field1",
                },
            },
            .{
                .tag = .field,
                .lhs_child = &.{
                    .tag = .ident,
                    .rhs_ident = "field2",
                },
            },
        },
        .rhs_child = &.{ .tag = .u8 },
    });
}

test "init untagged union" {
    try expectType(union {
        field0: u32,
        field1: Str,
        field2: Map(u32, Str),
    }, .{
        .tag = .@"union",
        .lhs_children = &.{
            .{
                .tag = .field,
                .lhs_child = &.{
                    .tag = .ident,
                    .lhs_child = &.{ .tag = .u32 },
                    .rhs_ident = "field0",
                },
            },
            .{
                .tag = .field,
                .lhs_child = &.{
                    .tag = .ident,
                    .lhs_child = &.{ .tag = .str },
                    .rhs_ident = "field1",
                },
            },
            .{
                .tag = .field,
                .lhs_child = &.{
                    .tag = .ident,
                    .lhs_child = &.{
                        .tag = .map,
                        .lhs_child = &.{ .tag = .u32 },
                        .rhs_child = &.{ .tag = .str },
                    },
                    .rhs_ident = "field2",
                },
            },
        },
        .rhs_value = 0,
    });
}

test "init tagged union" {
    try expectType(union(enum) {
        field0: u8,
        field2: u8,
    }, .{
        .tag = .@"union",
        .lhs_child = &.{
            .tag = .field,
            .lhs_child = &.{
                .tag = .ident,
                .lhs_child = &.{ .tag = .u8 },
                .rhs_ident = "field0",
            },
        },
        .rhs_child = &.{ .tag = .u8 },
    });
}

test "init complex type" {
    try expectType(struct {
        field0: struct {
            field0: bool,
            field1: u8,
        },
        field1: struct {
            u32,
            i32,
        },
        field2: enum {
            field0,
            field1,
        },
        field3: union {
            field0: List(u8),
        },
        field4: union(enum) {
            field0: Map(u32, Ref),
        },
        field5: [3]struct {
            field0: ?Str,
        },
    }, .{
        .tag = .@"struct",
        .lhs_children = &.{
            .{
                .tag = .field,
                .lhs_child = &.{
                    .tag = .ident,
                    .lhs_child = &.{
                        .tag = .@"struct",
                        .lhs_children = &.{
                            .{
                                .tag = .field,
                                .lhs_child = &.{
                                    .tag = .ident,
                                    .lhs_child = &.{ .tag = .bool },
                                    .rhs_ident = "field0",
                                },
                            },
                            .{
                                .tag = .field,
                                .lhs_child = &.{
                                    .tag = .ident,
                                    .lhs_child = &.{ .tag = .u8 },
                                    .rhs_ident = "field1",
                                },
                            },
                        },
                    },
                    .rhs_ident = "field0",
                },
            },
            .{
                .tag = .field,
                .lhs_child = &.{
                    .tag = .ident,
                    .lhs_child = &.{
                        .tag = .tuple,
                        .lhs_children = &.{
                            .{
                                .tag = .field,
                                .lhs_child = &.{ .tag = .u32 },
                            },
                            .{
                                .tag = .field,
                                .lhs_child = &.{ .tag = .i32 },
                            },
                        },
                    },
                    .rhs_ident = "field1",
                },
            },
            .{
                .tag = .field,
                .lhs_child = &.{
                    .tag = .ident,
                    .lhs_child = &.{
                        .tag = .@"enum",
                        .lhs_children = &.{
                            .{
                                .tag = .field,
                                .lhs_child = &.{
                                    .tag = .ident,
                                    .rhs_ident = "field0",
                                },
                            },
                            .{
                                .tag = .field,
                                .lhs_child = &.{
                                    .tag = .ident,
                                    .rhs_ident = "field1",
                                },
                            },
                        },
                    },
                    .rhs_ident = "field2",
                },
            },
            .{
                .tag = .field,
                .lhs_child = &.{
                    .tag = .ident,
                    .lhs_child = &.{
                        .tag = .@"union",
                        .lhs_child = &.{
                            .tag = .field,
                            .lhs_child = &.{
                                .tag = .ident,
                                .lhs_child = &.{
                                    .tag = .list,
                                    .lhs_child = &.{
                                        .tag = .u8,
                                    },
                                },
                                .rhs_ident = "field0",
                            },
                        },
                        .rhs_value = 0,
                    },
                    .rhs_ident = "field3",
                },
            },
            .{
                .tag = .field,
                .lhs_child = &.{
                    .tag = .ident,
                    .lhs_child = &.{
                        .tag = .@"union",
                        .lhs_child = &.{
                            .tag = .field,
                            .lhs_child = &.{
                                .tag = .ident,
                                .lhs_child = &.{
                                    .tag = .map,
                                    .lhs_child = &.{ .tag = .u32 },
                                    .rhs_child = &.{ .tag = .ref },
                                },
                                .rhs_ident = "field0",
                            },
                        },
                        .rhs_child = &.{ .tag = .u8 },
                    },
                    .rhs_ident = "field4",
                },
            },
            .{
                .tag = .field,
                .lhs_child = &.{
                    .tag = .ident,
                    .lhs_child = &.{
                        .tag = .array,
                        .lhs_child = &.{
                            .tag = .@"struct",
                            .lhs_child = &.{
                                .tag = .field,
                                .lhs_child = &.{
                                    .tag = .ident,
                                    .lhs_child = &.{
                                        .tag = .opt,
                                        .lhs_child = &.{ .tag = .str },
                                    },
                                    .rhs_ident = "field0",
                                },
                            },
                        },
                        .rhs_value = 3,
                    },
                    .rhs_ident = "field5",
                },
            },
        },
    });
}

const ExpectedNode = struct {
    tag: Type.Tag,
    lhs_child: ?*const ExpectedNode = null,
    lhs_children: ?[]const ExpectedNode = null,
    rhs_value: ?u32 = null,
    rhs_ident: ?[]const u8 = null,
    rhs_child: ?*const ExpectedNode = null,
};

fn expectType(comptime T: type, root: ExpectedNode) !void {
    var ty = try initType(std.testing.allocator, T);
    defer ty.deinit(std.testing.allocator);
    try expectNode(ty, 0, root);
}

fn expectNode(ty: Type, index: Type.Index, expected: ExpectedNode) !void {
    try std.testing.expectEqual(expected.tag, ty.tag[index]);
    if (expected.lhs_child) |child| {
        try expectNode(ty, ty.data[index].lhs, child.*);
    } else if (expected.lhs_children) |children| {
        var tail = ty.data[index].lhs;
        for (children) |child| {
            try expectNode(ty, tail, child);
            tail = ty.data[tail].rhs;
        }
        try std.testing.expectEqual(@as(Type.Index, 0), tail);
    }

    if (expected.rhs_value) |expected_value| {
        const actual_value = ty.data[index].rhs;
        try std.testing.expectEqual(expected_value, actual_value);
    } else if (expected.rhs_ident) |expected_ident| {
        const ident_start = ty.data[index].rhs;
        const actual_ident = std.mem.sliceTo(ty.ident[ident_start..], 0);
        try std.testing.expectEqualStrings(expected_ident, actual_ident);
    } else if (expected.rhs_child) |child| {
        try expectNode(ty, ty.data[index].rhs, child.*);
    }
}
