const std = @import("std");
const glfw = @import("glfw");
const rnd = @cImport({
    @cInclude("render/render.h");
});
const Store = @import("Store.zig");

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

pub const View = struct {
    nodes: std.MultiArrayList(Node) = .{},
    // cached ptrs to the `nodes.bytes` slice.
    tree: []Node.Tree = &.{},
    data: []Node.Data = &.{},

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
        const index = self.nodes.len;
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
};

pub fn BuildStack(comptime size: comptime_int) type {
    return struct {
        nodes: [size]View.NodeIndex = [_]View.NodeIndex{0} ** size,
        tails: [size]View.NodeIndex = [_]View.NodeIndex{0} ** size,
        len: std.math.IntFittingRange(0, size) = 0,
        const Self = @This();

        pub fn push(self: *Self, allocator: std.mem.Allocator, view: *View, data: View.TaggedData) void {
            const node = try view.append(allocator, view, data);
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

        pub fn append(self: *Self, allocator: std.mem.Allocator, view: *View, data: View.TaggedData) !void {
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

pub const Root = struct {
    rctx: *rnd.Context,
    rwnd: *rnd.Window,
    builders: std.AutoHashMapUnmanaged(Store.Id, Builder),
    nodes: std.AutoHashMapUnmanaged(Store.Id, RenderNode),

    pub const BuildFn = *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        view: *View,
        obj: [*]u8,
    ) anyerror!void;

    pub const Builder = struct {
        ctx: *anyopaque,
        build: BuildFn,
    };

    pub fn init(window: glfw.Window) Root {
        const rctx = rnd.createContext().?;
        const size = window.getSize();
        const hwnd = glfw.Native(.{ .win32 = true }).getWin32Window(window);
        const rwnd = rnd.createWindow(rctx, hwnd, size.width, size.height);
        return Root{
            .rctx = rctx,
            .rwnd = rwnd,
            .builders = .{},
            .roots = .{},
            .children = .{},
        };
    }

    pub fn registerBuilder(self: *Root, allocator: std.mem.Allocator, type_id: Store.Id, builder: Builder) !void {
        const gop = try self.builders.getOrPut(allocator, type_id);
        if (gop.found_existing) {
            return error.FoundExistingBuilder;
        }
        gop.value_ptr.* = builder;
    }

    pub fn renderObject(self: *Root, allocator: std.mem.Allocator, store: *Store, obj_id: Store.Id) !void {
        const gop = try self.nodes.getOrPut(allocator, obj_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = RenderNode{
                .view = .{},
                .children = .{},
                .size = null,
                .robj = undefined,
            };
        }
        const node: *RenderNode = gop.value_ptr;
        var ctx = RenderContext{
            .root = self,
            .allocator = allocator,
            .store = store,
            .ops = .{},
            .children = .{},
            .dirty = .{},
            .stack = .{},
        };
        try node.update(&ctx);
    }

    pub fn render(self: *Root) !void {
        _ = self;
    }
};

const RenderContext = struct {
    root: *Root,

    allocator: std.mem.Allocator,

    store: *Store,

    ops: std.ArrayListUnmanaged(RenderOp),

    children: std.ArrayListUnmanaged(u16),

    // A stack of nodes that are currently being rendered.
    // This is used to detech any cycles.
    stack: std.AutoHashMapUnmanaged(Store.Id, void),
};

const RenderOp = struct {
    tag: Tag,
    node: View.NodeIndex,
    rect: rnd.Rect,
    text: ?*rnd.Text,

    const Tag = enum {
        rect,
        rrect,
        text,
        view,
    };
};

const RenderNode = struct {
    view: View,
    children: std.AutoHashMapUnmanaged(Store.Id, Child),
    render_id: u8,
    size: ?rnd.Size,
    robj: *rnd.Object,

    const Child = struct {
        render_id: u8,
        node: RenderNode,
        offset: rnd.Offset,
    };

    fn deinit(self: *RenderNode, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    fn render(self: *RenderNode, ctx: *RenderContext, obj_id: Store.Id) !void {
        self.render_id = @addWithOverflow(self.render_id, 1)[0];

        const op_start = ctx.ops.items.len;
        try ctx.stack.put(ctx.allocator, obj_id, undefined);

        const obj = ctx.store.objects.get(obj_id).?;
        const builder = ctx.root.builders.get(obj.type).?;

        try builder.build(builder.ctx, ctx.allocator, &self.view, obj.data);

        try self.layoutViewNode(ctx, 0);
        const ops = ctx.ops.items[op_start..];

        if (ops.len == 0 or sizeIsZero(ops[0].rect.size)) {
            if (self.size != null) {
                rnd.destroyObject(self.robj);
                self.robj = undefined;
                self.size = null;
            }
            return;
        }

        const new_size = ops[0].rect.size;
        if (self.size) |old_size| {
            if (new_size != old_size) {
                rnd.destroyObject(self.robj);
            }
            self.robj = rnd.createObject(ctx.root.rwnd, new_size);
        } else {
            self.robj = rnd.createObject(ctx.root.rwnd, new_size);
        }
        self.size = new_size;

        rnd.beginDraw(self.robj);
        for (ctx.ops.items[op_start..]) |op| {
            switch (op.tag) {
                .rect => {
                    const data = self.view.data[op.node].rect;
                    rnd.drawRect(self.robj, op.rect, data.color);
                },
                .rrect => {
                    const data = self.view.data[op.node].rrect;
                    rnd.drawRRect(
                        self.robj,
                        rnd.RRect{
                            .rect = op.rect,
                            .rx = data.radius.rx,
                            .ry = data.radius.ry,
                        },
                        data.color,
                    );
                },
                .text => {
                    rnd.drawText(
                        self.robj,
                        op.text.?,
                        op.rect.offset,
                    );
                    // TODO: optimize text rendering
                    rnd.destroyText(op.text.?);
                },
                .view => {
                    // no-op
                },
            }
        }
        rnd.endDraw(self.robj);

        // remove any unused children
        var iter = self.children.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.render_id != self.render_id) {
                // this does not invalidate the iterator, it just sets the slot to 'empty'.
                _ = self.children.remove(entry.key_ptr.*);
            }
        }

        ctx.ops.shrinkRetainingCapacity(op_start);
        _ = ctx.stack.remove(obj_id);
    }

    fn layoutViewNode(self: *RenderNode, ctx: *RenderContext, node: View.NodeIndex) !rnd.Size {
        switch (self.view.tree[node].tag) {
            .row => {
                return self.layoutFlex(ctx, node, .row);
            },
            .column => {
                return self.layoutFlex(ctx, node, .column);
            },
            .padding => {
                const data = self.view.data[node].padding;
                const child_start = ctx.ops.items.len;
                const child_size = try self.layoutViewNode(ctx, self.view.tree[node].head);
                const ops = ctx.ops.items[child_start..];
                for (ops) |*op| {
                    op.rect.offset.dx += data.left;
                    op.rect.offset.dy += data.top;
                }
                return rnd.Size{
                    .width = child_size.width + data.left + data.right,
                    .height = child_size.height + data.top + data.bottom,
                };
            },
            .rect => {
                return self.layoutShape(ctx, node, .rect);
            },
            .rrect => {
                return self.layoutShape(ctx, node, .rrect);
            },
            .text => {
                const data = self.view.data[node].text;
                const text = rnd.createText(ctx.root.rctx, rnd.Size{
                    .width = data.font_size * 80, // 80 character max column width
                    .height = std.math.maxInt(f32), // can be as large as needed
                });
                const text_rect = rnd.getTextRect(text);
                try ctx.ops.append(ctx.allocator, RenderOp{
                    .tag = .text,
                    .node = node,
                    .rect = text_rect,
                    .text = text,
                });
                return text_rect.size;
            },
            .view => {
                const obj_id = self.view.data[node].view;
                const gop = try self.children.getOrPut(ctx.allocator, obj_id);
                const child: *Child = gop.value_ptr;
                child.render_id = self.render_id;
                try child.node.render(ctx, obj_id);
                const view_size = child.node.size.?;
                try ctx.ops.append(ctx.allocator, RenderOp{
                    .tag = .view,
                    .node = node,
                    .rect = rnd.Rect{
                        .size = view_size,
                        .offset = rnd.Offset{ .dx = 0, .dy = 0 },
                    },
                    .text = null,
                });
                return view_size;
            },
        }
    }

    inline fn layoutShape(self: *RenderNode, ctx: *RenderContext, node: View.NodeIndex, comptime tag: RenderOp.Tag) !rnd.Size {
        const op_i = ctx.ops.items.len;
        try ctx.ops.append(ctx.allocator, RenderOp{
            .tag = tag,
            .node = node,
            .rect = undefined,
            .text = null,
        });

        const child_size = try self.layoutViewNode(ctx, self.view.tree[node].head);
        if (sizeIsZero(child_size)) {
            _ = ctx.ops.pop();
            std.debug.assert(ctx.ops.items.len == op_i);
            return rnd.Size{ .width = 0, .height = 0 };
        }

        ctx.ops.items[op_i].rect = rnd.Rect{
            .size = child_size,
            .offset = rnd.Offset{ .dx = 0, .dy = 0 },
        };
        return child_size;
    }

    inline fn layoutFlex(self: *RenderNode, ctx: *RenderContext, node: View.NodeIndex, comptime axis: enum { column, row }) !void {
        const data = switch (axis) {
            .column => self.view.data[node].column,
            .row => self.view.data[node].row,
        };

        var width: f32 = 0;
        var height: f32 = 0;

        const children_start = ctx.children.items.len;
        var tail: View.NodeIndex = self.view.tree[node].head;
        while (tail != 0) : (tail = self.view.tree[tail].next) {
            const child_start = ctx.ops.items.len;
            const child_size = try self.layoutViewNode(ctx, tail);
            if (sizeIsZero(child_size)) {
                continue;
            }

            try ctx.children.append(ctx.allocator, child_start);

            switch (axis) {
                .column => {
                    width = @max(width, child_size.width);
                    height += child_size.height;
                    if (tail != self.view.tree[node].head) {
                        height += data.spacing;
                    }
                },
                .row => {
                    width += child_size.width;
                    if (tail != self.view.tree[node].head) {
                        width += data.spacing;
                    }
                    height = @max(height, child_size.height);
                },
            }
        }

        var offset: f32 = 0.0;
        const children = ctx.children.items[children_start..];
        for (children, 0..) |start, i| {
            const end = if (i + 1 < children.len)
                children[i + 1]
            else
                ctx.ops.items.len;
            const ops = ctx.ops.items[start..end];
            for (ops) |*op| {
                switch (axis) {
                    .column => {
                        switch (data.cross_align) {
                            .start => {},
                            .end => {
                                op.rect.offset.dx += width - ops[0].rect.size.width;
                            },
                            .center => {
                                op.rect.offset.dx += (width - ops[0].rect.size.width) / 2;
                            },
                        }

                        op.rect.offset.dy += offset;
                        if (i != 0) {
                            op.rect.offset.dy += data.spacing;
                            offset += data.spacing;
                        }
                        offset ++ op.rect.size.height;
                    },
                    .row => {
                        switch (data.cross_align) {
                            .start => {},
                            .end => {
                                op.rect.offset.dy += height - ops[0].rect.size.height;
                            },
                            .center => {
                                op.rect.offset.dy += (height - ops[0].rect.size.height) / 2;
                            },
                        }

                        op.rect.offset.dx += offset;
                        if (i != 0) {
                            op.rect.offset.dx += data.spacing;
                            offset += data.spacing;
                        }
                        offset ++ op.rect.size.width;
                    },
                }
            }
        }

        ctx.children.shrinkRetainingCapacity(children_start);

        return rnd.Size{
            .width = width,
            .height = height,
        };
    }
};

inline fn sizeIsZero(size: rnd.Size) bool {
    return size.width == 0 or size.height == 0;
}
