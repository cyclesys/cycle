const std = @import("std");
const win = @import("../windows.zig");
const Commands = @import("Commands.zig");
const Context = @import("Context.zig");
const Pipeline = @import("Pipeline.zig");

context: Context,
commands: Commands,
pipeline: Pipeline,

const Self = @This();

pub fn init(allocator: std.mem.Allocator, hwnd: win.HWND) !Self {
    const context = try Context.init(allocator, hwnd);
    return Self{
        .context = context,
        .commands = try Commands.init(&context),
    };
}
