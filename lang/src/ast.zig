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

        identifier,
        number,

        vis_pub,
        mut_const,
        mut_var,

        type,

        obj_exp,
        obj_scheme,

        cmd_exp,
        ui_exp,
        for_exp,
        if_exp,

        and_exp,
        or_exp,

        struct_exp,
        struct_field,

        struct_init,
        struct_field_init,

        field_access,
        array_access,

        string,

        neg_exp,
        add_exp,
        sub_exp,
        div_exp,
        mul_exp,

        enum_literal,
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
    expected: [16]tok.Token.Tag, // .eof is the null terminator
    token: tok.Token,

    const max_expected = 15;
};

const Parse = struct {
    allocator: std.mem.Allocator,
    tokens: TokenList,
    nodes: NodeList,
    err: ?Error,
};

pub fn parse(allocator: std.mem.Allocator, src: []const u8) !Result {
    var t = tok.Tokenizer.init(src);
    var p = Parse{
        .allocator = allocator,
        .tokens = TokenList{},
        .nodes = NodeList{},
    };

    parseRoot(&p, &t) catch |e| {
        if (e == error.ParseError) {
            return Result{ .Error = p.err.? };
        }
    };

    return Result{ .Ast = Ast{
        .tokens = p.tokens.toOwnedSlice(),
        .nodes = p.nodes.toOwnedslice(),
        .data = try p.data.toOwnedSlice(allocator),
    } };
}

fn parseRoot(p: *Parse, t: *tok.Tokenizer) !void {
    const node = try appendNode(&p, .root, tok.Token{
        .tag = .eof,
        .loc = tok.Token.Loc{ .start = 0, .end = 0 },
    });
    var tail: NodeIndex = 0;

    while (t.hasNext()) {
        tail = appendChild(p, node, tail, try parseRootMember(p, t));
    }
}

fn parseRootMember(p: *Parse, t: *tok.Tokenizer) !NodeIndex {
    const node = try appendNode(p, .decl, null);

    var tail = appendChild(p, node, 0, try maybeAppend(p, t, .kw_pub, .vis_pub));
    tail = appendChild(p, node, tail, try expectAppend(p, t, .identifier, .identifier));
    try expectDiscard(p, t, .colon);
    if (!peek(t, .colon)) {
        tail = appendChild(p, node, tail, try parseType(p, t));
    }
    tail = appendChild(p, node, tail, try expectAppend(p, t, .colon, .mut_const));
    _ = appendChild(p, node, tail, try parseExpression(p, t));

    return node;
}

fn parseObjExpression(p: *Parse, t: *tok.Tokenizer) !NodeIndex {
    const node = try appendNode(p, .obj_exp, t.next());
    const tail = try parseObjScheme(p, t);
    setHead(p, node, tail);
    _ = try parseStructBody(p, t, node, tail);
    return node;
}

fn parseObjScheme(p: *Parse, t: *tok.Tokenizer) !NodeIndex {
    const node = try expectAppend(p, t, .paren_left, .obj_scheme);
    var tail: NodeIndex = 0;

    var prev: enum { none, ident, sep } = .none;
    while (t.hasNext()) {
        if (maybe(t, .paren_right)) |token| {
            if (prev == .sep) {
                return err(p, token, .{.identifier});
            }
            break;
        }

        switch (prev) {
            .none, .sep => {
                tail = appendChild(p, node, tail, try expectAppend(p, t, .identifier, .identifier));
                prev = .ident;
            },
            .ident => {
                const token = t.next();
                if (token.tag != .period) {
                    return err(p, token, .{ .period, .paren_right });
                }
                prev = .sep;
            },
        }
    } else {
        if (prev == .sep) {
            return err(p, t.peek(), .{.identifier});
        }
        return err(p, t.peek(), .{.paren_right});
    }

    return node;
}

fn parseCmdExpression(p: *Parse, t: *tok.Tokenizer) !NodeIndex {
    const node = try appendNode(p, .cmd_exp, t.next());
    _ = try parseStructBody(p, t, node, 0);
    return node;
}

fn parseUiExpression(p: *Parse, t: *tok.Tokenizer) !NodeIndex {
    const node = try appendNode(p, .ui_exp, t.next());
    const tail: NodeIndex = try parseStructBody(p, t, node, 0);
    try expectDiscard(p, t, .arrow);
    _ = appendChild(p, node, tail, try parseExpression(p, t));
    return node;
}

fn parseStructBody(p: *Parse, t: *tok.Tokenizer, parent: NodeIndex, tail: NodeIndex) !NodeIndex {
    try expectDiscard(p, t, .brace_left);

    while (t.hasNext()) {
        if (maybe(t, .brace_right) != null) {
            break;
        }
        tail = appendChild(p, parent, tail, try parseStructField(p, t));
    } else {
        return err(p, Error{
            .expected = .brace_right,
            .token = t.peek(), // should return an .eof token
        });
    }

    return tail;
}

fn parseStructField(p: *Parse, t: *tok.Tokenizer) !NodeIndex {
    const node = try appendNode(p, .struct_field, null);
    const tail: NodeIndex = appendChild(p, node, 0, try expectAppend(p, t, .identifier, .identifier));
    try expectDiscard(p, t, .colon);
    _ = appendChild(p, node, tail, try parseType(p, t));
    maybeDiscard(t, .comma);

    return node;
}

fn parseStructInit(p: *Parse, t: *tok.Tokenizer) !NodeIndex {
    const node = try expectAppend(p, t, .brace_left, .struct_init);
    var tail: NodeIndex = 0;

    while (t.hasNext()) {
        if (maybe(t, .brace_right) != null) {
            break;
        }
        if (tail != 0) {
            try expectDiscard(p, t, .comma);
        }
        tail = appendChild(p, node, tail, try parseStructFieldInit(p, t));
    } else {
        return err(p, t.peek(), .{.brace_right});
    }

    return node;
}

fn parseStructFieldInit(p: *Parse, t: *tok.Tokenizer) !NodeIndex {
    const node = try appendNode(p, .struct_field_init, null);

    const expect_value = maybe(t, .period) != null;
    const tail = setHead(p, node, try expectAppend(p, t, .identifier, .identifier));
    if (expect_value) {
        try expectDiscard(p, t, .equal);
        setNext(p, tail, try parseExpression(p, t));
    }

    return node;
}

fn parseType(p: *Parse, t: *tok.Tokenizer) !NodeIndex {
    return try expectAppend(p, t, .identifier, .type);
}

fn parseExpression(p: *Parse, t: *tok.Tokenizer) !NodeIndex {
    var node: NodeIndex = 0;

    var token = t.peek();
    while (t.hasNext()) : (token = t.peek()) {
        if (node == 0) switch (token.tag) {
            .minus => {
                node = parseUnaryOp(p, t, .neg_exp);
            },
            .binary, .octal, .decimal, .hex, .float => {
                t.move(token);
                node = try appendNode(p, .number, token);
            },
            .identifier, .builtin => {
                node = try parseIdentExpression(p, t);
            },
            .string => {
                node = try appendNode(p, .string, token);
            },
            .kw_for => {
                node = try parseForExpression(p, t);
            },
            .kw_if => {
                node = try parseIfExpression(p, t);
            },
            .period => {
                return try parseEnumLiteral(p, t);
            },
            .kw_obj => {
                return try parseObjExpression(p, t);
            },
            .kw_ui => {
                return try parseUiExpression(p, t);
            },
            .kw_cmd => {
                return try parseCmdExpression(p, t);
            },
            else => return err(p, token, .{
                .identifier,
                .minus,
                .binary,
                .octal,
                .decimal,
                .hex,
                .float,
                .period,
                .kw_obj,
                .kw_ui,
                .kw_cmd,
                .kw_for,
                .kw_if,
            }),
        } else switch (token.tag) {
            .plus => {
                node = parseBinaryOp(p, t, .add_exp, node);
            },
            .minus => {
                node = parseBinaryOp(p, t, .sub_exp, node);
            },
            .slash => {
                node = parseBinaryOp(p, t, .div_exp, node);
            },
            .asterisk => {
                node = parseBinaryOp(p, t, .mul_exp, node);
            },
            .kw_and => {
                node = parseBinaryOp(p, t, .and_exp, node);
            },
            .kw_or => {
                node = parseBinaryOp(p, t, .or_exp, node);
            },
            else => {
                // expression ends at `node`
            },
        }
    }

    return node;
}

fn parseUnaryOp(p: *Parse, t: *tok.Tokenizer, exp: Node.Tag) !NodeIndex {
    const node = try appendNode(p, exp, t.next());
    const operand = try parseExpression(p, t);
    setHead(p, node, operand);
    return node;
}

fn parseBinaryOp(p: *Parse, t: *tok.Tokenizer, exp: Node.Tag, left: NodeIndex) !NodeIndex {
    const node = try appendNode(p, exp, t.next());
    setHead(p, node, left);
    const right = try parseExpression(p, t);
    setNext(p, left, right);
    return node;
}

fn parseIdentExpression(p: *Parse, t: *tok.Tokenizer) !NodeIndex {
    const node = try appendNode(p, .identifier, t.next());
    return try parseReceiverExpression(p, t, node);
}

fn parseForExpression(p: *Parse, t: *tok.Tokenizer) !NodeIndex {
    const node = try appendNode(p, .for_exp, t.next());
    const args = try parseExpression(p, t);
    try expectDiscard(p, t, .arrow);
    const exp = try parseExpression(p, t);
    setHead(p, node, args);
    setNext(p, args, exp);
    return node;
}

fn parseIfExpression(p: *Parse, t: *tok.Tokenizer) !NodeIndex {
    const node = try appendNode(p, .if_exp, t.next());
    const args = try parseExpression(p, t);
    setHead(p, node, args);
    try expectDiscard(p, t, .arrow);
    const exp = try parseExpression(p, t);
    setNext(p, args, exp);

    if (maybe(t, .kw_else) != null) {
        const else_exp = if (t.peek().tag == .kw_if)
            try parseIfExpression(p, t)
        else
            try parseExpression(p, t);
        setNext(p, exp, else_exp);
    }

    return node;
}

fn parseEnumLiteral(p: *Parse, t: *tok.Tokenizer) !NodeIndex {
    const node = try appendNode(p, .enum_literal, t.next());
    setHead(p, node, try expectAppend(p, t, .identifier, .identifier));
    return node;
}

fn parseReceiverExpression(p: *Parse, t: *tok.Tokenizer, receiver: NodeIndex) !NodeIndex {
    var exp_node: NodeIndex = undefined;

    const token = t.peek();
    switch (token.tag) {
        .period => {
            exp_node = try parseFieldAccess(p, t, receiver);
        },
        .brace_left => {
            exp_node = try parseStructInit(p, t, receiver);
        },
        .bracket_left => {
            exp_node = try parseArrayAccess(p, t, receiver);
        },
        else => {
            return receiver;
        },
    }

    return try parseReceiverExpression(p, t, exp_node);
}

fn parseFieldAccess(p: *Parse, t: *tok.Tokenizer, left: NodeIndex) !NodeIndex {
    const node = try appendNode(p, .field_access, t.next());
    setHead(p, node, left);
    setNext(p, left, try expectAppend(p, t, .identifier, .identifier));
    return node;
}

fn parseArrayAccess(p: *Parse, t: *tok.Tokenizer, left: NodeIndex) !NodeIndex {
    const node = try appendNode(p, .array_access, t.next());
    setHead(p, node, left);
    const index = try parseExpression(p, t);
    setNext(p, left, index);
    try expectDiscard(p, t, .bracket_right);
    return node;
}

fn maybe(t: *tok.Tokenizer, tag: tok.Token.Tag) ?tok.Token {
    const token = t.peek();
    if (token.tag != tag) {
        return null;
    }
    t.move(token);
    return token;
}

fn maybeToEof(t: *tok.Tokenizer, tag: tok.Token.Tag) ?tok.Token {
    const token = t.peek();
    if (token.tag == .eof) {
        return token;
    }

    if (token.tag != tag) {
        return null;
    }
    t.move(token);
    return token;
}

fn maybeDiscard(t: *tok.Tokenizer, tag: tok.Token.Tag) void {
    _ = maybe(t, tag) != null;
}

inline fn peek(t: tok.Tokenizer, tag: tok.Token.Tag) bool {
    return t.peek().tag == tag;
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

fn expectAny(p: *Parse, t: *tok.Tokenizer, any: anytype) !tok.Token {
    const token = t.next();
    inline for (any) |tag| {
        if (token.tag == tag) {
            return token;
        }
    }
    return err(p, any, token);
}

fn expectDiscard(p: *Parse, t: *tok.Tokenizer, tag: tok.Token.Tag) !void {
    _ = try expect(p, t, tag);
}

fn expectAppend(p: *Parse, t: *tok.Tokenizer, expected: tok.Token.Tag, tag: Node.Tag) !NodeIndex {
    return try appendNode(p, tag, try expect(p, t, expected));
}

fn expectAppendAny(p: *Parse, t: *tok.Tokenizer, any: anytype) !NodeIndex {
    var expected: [any.len]tok.Token.Tag = undefined;
    const token = t.next();
    inline for (any, 0..) |pair, i| {
        if (token.tag == pair[0]) {
            return try appendNode(p, pair[1], token);
        }
        expected[i] = pair[0];
    }

    return err(p, expected, token);
}

inline fn setHead(p: *Parse, parent: NodeIndex, child: NodeIndex) void {
    p.nodes.items(.head)[parent] = child;
}

inline fn setNext(p: *Parse, tail: NodeIndex, child: NodeIndex) void {
    p.nodes.items(.next)[tail] = child;
}

fn appendChild(p: *Parse, parent: NodeIndex, tail: NodeIndex, maybe_child: ?NodeIndex) NodeIndex {
    const child = maybe_child orelse return tail;
    if (tail == 0) {
        setHead(p, parent, child);
    } else {
        setNext(p, tail, child);
    }
    return child;
}

fn appendNode(p: *Parse, tag: Node.Tag, token: ?tok.Token) !NodeIndex {
    const token_index = if (token) |t| try appendToken(p, t) else 0;
    const node_index: NodeIndex = @intCast(try p.nodes.addOne(p.allocator));
    p.nodes.set(node_index, Node{
        .tag = tag,
        .token = token_index,
        .child = 0,
        .sibling = 0,
    });
    return node_index;
}

fn appendToken(p: *Parse, token: tok.Token) !TokenIndex {
    const index: TokenIndex = @intCast(try p.tokens.addOne(p.allocator));
    p.tokens.set(index, token);
    return index;
}

fn maybeAppend(p: *Parse, t: *tok.Tokenizer, expected: tok.Token.Tag, tag: Node.Tag) !?NodeIndex {
    const token = maybe(t, expected) orelse return null;
    return try appendNode(p, tag, token);
}

fn err(p: *Parse, token: tok.Token, expected: anytype) anyerror {
    var e = Error{
        .expected = undefined,
        .token = token,
    };

    comptime var len = 0;
    inline for (expected) |tag| {
        e.expected[len] = tag;
        len += 1;
        if (len > Error.max_expected) {
            @compileError("err cannot expect more than 7 tokens");
        }
    }
    e.expected[len] = .eof;

    p.err = e;
    return error.ParseError;
}
