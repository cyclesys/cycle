//!
rctx: *rnd.Context,
rwnd: *rnd.Window,

builders: std.AutoHashMapUnmanaged(Store.Id, View.Builder),
nodes: std.AutoHashMapUnmanaged(Store.Id, RootNode),

grid: Grid,
z_order: std.ArrayListUnmanaged(Store.Id),
width: f32,
height: f32,

const std = @import("std");
const glfw = @import("glfw");
const rnd = @cImport({
    @cInclude("render.h");
});
const Store = @import("../Store.zig");
const Grid = @import("Grid.zig");
const RenderNode = @import("RenderNode.zig");
const View = @import("View.zig");
const Root = @This();

const RootNode = struct {
    node: RenderNode,
    left: f32,
    top: f32,
};

pub fn init(allocator: std.mem.Allocator, window: glfw.Window) !Root {
    const rctx = rnd.createContext().?;
    const size = window.getSize();
    const hwnd = glfw.Native(.{ .win32 = true }).getWin32Window(window);
    const rwnd = rnd.createWindow(rctx, hwnd, size.width, size.height).?;

    const width: f32 = @floatFromInt(size.width);
    const height: f32 = @floatFromInt(size.height);
    const grid = try Grid.init(allocator, width, height);
    return Root{
        .rctx = rctx,
        .rwnd = rwnd,
        .builders = .{},
        .nodes = .{},
        .grid = grid,
        .z_order = .{},
        .width = width,
        .height = height,
    };
}

pub fn registerBuilder(
    self: *Root,
    allocator: std.mem.Allocator,
    type_id: Store.Id,
    builder: View.Builder,
) !void {
    const gop = try self.builders.getOrPut(allocator, type_id);
    if (gop.found_existing) {
        return error.FoundExistingBuilder;
    }
    gop.value_ptr.* = builder;
}

pub fn addNode(
    self: *Root,
    allocator: std.mem.Allocator,
    store: *Store,
    obj_id: Store.Id,
) !void {
    const gop = try self.nodes.getOrPut(allocator, obj_id);
    std.debug.assert(!gop.found_existing);
    const rn: *RootNode = gop.value_ptr;
    rn.* = RootNode{
        .node = RenderNode{
            .view = .{},
            .children = .{},
            .render_id = 0,
            .size = null,
            .robj = undefined,
        },
        .left = 0.0,
        .top = 0.0,
    };
    try self.renderNode(allocator, store, obj_id, rn);

    const size = rn.node.size.?;
    rn.left = (self.width - size.width) / 2;
    rn.top = (self.height - size.height) / 2;
    try self.grid.insert(
        allocator,
        obj_id,
        rn.left,
        rn.top,
        size.width,
        size.height,
    );
    try self.z_order.append(allocator, obj_id);
}

pub fn updateNode(
    self: *Root,
    allocator: std.mem.Allocator,
    store: *Store,
    obj_id: Store.Id,
) !void {
    const rn = self.nodes.getPtr(obj_id).?;
    try self.renderRootNode(allocator, store, rn);
}

fn renderNode(
    self: *Root,
    allocator: std.mem.Allocator,
    store: *Store,
    obj_id: Store.Id,
    rn: *RootNode,
) !void {
    var ctx = RenderNode.RenderContext{
        .allocator = allocator,
        .root = self,
        .store = store,
        .ops = .{},
        .children = .{},
        .stack = .{},
    };
    defer ctx.deinit();
    try rn.node.render(&ctx, obj_id);
}

pub fn render(self: *Root) !void {
    rnd.beginFrame(self.rwnd);
    for (self.z_order.items) |id| {
        const rn = self.nodes.get(id).?;
        rnd.drawObject(self.rwnd, rn.node.robj, rnd.Rect{
            .size = rn.node.size.?,
            .offset = rnd.Offset{
                .dx = rn.left,
                .dy = rn.top,
            },
        });
    }
    if (!rnd.endFrame(self.rwnd)) return error.RenderError;
}
