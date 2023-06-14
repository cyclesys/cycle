const super = @import("../ui.zig");
const tree = @import("tree.zig");

pub fn size(config: anytype) Size(@TypeOf(config)) {
    return .{ .config = config };
}

pub fn Size(comptime Config: type) type {
    return tree.LayoutNode(Config, .Size, .SingleOptional, struct {
        width: ?u16 = null,
        height: ?u16 = null,

        pub fn layout(opts: @This(), constraints: tree.Constraints, child: anytype) !tree.Size {
            if (child) |ch| {
                try ch.layout(.{
                    .width = opts.width orelse constraints.width,
                    .height = opts.height orelse constraints.height,
                });

                ch.offset(.{
                    .x = 0,
                    .y = 0,
                });
            }

            return .{
                .width = opts.width orelse if (child) |ch| ch.width else 0,
                .height = opts.height orelse if (child) |ch| ch.height else 0,
            };
        }
    });
}

pub fn fill(config: anytype) Fill(@TypeOf(config)) {
    return .{ .config = config };
}

pub fn Fill(comptime Config: type) type {
    return tree.LayoutNode(Config, .Fill, .SingleOptional, struct {
        orientation: ?super.Orientation = null,

        pub fn layout(opts: @This(), constraints: tree.Constraints, child: anytype) !tree.Size {
            if (child) |ch| {
                try ch.layout(constraints);
                ch.offset(.{
                    .x = 0,
                    .y = 0,
                });
            }

            if (opts.orientation) |orientation| {
                switch (orientation) {
                    .vertical => {
                        if (constraints.height) |height| {
                            return .{
                                .width = if (child) |ch| ch.width else 0,
                                .height = height,
                            };
                        } else {
                            return error.UnconstrainedFill;
                        }
                    },
                    .horizontal => {
                        if (constraints.width) |width| {
                            return .{
                                .width = width,
                                .height = if (child) |ch| ch.height else 0,
                            };
                        } else {
                            return error.UnconstrainedFill;
                        }
                    },
                }
            }

            if (constraints.width == null or constraints.height == null) {
                return error.UnconstrainedFill;
            }

            return .{
                .width = constraints.width.?,
                .height = constraints.height.?,
            };
        }
    });
}

pub fn center(config: anytype) Center(@TypeOf(config)) {
    return .{ .config = config };
}

pub fn Center(comptime Config: type) type {
    return tree.LayoutNode(Config, .Center, .Single, struct {
        orientation: ?super.Orientation = null,

        pub fn layout(opts: @This(), constraints: tree.Constraints, child: anytype) !tree.Size {
            try child.layout(constraints);
            if (opts.orientation) |orientation| {
                switch (orientation) {
                    .vertical => {
                        if (constraints.height) |height| {
                            child.offset(.{
                                .x = 0,
                                .y = (height - child.height) / 2,
                            });
                            return .{
                                .width = child.width,
                                .height = height,
                            };
                        } else {
                            return error.UnconstrainedCenter;
                        }
                    },
                    .horizontal => {
                        if (constraints.width) |width| {
                            child.offset(.{
                                .x = (width - child.width) / 2,
                                .y = 0,
                            });
                            return .{
                                .width = width,
                                .height = child.height,
                            };
                        } else {
                            return error.UnconstrainedCenter;
                        }
                    },
                }
            }

            if (constraints.width == null or constraints.height == null) {
                return error.UnconstrainedCenter;
            }
            const width = constraints.width.?;
            const height = constraints.height.?;

            child.offset(.{
                .x = (width - child.width) / 2,
                .y = (height - child.height) / 2,
            });
            return .{
                .width = width,
                .height = height,
            };
        }
    });
}

pub fn linear(config: anytype) Linear(@TypeOf(config)) {
    return .{ .config = config };
}

pub fn Linear(comptime Config: type) type {
    return tree.LayoutNode(Config, .Linear, .Indexed, struct {
        orientation: super.Orientation,
        main_align: ?LinearMainAlign = null,
        cross_align: ?LinearCrossAlign = null,

        pub fn layout(opts: @This(), constraints: tree.Constraints, children: anytype) !tree.Size {
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
                    if (info.weight) |weight| {
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
                    return error.LinearUnconstrained;
                }

                iter.reset();
                while (iter.next()) |child| {
                    if (child.info(.LinearChild)) |info| {
                        if (info.weight) |weight| {
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

                const child_main = if (opts.main_align) |main_align|
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
                    var cross_align: ?LinearCrossAlign = opts.cross_align;
                    if (child.info(.LinearChild)) |info| {
                        cross_align = info.cross_align orelse cross_align;
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
                        child.offset(.{
                            .x = child_cross,
                            .y = child_main,
                        });
                        offset_main += child.height;
                    },
                    .horizontal => {
                        child.offset(.{
                            .x = child_main,
                            .y = child_cross,
                        });
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

pub fn linearChild(config: anytype) LinearChild(@TypeOf(config)) {
    return .{ .config = config };
}

pub fn LinearChild(comptime Config: type) type {
    return tree.InfoNode(Config, .LinearChild, struct {
        weight: ?u16 = null,
        cross_align: ?LinearCrossAlign = null,
    });
}

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
