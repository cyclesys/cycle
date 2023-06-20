const std = @import("std");
const meta = @import("meta.zig");

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

const NodeKind = enum {
    Build,
    Input,
    Layout,
    Info,
    Render,
};

fn assertIsNode(comptime Type: type) void {
    if (!isNode(Type)) {
        @compileError("");
    }
}

fn isNode(comptime Type: type) bool {
    return @hasDecl(Type, "kind") and @TypeOf(Type.kind) == NodeKind;
}

pub fn BuildNode(comptime node_id: anytype, comptime ChildBuilder: type) type {
    return struct {
        opts: Builder,

        pub const kind = NodeKind.Build;
        pub const id = node_id;
        pub const Builder = ChildBuilder;
    };
}

pub fn InputNode(comptime node_id: anytype, comptime ChildNode: type, comptime InputListener: type) type {
    return struct {
        listener: Listener,
        child: Child,

        pub const kind = NodeKind.Input;
        pub const id = node_id;
        pub const Child = ChildNode;
        pub const Listener = InputListener;
    };
}

pub fn LayoutNode(comptime node_id: anytype, comptime ChildNodes: type, comptime ChildrenLayout: type) type {
    return struct {
        opts: Layout,
        child: Child,

        pub const kind = NodeKind.Layout;
        pub const id = node_id;
        pub const Child = ChildNodes;
        pub const Layout = ChildrenLayout;
    };
}

pub fn InfoNode(comptime node_id: anytype, comptime ChildNode: type, comptime ChildInfo: type) type {
    return struct {
        info: Info,
        child: Child,

        pub const kind = NodeKind.Info;
        pub const id = node_id;
        pub const Child = ChildNode;
        pub const Info = ChildInfo;
    };
}

pub fn RenderNode(comptime node_id: anytype, comptime ChildNode: type, comptime RenderInfo: type) type {
    return struct {
        info: Info,
        child: Child,

        pub const kind = NodeKind.Render;
        pub const id = node_id;
        pub const Child = ChildNode;
        pub const Info = RenderInfo;
    };
}

pub fn NodeType(comptime Type: type) type {
    assertIsNode(Type);
    return Type;
}

pub fn OptionalNodeType(comptime Type: type) type {
    const Node = if (@typeInfo((Type) == .Optional))
        std.meta.Child(Type)
    else
        Type;
    assertIsNode(Node);
    return ?Node;
}

pub fn ChildType(comptime Config: type) type {
    if (!@hasField(Config, "child")) {
        @compileError("");
    }
    const FieldType = std.meta.FieldType(Config, .child);
    assertIsNode(FieldType);
    return FieldType;
}

pub fn OptionalChildType(comptime Config: type) type {
    if (@hasField(Config, "child")) {
        const Type = std.meta.FieldType(Config, .child);
        if (@typeInfo(Type) == .Optional) {
            return ?NodeType(std.meta.Child(Type));
        }
        return NodeType(Type);
    }
    return void;
}

pub fn SlottedChildrenType(comptime Slots: type, comptime Config: type) type {
    const info = @typeInfo(Slots).Struct;
    var fields: [info.fields.len]std.builtin.Type.StructField = undefined;
    for (info.fields, 0..) |field, i| {
        const Type = if (@hasField(Config, field.name)) blk: {
            const ConfigType = meta.FieldType(Config, field.name);
            if (@typeInfo(ConfigType) == .Optional) {
                if (@typeInfo(field.type != .Optional)) {
                    @compileError("");
                }

                break :blk ?NodeType(std.meta.Child(ConfigType));
            }

            break :blk NodeType(ConfigType);
        } else if (@typeInfo(field.type) == .Optional)
            void
        else
            @compileError("");

        fields[i] = .{
            .name = field.name,
            .type = Type,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(Type),
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

pub fn IterableChildrenType(comptime Config: type) type {
    if (!@hasField(Config, "children")) {
        @compileError("");
    }

    const Children = std.meta.FieldType(Config, .children);
    const info = @typeInfo(Children).Struct;
    if (!info.is_tuple) {
        @compileError("");
    }

    for (info.fields) |field| {
        assertIsNode(field.type);
    }

    return Children;
}

pub fn ListenerType(comptime Config: type) type {
    return std.meta.FieldType(Config, .listener);
}

pub fn initNode(comptime Node: type, config: anytype) Node {
    switch (Node.kind) {
        .Build => {
            return Node{
                .opts = nodeOpts(Node.Opts, config),
            };
        },
        .Layout => {
            return Node{
                .opts = nodeOpts(Node.Opts, config),
                .child = blk: {
                    const Config = @TypeOf(config);
                    if (@hasField(Config, "child")) {
                        break :blk config.child;
                    }

                    if (@hasField(Config, "children")) {
                        break :blk config.children;
                    }
                },
            };
        },
        .Input => {
            return Node{
                .listener = config.listener,
                .child = config.child,
            };
        },
        .Info, .Render => {
            return Node{
                .info = nodeOpts(Node.Info, config),
                .child = if (Node.Child == void)
                    undefined
                else
                    config.child,
            };
        },
    }
}

fn nodeOpts(comptime Opts: type, config: anytype) Opts {
    const info = @typeInfo(Opts).Struct;
    if (info.fields.len == 0) {
        return .{};
    }

    const Config = @TypeOf(config);
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

pub fn SlottedLayoutChildren(comptime ChildNodes: type) type {
    const info = @typeInfo(ChildNodes);
    var fields: [info.fields.len]std.builtin.Type.StructField = undefined;
    for (fields, 0..) |field, i| {
        const FieldType = if (field.type == void)
            ?LayoutChild(void)
        else if (@typeInfo(field.type) == .Optional)
            ?LayoutChild(std.meta.Child(field.type))
        else
            LayoutChild(std.meta.Child(field.type));
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

pub fn IterableLayoutChildren(comptime ChildNodes: type, comptime Slot: type) type {
    return struct {
        comptime len: usize = children_len,
        children: *Children,

        const children_len = @typeInfo(ChildNodes).Struct.fields.len;
        pub const Iterator = struct {
            inner: *Inner,
            idx: usize = 0,

            const IteratorSelf = @This();

            pub fn next(self: *IteratorSelf) ?Child {
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
        pub const Children = [children_len]Child;
        pub const Child = struct {
            inner: *Inner,
            tag: Tag,
            slot: Slot = undefined,

            pub const Tag = meta.NumEnum(children_len);

            pub fn info(self: *Child, comptime Info: type) ?Info {
                switch (self.tag) {
                    inline else => |tag| {
                        return @field(self.inner, @tagName(tag)).info(Info);
                    },
                }
            }

            pub fn layout(self: *Child, constraints: Constraints) !Size {
                switch (self.tag) {
                    inline else => |tag| {
                        const size = try @field(self.inner, @tagName(tag)).layout(constraints);
                        if (Slot == Size) {
                            self.slot = size;
                        }
                    },
                }
            }

            pub fn offset(self: *Child, by: Offset) void {
                switch (self.tag) {
                    inline else => |tag| {
                        @field(self.inner, @tagName(tag)).offset(by);
                    },
                }
            }
        };
        pub const Inner = blk: {
            const info = @typeInfo(ChildNodes);
            var types: [info.fields.len]type = undefined;
            for (info.fields, 0..) |field, i| {
                types[i] = NodeLayout(field.type);
            }
            break :blk meta.Tuple(types);
        };
        const Self = @This();

        pub fn get(self: Self, at: usize) Child {
            if (at >= children_len) {
                @panic("index out of bounds");
            }
            return Child.init(&self.children, at);
        }

        pub fn iterator(self: Self) Iterator {
            return Iterator{
                .children = &self.children,
            };
        }
    };
}

pub fn LayoutChild(comptime Child: type) type {
    return struct {
        inner: *Inner,

        const Inner = blk: {
            if (Child == void) {
                break :blk void;
            }

            const Node = if (@typeInfo(Child) == .Optional)
                std.meta.Child(Child)
            else
                Child;

            break :blk NodeLayout(Node, void);
        };
        const Self = @This();

        pub fn info(self: Self, comptime Info: type) ?Info {
            if (Inner == void) {
                return null;
            }
            return self.inner.info(Info);
        }

        pub fn layout(self: Self, constraints: Constraints) !void {
            if (Inner != void) {
                try self.inner.layout(constraints);
                self.width = self.inner.width;
                self.height = self.inner.height;
            }
        }

        pub fn offset(self: Self, by: Offset) void {
            if (Inner != void) {
                self.inner.offset(by);
            }
        }
    };
}

fn NodeLayout(comptime Node: type) type {
    return struct {
        node: Node,
        input: Input = undefined,
        render: Render = undefined,

        const Input = InputTree(Node);
        const Render = RenderTree(Node);
        const Self = @This();

        pub fn info(self: *Self, comptime Info: type) ?Info {
            if (Node.kind == .Info and Node.Info == Info) {
                return self.node.info;
            }
            return null;
        }

        pub fn layout(self: *Self, constraints: Constraints) !Size {
            const result = if (Node.kind == .Info)
                try build(self.node.config.child, constraints)
            else
                try build(self.node, constraints);

            self.input = result.input;
            self.render = result.render;

            return result.size;
        }

        pub fn offset(self: *Self, by: Offset) void {
            offsetTree(Input, &self.input.?, by);
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

fn Build(comptime Node: type) type {
    return struct {
        input: InputTree(Node),
        render: RenderTree(Node),
        size: Size,
    };
}

fn InputTree(comptime Node: type) type {
    comptime {
        return switch (Node.kind) {
            .Input => InputTreeNode(Node),
            .Layout => LayoutTree(Node, InputTree),
            .Info, .Render => if (Node.Child == void)
                void
            else
                InputTree(Node.Child),
        };
    }
}

fn InputTreeNode(comptime Node: type) type {
    return struct {
        size: Size,
        offset: Offset = Offset.zero,
        opts: Node.options,
        child: Child,

        pub const Id = Node.id;
        const Child = InputTree(Node.Child);
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
            .Input => RenderTree(Node.Child),
            .Layout => LayoutTree(Node, RenderTree),
            .Info => RenderTree(Node.Child),
            .Render => RenderTreeNode(Node),
        };
    }
}

fn RenderTreeNode(comptime Node: type) type {
    return struct {
        size: Size,
        offset: Offset = Offset.zero,
        info: Node.Info,
        child: Child,

        pub const Id = Node.id;
        const Child = if (Node.Child == void) void else RenderTree(Node.Child);
        const Self = @This();

        pub fn offset(self: *Self, by: Offset) void {
            self.offset.add(by);
            offsetChild(self.child, by);
        }
    };
}

fn LayoutTree(comptime Node: type, comptime ChildTree: fn (comptime Node: type) type) type {
    const Child = Node.Child;
    if (@typeInfo(Child) == .Optional) {
        return ?ChildTree(std.meta.Child(Child));
    }

    if (isNode(Child)) {
        return ChildTree(Child);
    }

    return struct {
        children: Children,

        const Children = blk: {
            const info = @typeInfo(Child);
            var types: [info.fields.len]type = undefined;
            if (info.is_tuple) {
                for (info.fields, 0..) |field, i| {
                    types[i] = ChildTree(field.type);
                }
                break :blk meta.Tuple(types);
            }

            var len = 0;
            for (info.fields, 0..) |field, i| {
                if (field.type == void) {
                    continue;
                }

                types[i] = if (@typeInfo(field.type) == .Optional)
                    ?ChildTree(std.meta.Child(field.type))
                else
                    ChildTree(field.type);
                len += 1;
            }
            break :blk meta.Tuple(types[0..len]);
        };
        const Self = @This();

        pub fn offset(self: *Self, by: Offset) void {
            inline for (self.children) |child| {
                offsetChild(child, by);
            }
        }
    };
}

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
    const result = try build(node.config.child, constraints);
    return .{
        .input = .{
            .size = result.size,
            .listener = node.listener,
            .child = result.input,
        },
        .render = result.render,
        .size = result.size,
    };
}

fn buildLayout(node: anytype, constraints: Constraints) !Build(@TypeOf(node)) {
    const Node = @TypeOf(node);
    const Child = Node.Child;
    const Layout = Node.Layout;
    const has_opts = std.meta.fields(Node.Layout).len == 0;
    const params = @typeInfo(@TypeOf(Layout.layout)).Fn.params;
    const ChildParam = if (has_opts)
        params[2].type.?
    else
        params[1].type.?;

    const NodeInputTree = InputTree(Node);
    var input: NodeInputTree = undefined;

    const NodeRenderTree = RenderTree(Node);
    var render: NodeRenderTree = undefined;

    var size: Size = undefined;

    const info = @typeInfo(Child);
    if (info == .Optional or isNode(Child)) {
        const Inner = if (@typeInfo(ChildParam) == .Optional)
            std.meta.Child(ChildParam).Inner
        else
            ChildParam.Inner;

        if (@typeInfo(ChildParam) == .Optional and info == .Optional and node.child == null) {
            size = if (has_opts)
                try Layout.layout(node.opts, constraints, null)
            else
                try Layout.layout(constraints, null);

            input = null;
            render = null;
        } else {
            const child_node = if (info == .Optional)
                node.child.?
            else
                node.child;

            var inner = Inner{
                .node = child_node,
                .slot = undefined,
            };

            size = if (has_opts)
                try Layout.layout(node.opts, constraints, .{ .inner = &inner })
            else
                try Layout.layout(constraints, .{ .inner = &inner });

            input = inner.input;
            render = inner.render;
        }
    } else if (info.is_tuple) {
        var inner: ChildParam.Inner = undefined;
        inline for (info.fields) |field| {
            @field(inner, field.name) = .{
                .node = @field(node.child, field.name),
            };
        }

        var children: ChildParam.Children = undefined;
        inline for (0..info.fields.len) |i| {
            children[i] = .{
                .inner = &inner,
                .tag = @intToEnum(ChildParam.Child.Tag, i),
            };
        }

        size = if (has_opts)
            try Layout.layout(node.opts, constraints, ChildParam{ .children = &children })
        else
            try Layout.layout(constraints, ChildParam{ .children = &children });

        inline for (info.fields) |field| {
            @field(input.children, field.name) = @field(inner, field.name).input;
            @field(render.children, field.name) = @field(inner, field.name).render;
        }
    } else {
        const ChildrenInner = comptime blk: {
            var fields: [info.fields.len]std.builtin.Type.StructField = undefined;
            var len = 0;
            for (info.fields) |field| {
                if (field.type == void) {
                    continue;
                }

                const LayoutType = meta.FieldType(ChildParam, field.name);
                const InnerType = if (@typeInfo(LayoutType) == .Optional)
                    std.meta.Child(LayoutType).Inner
                else
                    LayoutType.Inner;

                fields[len] = .{
                    .name = field.name,
                    .type = InnerType,
                    .default_value = null,
                    .is_comptime = false,
                    .alignment = @alignOf(InnerType),
                };
                len += 1;
            }
            break :blk @Type(.{
                .Struct = .{
                    .layout = .Auto,
                    .backing_integer = null,
                    .fields = fields[0..len],
                    .decls = &[_]std.builtin.Type.Declaration{},
                    .is_tuple = false,
                },
            });
        };

        var inner: ChildrenInner = undefined;
        inline for (info.fields) |field| {
            if (field.type == void) {
                continue;
            }

            if (@typeInfo(field.type) == .Optional) {
                if (@field(node.child, field.name)) |child_node| {
                    @field(inner, field.name) = .{
                        .node = child_node,
                    };
                }
            } else {
                @field(inner, field.name) = .{
                    .node = @field(node.child, field.name),
                };
            }
        }

        var children: ChildParam = undefined;
        inline for (info.fields) |field| {
            if (field.type == void) {
                @field(children, field.name) = null;
            }

            if (@typeInfo(field.type) == .Optional) {
                if (@field(node.child, field.name) != null) {
                    @field(children, field.name) = .{ .inner = &@field(inner, field.name) };
                } else {
                    @field(children, field.name) = null;
                }
            } else {
                @field(children, field.name) = .{
                    .inner = &@field(inner, field.name),
                };
            }
        }

        size = if (has_opts)
            try Layout.layout(node.opts, constraints, children)
        else
            try Layout.layout(constraints, children);

        comptime var idx = 0;
        inline for (info.fields) |field| {
            if (field.type == void) {
                continue;
            }

            if (@typeInfo(field.type) == .Optional) {
                if (@field(inner, field.name)) |result| {
                    input.children[idx] = result.input;
                    render.children[idx] = result.render;
                }
            } else {
                input.children[idx] = @field(inner, field.name).input;
                render.children[idx] = @field(inner, field.name).render;
            }
            idx += 1;
        }
    }

    return .{
        .input = input,
        .render = render,
        .size = size,
    };
}

fn buildRender(node: anytype, constraints: Constraints) Build(@TypeOf(node)) {
    const Node = @TypeOf(node);
    if (Node.id == .Text) {
        @compileError("todo!");
    } else {
        const result = try build(node.child, constraints);
        return .{
            .input = result.input,
            .render = .{
                .size = result.size,
                .info = node.info,
                .child = result.render,
            },
            .size = result.size,
        };
    }
}

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
