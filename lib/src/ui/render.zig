const tree = @import("tree.zig");

pub fn rect(config: anytype) Rect(tree.Child(@TypeOf(config))) {
    const RectNode = Rect(tree.Child(@TypeOf(config)));
    return tree.initNode(RectNode, config);
}

pub fn Rect(comptime Child: type) type {
    return tree.RenderNode(.Rect, Child, struct {
        radius: ?struct {
            top_left: ?u16 = null,
            top_right: ?u16 = null,
            bottom_left: ?u16 = null,
            bottom_right: ?u16 = null,
        } = null,
    });
}

pub fn oval(config: anytype) Oval(tree.Child(@TypeOf(config))) {
    const OvalNode = Oval(tree.Child(@TypeOf(config)));
    return tree.initNode(OvalNode, config);
}

pub fn Oval(comptime Child: type) type {
    return tree.RenderNode(.Oval, Child, struct {});
}

pub fn text(config: anytype) Text {
    return tree.InitNode(Text, config);
}

pub const Text = tree.RenderNode(.Text, void, struct {
    text: []const u8,
});
