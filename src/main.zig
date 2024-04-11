const std = @import("std");
const glfw = @import("glfw");

const Context = struct {};

pub fn main() !void {
    glfw.setErrorCallback(onError);
    if (!glfw.init(.{})) {
        return error.GlfwInit;
    }
    defer glfw.terminate();

    const monitor = glfw.Monitor.getPrimary() orelse {
        return error.GlfwMonitorGetPrimary;
    };
    const workarea = monitor.getWorkarea();

    const window = glfw.Window.create(
        workarea.width / 2,
        workarea.height / 2,
        @as([*:0]const u8, "Cycle"),
        null,
        null,
        glfw.Window.Hints{
            .client_api = .no_api,
        },
    ) orelse {
        return error.GlfwWindowCreate;
    };
    defer window.destroy();

    const allocator = std.heap.c_allocator;
    const ctx = try allocator.create(Context);
    defer allocator.destroy(ctx);

    window.setUserPointer(@ptrCast(ctx));
    window.setFramebufferSizeCallback(onFramebufferSize);
    window.setRefreshCallback(onRefresh);
    window.setKeyCallback(onKey);
    window.setCharCallback(onChar);
    window.setMouseButtonCallback(onMouseButton);
    window.setCursorPosCallback(onCursorPos);
    window.setCursorEnterCallback(onCursorEnter);
    window.setScrollCallback(onScroll);
    window.show();

    while (!window.shouldClose()) {
        glfw.pollEvents();
    }
}

fn onError(error_code: glfw.ErrorCode, description: [:0]const u8) void {
    std.log.err("glfw {}: {s}\n", .{ error_code, description });
}

fn onFramebufferSize(w: glfw.Window, width: u32, height: u32) void {
    const ctx = w.getUserPointer(Context).?;
    _ = ctx;
    _ = width;
    _ = height;
}

fn onRefresh(w: glfw.Window) void {
    const ctx = w.getUserPointer(Context).?;
    _ = ctx;
}

fn onKey(w: glfw.Window, key: glfw.Key, scancode: i32, action: glfw.Action, mods: glfw.Mods) void {
    _ = w;
    _ = mods;
    _ = action;
    _ = scancode;
    _ = key;
}

fn onChar(window: glfw.Window, codepoint: u21) void {
    _ = window;
    _ = codepoint;
}

fn onMouseButton(window: glfw.Window, button: glfw.MouseButton, action: glfw.Action, mods: glfw.Mods) void {
    _ = window;
    _ = button;
    _ = action;
    _ = mods;
}

fn onCursorPos(window: glfw.Window, xpos: f64, ypos: f64) void {
    _ = window;
    _ = xpos;
    _ = ypos;
}

fn onCursorEnter(window: glfw.Window, entered: bool) void {
    _ = window;
    _ = entered;
}

fn onScroll(window: glfw.Window, xoffset: f64, yoffset: f64) void {
    _ = window;
    _ = xoffset;
    _ = yoffset;
}

test {
    _ = @import("gen_list.zig");
    _ = @import("raw.zig");
    _ = @import("zig.zig");
    _ = @import("TypeLayout.zig");
}
