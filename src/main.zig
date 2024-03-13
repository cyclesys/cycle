const std = @import("std");
const glfw = @import("glfw");
const render = @cImport({
    @cInclude("render/render.h");
});

pub fn main() !void {
    var ctx: Context = undefined;
    defer ctx.deinit();

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

    ctx.init(window);
    window.setUserPointer(@ptrCast(&ctx));
    window.setFramebufferSizeCallback(Context.onFramebufferSize);
    window.setRefreshCallback(Context.onRefresh);
    window.setKeyCallback(Context.onKey);
    window.setCharCallback(Context.onChar);
    window.setMouseButtonCallback(Context.onMouseButton);
    window.setCursorPosCallback(Context.onCursorPos);
    window.setCursorEnterCallback(Context.onCursorEnter);
    window.setScrollCallback(Context.onScroll);
    window.show();

    while (!window.shouldClose()) {
        glfw.pollEvents();
    }
}

const GlfwNative = glfw.Native(.{ .win32 = true });

const Context = struct {
    rctx: *render.Context,
    wnd: *render.Window,
    obj: *render.Object,
    text: *render.Text,
    first_render: bool,

    fn init(ctx: *Context, w: glfw.Window) void {
        const hwnd = GlfwNative.getWin32Window(w);
        const window_size = w.getSize();
        ctx.rctx = render.createContext().?;
        ctx.wnd = render.createWindow(ctx.rctx, hwnd, window_size.width, window_size.height).?;
        ctx.first_render = true;
    }

    fn deinit(ctx: *Context) void {
        if (!ctx.first_render) {
            render.destroyText(ctx.text);
            render.destroyObject(ctx.obj);
        }
        render.destroyWindow(ctx.wnd);
        render.destroyContext(ctx.rctx);
    }

    fn onFramebufferSize(w: glfw.Window, width: u32, height: u32) void {
        const ctx = w.getUserPointer(Context).?;
        if (!ctx.first_render) {
            render.destroyText(ctx.text);
            render.destroyObject(ctx.obj);
            render.resizeWindow(ctx.wnd, width, height);
            ctx.first_render = true;
        }
    }

    fn onRefresh(w: glfw.Window) void {
        const ctx = w.getUserPointer(Context).?;
        const window_size = w.getSize();
        const window_width: f32 = @floatFromInt(window_size.width);
        const window_height: f32 = @floatFromInt(window_size.height);

        const obj_size = render.Size{
            .width = window_width / 2,
            .height = window_height / 2,
        };

        if (ctx.first_render) {
            ctx.obj = render.createObject(ctx.wnd, obj_size).?;

            const text_chars = "Hello Cycle!";
            const text_size = render.Size{
                .width = obj_size.width / 2,
                .height = obj_size.height / 2,
            };
            ctx.text = render.createText(
                ctx.rctx,
                render.Size{
                    .width = text_size.width,
                    .height = text_size.height,
                },
                render.ConstSlice{
                    .ptr = @ptrCast(text_chars),
                    .len = text_chars.len,
                },
                16.0,
            ).?;
            const text_rect = render.getTextRect(ctx.text);

            render.beginDraw(ctx.obj);
            render.drawRect(ctx.obj, render.Rect{
                .offset = render.Offset{
                    .dx = 0,
                    .dy = 0,
                },
                .size = obj_size,
            }, 0x838383FF);

            render.drawText(
                ctx.obj,
                ctx.text,
                render.Offset{
                    .dx = (obj_size.width - text_rect.size.width) / 2,
                    .dy = (obj_size.height - text_rect.size.height) / 2,
                },
            );
            if (!render.endDraw(ctx.obj)) {
                @panic("endDraw failed");
            }

            ctx.first_render = false;
        }

        render.beginFrame(ctx.wnd);
        render.drawObject(
            ctx.wnd,
            ctx.obj,
            render.Rect{
                .offset = render.Offset{
                    .dx = (window_width - obj_size.width) / 2,
                    .dy = (window_height - obj_size.height) / 2,
                },
                .size = obj_size,
            },
        );
        if (!render.endFrame(ctx.wnd)) {
            @panic("endFrame failed");
        }
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
