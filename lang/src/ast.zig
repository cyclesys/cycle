const std = @import("std");
const tok = @import("token.zig");

pub const NodeList = std.MultiArrayList(Node);
pub const NodeIndex = u32;
pub const Node = struct {
    tag: Tag,
    str: u32,
    head: NodeIndex,
    next: NodeIndex,

    pub const Tag = enum(u8) {
        root,

        decl,
        decl_vis_pub,
        decl_mut_const,
        decl_mut_var,

        type_ident,
        type_builtin,
        type_list,
        type_array,
        type_map,

        struct_exp,
        struct_field,

        enum_exp,
        enum_field,

        union_exp,
        union_tag,

        obj_exp,
        obj_scheme,

        cmd_exp,
        ui_exp,

        neg_exp,
        add_exp,
        sub_exp,
        div_exp,
        mul_exp,

        eql_exp,
        gt_exp,
        lt_exp,
        gte_exp,
        lte_exp,

        for_exp,
        if_exp,

        and_exp,
        or_exp,

        assign_exp,
        group_exp,

        struct_init,
        struct_field_init,

        field_access,
        array_access,

        num_binary,
        num_octal,
        num_decimal,
        num_hex,
        num_float,
        string,
        identifier,
        builtin,
        enum_literal,
    };

    pub fn str(s: u32, src: []const u8) []const u8 {
        const loc: tok.Loc = @bitCast(s);
        return src[loc.start..loc.end];
    }
};

pub const Result = union(enum) {
    Ast: NodeList.Slice,
    Error: Error,
};

pub const Error = struct {
    expected: [16]tok.Token.Tag, // .eof is the null terminator
    token: tok.Token,

    const max_expected = 15;
};

const Parse = struct {
    allocator: std.mem.Allocator,
    nodes: NodeList,
    err: ?Error,
};

const ParseError = error{
    OutOfMemory,
    UnexpectedToken,
};

pub fn parse(allocator: std.mem.Allocator, src: []const u8) !Result {
    var t = tok.Tokenizer.init(src);
    var p = Parse{
        .allocator = allocator,
        .nodes = NodeList{},
        .err = null,
    };

    parseRoot(&p, &t) catch |e| {
        p.nodes.deinit(allocator);
        if (e == error.UnexpectedToken) {
            return Result{ .Error = p.err.? };
        }
        return e;
    };

    return Result{ .Ast = p.nodes.toOwnedSlice() };
}

fn parseNoWrap(allocator: std.mem.Allocator, src: []const u8) !NodeList.Slice {
    var t = tok.Tokenizer.init(src);
    var p = Parse{
        .allocator = allocator,
        .nodes = NodeList{},
        .err = null,
    };
    errdefer {
        p.nodes.deinit(allocator);
    }
    try parseRoot(&p, &t);
    return p.nodes.toOwnedSlice();
}

fn parseRoot(p: *Parse, t: *tok.Tokenizer) ParseError!void {
    const node = try appendNode(p, .root, null);
    var tail: NodeIndex = 0;
    while (t.peek().tag != .eof) {
        tail = appendChild(p, node, tail, try parseExpression(p, t, false));
    }
}

fn parseExpression(p: *Parse, t: *tok.Tokenizer, unit_only: bool) ParseError!NodeIndex {
    var node: NodeIndex = 0;

    var token = t.peek();
    while (token.tag != .eof) : (token = t.peek()) {
        if (node == 0) {
            switch (token.tag) {
                .binary, .octal, .decimal, .hex, .float => {
                    t.move(token);
                    node = try appendNode(p, numTag(token.tag), token);
                },
                .identifier => {
                    token = t.peekNext(token);
                    if (token.tag == .colon) {
                        return try parseDecl(p, t);
                    } else {
                        node = try parseIdentExpression(p, t, .identifier);
                    }
                },
                .builtin => {
                    node = try parseIdentExpression(p, t, .builtin);
                },
                .string => {
                    t.move(token);
                    node = try appendNode(p, .string, token);
                },
                .minus => {
                    node = try parseUnaryOp(p, t, .neg_exp);
                },
                .paren_left => {
                    return try parseGroupExp(p, t);
                },
                .kw_pub => {
                    return try parseDecl(p, t);
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
                .kw_struct => {
                    return try parseStructExpression(p, t);
                },
                .kw_enum => {
                    return try parseEnumExpression(p, t);
                },
                .kw_union => {
                    return try parseUnionExpression(p, t);
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
                else => return err(p, token, .{
                    .identifier,
                    .minus,
                    .binary,
                    .octal,
                    .decimal,
                    .hex,
                    .float,
                    .period,
                    .kw_pub,
                    .kw_obj,
                    .kw_ui,
                    .kw_cmd,
                    .kw_for,
                    .kw_if,
                }),
            }

            if (unit_only) {
                return node;
            }
        } else switch (token.tag) {
            .plus => {
                node = try parseBinaryOp(p, t, .add_exp, node);
            },
            .minus => {
                node = try parseBinaryOp(p, t, .sub_exp, node);
            },
            .slash => {
                node = try parseBinaryOp(p, t, .div_exp, node);
            },
            .asterisk => {
                node = try parseBinaryOp(p, t, .mul_exp, node);
            },
            .kw_and => {
                node = try parseBinaryOp(p, t, .and_exp, node);
            },
            .kw_or => {
                node = try parseBinaryOp(p, t, .or_exp, node);
            },
            .equal => {
                return try parseAssignExpression(p, t, node);
            },
            .equal_equal => {
                node = try parseBinaryOp(p, t, .eql_exp, node);
            },
            .angled_greater => {
                node = try parseBinaryOp(p, t, .gt_exp, node);
            },
            .angled_lesser => {
                node = try parseBinaryOp(p, t, .lt_exp, node);
            },
            .greater_equal => {
                node = try parseBinaryOp(p, t, .gte_exp, node);
            },
            .lesser_equal => {
                node = try parseBinaryOp(p, t, .lte_exp, node);
            },
            else => {
                // expression ends
                break;
            },
        }
    }

    return node;
}

fn parseDecl(p: *Parse, t: *tok.Tokenizer) ParseError!NodeIndex {
    const node = try appendNode(p, .decl, null);

    var tail = appendChild(p, node, 0, try maybeAppend(p, t, .kw_pub, .decl_vis_pub));
    tail = appendChild(p, node, tail, try expectAppend(p, t, .identifier, .identifier));
    try expectDiscard(p, t, .colon);

    var mut = try parseDeclMut(p, t, false);
    if (mut == 0) {
        tail = appendChild(p, node, tail, try parseType(p, t));
        mut = try parseDeclMut(p, t, true);
    }
    tail = appendChild(p, node, tail, mut);
    _ = appendChild(p, node, tail, try parseExpression(p, t, false));

    return node;
}

fn parseDeclMut(p: *Parse, t: *tok.Tokenizer, expected: bool) ParseError!NodeIndex {
    const token = t.peek();
    switch (token.tag) {
        .colon => {
            t.move(token);
            return try appendNode(p, .decl_mut_const, token);
        },
        .equal => {
            t.move(token);
            return try appendNode(p, .decl_mut_var, token);
        },
        else => {
            if (expected) {
                return error.UnexpectedToken;
            }
            return 0;
        },
    }
}

fn parseType(p: *Parse, t: *tok.Tokenizer) ParseError!NodeIndex {
    const token = t.peek();
    switch (token.tag) {
        .bracket_left => {
            return parseBracketType(p, t);
        },
        .identifier => {
            return try parseIdentExpression(p, t, .type_ident);
        },
        .builtin => {
            return try parseIdentExpression(p, t, .type_builtin);
        },
        else => {
            return err(p, token, .{
                .bracket_left,
                .identifier,
                .builtin,
            });
        },
    }
}

fn parseBracketType(p: *Parse, t: *tok.Tokenizer) ParseError!NodeIndex {
    const node = try appendNode(p, .type_list, t.next());

    const token = t.peek();
    if (isNumber(token)) {
        t.move(token);
        const head = appendChild(p, node, 0, try appendNode(p, numTag(token.tag), token));
        try expectDiscard(p, t, .colon);
        _ = appendChild(p, node, head, try parseType(p, t));
        setTag(p, node, .type_array);
    } else {
        const head = appendChild(p, node, 0, try parseType(p, t));
        if (maybe(t, .colon) != null) {
            _ = appendChild(p, node, head, try parseType(p, t));
            setTag(p, node, .type_map);
        }
    }
    try expectDiscard(p, t, .bracket_right);

    return node;
}

fn isNumber(token: tok.Token) bool {
    return switch (token.tag) {
        .binary, .octal, .decimal, .hex, .float => true,
        else => false,
    };
}

fn numTag(tag: tok.Token.Tag) Node.Tag {
    return switch (tag) {
        .binary => .num_binary,
        .octal => .num_octal,
        .decimal => .num_decimal,
        .hex => .num_hex,
        .float => .num_float,
        else => unreachable,
    };
}

fn parseObjExpression(p: *Parse, t: *tok.Tokenizer) ParseError!NodeIndex {
    const node = try appendNode(p, .obj_exp, t.next());
    const tail = try parseObjScheme(p, t);
    setHead(p, node, tail);
    _ = try parseContainerBody(p, t, node, tail, parseStructField);
    return node;
}

fn parseObjScheme(p: *Parse, t: *tok.Tokenizer) ParseError!NodeIndex {
    const node = try expectAppend(p, t, .paren_left, .obj_scheme);
    var tail: NodeIndex = 0;

    var prev: enum { none, ident, sep } = .none;
    while (t.peek().tag != .eof) {
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

fn parseCmdExpression(p: *Parse, t: *tok.Tokenizer) ParseError!NodeIndex {
    const node = try appendNode(p, .cmd_exp, t.next());
    _ = try parseContainerBody(p, t, node, 0, parseStructField);
    return node;
}

fn parseUiExpression(p: *Parse, t: *tok.Tokenizer) ParseError!NodeIndex {
    const node = try appendNode(p, .ui_exp, t.next());
    const tail: NodeIndex = try parseContainerBody(p, t, node, 0, parseStructField);
    try expectDiscard(p, t, .arrow);
    _ = appendChild(p, node, tail, try parseExpression(p, t, false));
    return node;
}

fn parseStructExpression(p: *Parse, t: *tok.Tokenizer) ParseError!NodeIndex {
    const node = try appendNode(p, .struct_exp, t.next());
    _ = try parseContainerBody(p, t, node, 0, parseStructField);
    return node;
}

fn parseStructField(p: *Parse, t: *tok.Tokenizer) ParseError!NodeIndex {
    const node = try appendNode(p, .struct_field, null);
    const tail: NodeIndex = appendChild(p, node, 0, try expectAppend(p, t, .identifier, .identifier));
    try expectDiscard(p, t, .colon);
    _ = appendChild(p, node, tail, try parseType(p, t));

    return node;
}

fn parseEnumExpression(p: *Parse, t: *tok.Tokenizer) ParseError!NodeIndex {
    const node = try appendNode(p, .enum_exp, t.next());
    _ = try parseContainerBody(p, t, node, 0, parseEnumField);
    return node;
}

fn parseEnumField(p: *Parse, t: *tok.Tokenizer) ParseError!NodeIndex {
    const node = try appendNode(p, .enum_field, null);
    const head = try expectAppend(p, t, .identifier, .identifier);
    setHead(p, node, head);
    if (maybe(t, .equal) != null) {
        setNext(p, head, try parseExpression(p, t, false));
    }
    return node;
}

fn parseEnumLiteral(p: *Parse, t: *tok.Tokenizer) ParseError!NodeIndex {
    const node = try appendNode(p, .enum_literal, t.next());
    setHead(p, node, try expectAppend(p, t, .identifier, .identifier));
    return node;
}

fn parseUnionExpression(p: *Parse, t: *tok.Tokenizer) ParseError!NodeIndex {
    const node = try appendNode(p, .union_exp, t.next());
    const head = try parseUnionTag(p, t);
    setHead(p, node, head);
    _ = try parseContainerBody(p, t, node, head, parseStructField);
    return node;
}

fn parseUnionTag(p: *Parse, t: *tok.Tokenizer) ParseError!NodeIndex {
    if (maybe(t, .paren_left) == null) {
        return 0;
    }

    const token = t.next();
    const node = switch (token.tag) {
        .kw_enum, .identifier => try appendNode(p, .union_tag, token),
        else => {
            return err(p, token, .{ .kw_enum, .identifier });
        },
    };
    try expectDiscard(p, t, .paren_right);

    return node;
}

fn parseContainerBody(
    p: *Parse,
    t: *tok.Tokenizer,
    parent: NodeIndex,
    child: NodeIndex,
    parseFieldFn: fn (*Parse, *tok.Tokenizer) ParseError!NodeIndex,
) ParseError!NodeIndex {
    try expectDiscard(p, t, .brace_left);

    var missing_sep = false;
    var tail = child;
    while (t.peek().tag != .eof) {
        if (maybe(t, .brace_right) != null) {
            break;
        }

        if (missing_sep) {
            return err(p, t.peek(), .{ .comma, .brace_right });
        }

        tail = appendChild(p, parent, tail, try parseFieldFn(p, t));

        if (maybe(t, .comma) == null) {
            missing_sep = true;
        }
    } else {
        return err(p, t.peek(), .{.brace_right});
    }

    return tail;
}

fn parseStructInit(p: *Parse, t: *tok.Tokenizer, receiver: NodeIndex) ParseError!NodeIndex {
    const node = try appendNode(p, .struct_init, null);
    setHead(p, node, receiver);
    try expectDiscard(p, t, .brace_left);

    var missing_sep = false;
    var tail: NodeIndex = receiver;
    while (t.peek().tag != .eof) {
        if (maybe(t, .brace_right) != null) {
            break;
        }

        if (missing_sep) {
            return err(p, t.peek(), .{ .comma, .brace_right });
        }

        tail = appendChild(p, node, tail, try parseStructFieldInit(p, t));

        if (maybe(t, .comma) == null) {
            missing_sep = true;
        }
    } else {
        return err(p, t.peek(), .{.brace_right});
    }

    return node;
}

fn parseStructFieldInit(p: *Parse, t: *tok.Tokenizer) ParseError!NodeIndex {
    const node = try appendNode(p, .struct_field_init, null);

    const expect_value = maybe(t, .period) != null;
    const head = try expectAppend(p, t, .identifier, .identifier);
    setHead(p, node, head);
    if (expect_value) {
        try expectDiscard(p, t, .equal);
        setNext(p, head, try parseExpression(p, t, false));
    }

    return node;
}

fn parseUnaryOp(p: *Parse, t: *tok.Tokenizer, exp: Node.Tag) ParseError!NodeIndex {
    const node = try appendNode(p, exp, t.next());
    const operand = try parseExpression(p, t, true);
    setHead(p, node, operand);
    return node;
}

fn parseBinaryOp(p: *Parse, t: *tok.Tokenizer, exp: Node.Tag, left: NodeIndex) ParseError!NodeIndex {
    const node = try appendNode(p, exp, t.next());
    setHead(p, node, left);
    const right = try parseExpression(p, t, true);
    setNext(p, left, right);
    return node;
}

fn parseAssignExpression(p: *Parse, t: *tok.Tokenizer, left: NodeIndex) ParseError!NodeIndex {
    const node = try appendNode(p, .assign_exp, t.next());
    setHead(p, node, left);
    const right = try parseExpression(p, t, false);
    setNext(p, left, right);
    return node;
}

fn parseGroupExp(p: *Parse, t: *tok.Tokenizer) ParseError!NodeIndex {
    const node = try appendNode(p, .group_exp, t.next());
    const exp = try parseExpression(p, t, false);
    setHead(p, node, exp);
    try expectDiscard(p, t, .paren_right);
    return node;
}

fn parseIdentExpression(p: *Parse, t: *tok.Tokenizer, tag: Node.Tag) ParseError!NodeIndex {
    const node = try appendNode(p, tag, t.next());
    return try parseReceiverExpression(p, t, node);
}

fn parseForExpression(p: *Parse, t: *tok.Tokenizer) ParseError!NodeIndex {
    const node = try appendNode(p, .for_exp, t.next());
    const args = try parseExpression(p, t, false);
    try expectDiscard(p, t, .arrow);
    const exp = try parseExpression(p, t, false);
    setHead(p, node, args);
    setNext(p, args, exp);
    return node;
}

fn parseIfExpression(p: *Parse, t: *tok.Tokenizer) ParseError!NodeIndex {
    const node = try appendNode(p, .if_exp, t.next());
    const args = try parseExpression(p, t, false);
    setHead(p, node, args);
    try expectDiscard(p, t, .arrow);
    const exp = try parseExpression(p, t, false);
    setNext(p, args, exp);

    if (maybe(t, .kw_else) != null) {
        const else_exp = if (t.peek().tag == .kw_if)
            try parseIfExpression(p, t)
        else
            try parseExpression(p, t, false);
        setNext(p, exp, else_exp);
    }

    return node;
}

fn parseReceiverExpression(p: *Parse, t: *tok.Tokenizer, receiver: NodeIndex) ParseError!NodeIndex {
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

fn parseFieldAccess(p: *Parse, t: *tok.Tokenizer, left: NodeIndex) ParseError!NodeIndex {
    const node = try appendNode(p, .field_access, t.next());
    setHead(p, node, left);
    setNext(p, left, try expectAppend(p, t, .identifier, .identifier));
    return node;
}

fn parseArrayAccess(p: *Parse, t: *tok.Tokenizer, left: NodeIndex) ParseError!NodeIndex {
    const node = try appendNode(p, .array_access, t.next());
    setHead(p, node, left);
    const index = try parseExpression(p, t, false);
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

inline fn peek(t: *tok.Tokenizer, tag: tok.Token.Tag) bool {
    return t.peek().tag == tag;
}

fn expect(p: *Parse, t: *tok.Tokenizer, tag: tok.Token.Tag) ParseError!tok.Token {
    const token = t.next();
    if (token.tag != tag) {
        return err(p, token, .{tag});
    }
    return token;
}

fn expectDiscard(p: *Parse, t: *tok.Tokenizer, tag: tok.Token.Tag) ParseError!void {
    _ = try expect(p, t, tag);
}

fn expectAppend(p: *Parse, t: *tok.Tokenizer, expected: tok.Token.Tag, tag: Node.Tag) ParseError!NodeIndex {
    return try appendNode(p, tag, try expect(p, t, expected));
}

inline fn setTag(p: *Parse, node: NodeIndex, tag: Node.Tag) void {
    p.nodes.items(.tag)[node] = tag;
}

inline fn setHead(p: *Parse, parent: NodeIndex, child: NodeIndex) void {
    p.nodes.items(.head)[parent] = child;
}

inline fn setNext(p: *Parse, tail: NodeIndex, child: NodeIndex) void {
    p.nodes.items(.next)[tail] = child;
}

fn appendChild(p: *Parse, parent: NodeIndex, tail: NodeIndex, child: NodeIndex) NodeIndex {
    if (child == 0) {
        return tail;
    }

    if (tail == 0) {
        setHead(p, parent, child);
    } else {
        setNext(p, tail, child);
    }

    return child;
}

fn appendNode(p: *Parse, tag: Node.Tag, token: ?tok.Token) ParseError!NodeIndex {
    const str: u32 = if (token) |tn| @bitCast(tn.loc) else 0;
    const node_index: NodeIndex = @intCast(try p.nodes.addOne(p.allocator));
    p.nodes.set(node_index, Node{
        .tag = tag,
        .str = str,
        .head = 0,
        .next = 0,
    });
    return node_index;
}

fn maybeAppend(p: *Parse, t: *tok.Tokenizer, expected: tok.Token.Tag, tag: Node.Tag) ParseError!NodeIndex {
    const token = maybe(t, expected) orelse return 0;
    return try appendNode(p, tag, token);
}

fn err(p: *Parse, token: tok.Token, expected: anytype) ParseError {
    var e = Error{
        .expected = undefined,
        .token = token,
    };

    comptime var len = 0;
    inline for (expected) |tag| {
        e.expected[len] = tag;
        len += 1;
    }
    e.expected[len] = .eof;

    p.err = e;
    return error.UnexpectedToken;
}

test "arithmetic exp" {
    const src = "1000 + 0xABDF * 0b101 - -10.01 / 0o0102";
    try expectAst(src, &.{
        .{ .tag = .div_exp, .str = "/", .children = &.{
            .{ .tag = .sub_exp, .str = "-", .children = &.{
                .{ .tag = .mul_exp, .str = "*", .children = &.{
                    .{ .tag = .add_exp, .str = "+", .children = &.{
                        .{ .tag = .num_decimal, .str = "1000" },
                        .{ .tag = .num_hex, .str = "0xABDF" },
                    } },
                    .{ .tag = .num_binary, .str = "0b101" },
                } },
                .{ .tag = .neg_exp, .children = &.{
                    .{ .tag = .num_float, .str = "10.01" },
                } },
            } },
            .{ .tag = .num_octal, .str = "0o0102" },
        } },
    });
}

test "str add exp" {
    const src = "\"Hello\" + \" \" + \"world!\"";
    try expectAst(src, &.{
        .{ .tag = .add_exp, .children = &.{
            .{ .tag = .add_exp, .children = &.{
                .{ .tag = .string, .str = "\"Hello\"" },
                .{ .tag = .string, .str = "\" \"" },
            } },
            .{ .tag = .string, .str = "\"world!\"" },
        } },
    });
}

test "eql exp" {
    const src = "a == b ";
    try expectAst(src, &.{
        .{ .tag = .eql_exp, .str = "==", .children = &.{
            .{ .tag = .identifier, .str = "a" },
            .{ .tag = .identifier, .str = "b" },
        } },
    });
}

test "gt exp" {
    const src = "a > b";
    try expectAst(src, &.{
        .{ .tag = .gt_exp, .str = ">", .children = &.{
            .{ .tag = .identifier, .str = "a" },
            .{ .tag = .identifier, .str = "b" },
        } },
    });
}

test "lt exp" {
    const src = "a < b";
    try expectAst(src, &.{
        .{ .tag = .lt_exp, .str = "<", .children = &.{
            .{ .tag = .identifier, .str = "a" },
            .{ .tag = .identifier, .str = "b" },
        } },
    });
}

test "gte exp" {
    const src = "a >= b";
    try expectAst(src, &.{
        .{ .tag = .gte_exp, .str = ">=", .children = &.{
            .{ .tag = .identifier, .str = "a" },
            .{ .tag = .identifier, .str = "b" },
        } },
    });
}

test "lte exp" {
    const src = "a <= b";
    try expectAst(src, &.{
        .{ .tag = .lte_exp, .str = "<=", .children = &.{
            .{ .tag = .identifier, .str = "a" },
            .{ .tag = .identifier, .str = "b" },
        } },
    });
}

test "for exp" {
    const src = "for list => it + 1";
    try expectAst(src, &.{
        .{ .tag = .for_exp, .children = &.{
            .{ .tag = .identifier, .str = "list" },
            .{ .tag = .add_exp, .children = &.{
                .{ .tag = .identifier, .str = "it" },
                .{ .tag = .num_decimal, .str = "1" },
            } },
        } },
    });
}

test "if exp" {
    const src = "if condition => value else if other_condition => other_value else last_value";
    try expectAst(src, &.{
        .{ .tag = .if_exp, .children = &.{
            .{ .tag = .identifier, .str = "condition" },
            .{ .tag = .identifier, .str = "value" },
            .{ .tag = .if_exp, .children = &.{
                .{ .tag = .identifier, .str = "other_condition" },
                .{ .tag = .identifier, .str = "other_value" },
                .{ .tag = .identifier, .str = "last_value" },
            } },
        } },
    });
}

test "boolean exp" {
    const src = "some_bool and other_bool or last_bool";
    try expectAst(src, &.{
        .{ .tag = .or_exp, .children = &.{
            .{ .tag = .and_exp, .children = &.{
                .{ .tag = .identifier, .str = "some_bool" },
                .{ .tag = .identifier, .str = "other_bool" },
            } },
            .{ .tag = .identifier, .str = "last_bool" },
        } },
    });
}

test "assign exp" {
    const src = "a = b";
    try expectAst(src, &.{
        .{ .tag = .assign_exp, .str = "=", .children = &.{
            .{ .tag = .identifier, .str = "a" },
            .{ .tag = .identifier, .str = "b" },
        } },
    });
}

test "group exp" {
    const src = "(a + b + c)";
    try expectAst(src, &.{
        .{ .tag = .group_exp, .children = &.{
            .{ .tag = .add_exp, .children = &.{
                .{ .tag = .add_exp, .children = &.{
                    .{ .tag = .identifier, .str = "a" },
                    .{ .tag = .identifier, .str = "b" },
                } },
                .{ .tag = .identifier, .str = "c" },
            } },
        } },
    });
}

test "struct init" {
    const src = "@Struct{ .field = 0, .field = \"str\" }";
    try expectAst(src, &.{
        .{ .tag = .struct_init, .children = &.{
            .{ .tag = .builtin, .str = "@Struct" },
            .{ .tag = .struct_field_init, .children = &.{
                .{ .tag = .identifier, .str = "field" },
                .{ .tag = .num_decimal, .str = "0" },
            } },
            .{ .tag = .struct_field_init, .children = &.{
                .{ .tag = .identifier, .str = "field" },
                .{ .tag = .string, .str = "\"str\"" },
            } },
        } },
    });
}

test "field_access" {
    const src = "value.field.field";
    try expectAst(src, &.{
        .{ .tag = .field_access, .children = &.{
            .{ .tag = .field_access, .children = &.{
                .{ .tag = .identifier, .str = "value" },
                .{ .tag = .identifier, .str = "field" },
            } },
            .{ .tag = .identifier, .str = "field" },
        } },
    });
}

test "array access" {
    const src = "value[0][1]";
    try expectAst(src, &.{
        .{ .tag = .array_access, .children = &.{
            .{ .tag = .array_access, .children = &.{
                .{ .tag = .identifier, .str = "value" },
                .{ .tag = .num_decimal, .str = "0" },
            } },
            .{ .tag = .num_decimal, .str = "1" },
        } },
    });
}

test "enum literal" {
    const src = ".field";
    try expectAst(src, &.{
        .{ .tag = .enum_literal, .str = ".", .children = &.{
            .{ .tag = .identifier, .str = "field" },
        } },
    });
}

test "struct exp" {
    const src = "struct { field: bool, field: str, }";
    try expectAst(src, &.{
        .{ .tag = .struct_exp, .children = &.{
            .{ .tag = .struct_field, .children = &.{
                .{ .tag = .identifier, .str = "field" },
                .{ .tag = .type_ident, .str = "bool" },
            } },
            .{ .tag = .struct_field, .children = &.{
                .{ .tag = .identifier, .str = "field" },
                .{ .tag = .type_ident, .str = "str" },
            } },
        } },
    });
}

test "enum exp" {
    const src = "enum { field, field, }";
    try expectAst(src, &.{
        .{ .tag = .enum_exp, .children = &.{
            .{ .tag = .enum_field, .children = &.{
                .{ .tag = .identifier, .str = "field" },
            } },
            .{ .tag = .enum_field, .children = &.{
                .{ .tag = .identifier, .str = "field" },
            } },
        } },
    });
}

test "union exp" {
    const src = "union { field: str, field: void, }";
    try expectAst(src, &.{
        .{ .tag = .union_exp, .children = &.{
            .{ .tag = .struct_field, .children = &.{
                .{ .tag = .identifier, .str = "field" },
                .{ .tag = .type_ident, .str = "str" },
            } },
            .{ .tag = .struct_field, .children = &.{
                .{ .tag = .identifier, .str = "field" },
                .{ .tag = .type_ident, .str = "void" },
            } },
        } },
    });
}

test "obj exp" {
    const src =
        "obj(test.Object) {\n" ++
        "    field: str,\n" ++
        "}\n";
    try expectAst(src, &.{
        .{ .tag = .obj_exp, .children = &.{
            .{ .tag = .obj_scheme, .children = &.{
                .{ .tag = .identifier, .str = "test" },
                .{ .tag = .identifier, .str = "Object" },
            } },
        } },
    });
}

test "cmd exp" {
    const src =
        "cmd {\n" ++
        "    arg: Object,\n" ++
        "}\n";

    try expectAst(src, &.{
        .{ .tag = .cmd_exp, .children = &.{} },
    });
}

test "ui exp" {
    const src =
        "ui { ob: Object, child: @UiNode} =>\n" ++
        "    @Rect{" ++
        "        .color = 0xFFFFFFFF," ++
        "        .child = child," ++
        "    }\n";
    try expectAst(src, &.{
        .{ .tag = .ui_exp, .children = &.{
            .{ .tag = .struct_field, .children = &.{
                .{ .tag = .identifier, .str = "ob" },
                .{ .tag = .type_ident, .str = "Object" },
            } },
            .{ .tag = .struct_field, .children = &.{
                .{ .tag = .identifier, .str = "child" },
                .{ .tag = .type_builtin, .str = "@UiNode" },
            } },
            .{ .tag = .struct_init, .children = &.{
                .{ .tag = .builtin, .str = "@Rect" },
                .{ .tag = .struct_field_init, .children = &.{
                    .{ .tag = .identifier, .str = "color" },
                    .{ .tag = .num_hex, .str = "0xFFFFFFFF" },
                } },
                .{ .tag = .struct_field_init, .children = &.{
                    .{ .tag = .identifier, .str = "child" },
                    .{ .tag = .identifier, .str = "child" },
                } },
            } },
        } },
    });
}

test "const decl" {
    const src = "decl :: value";
    try expectAst(src, &.{
        .{ .tag = .decl, .children = &.{
            .{ .tag = .identifier, .str = "decl" },
            .{ .tag = .decl_mut_const },
            .{ .tag = .identifier, .str = "value" },
        } },
    });
}

test "pub const decl" {
    const src = "pub decl :: value";
    try expectAst(src, &.{
        .{ .tag = .decl, .children = &.{
            .{ .tag = .decl_vis_pub },
            .{ .tag = .identifier, .str = "decl" },
            .{ .tag = .decl_mut_const },
            .{ .tag = .identifier, .str = "value" },
        } },
    });
}

test "var decl" {
    const src = "decl := value";
    try expectAst(src, &.{
        .{ .tag = .decl, .children = &.{
            .{ .tag = .identifier, .str = "decl" },
            .{ .tag = .decl_mut_var },
            .{ .tag = .identifier, .str = "value" },
        } },
    });
}

test "pub var decl" {
    const src = "pub decl := value";
    try expectAst(src, &.{
        .{ .tag = .decl, .children = &.{
            .{ .tag = .decl_vis_pub },
            .{ .tag = .identifier, .str = "decl" },
            .{ .tag = .decl_mut_var },
            .{ .tag = .identifier, .str = "value" },
        } },
    });
}

test "decl ident type" {
    const src = "decl: Type : value";
    try expectAst(src, &.{
        .{ .tag = .decl, .children = &.{
            .{ .tag = .identifier, .str = "decl" },
            .{ .tag = .type_ident, .str = "Type" },
            .{ .tag = .decl_mut_const },
            .{ .tag = .identifier, .str = "value" },
        } },
    });
}

test "decl builtin type" {
    const src = "decl: @Builtin : value";
    try expectAst(src, &.{
        .{ .tag = .decl, .children = &.{
            .{ .tag = .identifier, .str = "decl" },
            .{ .tag = .type_builtin, .str = "@Builtin" },
            .{ .tag = .decl_mut_const },
            .{ .tag = .identifier, .str = "value" },
        } },
    });
}

test "decl list type" {
    const src = "decl: [Type] : value";
    try expectAst(src, &.{
        .{ .tag = .decl, .children = &.{
            .{ .tag = .identifier, .str = "decl" },
            .{ .tag = .type_list, .children = &.{
                .{ .tag = .type_ident, .str = "Type" },
            } },
            .{ .tag = .decl_mut_const },
            .{ .tag = .identifier, .str = "value" },
        } },
    });
}

test "decl array type" {
    const src = "decl: [10: Type] : value";
    try expectAst(src, &.{
        .{ .tag = .decl, .children = &.{
            .{ .tag = .identifier, .str = "decl" },
            .{ .tag = .type_array, .children = &.{
                .{ .tag = .num_decimal, .str = "10" },
                .{ .tag = .type_ident, .str = "Type" },
            } },
            .{ .tag = .decl_mut_const },
            .{ .tag = .identifier, .str = "value" },
        } },
    });
}

test "decl map type" {
    const src = "decl: [Key: Value] : value";
    try expectAst(src, &.{
        .{ .tag = .decl, .children = &.{
            .{ .tag = .identifier, .str = "decl" },
            .{ .tag = .type_map, .children = &.{
                .{ .tag = .type_ident, .str = "Key" },
                .{ .tag = .type_ident, .str = "Value" },
            } },
            .{ .tag = .decl_mut_const },
            .{ .tag = .identifier, .str = "value" },
        } },
    });
}

test "multiple decls" {
    const src =
        "decl_one :: value_one\n" ++
        "decl_two :: value_two";
    try expectAst(src, &.{
        .{ .tag = .decl, .children = &.{
            .{ .tag = .identifier, .str = "decl_one" },
            .{ .tag = .decl_mut_const },
            .{ .tag = .identifier, .str = "value_one" },
        } },
        .{ .tag = .decl, .children = &.{
            .{ .tag = .identifier, .str = "decl_two" },
            .{ .tag = .decl_mut_const },
            .{ .tag = .identifier, .str = "value_two" },
        } },
    });
}

test "multiple type decls" {
    const src =
        "pub Object :: obj(test.Scheme) {\n" ++
        "    field: str,\n" ++
        "}\n" ++
        "\n" ++
        "pub Command :: cmd {\n" ++
        "    object: Object,\n" ++
        "}\n";

    try expectAst(src, &.{
        .{ .tag = .decl, .children = &.{
            .{ .tag = .decl_vis_pub },
            .{ .tag = .identifier, .str = "Object" },
            .{ .tag = .decl_mut_const },
            .{ .tag = .obj_exp, .children = &.{
                .{ .tag = .obj_scheme, .children = &.{
                    .{ .tag = .identifier, .str = "test" },
                    .{ .tag = .identifier, .str = "Scheme" },
                } },
                .{ .tag = .struct_field, .children = &.{
                    .{ .tag = .identifier, .str = "field" },
                    .{ .tag = .type_ident, .str = "str" },
                } },
            } },
        } },
        .{ .tag = .decl, .children = &.{
            .{ .tag = .decl_vis_pub },
            .{ .tag = .identifier, .str = "Command" },
            .{ .tag = .decl_mut_const },
            .{ .tag = .cmd_exp, .children = &.{
                .{ .tag = .struct_field, .children = &.{
                    .{ .tag = .identifier, .str = "object" },
                    .{ .tag = .type_ident, .str = "Object" },
                } },
            } },
        } },
    });
}

const NodeExpect = struct {
    tag: Node.Tag,
    str: ?[]const u8 = null,
    children: ?[]const NodeExpect = null,
};

fn expectAst(src: []const u8, root_children: []const NodeExpect) !void {
    var nodes = try parseNoWrap(std.testing.allocator, src);
    defer nodes.deinit(std.testing.allocator);

    try expectNode(src, nodes, 0, NodeExpect{
        .tag = .root,
        .children = root_children,
    });
}

fn expectNode(src: []const u8, nodes: NodeList.Slice, index: NodeIndex, expected: NodeExpect) !void {
    const tag = nodes.items(.tag);
    const str = nodes.items(.str);
    const head = nodes.items(.head);
    const next = nodes.items(.next);

    try std.testing.expectEqual(expected.tag, tag[index]);
    if (expected.str) |expected_str| {
        const actual_str = Node.str(str[index], src);
        try std.testing.expectEqualStrings(expected_str, actual_str);
    }

    if (expected.children) |expected_children| {
        var tail = head[index];
        for (expected_children) |expected_child| {
            try expectNode(src, nodes, tail, expected_child);
            tail = next[tail];
        }
    }
}
