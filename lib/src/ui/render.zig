const tree = @import("tree.zig");

pub fn line(config: anytype) Line(@TypeOf(config)) {
    return Line(@TypeOf(config)).new(config);
}

pub fn Line(comptime Config: type) type {
    return tree.RenderNode(Config, .Line, struct {
        start: u16,
        end: u16,
    });
}

pub fn rect(config: anytype) Rect(@TypeOf(config)) {
    return Rect(@TypeOf(config)).new(config);
}

pub fn Rect(comptime Config: type) type {
    return tree.RenderNode(Config, .Rect, struct {
        radius: ?struct {
            top_left: ?u16,
            top_right: ?u16,
            bottom_left: ?u16,
            bottom_right: ?u16,
        },
    });
}

pub fn oval(config: anytype) Oval(@TypeOf(config)) {
    return Oval(@TypeOf(config)).new(config);
}

pub fn Oval(comptime Config: type) type {
    return tree.RenderNode(
        Config,
        .Oval,
        struct {},
    );
}

pub fn text(config: anytype) Text(@TypeOf(config)) {
    return Text(@TypeOf(config)).new(config);
}

pub fn Text(comptime Config: type) type {
    return tree.RenderNode(
        Config,
        .Text,
        struct {
            text: []const u8,
        },
    );
}
