const tree = @import("tree.zig");

pub fn rect(config: anytype) Rect(@TypeOf(config)) {
    return .{ .config = config };
}

pub fn Rect(comptime Config: type) type {
    return tree.RenderNode(Config, .Rect, struct {
        radius: ?struct {
            top_left: ?u16 = null,
            top_right: ?u16 = null,
            bottom_left: ?u16 = null,
            bottom_right: ?u16 = null,
        } = null,
    });
}

pub fn oval(config: anytype) Oval(@TypeOf(config)) {
    return .{ .config = config };
}

pub fn Oval(comptime Config: type) type {
    return tree.RenderNode(Config, .Oval, struct {});
}

pub fn text(config: anytype) Text(@TypeOf(config)) {
    return .{ .config = config };
}

pub fn Text(comptime Config: type) type {
    return tree.RenderNode(Config, .Text, struct {
        text: []const u8,
    });
}
