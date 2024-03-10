const std = @import("std");
const chan = @import("../lib.zig").chan;
const def = @import("../lib.zig").def;
const win = @import("../windows.zig");

// Id for a pure user-interface object (i.e. an object not backed by data).
pub const UIObjectId = u64;

// Either a ui object, or a data object id.
pub const RenderObjectId = union(enum) {
    ui: RenderObjectId,
    data: def.ObjectIdInt,
};

pub const SystemMessage = union(enum) {
    RenderContextObject: struct {
        id: RenderObjectId,
        context: RenderObjectId,
    },
    RenderDataObject: def.ObjectIdInt,
    UpdateRenderTarget: struct {
        id: RenderObjectId,
        width: u32,
        height: u32,
        handle: win.HANDLE,
    },
};

pub const PluginMessage = union(enum) {
    UpdateSize: struct {
        id: RenderObjectId,
        width: u32,
        height: u32,
    },
};

pub const Handles = struct {
    read: chan.Channel.Handles,
    write: chan.Channel.Handles,
};

pub fn Runtime(comptime Context: type) type {
    return struct {
        reader: chan.Reader(SystemMessage),
        writer: chan.Writer(PluginMessage),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, h: Handles) Self {
            return Self{
                .reader = try chan.Reader(SystemMessage).initHandles(allocator, h.read),
                .writer = try chan.Writer(PluginMessage).initHandles(allocator, h.write),
            };
        }

        pub fn deinit(self: Self) void {
            _ = self;
        }
    };
}
