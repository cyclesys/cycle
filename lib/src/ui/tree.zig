const std = @import("std");
const meta = @import("meta.zig");
const geometry = @import("geometry.zig");

pub const Tree = struct {};

pub fn InputNode(
    comptime Config: type,
    comptime id: anytype,
    comptime Options: type,
) type {
    return struct {
        opts: Opts,

        pub const node_type = NodeType.input;
        pub const node_id = id;
        pub const Opts = meta.merge(Options, Config);
    };
}

pub fn InfoNode(
    comptime Config: type,
    comptime id: anytype,
    comptime Options: type,
) type {
    return struct {
        opts: Opts,
        child: Child,

        pub const node_type = NodeType.info;
        pub const node_id = id;
        pub const Opts = OptionsType(Options, Config);
        pub const Child = ChildType(Config);
        const Self = @This();

        pub fn new(config: Config) Self {
            return Self{
                .config = options(Options, config),
                .child = child(config),
            };
        }
    };
}

pub fn LayoutNode(
    comptime Config: type,
    comptime id: anytype,
    comptime kind: anytype,
    comptime Impl: type,
) type {
    return struct {
        opts: Opts,
        children: Children,

        pub const node_type = NodeType.layout;
        pub const node_id = id;
        pub const layout_kind = kind;
        pub const Opts = OptionsType(Impl, Config);
        pub const Layout = Impl;
        pub const Children = ChildrenType(Config, Opts, kind);
        const Self = @This();

        pub fn new(config: Config) Self {
            return Self{
                .opts = options(Layout, config),
                .children = children(Layout, config),
            };
        }
    };
}

fn children(comptime Config: type, comptime Opts: type, comptime kind: anytype, config: Config) ChildrenType(Config, Opts, kind) {
    _ = config;
}

fn ChildrenType(comptime Config: type, comptime Opts: type, comptime kind: anytype) type {
    if (@TypeOf(kind) == type) {
        return SlottedChildren(Config, kind);
    }

    return switch (kind) {
        .single => SingleChild(Config),
        .indexed => IndexedChildren(Config, Opts),
        else => @compileError(""),
    };
}

fn SingleChild(comptime Config: type) type {
    _ = Config;
}

fn SlottedChildren(comptime Config: type, comptime Children: type) type {
    _ = Config;
    _ = Children;
}

fn IndexedChildren(comptime Config: type, comptime Opts: type) type {
    _ = Config;
    _ = Opts;
}

pub fn RenderNode(
    comptime Config: type,
    comptime id: anytype,
    comptime Options: type,
) type {
    return struct {
        opts: Opts,
        child: Child,

        pub const node_type = NodeType.render;
        pub const node_id = id;
        pub const Opts = OptionsType(Options, Config);
        pub const Child = ChildType(Config);
        const Self = @This();

        pub fn new(config: Config) Self {
            return Self{
                .opts = options(Options, config),
                .child = child(config),
            };
        }
    };
}

pub fn options(comptime Options: type, config: anytype) OptionsType(Options, @TypeOf(config)) {
    const Opts = OptionsType(Options, @TypeOf(config));
    if (Opts != void) {
        return meta.initMerge(Options, config);
    }
}

pub fn OptionsType(comptime Options: type, comptime Config: type) type {
    if (std.meta.fields(Options).len == 0) {
        return void;
    }
    return meta.Merge(Options, Config);
}

pub fn child(config: anytype) ChildType(@TypeOf(config)) {
    if (@hasField(@TypeOf(config), "child")) {
        return config.child;
    }
}

pub fn ChildType(comptime Cfg: type) type {
    return if (@hasField(Cfg, "child")) std.meta.FieldType(Cfg, .child) else void;
}

const NodeType = enum {
    input,
    info,
    layout,
    render,
};
