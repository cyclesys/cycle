const meta = @import("meta.zig");
const tree = @import("tree.zig");

pub const LinearOrientation = enum {
    vertical,
    horizontal,
};

pub const LinearMainAlign = enum {
    end,
    center,
    between,
    evenly,
};

pub const LinearCrossAlign = enum {
    end,
    center,
};

pub fn linearChild(config: anytype) LinearChild(@TypeOf(config)) {
    return LinearChild(@TypeOf(config)).new(config);
}

pub fn LinearChild(comptime Config: type) type {
    return tree.InfoNode(Config, .LinearChild, struct {
        weight: ?u16,
        cross_align: ?LinearCrossAlign,
    });
}

pub fn linear(config: anytype) Linear(@TypeOf(config)) {
    return Linear(@TypeOf(config)).new(config);
}

pub fn Linear(comptime Config: type) type {
    return tree.LayoutNode(Config, .LinearVertical, .Indexed, struct {
        orientation: LinearOrientation,
        main_align: ?LinearMainAlign,
        cross_align: ?LinearCrossAlign,

        pub fn layout(opts: anytype, constraints: tree.Constraints, children: anytype) !tree.Size {
            var remaining_extent: ?u16 = switch (opts.orientation) {
                .vertical => constraints.height,
                .horizontal => constraints.width,
            };
            var max_cross: u16 = 0;
            var total_main: u16 = 0;
            var total_weight: u16 = 0;

            var iter = children.iterator();
            while (iter.next()) |child| {
                if (child.info(.LinearChild)) |info| {
                    if (meta.opt(info, .weight)) |weight| {
                        if (weight == 0) {
                            return error.LinearChildZeroWeight;
                        }

                        total_weight += weight;
                        continue;
                    }
                }
                switch (opts.orientation) {
                    .vertical => {
                        try child.layout(.{
                            .width = constraints.width,
                            .height = remaining_extent,
                        });
                        if (remaining_extent != null) {
                            remaining_extent.? -= child.height;
                        }
                        max_cross = @max(max_cross, child.width);
                        total_main += child.height;
                    },
                    .horizontal => {
                        try child.layout(.{
                            .width = remaining_extent,
                            .height = constraints.height,
                        });
                        if (remaining_extent != null) {
                            remaining_extent.? -= child.width;
                        }
                        max_cross = @max(max_cross, child.height);
                        total_main += child.width;
                    },
                }
            }

            if (total_weight > 0) {
                var remaining_weight = total_weight;
                if (remaining_extent == null) {
                    return error.UnconstrainedLinearMain;
                }

                iter.reset();
                while (iter.next()) |child| {
                    if (child.info(.LinearChild)) |info| {
                        if (meta.opt(info, .weight)) |weight| {
                            const child_main = weight / remaining_weight * remaining_extent.?;
                            remaining_weight -= weight;

                            switch (opts.orientation) {
                                .vertical => {
                                    try child.layout(.{
                                        .width = constraints.width,
                                        .height = child_main,
                                    });
                                    remaining_extent.? -= child.height;
                                    max_cross = @max(max_cross, child.width);
                                    total_main += child.height;
                                },
                                .horizontal => {
                                    try child.layout(.{
                                        .width = child_main,
                                        .height = constraints.height,
                                    });
                                    remaining_extent -= child.width;
                                    max_cross = @max(max_cross, child.height);
                                    total_main += child.width;
                                },
                            }

                            if (remaining_extent.? == 0)
                                break;
                        }
                    }
                }
            }

            const spacing_left = if (remaining_extent) |extent| extent else 0;
            var offset_main: u16 = 0;
            for (0..children.len) |i| {
                const child = children.get(i);

                const child_main = if (meta.opt(opts, .main_align)) |main_align|
                    switch (main_align) {
                        .end => offset_main + spacing_left,
                        .center => offset_main + (spacing_left / 2),
                        .between => if (i > 0)
                            offset_main + (spacing_left / (children.len - 1))
                        else
                            offset_main,
                        .evenly => offset_main + (spacing_left / children.len + 1),
                    }
                else
                    offset_main;

                const child_cross_size = switch (opts.orientation) {
                    .vertical => child.height,
                    .horizontal => child.width,
                };
                const child_cross = blk: {
                    var cross_align: ?LinearCrossAlign = meta.opt(opts, .cross_align);
                    if (child.info(.LinearChild)) |info| {
                        if (meta.opt(info, .cross_align)) |ca| {
                            cross_align = ca;
                        }
                    }

                    if (cross_align) |ca| {
                        break :blk switch (ca) {
                            .end => max_cross - child_cross_size,
                            .center => (max_cross - child_cross_size) / 2,
                        };
                    }

                    break :blk 0;
                };

                switch (opts.orientation) {
                    .vertical => {
                        child.y = child_main;
                        child.x = child_cross;
                        offset_main += child.height;
                    },
                    .horizontal => {
                        child.y = child_cross;
                        child.x = child_main;
                        offset_main += child.width;
                    },
                }
            }

            return switch (opts.orientation) {
                .vertical => .{
                    .width = max_cross,
                    .height = total_main,
                },
                .horizontal => .{
                    .width = total_main,
                    .height = max_cross,
                },
            };
        }
    });
}
