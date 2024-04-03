//! Layout for stored values of a `Type`.
data: []const Data,
tree: []const Tree,

const std = @import("std");
const gen_list = @import("gen_list.zig");
const Type = @import("Type.zig");

pub const Data = struct {
    size: u32,
    alignment: u8,
    offset: u32,
};

pub const Tree = struct {
    head: Index,
    next: Index,
};

pub const Index = u32;

const NodeList = std.MultiArrayList(Node);
const Node = struct {
    data: Data,
    tree: Tree,
};
const TypeLayout = @This();

pub fn init(allocator: std.mem.Allocator, ty: Type) !TypeLayout {
    var s = InitState{
        .allocator = allocator,
        .ty = ty,
        .nodes = .{},
        .fields = .{},
    };
    defer s.fields.deinit(allocator);

    _ = try appendLayout(&s, 0);

    var nodes = s.nodes.toOwnedSlice();
    defer nodes.deinit(allocator);

    const data = try allocator.dupe(Data, nodes.items(.data));
    const tree = try allocator.dupe(Tree, nodes.items(.tree));

    return TypeLayout{
        .data = data,
        .tree = tree,
    };
}

pub fn deinit(self: *TypeLayout, allocator: std.mem.Allocator) void {
    allocator.free(self.data);
    allocator.free(self.tree);
    self.* = undefined;
}

const InitState = struct {
    allocator: std.mem.Allocator,
    ty: Type,
    nodes: NodeList,
    // temp buffer used to sort struct and tuple fields.
    fields: std.ArrayListUnmanaged(SortField),
};

const SortField = struct {
    node: Index,
    alignment: u8,

    fn greaterThan(_: void, lhs: SortField, rhs: SortField) bool {
        return lhs.alignment > rhs.alignment;
    }
};

fn appendLayout(s: *InitState, type_node: Type.Index) std.mem.Allocator.Error!Index {
    switch (s.ty.tag[type_node]) {
        // Stored as its native type.
        .void => {
            return try appendNode(s, 0, 0);
        },

        // Stored as its native type.
        .i8, .u8, .bool => {
            return try appendNode(s, 1, 1);
        },

        // Stored as its native type.
        .i16, .u16, .f16 => {
            return try appendNode(s, 2, 2);
        },

        // Stored as its native type.
        .i32, .u32, .f32 => {
            return try appendNode(s, 4, 4);
        },

        // Stored as its native type.
        .i64, .u64, .f64 => {
            return try appendNode(s, 8, 8);
        },

        // Stored as its native type.
        .i128, .u128, .f128 => {
            return try appendNode(s, 16, 16);
        },

        // Stored as a pointer type.
        .str => {
            return try appendNode(s, @sizeOf(*anyopaque), @alignOf(*anyopaque));
        },

        // Stored as a `gen_list.Id` type.
        .ref => {
            return try appendNode(s, @sizeOf(gen_list.Id), @alignOf(gen_list.Id));
        },

        // Stored as an `extern struct {
        //     value: child_type,
        //     some: bool,
        // }`.
        .opt => {
            const node = try appendNode(s, 1, 1);
            const child = try appendLayout(s, s.ty.data[type_node].lhs);
            setHead(s, node, child);
            const data = s.nodes.items(.data);
            const child_data = data[child];
            if (child_data.size > 0) {
                var size = child_data.size + 1;
                const alignment = child_data.alignment;
                size = alignedSize(size, alignment);
                data[node].size = size;
                data[node].alignment = alignment;
            }
            return node;
        },

        // Stored as an `[array_size]child_type`.
        .array => {
            const node = try appendNode(s, 0, 0);
            const child = try appendLayout(s, s.ty.data[type_node].lhs);
            setHead(s, node, child);
            const array_size = s.ty.data[type_node].rhs;
            const data = s.nodes.items(.data);
            data[node].size = data[child].size * array_size;
            data[node].alignment = data[child].alignment;
            return node;
        },

        // Stored as a pointer type.
        .list => {
            const node = try appendNode(s, @sizeOf(*anyopaque), @alignOf(*anyopaque));
            const child = try appendLayout(s, s.ty.data[type_node].lhs);
            setHead(s, node, child);
            return node;
        },

        // Stored as a pointer type.
        .map => {
            const node = try appendNode(s, @sizeOf(*anyopaque), @alignOf(*anyopaque));
            const key = try appendLayout(s, s.ty.data[type_node].lhs);
            setHead(s, node, key);
            const value = try appendLayout(s, s.ty.data[type_node].rhs);
            setNext(s, key, value);
            return node;
        },

        // Stored as an `extern struct { fields... }`.
        // Fields are reordered by alignment in descending order.
        .@"struct" => {
            return try appendStructLayout(s, type_node, struct {
                // Struct fields are stored as `field -> ident -> type`.
                fn fieldTypeNode(is: *InitState, field_node: Type.Index) Index {
                    const field_ident_node = is.ty.data[field_node].lhs;
                    return is.ty.data[field_ident_node].lhs;
                }
            }.fieldTypeNode);
        },

        // Stored as an `extern struct { fields... }`.
        // Fields are reordered by alignment in descending order.
        .tuple => {
            return try appendStructLayout(s, type_node, struct {
                // Tuple fields are stored as `field -> type`.
                fn fieldTypeNode(is: *InitState, field_node: Type.Index) Index {
                    return is.ty.data[field_node].lhs;
                }
            }.fieldTypeNode);
        },

        // Stored as a `tag_int`.
        .@"enum" => {
            const tag_type_node = s.ty.data[type_node].rhs;
            const size: u8 = switch (s.ty.tag[tag_type_node]) {
                .u8 => 1,
                .u16 => 2,
                .u32 => 4,
                .u64 => 8,
                .u128 => 16,
                else => unreachable,
            };
            return try appendNode(s, size, size);
        },

        // If tagged, stored as an `extern struct {
        //     value: extern union {
        //         fields..
        //     },
        //     tag: tag_int_type,
        // }`
        //
        // `value` and `tag` are sorted by alignment in descending order.
        //
        // If untagged, stored as an `extern union { fields.. }`.
        .@"union" => {
            const node = try appendNode(s, 0, 0);

            var layout_tail: Index = 0;
            var tag_child: Index = 0;
            const tag_type_node = s.ty.data[type_node].rhs;
            if (tag_type_node != 0) {
                tag_child = try appendLayout(s, tag_type_node);
                setHead(s, node, tag_child);
                layout_tail = tag_child;
            }

            var size: u32 = 0;
            var alignment: u8 = 0;
            var type_tail = s.ty.data[type_node].lhs;
            while (type_tail != 0) {
                const field_ident_node = s.ty.data[type_tail].lhs;
                const field_type_node = s.ty.data[field_ident_node].lhs;
                const child = try appendLayout(s, field_type_node);
                appendChild(s, node, layout_tail, child);

                const data = s.nodes.items(.data);
                size = @max(size, data[child].size);
                alignment = @max(alignment, data[child].alignment);

                layout_tail = child;
                type_tail = s.ty.data[type_tail].rhs;
            }
            size = alignedSize(size, alignment);

            const data = s.nodes.items(.data);
            if (tag_child != 0) {
                if (data[tag_child].alignment >= alignment) {
                    alignment = data[tag_child].alignment;

                    const tree = s.nodes.items(.tree);
                    var tail = tree[tag_child].next;
                    while (tail != 0) {
                        // offset the union fields to after the tag
                        data[tail].offset = data[tag_child].size;
                        tail = tree[tail].next;
                    }
                } else {
                    data[tag_child].offset = size;
                }
                size += data[tag_child].size;
                size = alignedSize(size, alignment);
            }

            data[node].size = size;
            data[node].alignment = alignment;

            return node;
        },

        .field, .ident => unreachable,
    }
}

fn appendStructLayout(
    s: *InitState,
    type_node: Type.Index,
    fieldTypeNodeFn: *const fn (*InitState, Type.Index) Type.Index,
) !Index {
    const node = try appendNode(s, 0, 0);
    var layout_tail: Index = 0;
    var type_tail = s.ty.data[type_node].lhs;

    const parent_fields_len: usize = s.fields.items.len;
    while (type_tail != 0) {
        const field_type_node = fieldTypeNodeFn(s, type_tail);
        const child = try appendLayout(s, field_type_node);
        try s.fields.append(s.allocator, SortField{
            .node = child,
            .alignment = s.nodes.items(.data)[child].alignment,
        });
        appendChild(s, node, layout_tail, child);
        layout_tail = child;
        type_tail = s.ty.data[type_tail].rhs;
    }

    const sort_fields = s.fields.items[parent_fields_len..];
    std.mem.sort(SortField, sort_fields, @as(void, undefined), SortField.greaterThan);

    const data = s.nodes.items(.data);
    var size: u32 = 0;
    var offset: u32 = 0;
    for (sort_fields) |field| {
        data[field.node].offset = offset;
        size += data[field.node].size;
        offset += data[field.node].size;
    }

    if (size > 0) {
        // Alignment of struct is the alignment of the field with the greatest alignment.
        const alignment = sort_fields[0].alignment;
        // Pad container to be multiple of alignment.
        size = alignedSize(size, alignment);
        data[node].size = size;
        data[node].alignment = alignment;
    }
    s.fields.shrinkRetainingCapacity(parent_fields_len);

    return node;
}

inline fn alignedSize(size: u32, alignment: u8) u32 {
    if (size % alignment != 0) {
        return size + (alignment - (size % alignment));
    }
    return size;
}

fn appendNode(s: *InitState, size: u32, alignment: u8) !Index {
    const index: Index = @intCast(s.nodes.len);
    try s.nodes.append(s.allocator, Node{
        .data = Data{
            .size = size,
            .alignment = alignment,
            .offset = 0,
        },
        .tree = Tree{
            .head = 0,
            .next = 0,
        },
    });
    return index;
}

inline fn appendChild(s: *const InitState, node: Index, tail: Index, child: Index) void {
    if (tail == 0) {
        setHead(s, node, child);
    } else {
        setNext(s, tail, child);
    }
}

inline fn setHead(s: *const InitState, node: Index, child: Index) void {
    s.nodes.items(.tree)[node].head = child;
}

inline fn setNext(s: *const InitState, tail: Index, child: Index) void {
    s.nodes.items(.tree)[tail].next = child;
}

// sanity test to make sure the container tests are building on a solid foundation
test "fixed layouts" {
    try expectLayout(void, .{ .size = 0, .alignment = 0 });

    try expectLayout(i8, .{ .size = 1, .alignment = 1 });
    try expectLayout(u8, .{ .size = 1, .alignment = 1 });
    try expectLayout(bool, .{ .size = 1, .alignment = 1 });

    try expectLayout(i16, .{ .size = 2, .alignment = 2 });
    try expectLayout(u16, .{ .size = 2, .alignment = 2 });
    try expectLayout(f16, .{ .size = 2, .alignment = 2 });

    try expectLayout(i32, .{ .size = 4, .alignment = 4 });
    try expectLayout(u32, .{ .size = 4, .alignment = 4 });
    try expectLayout(f32, .{ .size = 4, .alignment = 4 });

    try expectLayout(i64, .{ .size = 8, .alignment = 8 });
    try expectLayout(u64, .{ .size = 8, .alignment = 8 });
    try expectLayout(f64, .{ .size = 8, .alignment = 8 });

    try expectLayout(i128, .{ .size = 16, .alignment = 16 });
    try expectLayout(u128, .{ .size = 16, .alignment = 16 });
    try expectLayout(f128, .{ .size = 16, .alignment = 16 });

    try expectLayout(Type.zig.Ref, .{ .size = @sizeOf(gen_list.Id), .alignment = @alignOf(gen_list.Id) });
    try expectLayout(Type.zig.Str, .{ .size = @sizeOf(*anyopaque), .alignment = @alignOf(*anyopaque) });
    try expectLayout(Type.zig.List(u8), .{
        .size = @sizeOf(*anyopaque),
        .alignment = @alignOf(*anyopaque),
        .child = &.{ .size = 1, .alignment = 1 },
    });
    try expectLayout(Type.zig.Map(u8, u8), .{
        .size = @sizeOf(*anyopaque),
        .alignment = @alignOf(*anyopaque),
        .children = &.{
            .{ .size = 1, .alignment = 1 },
            .{ .size = 1, .alignment = 1 },
        },
    });
}

test "basic opt layout" {
    try expectLayout(?u128, .{
        .size = 32,
        .alignment = 16,
        .child = &.{
            .size = 16,
            .alignment = 16,
        },
    });
}

test "basic array layout" {
    try expectLayout([8]u32, .{
        .size = 32,
        .alignment = 4,
        .child = &.{
            .size = 4,
            .alignment = 4,
        },
    });
}

test "basic struct layout" {
    try expectLayout(struct {
        f1: u32,
        f2: u8,
        f3: u16,
        f4: u64,
    }, .{
        .size = 16,
        .alignment = 8,
        .children = &.{
            .{ .size = 4, .alignment = 4, .offset = 8 },
            .{ .size = 1, .alignment = 1, .offset = 14 },
            .{ .size = 2, .alignment = 2, .offset = 12 },
            .{ .size = 8, .alignment = 8, .offset = 0 },
        },
    });
}

test "basic enum layout" {
    try expectLayout(enum {
        f1,
        f2,
        f3,
        f4,
    }, .{ .size = 1, .alignment = 1 });
}

test "basic untagged union" {
    try expectLayout(union {
        f1: u8,
        f2: u16,
        f3: u32,
        f4: u64,
    }, .{
        .size = 8,
        .alignment = 8,
        .children = &.{
            .{ .size = 1, .alignment = 1 },
            .{ .size = 2, .alignment = 2 },
            .{ .size = 4, .alignment = 4 },
            .{ .size = 8, .alignment = 8 },
        },
    });
}

test "basic tagged union" {
    try expectLayout(union(enum) {
        f1: u8,
        f2: u16,
        f3: u32,
        f4: u64,
    }, .{
        .size = 16,
        .alignment = 8,
        .children = &.{
            .{ .size = 1, .alignment = 1, .offset = 8 }, // tag
            .{ .size = 1, .alignment = 1, .offset = 0 },
            .{ .size = 2, .alignment = 2, .offset = 0 },
            .{ .size = 4, .alignment = 4, .offset = 0 },
            .{ .size = 8, .alignment = 8, .offset = 0 },
        },
    });
}

test "opt struct layout" {
    try expectLayout(?struct {
        f1: u32,
        f2: u8,
        f3: u16,
        f4: u64,
    }, .{
        .size = 24,
        .alignment = 8,
        .child = &.{
            .size = 16,
            .alignment = 8,
            .children = &.{
                .{ .size = 4, .alignment = 4, .offset = 8 },
                .{ .size = 1, .alignment = 1, .offset = 14 },
                .{ .size = 2, .alignment = 2, .offset = 12 },
                .{ .size = 8, .alignment = 8, .offset = 0 },
            },
        },
    });
}

test "array of structs layout" {
    try expectLayout([2]struct {
        f1: u32,
        f2: u8,
        f3: u16,
        f4: u64,
    }, .{
        .size = 32,
        .alignment = 8,
        .child = &.{
            .size = 16,
            .alignment = 8,
            .children = &.{
                .{ .size = 4, .alignment = 4, .offset = 8 },
                .{ .size = 1, .alignment = 1, .offset = 14 },
                .{ .size = 2, .alignment = 2, .offset = 12 },
                .{ .size = 8, .alignment = 8, .offset = 0 },
            },
        },
    });
}

test "nested structs layout" {
    try expectLayout(struct {
        f1: u8,
        f2: struct {
            f1: u16,
            f2: u32,
        },
        f3: u64,
    }, .{
        .size = 24,
        .alignment = 8,
        .children = &.{
            .{ .size = 1, .alignment = 1, .offset = 16 },
            .{ .size = 8, .alignment = 4, .offset = 8, .children = &.{
                .{ .size = 2, .alignment = 2, .offset = 4 },
                .{ .size = 4, .alignment = 4, .offset = 0 },
            } },
            .{ .size = 8, .alignment = 8, .offset = 0 },
        },
    });
}

test "large enum layout" {
    try expectLayout(enum(u64) {
        f1,
        f2,
    }, .{ .size = 8, .alignment = 8 });
}

test "untagged union with struct" {
    try expectLayout(union {
        f1: u8,
        f2: struct {
            f1: u16,
            f2: u32,
            f3: u32,
        },
        f3: u64,
    }, .{
        .size = 16,
        .alignment = 8,
        .children = &.{
            .{ .size = 1, .alignment = 1 },
            .{ .size = 12, .alignment = 4, .children = &.{
                .{ .size = 2, .alignment = 2, .offset = 8 },
                .{ .size = 4, .alignment = 4, .offset = 0 },
                .{ .size = 4, .alignment = 4, .offset = 4 },
            } },
            .{ .size = 8, .alignment = 8 },
        },
    });
}

test "tagged union with struct" {
    try expectLayout(union(enum) {
        f1: u8,
        f2: struct {
            f1: u16,
            f2: u32,
            f3: u32,
        },
        f3: u64,
    }, .{
        .size = 24,
        .alignment = 8,
        .children = &.{
            .{ .size = 1, .alignment = 1, .offset = 16 }, // tag
            .{ .size = 1, .alignment = 1 },
            .{ .size = 12, .alignment = 4, .children = &.{
                .{ .size = 2, .alignment = 2, .offset = 8 },
                .{ .size = 4, .alignment = 4, .offset = 0 },
                .{ .size = 4, .alignment = 4, .offset = 4 },
            } },
            .{ .size = 8, .alignment = 8 },
        },
    });
}

test "tagged union with larger alignment tag than payload" {
    try expectLayout(union(enum(u128)) {
        f1: u8,
        f2: struct {
            f1: u16,
            f2: u32,
            f3: u32,
        },
        f3: u64,
    }, .{
        .size = 32,
        .alignment = 16,
        .children = &.{
            .{ .size = 16, .alignment = 16, .offset = 0 }, // tag
            .{ .size = 1, .alignment = 1, .offset = 16 },
            .{ .size = 12, .alignment = 4, .offset = 16, .children = &.{
                .{ .size = 2, .alignment = 2, .offset = 8 },
                .{ .size = 4, .alignment = 4, .offset = 0 },
                .{ .size = 4, .alignment = 4, .offset = 4 },
            } },
            .{ .size = 8, .alignment = 8, .offset = 16 },
        },
    });
}

const ExpectedNode = struct {
    size: u32,
    alignment: u8,
    offset: u32 = 0,
    child: ?*const ExpectedNode = null,
    children: ?[]const ExpectedNode = null,
};

fn expectLayout(comptime T: type, root: ExpectedNode) !void {
    const allocator = std.testing.allocator;
    var ty = try Type.zig.init(allocator, T);
    defer ty.deinit(allocator);

    var layout = try init(allocator, ty);
    defer layout.deinit(allocator);

    try expectNode(layout, 0, root);
}

fn expectNode(layout: TypeLayout, index: Index, expected: ExpectedNode) !void {
    try std.testing.expectEqual(expected.size, layout.data[index].size);
    try std.testing.expectEqual(expected.alignment, layout.data[index].alignment);
    try std.testing.expectEqual(expected.offset, layout.data[index].offset);
    if (expected.child) |expected_child| {
        try expectNode(layout, layout.tree[index].head, expected_child.*);
    } else if (expected.children) |expected_children| {
        var tail = layout.tree[index].head;
        for (expected_children) |expected_child| {
            try expectNode(layout, tail, expected_child);
            tail = layout.tree[tail].next;
        }
        try std.testing.expectEqual(@as(Index, 0), tail);
    }
}
