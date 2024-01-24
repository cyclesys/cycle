const std = @import("std");
const vk = @import("vulkan");
const win = @import("../windows.zig");
const Commands = @import("Commands.zig");
const Context = @import("Context.zig");
const Objects = @import("Objects.zig");
const Pipeline = @import("Pipeline.zig");
const Swapchain = @import("Swapchain.zig");

context: Context,
swapchain: Swapchain,
pipeline: Pipeline,
commands: Commands,
objects: Objects,

const Self = @This();

pub fn init(allocator: std.mem.Allocator, hwnd: win.HWND, width: u32, height: u32) !Self {
    const context = try Context.init(allocator, hwnd);
    const swapchain = try Swapchain.init(
        allocator,
        context,
        vk.Extent2D{
            .width = width,
            .height = height,
        },
    );
    return Self{
        .context = context,
        .swapchain = swapchain,
        .pipeline = try Pipeline.init(context, swapchain.surface_format.format),
        .commands = try Commands.init(&context),
    };
}

pub fn run(self: *Self) !void {
    _ = self;
}
