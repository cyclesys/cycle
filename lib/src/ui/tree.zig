const std = @import("std");
const meta = @import("meta.zig");

pub fn InputNode(comptime Config: type, comptime Id: anytype, comptime Options: type) type {
    return struct {
        config: Config,

        pub const kind = .Input;
        pub const config = Config;
        pub const id = Id;
        pub const options = Options;
    };
}

pub fn LayoutNode(comptime Config: type, comptime Id: anytype, comptime Slots: anytype, comptime Layout: type) type {
    return struct {
        config: Config,

        pub const kind = .Layout;
        pub const config = Config;
        pub const id = Id;
        pub const slots = Slots;
        pub const layout = Layout;
    };
}

pub fn InfoNode(comptime Config: type, comptime Id: anytype, comptime Options: type) type {
    return struct {
        config: Config,

        pub const kind = .Info;
        pub const config = Config;
        pub const id = Id;
        pub const options = Options;
    };
}

pub fn RenderNode(comptime Config: type, comptime Id: anytype, comptime Options: type) type {
    return struct {
        config: Config,

        pub const kind = .Render;
        pub const config = Config;
        pub const id = Id;
        pub const options = Options;
    };
}

pub const Constraints = struct {
    width: ?u16 = null,
    height: ?u126 = null,
};

pub const Size = struct {
    width: u16,
    height: u16,
};

pub const Offset = struct {
    x: u16,
    y: u16,

    pub const zero = Offset{
        .x = 0,
        .y = 0,
    };

    pub fn add(self: *Offset, other: Offset) void {
        self.x += other.x;
        self.y += other.y;
    }
};

pub const Tree = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        typeName: *const fn () []const u8,
    };

    fn typeName(self: Tree) []const u8 {
        return self.vtable.typeName();
    }
};

pub fn build(node: anytype, constraints: Constraints) !Build(@TypeOf(node)) {
    const Node = @TypeOf(node);
    return switch (Node.kind) {
        .Input => buildInput(node, constraints),
        .Layout => buildLayout(node, constraints),
        .Render => buildRender(node, constraints),
        else => @compileError("expected an input, layout, or render node here."),
    };
}

fn buildInput(node: anytype, constraints: Constraints) !Build(@TypeOf(node)) {
    const Node = @TypeOf(node);
    const result = try build(node.config.child, constraints);
    return .{
        .state = .{
            .size = result.size,
            .opts = configOpts(Node.options, node.config),
            .child = result.state,
        },
        .render = result.render,
        .size = result.size,
    };
}

fn buildLayout(node: anytype, constraints: Constraints) !Build(@TypeOf(node)) {
    const Node = @TypeOf(node);
    const Slots = Node.slots;
    const Layout = Node.layout;
    const has_opts = std.meta.fields(Layout).len == 0;

    if (@TypeOf(Slots) == type or Slots == .Indexed) {
        const children = if (@TypeOf(Slots) == type)
            slottedChildren(Slots, node.config)
        else
            indexedChildren(node.config);

        const size = if (has_opts)
            try Layout.layout(configOpts(Layout, node.config), constraints, &children)
        else
            try Layout.layout(constraints, &children);

        const result = if (@TypeOf(Slots) == type)
            slotsResult(@TypeOf(node.config), children)
        else
            indexedResult(children);

        return .{
            .state = result.state,
            .render = result.render,
            .size = size,
        };
    }

    if (Slots == .SingleOptional) {
        const child = singleOptionalChild(node.config);
        const size = if (has_opts)
            try Layout.layout(configOpts(Layout, node.config), constraints, child)
        else
            try Layout.layout(constraints, child);

        return .{
            .state = if (child) |c| c.inner.state,
            .render = if (child) |c| c.inner.render,
            .size = size,
        };
    }

    if (Slots == .Single) {
        const child = singleChild(node.config);
        const size = if (has_opts)
            try Layout.layot(configOpts(Layout, node.config), constraints, &child)
        else
            try Layout.layout(constraints, &child);

        return .{
            .state = child.state,
            .render = child.render,
            .size = size,
        };
    }

    @compileError("");
}

fn singleChild(config: anytype) SingleChild(@TypeOf(config)) {
    const Config = @TypeOf(config);
    const field_name = singleChildFieldName(Config).?;
    return childLayout(@field(config, field_name));
}

fn SingleChild(comptime Config: type) type {
    if (singleChildFieldName(Config)) |field_name| {
        return ChildLayout(meta.FieldType(Config, field_name));
    }
    @compileError("");
}

fn singleOptionalChild(config: anytype) SingleOptionalChild(@TypeOf(config)) {
    const Config = @TypeOf(config);
    if (singleChildFieldName(Config)) |field_name| {
        const Child = meta.FieldType(Config, field_name);
        if (@typeInfo(Child) == .Optional) {
            if (@field(config, field_name)) |child| {
                return .{ .inner = childLayout(child) };
            }
        } else {
            return .{ .inner = childLayout(@field(config, field_name)) };
        }
    }
    return null;
}

fn SingleOptionalChild(comptime Config: type) type {
    if (singleChildFieldName(Config)) |field_name| {
        return ?struct {
            inner: *Inner,
            width: u16 = 0,
            height: u16 = 0,

            const Inner = ChildLayout(meta.FieldType(field_name));
            const Self = @This();

            pub fn info(self: *Self, id: anytype) ?Inner.Info {
                return self.inner.info(id);
            }

            pub fn layout(self: *Self, constraints: Constraints) !void {
                try self.inner.layout(constraints);
                self.width = self.inner.width;
                self.height = self.inner.height;
            }

            pub fn offset(self: *Self, by: Offset) void {
                self.inner.offset(by);
            }
        };
    }
    return ?void;
}

fn singleChildFieldName(comptime Config: type) ?[]const u8 {
    if (@hasField(Config, "child")) {
        return "child";
    }

    if (std.meta.trait.isTuple(Config) and std.meta.fields(Config).len == 1) {
        return "0";
    }

    return null;
}

fn slotsResult(comptime Config: type, children: anytype) SlotsResult(Config, @TypeOf(children)) {
    const Result = SlotsResult(Config, @TypeOf(children));
    const State = std.meta.FieldType(Result, .state);
    const Render = std.meta.FieldType(Result, .render);
    var state: State = undefined;
    var render: Render = undefined;

    const info = @typeInfo(@TypeOf(children));
    inline for (info.fields, 0..) |field, i| {
        if (@typeInfo(field.type) == ?void) {
            state[i] = undefined;
            render[i] = undefined;
        }

        if (@typeInfo(field.type) == .Optional) {
            if (@field(children, field.name)) |child| {
                state[i] = child.state;
                render[i] = child.render;
            } else {
                state[i] = null;
                render[i] = null;
            }
        } else {
            state[i] = @field(children, field.name).state;
            render[i] = @field(children, field.name).render;
        }
    }

    return Result{
        .state = state,
        .render = render,
    };
}

fn SlotsResult(comptime Config: type, comptime Children: type) type {
    const info = @typeInfo(Children);
    var state_types: [info.fields.len]type = undefined;
    var render_types: [info.fields.len]type = undefined;
    for (info.fields, 0..) |field, i| {
        if (field.type == ?void) {
            state_types[i] = void;
            render_types[i] = void;
            continue;
        }

        const Child = if (@typeInfo(field.type == .Optional))
            std.meta.Child(field.type)
        else
            field.type;

        const ConfigField = meta.FieldType(Config, field.name);
        state_types[i] = if (@typeInfo(ConfigField) == .Optional)
            ?Child.State
        else
            Child.State;

        render_types[i] = if (@typeInfo(ConfigField) == .Optional)
            ?Child.Render
        else
            Child.Render;
    }
    const State = meta.Tuple(state_types);
    const Render = meta.Tuple(render_types);
    return struct {
        state: State,
        render: Render,
    };
}

fn slottedChildren(comptime Slots: type, config: anytype) SlottedChildren(Slots, @TypeOf(config)) {
    const Config = @TypeOf(config);
    const Children = SlottedChildren(Slots, Config);
    var result: Children = undefined;

    const info = @typeInfo(Slots).Struct;
    inline for (info.fields) |field| {
        if (@hasField(Config, field.name)) {
            const ChildNode = meta.FieldType(Config, field.name);
            if (@typeInfo(ChildNode) == .Optional) {
                if (@field(config, field.name)) |child| {
                    @field(result, field.name) = childLayout(child);
                    continue;
                }
            } else {
                @field(result, field.name) = childLayout(@field(config, field.name));
                continue;
            }
        }
        @field(result, field.name) = null;
    }

    return result;
}

fn SlottedChildren(comptime Slots: type, comptime Config: type) type {
    const info = @typeInfo(Slots).Struct;
    var fields: [info.fields.len]std.builtin.Type.StructField = undefined;
    for (info.fields, 0..) |field, i| {
        const FieldType = if (@hasField(Config, field.name)) blk: {
            const FieldType = meta.FieldType(Config, field.name);
            if (@typeInfo(field.type) == .Optional) {
                if (@typeInfo(FieldType) == .Optional) {
                    break :blk ChildLayout(std.meta.Child(FieldType));
                }
                break :blk ?ChildLayout(FieldType);
            }

            if (@typeInfo(FieldType) == .Optional) {
                @compileError("");
            }

            break :blk ChildLayout(FieldType);
        } else if (@typeInfo(field.type) == .Optional)
            ?void
        else
            @compileError("");

        fields[i] = .{
            .name = field.name,
            .type = FieldType,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(FieldType),
        };
    }
    return @Type(.{
        .Struct = .{
            .layout = .Auto,
            .backing_integer = null,
            .fields = &fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = false,
        },
    });
}

fn indexedResult(children: anytype) IndexedResult(@TypeOf(children)) {
    const Result = IndexedResult(@TypeOf(children));
    const State = std.meta.FieldType(Result, .state);
    const Render = std.meta.FieldType(Result, .render);

    var state: State = undefined;
    var render: Render = undefined;
    inline for (children, 0..) |child, i| {
        state[i] = child.state;
        render[i] = child.render;
    }

    return Result{
        .state = state,
        .render = render,
    };
}

fn IndexedResult(comptime Children: type) type {
    const info = @typeInfo(Children);
    var state_types: [info.fields.len]type = undefined;
    var render_types: [info.fields.len]type = undefined;

    for (info.fields, 0..) |field, i| {
        const Child = field.type;
        state_types[i] = Child.State;
        render_types[i] = Child.Render;
    }

    const State = meta.Tuple(state_types);
    const Render = meta.Tuple(render_types);

    return struct {
        state: State,
        render: Render,
    };
}

fn indexedChildren(config: anytype) IndexedChildren(@TypeOf(config)) {
    const Config = @TypeOf(config);
    const Children = IndexedChildren(Config).Children;
    const children = blk: {
        if (@hasField(Config, "children")) {
            const ConfigChildren = std.meta.FieldType(Config, .children);
            if (!std.meta.trait.isTuple(ConfigChildren)) {
                @compileError("");
            }

            break :blk config.children;
        }

        if (!std.meta.trait.isTuple(Config)) {
            @compileError("");
        }
        break :blk config;
    };

    var result: Children = undefined;
    const info = @typeInfo(Children);
    inline for (info.fields) |field| {
        @field(result, field.name) = childLayout(@field(children, field.name));
    }

    return .{
        .children = children,
    };
}

fn IndexedChildren(comptime Config: type) type {
    return struct {
        comptime len: usize = children_len,
        children: Children,

        const children_len = @typeInfo(Children).Struct.fields.len;

        const Children = blk: {
            const ChildNodes = if (@hasField(Config, "children")) inner_blk: {
                const ConfigChildren = std.meta.FieldType(Config, .children);
                if (!std.meta.trait.isTuple(ConfigChildren)) {
                    @compileError("");
                }
                break :inner_blk ConfigChildren;
            } else if (std.meta.trait.isTuple(Config))
                Config
            else
                @compileError("");

            const info = @typeInfo(ChildNodes).Struct;
            var fields: [info.fields.len]std.builtin.Type.StructField = undefined;
            for (info.fields, 0..) |field, i| {
                const FieldType = ChildLayout(field.type);
                fields[i] = .{
                    .name = field.name,
                    .type = FieldType,
                    .default_value = null,
                    .is_comptime = false,
                    .alignment = @alignOf(FieldType),
                };
            }
            break :blk @Type(.{
                .Struct = .{
                    .layout = .Auto,
                    .backing_integer = null,
                    .fields = &fields,
                    .decls = &[_]std.builtin.Type.Declaration{},
                    .is_tuple = true,
                },
            });
        };
        const Iterator = IndexedIterator(Children);
        const Child = IndexedChild(Children);
        const Self = @This();

        pub fn get(self: *Self, at: usize) Child {
            if (at >= children_len) {
                @panic("index out of bounds");
            }
            return Child.init(&self.children, at);
        }

        pub fn iterator(self: *Self) Iterator {
            return .{
                .children = &self.children,
            };
        }
    };
}

fn IndexedIterator(comptime Children: type) type {
    return struct {
        children: *Children,
        idx: usize = 0,

        const Child = IndexedChild(Children);
        const Self = @This();

        pub fn next(self: *Self) ?Child {
            const children_len = @typeInfo(Children).Struct.fields.len;
            if (self.idx >= children_len) {
                return null;
            }

            const child = Child.init(self.children, self.idx);
            self.idx += 1;
            return child;
        }

        pub fn reset(self: *Self) void {
            self.idx = 0;
        }
    };
}

fn IndexedChild(comptime Children: type) type {
    return struct {
        ptr: Ptr,
        width: u16 = 0,
        height: u16 = 0,

        const Ptr = blk: {
            const children_info = @typeInfo(Children).Struct;
            var fields: [children_info.fields.len]std.builtin.Type.UnionField = undefined;
            for (info.fields.len, 0..) |field, i| {
                const ChildType = field.type;
                fields[i] = .{
                    .name = field.name,
                    .type = *ChildType,
                    .alignment = @alignOf(*ChildType),
                };
            }
            break :blk @Type(.{
                .Union = .{
                    .layout = .Auto,
                    .tag_type = meta.NumEnum(info.fields.len),
                    .fields = &fields,
                    .decls = &[_]std.builtin.Type.Declaration{},
                },
            });
        };
        const Info = blk: {
            const children_info = @typeInfo(Children).Struct;
            var result: ?type = null;
            for (children_info.fields) |field| {
                const InfoType = ChildInfo(field.type);
                if (InfoType == void)
                    continue;

                if (result) |T| {
                    if (InfoType != T) {
                        @compileError("");
                    }
                }

                result = InfoType;
            }
            break :blk result orelse void;
        };
        const Self = @This();

        fn ChildInfo(comptime Child: type) type {
            const fn_info = @typeInfo(@TypeOf(Child.info)).Fn;
            const return_type = fn_info.return_type.?;
            return std.meta.Child(return_type);
        }

        fn init(children: *Children, at: usize) Self {
            const Tag = std.meta.Tag(Ptr);
            const tag = @intToEnum(Tag, at);
            switch (tag) {
                inline else => |t| {
                    return Self{
                        .ptr = @unionInit(
                            Ptr,
                            @tagName(t),
                            &@field(children, @tagName(t)),
                        ),
                    };
                },
            }
        }

        pub fn info(self: *Self, id: anytype) ?Info {
            switch (self.ptr) {
                inline else => |child| {
                    const Child = std.meta.Child(@TypeOf(child));
                    const InfoType = ChildInfo(Child);
                    if (InfoType != void) {
                        return child.info(id);
                    }
                    return null;
                },
            }
        }

        pub fn layout(self: *Self, constraints: Constraints) !void {
            switch (self.ptr) {
                inline else => |child| {
                    try child.layout(constraints);
                    self.width = child.width;
                    self.height = child.height;
                },
            }
        }

        pub fn offset(self: *Self, by: Offset) void {
            switch (self.ptr) {
                inline else => |child| {
                    child.offset(by);
                },
            }
        }
    };
}

fn childLayout(node: anytype) ChildLayout(@TypeOf(node)) {
    return .{ .node = node };
}

fn ChildLayout(comptime Node: type) type {
    return struct {
        node: Node,
        state: State,
        render: Render,
        width: u16 = 0,
        height: u16 = 0,

        const State = StateTree(Node);
        const Render = RenderTree(Node);
        const Info = if (Node.kind == .Info)
            Node.options
        else
            void;
        const Self = @This();

        pub fn info(self: *Self, id: anytype) ?Info {
            if (Node.kind == .Info and Node.id == id) {
                return configOpts(Info, self.node);
            }
            return null;
        }

        pub fn layout(self: *Self, constraints: Constraints) !void {
            const result = if (Node.kind == .Info)
                try build(self.node.config.child, constraints)
            else
                try build(self.node, constraints);

            self.state = result.state;
            self.render = result.render;
            self.width = result.size.width;
            self.height = result.size.height;
        }

        pub fn offset(self: *Self, by: Offset) void {
            offsetTree(State, &self.state.?, by);
            offsetTree(Render, &self.render.?, by);
        }

        inline fn offsetTree(comptime T: type, t: *T, by: Offset) void {
            if (std.meta.trait.isTuple(T)) {
                inline for (t) |*node| {
                    node.offset(by);
                }
            } else {
                t.offset(by);
            }
        }
    };
}

fn buildRender(node: anytype, constraints: Constraints) Build(@TypeOf(node)) {
    const Node = @TypeOf(node);
    if (Node.id == .Text) {
        @compileError("todo!");
    } else {
        const result = try build(node.child, constraints);
        return .{
            .state = result.state,
            .render = .{
                .size = result.size,
                .opts = configOpts(Node.options, node.config),
                .child = result.render,
            },
            .size = result.size,
        };
    }
}

fn configOpts(comptime Opts: type, config: anytype) Opts {
    const Config = @TypeOf(config);
    const info = @typeInfo(Opts).Struct;
    var result: Opts = undefined;
    inline for (info.fields) |field| {
        if (@hasField(Config, field.name)) {
            @field(result, field.name) = @field(config, field.name);
        } else if (field.default_value) |default_value| {
            @field(result, field.name) = @ptrCast(*const field.type, default_value).*;
        } else {
            @compileError("");
        }
    }
    return result;
}

fn Build(comptime Node: type) type {
    return struct {
        state: StateTree(Node),
        render: RenderTree(Node),
        size: Size,
    };
}

fn StateTree(comptime Node: type) type {
    comptime {
        return switch (Node.kind) {
            .Input => StateTreeNode(Node),
            .Layout => LayoutTree(Node, StateTree),
            .Info => ChildTree(Node, StateTree),
            .Render => if (Node.id == .Text)
                void
            else
                ChildTree(Node, StateTree),
        };
    }
}

fn StateTreeNode(comptime Node: type) type {
    return struct {
        size: Size,
        offset: Offset = Offset.zero,
        opts: Node.options,
        child: Child,

        pub const Id = Node.id;
        const Child = ChildTree(Node, StateTree);
        const Self = @This();

        pub fn offset(self: *Self, by: Offset) void {
            self.offset.add(by);
            offsetChild(self.child, by);
        }
    };
}

fn RenderTree(comptime Node: type) type {
    comptime {
        return switch (Node.kind) {
            .Input => ChildTree(Node, RenderTree),
            .Layout => LayoutTree(Node, RenderTree),
            .Info => ChildTree(Node, RenderTree),
            .Render => RenderTreeNode(Node),
        };
    }
}

fn RenderTreeNode(comptime Node: type) type {
    return struct {
        size: Size,
        offset: Offset = Offset.zero,
        opts: Node.options,
        child: Child,

        pub const Id = Node.id;
        const Child = if (Node.id == .Text) void else ChildTree(Node, RenderTree);
        const Self = @This();

        pub fn offset(self: *Self, by: Offset) void {
            self.offset.add(by);
            offsetChild(self.child, by);
        }
    };
}

fn LayoutTree(comptime Node: type, comptime tree: TreeFn) type {
    comptime {
        return if (@TypeOf(Node.slots) == type)
            SlottedTree(Node, tree)
        else switch (Node.slots) {
            .Single => ChildTree(Node, tree),
            .SingleOptional => blk: {
                if (@hasField(Node.config, "child")) {
                    const Child = std.meta.FieldType(Node.config, .child);
                    if (@typeInfo(Child) == .Optional) {
                        break :blk ?tree(std.meta.Child(Child));
                    } else {
                        break :blk tree(Child);
                    }
                }
                break :blk void;
            },
            .Indexed => IndexedTree(Node, tree),
            else => @compileError(""),
        };
    }
}

fn SlottedTree(comptime Node: type, comptime tree: TreeFn) type {
    return ChildrenTree(blk: {
        const info = @typeInfo(Node.slots).Struct;
        var types: [info.fields.len]type = undefined;
        for (info.fields, 0..) |field, i| {
            if (@hasField(Node.config, field.name)) {
                const Child = meta.FieldType(Node.config, field.name);
                types[i] = if (@typeInfo(Child) == .Optional)
                    ?tree(std.meta.Child(Child))
                else
                    tree(Child);
            } else {
                types[i] = void;
            }
        }

        break :blk meta.Tuple(types);
    });
}

fn IndexedTree(comptime Node: type, comptime tree: fn (comptime Node: type) type) type {
    return ChildrenTree(blk: {
        const Children = if (@hasField(Node.config, "children"))
            std.meta.FieldType(Node.config, .children)
        else if (std.meta.trait.isTuple(Node.config))
            Node.config
        else
            @compileError("");

        const info = @typeInfo(Children);
        var types: [info.fields.len]type = undefined;
        for (info.fields, 0..) |field, i| {
            types[i] = tree(field.type);
        }

        break :blk meta.Tuple(types);
    });
}

fn ChildrenTree(comptime Children: type) type {
    return struct {
        children: Children,

        const Self = @This();

        pub fn offset(self: *Self, by: Offset) void {
            inline for (self.children) |child| {
                offsetChild(child, by);
            }
        }
    };
}

fn ChildTree(comptime Node: type, comptime tree: TreeFn) type {
    return tree(std.meta.FieldType(Node.config, .child));
}

const TreeFn = fn (comptime Node: type) type;

inline fn offsetChild(child: anytype, by: Offset) void {
    const Child = @TypeOf(child);
    if (Child == void) {
        return;
    }

    if (@typeInfo(Child) == .Optional) {
        if (child) |c| {
            c.offset(by);
        }
    } else {
        child.offset(by);
    }
}
