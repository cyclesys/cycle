//! A tree of ui elements.
nodes: std.MultiArrayList(Node) = .{},

// cached ptrs to the `nodes.bytes` slice.
tree: []Node.Tree = &.{},
data: []Node.Data = &.{},

const std = @import("std");
const rnd = @cImport({
    @cInclude("render/render.h");
});
const Store = @import("../Store.zig");
const View = @This();

pub const Builder = struct {
    ctx: *anyopaque,
    build: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        view: *View,
        obj: [*]u8,
    ) anyerror!void,

    pub inline fn build(self: Builder, allocator: std.mem.Allocator, view: *View, obj: [*]u8) anyerror!void {
        try self.build(self.ctx, allocator, view, obj);
    }
};

pub fn BuildStack(comptime size: comptime_int) type {
    return struct {
        nodes: [size]View.NodeIndex = [_]View.NodeIndex{0} ** size,
        tails: [size]View.NodeIndex = [_]View.NodeIndex{0} ** size,
        len: std.math.IntFittingRange(0, size) = 0,
        const Self = @This();

        pub fn push(
            self: *Self,
            allocator: std.mem.Allocator,
            view: *View,
            data: View.TaggedData,
        ) !void {
            const node = try view.append(allocator, data);
            if (self.len > 0) {
                self.appendChild(view, node);
            }
            self.nodes[self.len] = node;
            self.tails[self.len] = 0;
            self.len += 1;
        }

        pub fn pop(self: *Self) void {
            self.len -= 1;
        }

        pub fn append(
            self: *Self,
            allocator: std.mem.Allocator,
            view: *View,
            data: View.TaggedData,
        ) !void {
            std.debug.assert(self.len > 0);
            const node = try view.append(allocator, data);
            self.appendChild(view, node);
        }

        fn appendChild(self: *Self, view: *View, node: View.NodeIndex) void {
            const parent_i = self.len - 1;
            const parent = self.nodes[parent_i];
            const tail = self.tails[parent_i];
            if (tail == 0) {
                view.tree[parent].head = node;
            } else {
                view.tree[tail].next = node;
            }
            self.tails[parent_i] = node;
        }
    };
}

pub const Color = struct {
    code: rnd.Color,

    pub const transparent = Color{ .code = 0x00000000 };
    pub const black = Color{ .code = 0x000000FF };
    pub const white = Color{ .code = 0xFFFFFFFF };
};

pub const Radius = struct {
    rx: f32,
    ry: f32,

    pub fn circle(r: f32) Radius {
        return .{
            .rx = r,
            .ry = r,
        };
    }
};

pub const Border = struct {
    color: Color = Color.transparent,
    thickness: f32 = 0.0,
};

pub const Flex = struct {
    cross_align: CrossAlign = .start,
    spacing: f32 = 0.0,

    pub const CrossAlign = enum {
        start,
        center,
        end,
    };
};

pub const Padding = struct {
    left: f32 = 0.0,
    top: f32 = 0.0,
    right: f32 = 0.0,
    bottom: f32 = 0.0,

    pub fn all(p: f32) Padding {
        return .{
            .left = p,
            .top = p,
            .right = p,
            .bottom = p,
        };
    }

    pub fn vertical(p: f32) Padding {
        return .{
            .top = p,
            .bottom = p,
        };
    }

    pub fn horizontal(p: f32) Padding {
        return .{
            .left = p,
            .right = p,
        };
    }
};

pub const Rect = struct {
    color: Color,
    border: Border = .{},
};

pub const RRect = struct {
    color: Color,
    radius: Radius,
    border: Border = .{},
};

pub const Text = struct {
    str: []const u8,
    font_size: f32 = 16.0,
};

pub const NodeIndex = u32;
pub const Node = struct {
    tree: Tree,
    data: Data,

    pub const Tree = struct {
        tag: Tag,
        head: NodeIndex,
        next: NodeIndex,
    };

    pub const Tag = enum(u8) {
        row,
        column,
        padding,
        rect,
        rrect,
        text,
        view,
    };

    pub const Data = union {
        row: Flex,
        column: Flex,
        padding: Padding,
        rect: Rect,
        rrect: RRect,
        text: Text,
        view: Store.Id,
    };
};

pub const TaggedData = union(Node.Tag) {
    row: Flex,
    column: Flex,
    padding: Padding,
    rect: Rect,
    rrect: RRect,
    text: Text,
    view: Store.Id,
};

pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
    self.nodes.deinit(allocator);
    self.* = undefined;
}

pub fn clear(self: *View) void {
    self.nodes.shrinkRetainingCapacity(0);
}

pub fn append(self: *View, allocator: std.mem.Allocator, data: TaggedData) !NodeIndex {
    const old_ptr = @intFromPtr(self.nodes.bytes);
    const index: u32 = @intCast(self.nodes.len);
    try self.nodes.append(allocator, .{
        .tree = .{
            .tag = data,
            .head = 0,
            .next = 0,
        },
        .data = switch (data) {
            inline else => |val, tag| @unionInit(Node.Data, @tagName(tag), val),
        },
    });
    if (old_ptr != @intFromPtr(self.nodes.bytes)) {
        const slice = self.nodes.slice();
        self.tree = slice.items(.tree);
        self.data = slice.items(.data);
    }
    return index;
}
