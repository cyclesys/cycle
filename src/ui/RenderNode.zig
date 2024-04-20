//!
view: View,
children: std.AutoHashMapUnmanaged(Store.Id, Child),
render_id: u8,
size: ?rnd.Size,
robj: *rnd.Object,

const std = @import("std");
const rnd = @cImport({
    @cInclude("render/render.h");
});
const Root = @import("Root.zig");
const Store = @import("../Store.zig");
const View = @import("View.zig");
const RenderNode = @This();

pub const RenderContext = struct {
    allocator: std.mem.Allocator,
    root: *Root,
    store: *Store,
    ops: std.ArrayListUnmanaged(RenderOp) = .{},
    children: std.ArrayListUnmanaged(u16) = .{},
    // A stack of nodes that are currently being rendered.
    // This is used to detech any cycles.
    stack: std.AutoHashMapUnmanaged(Store.Id, void) = .{},
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

const Child = struct {
    render_id: u8,
    node: RenderNode,
    offset: rnd.Offset,
};

pub fn deinit(self: *RenderNode, allocator: std.mem.Allocator) void {
    if (self.size != null) {
        rnd.destroyObject(self.robj);
    }

    var iter = self.children.valueIterator();
    while (iter.next()) |child| {
        child.node.deinit(allocator);
    }

    self.children.deinit(allocator);
    self.* = undefined;
}

pub fn render(self: *RenderNode, ctx: *RenderContext, obj_id: Store.Id) !void {
    self.render_id = @addWithOverflow(self.render_id, 1)[0];

    const op_start = ctx.ops.items.len;
    try ctx.stack.put(ctx.allocator, obj_id, undefined);

    const obj = ctx.store.objects.get(obj_id).?;
    const builder = ctx.builders.get(obj.type).?;

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
        self.robj = rnd.createObject(ctx.rwnd, new_size);
    } else {
        self.robj = rnd.createObject(ctx.rwnd, new_size);
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
                const id = self.view.data[op.node].view;
                const child = self.children.getPtr(id).?;
                child.offset = op.rect.offset;
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
            const text = rnd.createText(ctx.rctx, rnd.Size{
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
            if (ctx.stack.contains(obj_id)) {
                return rnd.Size{ .width = 0, .height = 0 };
            }

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

inline fn layoutShape(
    self: *RenderNode,
    ctx: *RenderContext,
    node: View.NodeIndex,
    comptime tag: RenderOp.Tag,
) !rnd.Size {
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

inline fn layoutFlex(
    self: *RenderNode,
    ctx: *RenderContext,
    node: View.NodeIndex,
    comptime axis: enum { column, row },
) !void {
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

inline fn sizeIsZero(size: rnd.Size) bool {
    return size.width == 0 or size.height == 0;
}
