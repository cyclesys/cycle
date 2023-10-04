const std = @import("std");
const lib = @import("lib");
const glfw = @import("glfw");

fn errorCallback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
    std.log.err("glfw {}: {s}\n", .{ error_code, description });
}

pub fn main() !void {
    glfw.setErrorCallback(errorCallback);
    if (!glfw.init(.{})) {
        return error.GlfwInit;
    }
    defer glfw.terminate();

    const monitor = glfw.Monitor.getPrimary() orelse {
        return error.GlfwMonitorGetPrimary;
    };

    const workarea = monitor.getWorkarea();

    const window = glfw.Window.create(
        workarea.width,
        workarea.height,
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

    while (!window.shouldClose()) {}
}
