const std = @import("std");
const glfw = @import("glfw");
const PluginDir = @import("PluginDir.zig");
const TypeTable = @import("TypeTable.zig");

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var state = State{
        .type_table = TypeTable.init(allocator),
        .plugin_dir = try PluginDir.init(allocator),
    };

    // run all plugins immediately
    for (state.plugin_dir.plugins) |*plugin| {
        try plugin.run(&state.type_table);
    }

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

    window.setUserPointer(&state);
    window.setFrameBufferSizeCallback(framebufferSizeCallback);
    window.setKeyCallback(keyCallback);
    window.setCharCallback(charCallback);
    window.setMouseButtonCallback(mouseButtonCallback);
    window.setCursorPosCallback(cursorPosCallback);
    window.setCursorEnterCallback(cursorEnterCallback);
    window.setScrollCallback(scrollCallback);
    window.show();

    while (!window.shouldClose()) {
        glfw.pollEvents();
    }
}

const State = struct {
    type_table: TypeTable,
    plugin_dir: PluginDir,
};

fn framebufferSizeCallback(window: glfw.Window, width: u32, height: u32) void {
    _ = window;
    _ = width;
    _ = height;
}

fn keyCallback(window: glfw.Window, key: glfw.Key, scancode: i32, action: glfw.Action, mods: glfw.Mods) void {
    _ = window;
    _ = key;
    _ = scancode;
    _ = action;
    _ = mods;
}

fn charCallback(window: glfw.Window, codepoint: u32) void {
    _ = window;
    _ = codepoint;
}

fn mouseButtonCallback(window: glfw.Window, button: glfw.MouseButton, action: glfw.Action, mods: glfw.Mods) void {
    _ = window;
    _ = button;
    _ = action;
    _ = mods;
}

fn cursorPosCallback(window: glfw.Window, xpos: f64, ypos: f64) void {
    _ = window;
    _ = xpos;
    _ = ypos;
}

fn cursorEnterCallback(window: glfw.Window, entered: bool) void {
    _ = window;
    _ = entered;
}

fn scrollCallback(window: glfw.Window, xoffset: f64, yoffset: f64) void {
    _ = window;
    _ = xoffset;
    _ = yoffset;
}

fn errorCallback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
    std.log.err("glfw {}: {s}\n", .{ error_code, description });
}

test {
    _ = @import("TypeIndex.zig");
    _ = @import("TypeTable.zig");
}
