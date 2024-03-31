const std = @import("std");
const render = @cImport({
    @cInclude("render/render.h");
});

pub const NodeList = std.MultiArrayList(Node);
pub const NodeIndex = u16;
pub const Node = struct {
    tag: Tag,
    data: Data,
    head: u16,
    next: u16,

    pub const Tag = enum(u8) {
        flex,
        padding,
        rrect,
        rect,
        oval,
        text,
        obj_tree,
    };

    pub const Data = union {
        flex: Flex,
        padding: Padding,
        rrect: RRect,
        rect: Rect,
        oval: Oval,
        text: Text,
        obj_tree: ObjTree,
    };
};

pub const Color = render.Color;

pub const colors = struct {
    pub const black = 0x000000FF;
    pub const white = 0xFFFFFFFF;
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

pub const Flex = struct {
    direction: Direction,
    cross_align: CrossAlign = .start,
    spacing: f32 = 0.0,

    pub const Direction = enum {
        column,
        row,
    };

    pub const CrossAlign = enum {
        start,
        center,
        end,
    };
};

pub const Padding = struct {
    left: f32 = 0,
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,

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

pub const RRect = struct {
    color: Color,
    radius: Radius,
};

pub const Rect = struct {
    color: Color,
};

pub const Oval = struct {
    color: Color,
    radius: Radius,
};

pub const Text = struct {
    str: []const u8,
    font_size: f32 = 16.0,
};

pub const ObjTree = struct {};

pub const Tree = struct {
    allocator: std.mem.Allocator,
    nodes: std.MultiArrayList(Node),
    robj: ?*render.Object,

    pub fn init(allocator: std.mem.Allocator) Tree {
        return .{
            .allocator = allocator,
            .nodes = .{},
            .robj = null,
        };
    }

    pub fn clear(tree: *Tree) void {
        tree.nodes.shrinkRetainingCapacity(0);
    }

    pub fn flex(tree: *Tree, data: Flex, children: []const ?NodeIndex) !NodeIndex {
        const node = try tree.append(.flex, .{ .flex = data });
        try setChildren(node, children);
        return node;
    }

    pub fn padding(tree: *Tree, data: Padding, maybe_child: ?NodeIndex) !NodeIndex {
        const node = try tree.append(.padding, .{ .padding = data });
        if (maybe_child) |child| {
            tree.setHead(node, child);
        }
        return node;
    }

    pub fn rrect(tree: *Tree, data: RRect, child: NodeIndex) !NodeIndex {
        const node = try tree.append(.rrect, .{ .rrect = data });
        tree.setHead(node, child);
        return node;
    }

    pub fn rect(tree: *Tree, data: Rect, child: NodeIndex) !NodeIndex {
        const node = try tree.append(.rect, .{ .rect = data });
        tree.setHead(node, child);
        return node;
    }

    pub fn oval(tree: *Tree, data: Oval, child: NodeIndex) !NodeIndex {
        const node = try tree.append(.oval, .{ .oval = data });
        tree.setHead(node, child);
        return node;
    }

    pub fn text(tree: *Tree, data: Text) !NodeIndex {
        return try tree.append(.text, .{ .text = data });
    }

    pub fn objTree(tree: *Tree, data: ObjTree) !NodeIndex {
        return try tree.append(.obj_tree, .{ .obj_tree = data });
    }

    fn append(tree: *Tree, tag: Node.Tag, data: Node.Data) !NodeIndex {
        const index = tree.nodes.len;
        try tree.nodes.append(tree.allocator, Node{
            .tag = tag,
            .data = data,
            .head = 0,
            .next = 0,
        });
        return index;
    }

    fn setChildren(tree: *Tree, parent: NodeIndex, children: []const ?NodeIndex) !void {
        var tail: ?NodeIndex = null;
        for (children) |child| {
            tail = try appendChild(tree, parent, tail, child);
        }
    }

    pub fn appendChild(
        tree: *Tree,
        parent: NodeIndex,
        maybe_tail: ?NodeIndex,
        maybe_child: ?NodeIndex,
    ) !?NodeIndex {
        const child = if (maybe_child) |mc| mc else return null;

        if (maybe_tail) |tail| {
            tree.setNext(tail, child);
        } else {
            tree.setHead(parent, child);
        }
        return child;
    }

    inline fn setHead(tree: *Tree, parent: NodeIndex, child: NodeIndex) void {
        tree.nodes.items(.head)[parent] = child;
    }

    inline fn setNext(tree: *Tree, tail: NodeIndex, child: NodeIndex) void {
        tree.nodes.items(.next)[tail] = child;
    }
};
