const std = @import("std");
const zig = @import("zig.zig");
const Root = @import("ui/Root.zig");
const Store = @import("Store.zig");
const Type = @import("Type.zig");
const View = @import("ui/View.zig");

const System = struct {
    apps: zig.List(zig.Ref),

    pub const name = "cycle.sys.System";
};
const SystemObj = zig.LayoutType(System);

const App = struct {
    name: zig.Str,
    is_running: bool,

    pub const name = "cycle.sys.App";
};
const AppObj = zig.LayoutType(App);

pub const State = struct {
    sys_obj_id: Store.Id,
};

pub fn init(allocator: std.mem.Allocator, store: *Store, root: *Root) !*State {
    const state = try allocator.create(State);

    const sys_type_id = try store.addType(allocator, System.name, try zig.initType(allocator, System));
    state.sys_obj_id = try store.addObject(allocator, null, sys_type_id);

    const sys: *SystemObj = @ptrCast(@alignCast(store.objects.get(state.sys_obj_id).?.data));
    sys.apps = .{};

    try root.registerBuilder(allocator, sys_type_id, .{
        .ctx = @ptrCast(state),
        .build = systemView,
    });

    const app_type_id = try store.addType(allocator, App.name, try zig.initType(allocator, App));
    try root.registerBuilder(allocator, app_type_id, .{
        .ctx = @ptrCast(state),
        .build = appView,
    });

    try root.addNode(allocator, store, state.sys_obj_id);

    return state;
}

pub fn systemView(ctx: *anyopaque, allocator: std.mem.Allocator, view: *View, obj: [*]u8) !void {
    _ = ctx;
    const sys: *SystemObj = @ptrCast(@alignCast(obj));

    view.clear();
    var stack = View.BuildStack(8){};
    try stack.push(allocator, view, .{
        .rrect = .{
            .color = View.Color.white,
            .radius = View.Radius.circle(16.0),
        },
    });
    try stack.push(allocator, view, .{
        .padding = View.Padding.all(16.0),
    });
    try stack.push(allocator, view, .{
        .column = .{
            .cross_align = .start,
            .spacing = 16.0,
        },
    });
    try stack.append(allocator, view, .{
        .text = .{
            .str = "System",
            .font_size = 24.0,
        },
    });
    try stack.push(allocator, view, .{
        .column = .{
            .cross_align = .start,
            .spacing = 16.0,
        },
    });
    for (sys.apps.items()) |app| {
        try stack.append(allocator, view, .{
            .view = app,
        });
    }
}

pub fn appView(ctx: *anyopaque, allocator: std.mem.Allocator, view: *View, obj: [*]u8) !void {
    _ = ctx;
    const app: *AppObj = @ptrCast(@alignCast(obj));

    view.clear();
    var stack = View.BuildStack(8){};
    try stack.push(allocator, view, .{
        .rrect = .{
            .color = View.Color.white,
            .radius = View.Radius.circle(16.0),
            .border = View.Border{
                .color = View.Color.black,
                .thickness = 1.0,
            },
        },
    });
    try stack.push(allocator, view, .{
        .row = .{
            .spacing = 16.0,
        },
    });
    try stack.append(allocator, view, .{
        .text = .{
            .str = app.name.buf[0..app.name.len],
        },
    });
    try stack.append(allocator, view, .{
        .text = .{
            .str = if (app.is_running) "Active" else "Inactive",
        },
    });
}
