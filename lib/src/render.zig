const std = @import("std");
const ui = @import("ui.zig");
pub const vk = @import("render/vulkan.zig");

pub const Renderer = switch (@import("builtin").os.tag) {
    .windows => vk.Renderer,
    else => @compileError("target os not supported"),
};

pub const Layer = union(enum) {
    Text: ui.Text,
    Rect: ui.Rect,
};
