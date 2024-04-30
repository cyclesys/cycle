//! Functianality for interacting with the Cycle runtime using Zig.
const std = @import("std");
const raw = @import("raw.zig");
const Store = @import("Store.zig");
const Type = @import("Type.zig");

pub fn LayoutType(comptime T: type) type {
    switch (@typeInfo(T)) {
        .Void, .Bool, .Int, .Float => {
            return T;
        },

        .Optional => {
            return LayoutOptional(T);
        },

        .Array => {
            return LayoutArray(T);
        },

        .Struct => |info| {
            if (@hasDecl(T, "def_kind")) {
                switch (T.def_kind) {
                    .str => {
                        return raw.ByteList;
                    },
                    .ref => {
                        return Store.Id;
                    },
                    .list => {
                        return LayoutList(T);
                    },
                }
            }

            if (info.is_tuple) {
                return LayoutTuple(T);
            }

            return LayoutStruct(T);
        },

        .Enum => {
            return LayoutEnum(T);
        },

        .Union => {
            return LayoutUnion(T);
        },

        else => @compileError("unsupported"),
    }
}

pub fn LayoutOptional(comptime T: type) type {
    const info = @typeInfo(T).Optional;
    return extern struct {
        value: LayoutType(info.child),
        some: bool,
    };
}

pub fn LayoutArray(comptime T: type) type {
    const info = @typeInfo(T).Array;
    return [info.len]LayoutType(info.child);
}

pub fn LayoutList(comptime T: type) type {
    return extern struct {
        inner: raw.List = .{
            .item_size = @sizeOf(Child),
            .item_alignment = @alignOf(Child),
        },

        pub const Child = LayoutType(T.child);
        const Self = @This();

        pub inline fn items(self: Self) []Child {
            const slice: [*]Child = @ptrCast(@alignCast(self.inner.bytes));
            return slice[0..self.inner.len];
        }

        pub fn get(self: Self, i: u32) *Child {
            const bytes = self.inner.get(i);
            return @ptrCast(@alignCast(bytes));
        }

        pub fn getRange(self: Self, start: u32, len: u32) []Child {
            const bytes = self.inner.getRange(start, len);
            var slice: []Child = undefined;
            slice.ptr = @ptrCast(@alignCast(bytes));
            slice.len = len;
            return slice;
        }

        pub fn append(self: *Self, allocator: std.mem.Allocator, child: Child) !void {
            try self.inner.ensureAvailable(allocator, 1);
            const bytes = self.inner.append();
            const ptr: *Child = @ptrCast(@alignCast(bytes));
            ptr.* = child;
        }

        pub fn appendRange(self: *Self, allocator: std.mem.allocator, children: []const Child) !void {
            try self.inner.ensureAvailable(allocator, children.len);
            const range = self.inner.appendRange(children.len);
            setRange(range, children);
        }

        pub fn insert(self: *Self, allocator: std.mem.Allocator, i: raw.List.Index, child: Child) !void {
            try self.inner.ensureAvailable(allocator, 1);
            const bytes = self.inner.insert(i);
            const ptr: *Child = @ptrCast(@alignCast(bytes));
            ptr.* = child;
        }

        pub fn insertRange(self: *Self, allocator: std.mem.Allocator, i: raw.List.Index, children: []const Child) !void {
            try self.inner.ensureAvailable(allocator, children.len);
            const range = self.inner.insertRange(i, children.len);
            setRange(range, children);
        }

        fn setRange(range: [*]u8, children: []const Child) void {
            const stride = @sizeOf(Child);
            for (0..children.len) |i| {
                const bytes = range[i * stride ..][0..stride];
                const ptr: *Child = @ptrCast(@alignCast(bytes));
                ptr.* = children[i];
            }
        }

        pub fn remove(self: *Self, i: raw.List.Index) !void {
            self.inner.remove(i);
        }

        pub fn removeRange(self: *Self, start: raw.List.Index, len: raw.List.Index) void {
            self.inner.removeRange(start, len);
        }
    };
}

pub fn LayoutTuple(comptime T: type) type {
    const info = @typeInfo(T).Struct;
    var fields: [info.fields.len]std.builtin.Type.StructField = undefined;
    for (info.fields, 0..) |field, i| {
        const FieldType = LayoutType(field.type);
        fields[i] = .{
            .name = tupleFieldName(i),
            .type = FieldType,
            .default_value = null,
            .is_comptime = false,
            .alignment = alignOf(FieldType),
        };
    }
    comptime std.sort.insertion(std.builtin.Type.StructField, &fields, @as(void, undefined), alignSort);
    return @Type(.{
        .Struct = .{
            .layout = .Extern,
            .backing_integer = null,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

pub fn LayoutStruct(comptime T: type) type {
    const info = @typeInfo(T).Struct;
    var fields: [info.fields.len]std.builtin.Type.StructField = undefined;
    for (info.fields, 0..) |field, i| {
        const FieldType = LayoutType(field.type);
        fields[i] = .{
            .name = field.name,
            .type = FieldType,
            .default_value = null,
            .is_comptime = false,
            .alignment = alignOf(FieldType),
        };
    }
    comptime std.sort.insertion(std.builtin.Type.StructField, &fields, @as(void, undefined), alignSort);
    return @Type(.{
        .Struct = .{
            .layout = .Extern,
            .backing_integer = null,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

pub fn LayoutEnum(comptime T: type) type {
    const info = @typeInfo(T).Enum;
    const EnumTag = std.meta.Int(.unsigned, @sizeOf(info.tag_type) * 8);
    return @Type(.{
        .Enum = .{
            .tag_type = EnumTag,
            .fields = info.fields,
            .decls = &.{},
            .is_exhaustive = true,
        },
    });
}

pub fn LayoutUnion(comptime T: type) type {
    const info = @typeInfo(T).Union;

    var union_fields: [info.fields.len]std.builtin.Type.UnionField = undefined;
    for (info.fields, 0..) |field, i| {
        const FieldType = LayoutType(field.type);
        union_fields[i] = .{
            .name = field.name,
            .type = FieldType,
            .alignment = alignOf(FieldType),
        };
    }

    const Union = @Type(.{
        .Union = .{
            .layout = .Extern,
            .tag_type = null,
            .fields = &union_fields,
            .decls = &.{},
        },
    });

    if (info.tag_type == null) {
        return Union;
    }

    const UnionTag = LayoutEnum(info.tag_type.?);
    var struct_fields = [_]std.builtin.Type.StructField{
        .{
            .name = "value",
            .type = Union,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(Union),
        },
        .{
            .name = "tag",
            .type = UnionTag,
            .default_value = null,
            .is_comptime = false,
            .alignment = alignOf(UnionTag),
        },
    };
    comptime std.sort.insertion(std.builtin.Type.StructField, &struct_fields, @as(void, undefined), alignSort);
    return @Type(.{
        .Struct = .{
            .layout = .Extern,
            .backing_integer = null,
            .fields = &struct_fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

fn alignSort(_: void, comptime lhs: std.builtin.Type.StructField, comptime rhs: std.builtin.Type.StructField) bool {
    return alignOf(lhs.type) > alignOf(rhs.type);
}

fn alignOf(comptime T: type) comptime_int {
    comptime {
        return switch (T) {
            // zig aligns these as 8 normally, but we need them aligned as they are in `extern` types.
            i128, u128, f128 => 16,
            else => switch (@typeInfo(T)) {
                .Enum => |info| alignOf(info.tag_type),
                else => @alignOf(T),
            },
        };
    }
}

fn tupleFieldName(comptime index: comptime_int) []const u8 {
    comptime {
        const buf_size = std.fmt.count("{d}", .{index});
        var buf: [buf_size]u8 = undefined;
        _ = std.fmt.formatIntBuf(&buf, index, 10, .upper, .{});
        return &buf;
    }
}

const DefKind = enum {
    str,
    ref,
    list,
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
pub fn List(comptime T: type) type {
    return struct {
        pub const def_kind = DefKind.list;
        pub const child = T;
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
            if (@sizeOf(EnumTag) > 16) {
                @compileError("unsupported");
            }
            setRhs(s, node, try appendType(s, EnumTag));

            var tail: Type.Index = 0;
            inline for (info.fields) |field| {
                const field_node = try appendNode(s, .field);
                setLhs(s, field_node, try appendIdent(s, field.name));
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

                if (@sizeOf(UnionTag) > 16) {
                    @compileError("unsupported");
                }

                setRhs(s, node, try appendType(s, UnionTag));
            }

            var tail: Type.Index = 0;
            inline for (info.fields) |field| {
                const field_node = try appendNode(s, .field);

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
        field2: List(u32),
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
                        .tag = .list,
                        .lhs_child = &.{ .tag = .u32 },
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
            field0: List(Ref),
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
                                    .tag = .list,
                                    .lhs_child = &.{ .tag = .ref },
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
