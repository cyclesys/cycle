const std = @import("std");
const glfw = @import("glfw");
const render = @cImport({
    @cInclude("render/render.h");
});

pub fn main() !void {
    var ctx = Context{};
    const window = try initGlfw(&ctx);
    defer glfw.terminate();
    defer window.destroy();

    const hwnd = GlfwNative.getWin32Window(window);
    const render_context = render.createRenderContext(@alignCast(@ptrCast(hwnd)));
    defer render.destroyRenderContext(render_context);

    window.show();
    while (!window.shouldClose()) {
        glfw.pollEvents();
    }
}

const GlfwNative = glfw.Native(.{ .win32 = true });

fn initGlfw(ctx: *Context) !glfw.Window {
    glfw.setErrorCallback(errorCallback);
    if (!glfw.init(.{})) {
        return error.GlfwInit;
    }

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

    window.setUserPointer(@ptrCast(ctx));
    window.setFramebufferSizeCallback(Context.onFramebufferSize);
    window.setKeyCallback(Context.onKey);
    window.setCharCallback(Context.onChar);
    window.setMouseButtonCallback(Context.onMouseButton);
    window.setCursorPosCallback(Context.onCursorPos);
    window.setCursorEnterCallback(Context.onCursorEnter);
    window.setScrollCallback(Context.onScroll);

    return window;
}

const Context = struct {
    fn onFramebufferSize(w: glfw.Window, width: u32, height: u32) void {
        _ = w;
        _ = height;
        _ = width;
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
};

fn errorCallback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
    std.log.err("glfw {}: {s}\n", .{ error_code, description });
}
