const vk = @import("composite/vulkan.zig");

pub const Compositor = switch (@import("builtin").os.tag) {
    .windows => vk.Compositor,
    else => @compileError("wut"),
};
