const std = @import("std");
const tok = @import("token.zig");

pub const Ast = struct {
    tokens: TokenList.Slice,
    nodes: NodeList.Slice,

    pub fn deinit(ast: *Ast, allocator: std.mem.Allocator) void {
        ast.tokens.deinit(allocator);
        ast.nodes.deinit(allocator);
        allocator.free(ast.data);
        ast.* = undefined;
    }
};

pub const Node = struct {
    tag: Tag,
    token: TokenIndex,
    head: NodeIndex,
    next: NodeIndex,

    pub const Tag = enum(u8) {
        root,
        decl,
        type,

        vis_pub,

        mut_const,
        mut_var,

        obj_exp,
        cmd_exp,
        node_exp,

        scheme,
        identifier,
    };
};

pub const TokenList = std.MultiArrayList(tok.Token);
pub const NodeList = std.MultiArrayList(Node);
pub const TokenIndex = tok.Token.SrcOffset;
pub const NodeIndex = u32;

pub const Result = union(enum) {
    Ast: Ast,
    Error: Error,
};

pub const Error = struct {
    expected: tok.Token.Tag,
    token: tok.Token,
};

const Parse = struct {
    allocator: std.mem.Allocator,
    tokens: TokenList,
    nodes: NodeList,
    err: ?Error,
};

const NodeChildren = struct {
    tail: NodeIndex = 0,

    fn init(nc: *NodeChildren, p: *Parse, parent: NodeIndex, child: NodeIndex) void {
        p.nodes.items(.head)[parent] = child;
        nc.tail = child;
    }

    fn append(nc: *NodeChildren, p: *Parse, child: NodeIndex) void {
        p.nodes.items(.next)[nc.tail] = child;
        nc.tail = child;
    }

    fn initOrAppend(nc: *NodeChildren, p: *Parse, parent: NodeIndex, child: NodeIndex) void {
        if (nc.tail == 0) {
            nc.init(p, parent, child);
        } else {
            nc.append(p, child);
        }
    }

    fn maybeInit(nc: *NodeChildren, p: *Parse, parent: NodeIndex, maybe_child: ?NodeIndex) void {
        const child = maybe_child orelse return;
        nc.init(p, parent, child);
    }

    fn maybeInitOrAppend(nc: *NodeChildren, p: *Parse, parent: NodeIndex, maybe_child: ?NodeIndex) void {
        const child = maybe_child orelse return;
        nc.initOrAppend(p, parent, child);
    }
};

pub fn parse(allocator: std.mem.Allocator, src: []const u8) !Result {
    var t = tok.Tokenizer.init(src);
    var p = Parse{
        .allocator = allocator,
        .tokens = TokenList{},
        .nodes = NodeList{},
    };

    const root_node = try append(&p, .root, tok.Token{
        .tag = .eof,
        .loc = tok.Token.Loc{ .start = 0, .end = 0 },
    });
    var root_children = NodeChildren{};

    while (t.hasNext()) {
        const member_node = parseRootMember(&p, &t) catch |e| {
            if (e == error.ParseError) {
                return Result{ .Error = p.err.? };
            }
        };
        root_children.initOrAppend(p, root_node, member_node);
    }

    return Result{ .Ast = Ast{
        .tokens = p.tokens.toOwnedSlice(),
        .nodes = p.nodes.toOwnedslice(),
        .data = try p.data.toOwnedSlice(allocator),
    } };
}

fn parseRootMember(p: *Parse, t: *tok.Tokenizer) !NodeIndex {
    const decl_node = try append(p, .decl, null);
    var decl_children = NodeChildren{};

    decl_children.maybeInit(p, decl_node, try maybeAppend(p, t, .kw_pub, .vis_pub));
    decl_children.initOrAppend(p, decl_node, try expectAppend(p, t, .identifier, .identifier));

    try expectDiscard(p, t, .colon);
    if (!peek(t, .colon)) {
        decl_children.initOrAppend(p, decl_node, try parseType(p, t));
    }

    decl_children.initOrAppend(p, decl_node, try expectAppend(p, t, .colon, .mut_const));
    decl_children.append(p, try parseExpression(p, t));

    return decl_node;
}

fn parseType(p: *Parse, t: *tok.Tokenizer) !NodeIndex {
    return try expectAppend(p, t, .identifier, .type);
}

fn parseExpression(p: *Parse, t: *tok.Tokenizer) !NodeIndex {
    const token = t.peek();
    switch (token.tag) {
        .kw_obj => return try parseObjExp(p, t),
        .kw_cmd => return try parseCmdExp(p, t),
        .kw_node => return try parseNodeExp(p, t),
    }
}

fn parseObjExp(p: *Parse, t: *tok.Tokenizer) !NodeIndex {
    const obj_node = try append(p, .obj_exp, t.next());
    var obj_children = NodeChildren{};
    obj_children.init(p, obj_node, try parseObjScheme(p, t));
    return obj_node;
}

fn parseObjScheme(p: *Parse, t: *tok.Tokenizer) !NodeIndex {
    try expectDiscard(p, t, .paren_left);

    const scheme_node = try append(p, .scheme, null);
    var scheme_children = NodeChildren{};

    var next: enum { ident, sep_or_close } = .ident;
    while (t.hasNext()) {
        switch (next) {
            .ident => {
                scheme_children.initOrAppend(p, scheme_node, try expectAppend(p, t, .identifier, .identifier));
                next = .sep;
            },
            .sep_or_close => {
                const token = t.next();
                switch (token.tag) {
                    .period => {
                        next = .ident;
                    },
                    .paren_right => {
                        break;
                    },
                    else => {
                        return err(p, Error{
                            .expected = .paren_right,
                            .token = token,
                        });
                    },
                }
            },
        }
    } else {
        return err(p, Error{
            .expected = if (next == .ident) .identifier else .paren_right,
            .token = t.peek(), // should return an .eof token
        });
    }

    return scheme_node;
}

fn parseStructField(p: *Parse, t: *tok.Tokenizer) void {
    _ = p;
    _ = t;
}

fn parseCmdExp(p: *Parse, t: *tok.Tokenizer) !NodeIndex {
    _ = p;
    _ = t;
}

fn parseNodeExp(p: *Parse, t: *tok.Tokenizer) !NodeIndex {
    _ = p;
    _ = t;
}

fn maybe(t: *tok.Tokenizer, tag: tok.Token.Tag) ?tok.Token {
    const token = t.peek();
    if (token.tag != tag) {
        return null;
    }
    t.move(token);
    return token;
}

fn maybeDiscard(t: *tok.Tokenizer, tag: tok.Token.Tag) bool {
    return maybe(t, tag) != null;
}

inline fn peek(t: tok.Tokenizer, tag: tok.Token.Tag) bool {
    return t.peek().tag == tag;
}

fn append(p: *Parse, tag: Node.Tag, token: ?tok.Token) !NodeIndex {
    var token_index: TokenIndex = 0;
    if (token) |t| {
        token_index = @intCast(try p.tokens.addOne(p.allocator));
        p.tokens.set(token_index, t);
    }

    const node_index: NodeIndex = @intCast(try p.nodes.addOne(p.allocator));
    p.nodes.set(node_index, Node{
        .tag = tag,
        .token = token_index,
        .child = 0,
        .sibling = 0,
    });

    return node_index;
}

fn maybeAppend(p: *Parse, t: *tok.Tokenizer, expected: tok.Token.Tag, tag: Node.Tag) !?NodeIndex {
    const token = maybe(t, expected) orelse return null;
    return try append(p, tag, token);
}

fn expect(p: *Parse, t: *tok.Tokenizer, tag: tok.Token.Tag) !tok.Token {
    const token = t.next();
    if (token.tag != tag) {
        return err(p, Error{
            .expected = tag,
            .token = token,
        });
    }
    return token;
}

fn expectDiscard(p: *Parse, t: *tok.Tokenizer, tag: tok.Token.Tag) !void {
    _ = try expect(p, t, tag);
}

fn expectAppend(p: *Parse, t: *tok.Tokenizer, expected: tok.Token.Tag, tag: Node.Tag) !NodeIndex {
    return try append(p, tag, try expect(p, t, expected));
}

fn err(p: *Parse, e: Error) anyerror {
    p.err = e;
    return error.ParseError;
}
