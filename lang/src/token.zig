const std = @import("std");

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Tag = enum(u8) {
        // single char symbols
        plus,
        minus,
        slash,
        asterisk,
        period,
        comma,
        question_mark,
        equal,
        colon,
        semicolon,
        paren_left,
        paren_right,
        bracket_left,
        bracket_right,
        brace_left,
        brace_right,

        // multi char symbols
        equal_equal,
        not_equal,
        arrow,

        // number literals
        binary,
        octal,
        decimal,
        hex,
        float,

        // multi-char
        identifier,
        builtin,
        string,
        comment,
        doc_comment,

        // keywords
        kw_pub,
        kw_obj,
        kw_ui,
        kw_cmd,
        kw_for,
        kw_if,
        kw_else,
        kw_and,
        kw_or,

        eof,
        invalid,
    };

    pub const SrcOffset = u16;

    pub const Loc = packed struct(u32) {
        start: SrcOffset,
        end: SrcOffset,
    };

    pub inline fn str(t: Token, src: []const u8) []const u8 {
        return src[t.loc.start..t.loc.end];
    }
};

const keywords = std.ComptimeStringMap(Token.Tag, .{
    .{ "pub", .kw_pub },
    .{ "obj", .kw_obj },
    .{ "ui", .kw_ui },
    .{ "cmd", .kw_cmd },
    .{ "for", .kw_for },
    .{ "if", .kw_if },
    .{ "else", .kw_else },
    .{ "and", .kw_and },
    .{ "or", .kw_or },
});

pub const Tokenizer = struct {
    src: []const u8,
    pos: usize,

    pub fn init(src: []const u8) Tokenizer {
        return Tokenizer{
            .src = src,
            .pos = 0,
        };
    }

    pub fn hasNext(t: Tokenizer) bool {
        return t.pos < t.src.len;
    }

    pub fn move(t: *Tokenizer, token: Token) void {
        t.pos = token.loc.end;
    }

    pub fn next(t: *Tokenizer) Token {
        const token = t.peek();
        t.move(token);
        return token;
    }

    pub fn peekNext(t: *Tokenizer, curr: Token) Token {
        const pos = t.pos;
        t.pos = curr.loc.end;
        const token = t.peek();
        t.pos = pos;
        return token;
    }

    pub fn peek(t: Tokenizer) Token {
        if (!t.hasNext()) {
            return Token{
                .loc = Token.Loc{
                    .start = @intCast(t.pos),
                    .end = @intCast(t.pos),
                },
                .tag = .eof,
            };
        }

        var pos: usize = t.pos;
        var prev: u8 = undefined;

        var start = pos;
        var end: ?usize = null;
        var tag: Token.Tag = .eof;

        var state: enum {
            start,
            exclamation,
            equal,
            zero,
            binary,
            octal,
            decimal,
            hex,
            float,
            at_sign,
            identifier,
            string,
            string_escape,
            slash,
            comment_start,
            doc_comment_start,
            comment_body,
            comment_new_line,
        } = .start;
        var first_comment_line = true;

        var c: u8 = undefined;
        while (pos < t.src.len) : (pos += 1) {
            prev = c;
            c = t.src[pos];
            switch (state) {
                .start => switch (c) {
                    '+' => {
                        tag = .plus;
                        pos += 1;
                        break;
                    },
                    '-' => {
                        tag = .minus;
                        pos += 1;
                        break;
                    },
                    '*' => {
                        tag = .asterisk;
                        pos += 1;
                        break;
                    },
                    '.' => {
                        tag = .period;
                        pos += 1;
                        break;
                    },
                    ',' => {
                        tag = .comma;
                        pos += 1;
                        break;
                    },
                    '?' => {
                        tag = .question_mark;
                        pos += 1;
                        break;
                    },
                    '!' => {
                        // exclamation is invalid unless it's followed by an equal sign
                        tag = .invalid;
                        state = .exclamation;
                    },
                    '=' => {
                        tag = .equal;
                        state = .equal;
                    },
                    ':' => {
                        tag = .colon;
                        pos += 1;
                        break;
                    },
                    ';' => {
                        tag = .semicolon;
                        pos += 1;
                        break;
                    },
                    '(' => {
                        tag = .paren_left;
                        pos += 1;
                        break;
                    },
                    ')' => {
                        tag = .paren_right;
                        pos += 1;
                        break;
                    },
                    '[' => {
                        tag = .bracket_left;
                        pos += 1;
                        break;
                    },
                    ']' => {
                        tag = .bracket_right;
                        pos += 1;
                        break;
                    },
                    '{' => {
                        tag = .brace_left;
                        pos += 1;
                        break;
                    },
                    '}' => {
                        tag = .brace_right;
                        pos += 1;
                        break;
                    },
                    '0' => {
                        tag = .decimal;
                        state = .zero;
                    },
                    '1'...'9' => {
                        tag = .decimal;
                        state = .decimal;
                    },
                    'a'...'z', 'A'...'Z', '_' => {
                        tag = .identifier;
                        state = .identifier;
                    },
                    '@' => {
                        // this char is invalid unless it's followed by alpha characters, in which case
                        // it becomes part of a builtin
                        tag = .invalid;
                        state = .at_sign;
                    },
                    '"' => {
                        tag = .string;
                        state = .string;
                    },
                    '/' => {
                        tag = .slash;
                        state = .slash;
                    },
                    ' ', '\n' => {
                        // whitespace is ignored
                        start += 1;
                        continue;
                    },
                    else => {
                        // anything else is invalid
                        tag = .invalid;
                        pos += 1;
                        break;
                    },
                },
                .slash => switch (c) {
                    '/' => {
                        if (tag == .slash) {
                            tag = .comment;
                        }
                        state = .comment_start;
                    },
                    else => break,
                },
                .equal => switch (c) {
                    '=' => {
                        tag = .equal_equal;
                        pos += 1;
                        break;
                    },
                    '>' => {
                        tag = .arrow;
                        pos += 1;
                        break;
                    },
                    else => break,
                },
                .exclamation => {
                    if (c == '=') {
                        tag = .not_equal;
                        pos += 1;
                    }
                    break;
                },
                .zero => switch (c) {
                    '0'...'9', '_' => {
                        state = .decimal;
                    },
                    'B', 'O', 'X' => {
                        // Base characters should be lower-case.
                        // The invalid base character is included as part of the token.
                        pos += 1;
                        break;
                    },
                    'b' => {
                        tag = .binary;
                        state = .binary;
                    },
                    'o' => {
                        tag = .octal;
                        state = .octal;
                    },
                    'x' => {
                        tag = .hex;
                        state = .hex;
                    },
                    '.' => {
                        tag = .float;
                        state = .float;
                    },
                    'A', 'C'...'F', 'a', 'c'...'f' => {
                        // A to F can only be used in hexadecimal literals
                        tag = .invalid;
                        pos += 1;
                        break;
                    },
                    else => break,
                },
                .binary => switch (c) {
                    '0', '1' => continue,
                    '2'...'9', 'a'...'f', 'A'...'F', '.' => {
                        // invalid digits or float base
                        tag = .invalid;
                        pos += 1;
                        break;
                    },
                    '_' => switch (prev) {
                        '_', 'b' => {
                            // repeat separator or no digit before qualifier and separator
                            tag = .invalid;
                            pos += 1;
                            break;
                        },
                        else => continue,
                    },
                    else => {
                        switch (prev) {
                            '_', 'b' => {
                                // binary cannot end on a separator or the qualifier
                                tag = .invalid;
                            },
                            else => {},
                        }
                        break;
                    },
                },
                .octal => switch (c) {
                    '0'...'7' => continue,
                    '8'...'9', 'a'...'f', 'A'...'F', '.' => {
                        // invalid digit or float base
                        tag = .invalid;
                        pos += 1;
                        break;
                    },
                    '_' => switch (prev) {
                        '_', 'o' => {
                            // repeat separator or no digit before qualifier and separator
                            tag = .invalid;
                            pos += 1;
                            break;
                        },
                        else => continue,
                    },
                    else => {
                        switch (prev) {
                            '_', 'o' => {
                                // octal cannot end on a separator or the qualifier
                                tag = .invalid;
                            },
                            else => {},
                        }
                        break;
                    },
                },
                .decimal => switch (c) {
                    '0'...'9' => continue,
                    'A'...'F', 'a'...'f' => {
                        // invalid digits
                        tag = .invalid;
                        pos += 1;
                        break;
                    },
                    '_' => switch (prev) {
                        '_' => {
                            // repeat separator
                            tag = .invalid;
                            pos += 1;
                            break;
                        },
                        else => continue,
                    },
                    '.' => {
                        tag = .float;
                        state = .float;
                    },
                    else => {
                        if (prev == '_') {
                            // decimal cannot end on a separator
                            tag = .invalid;
                        }
                        break;
                    },
                },
                .hex => switch (c) {
                    '0'...'9', 'A'...'F' => continue,
                    'a'...'f', '.' => {
                        // invalid digit case or float base
                        tag = .invalid;
                        pos += 1;
                        break;
                    },
                    '_' => switch (prev) {
                        '_', 'x' => {
                            // repeat separator or no digit before qualifier and separator
                            tag = .invalid;
                            pos += 1;
                            break;
                        },
                        else => continue,
                    },
                    else => {
                        switch (prev) {
                            '_', 'x' => {
                                // hex cannot end on a separator or the qualifier
                                tag = .invalid;
                            },
                            else => {},
                        }
                        break;
                    },
                },
                .float => switch (c) {
                    '0'...'9' => continue,
                    '.', 'a'...'f', 'A'...'F' => {
                        // repeat decimal point or non-decimal digit
                        tag = .invalid;
                        pos += 1;
                        break;
                    },
                    '_' => switch (prev) {
                        '_', '.' => {
                            // repeat separator or no digit before qualifier and separator
                            tag = .invalid;
                            pos += 1;
                            break;
                        },
                        else => continue,
                    },
                    else => {
                        switch (prev) {
                            '_', '.' => {
                                // float cannot end on a separator or the decimal point
                                tag = .invalid;
                            },
                            else => {},
                        }
                        break;
                    },
                },
                .at_sign => switch (c) {
                    'a'...'z', 'A'...'Z' => {
                        tag = .builtin;
                        state = .identifier;
                    },
                    else => break,
                },
                .identifier => switch (c) {
                    'a'...'z', 'A'...'Z', '0'...'9', '_' => continue,
                    else => {
                        if (keywords.get(t.src[start..pos])) |kw| {
                            tag = kw;
                        }
                        break;
                    },
                },
                .string => switch (c) {
                    '"' => {
                        pos += 1;
                        break;
                    },
                    '\n' => {
                        // strings must be on one line
                        tag = .invalid;
                        pos += 1;
                        break;
                    },
                    '\\' => {
                        state = .string_escape;
                    },
                    else => continue,
                },
                .string_escape => {
                    state = .string;
                },
                .comment_start => switch (c) {
                    '/' => {
                        if (!first_comment_line and tag == .comment) {
                            // comments and doc comments are separate tokens
                            break;
                        }
                        tag = .doc_comment;
                        state = .doc_comment_start;
                    },
                    ' ' => {
                        if (!first_comment_line and tag == .doc_comment) {
                            // comments and doc comments are separate tokens
                            break;
                        }
                        state = .comment_body;
                    },
                    else => {
                        // comments must contain a space between the slashes and body
                        tag = .invalid;
                        pos += 1;
                        break;
                    },
                },
                .doc_comment_start => switch (c) {
                    ' ' => {
                        state = .comment_body;
                    },
                    else => {
                        // comments must contain a space between the slashes and body
                        tag = .invalid;
                        pos += 1;
                        break;
                    },
                },
                .comment_body => switch (c) {
                    '\n' => {
                        end = pos;
                        state = .comment_new_line;
                        first_comment_line = false;
                    },
                    else => continue,
                },
                .comment_new_line => switch (c) {
                    ' ' => continue,
                    '/' => {
                        state = .slash;
                    },
                    else => break,
                },
            }
        } else {
            switch (state) {
                .binary => switch (prev) {
                    'b', '_' => {
                        // can't end with qualifier or separator
                        tag = .invalid;
                    },
                    else => {},
                },
                .octal => switch (prev) {
                    'o', '_' => {
                        // can't end with qualifier or separator
                        tag = .invalid;
                    },
                    else => {},
                },
                .decimal => switch (prev) {
                    '_' => {
                        // can't end with separator
                        tag = .invalid;
                    },
                    else => {},
                },
                .hex => switch (prev) {
                    'x', '_' => {
                        // can't end with qualifier or separator
                        tag = .invalid;
                    },
                    else => {},
                },
                .float => switch (prev) {
                    '.', '_' => {
                        // can't end with decimal point or separator
                        tag = .invalid;
                    },
                    else => {},
                },
                .identifier => {
                    if (keywords.get(t.src[start..pos])) |kw| {
                        tag = kw;
                    }
                },
                .string => {
                    // unterminated string
                    tag = .invalid;
                },
                .comment_body => {
                    end = null;
                },
                else => {},
            }
        }

        return Token{
            .tag = tag,
            .loc = Token.Loc{
                .start = @intCast(start),
                .end = @intCast(end orelse pos),
            },
        };
    }
};

test "symbols" {
    try expectTokenTags("+-/*.,?:;()[]{}", &.{
        .plus,
        .minus,
        .slash,
        .asterisk,
        .period,
        .comma,
        .question_mark,
        .colon,
        .semicolon,
        .paren_left,
        .paren_right,
        .bracket_left,
        .bracket_right,
        .brace_left,
        .brace_right,
    });
}

test "multi symbols" {
    try expectTokenTags(" == != => ", &.{ .equal_equal, .not_equal, .arrow });
}

test "incomplete symbols" {
    try expectTokenTags(" ! @ ", &.{ .invalid, .invalid });
}

test "zero" {
    try expectTokenTags(" 0 ", &.{.decimal});
}

test "binary" {
    try expectTokenTags(" 0b0_1 ", &.{.binary});
}

test "binary no digits" {
    try expectTokenTags(" 0b ", &.{.invalid});
}

test "binary start with separator" {
    try expectTokenTags(" 0b_01 ", &.{ .invalid, .decimal });
}

test "binary repeat separator" {
    try expectTokenTags(" 0b0__1 ", &.{ .invalid, .decimal });
}

test "binary end with separator" {
    try expectTokenTags(" 0b0_ ", &.{.invalid});
}

test "binary invalid digits" {
    try expectInvalidDigits(" 0b", "23456789ABCDEF");
}

test "binary float" {
    try expectInvalidFloatBase(" 0b0");
}

test "octal" {
    try expectTokenTags(" 0o0123_4567 ", &.{.octal});
}

test "octal no digits" {
    try expectTokenTags(" 0o ", &.{.invalid});
}

test "octal start with separator" {
    try expectTokenTags(" 0o_ ", &.{.invalid});
}

test "octal repeat separator" {
    try expectTokenTags(" 0o0123__4567 ", &.{ .invalid, .decimal });
}

test "octal end with separator" {
    try expectTokenTags(" 0o01234_ ", &.{.invalid});
}

test "octal invalid digits" {
    try expectInvalidDigits(" 0o", "89ABCDEF");
}

test "octal float" {
    try expectInvalidFloatBase(" 0o0");
}

test "decimal" {
    try expectTokenTags(" 1234567890 ", &.{.decimal});
}

test "decimal repeat separator" {
    try expectTokenTags(" 123__0 ", &.{ .invalid, .decimal });
}

test "decimal end with separator" {
    try expectTokenTags(" 123_ ", &.{.invalid});
}

test "decimal invalid digits" {
    try expectInvalidDigits(" 123", "ABCDEF");
}

test "hex" {
    try expectTokenTags(" 0x0123456789ABCDEF ", &.{.hex});
}

test "hex no digits" {
    try expectTokenTags(" 0x ", &.{.invalid});
}

test "hex start with separator" {
    try expectTokenTags(" 0x_0 ", &.{ .invalid, .decimal });
}

test "hex repeat separator" {
    try expectTokenTags(" 0x0__9 ", &.{ .invalid, .decimal });
}

test "hex end with separator" {
    try expectTokenTags(" 0x0F_ ", &.{.invalid});
}

test "hex lowercase" {
    try expectTokenTags(" 0xa ", &.{.invalid});
    try expectTokenTags(" 0xb ", &.{.invalid});
    try expectTokenTags(" 0xc ", &.{.invalid});
    try expectTokenTags(" 0xd ", &.{.invalid});
    try expectTokenTags(" 0xe ", &.{.invalid});
    try expectTokenTags(" 0xf ", &.{.invalid});
}

test "hex float" {
    try expectInvalidFloatBase(" 0xA");
}

test "float" {
    try expectTokenTags("0123456789.0123456789", &.{.float});
}

test "float end with decimal point" {
    try expectTokenTags(" 0. ", &.{.invalid});
}

test "float start with separator" {
    try expectTokenTags(" 0._1 ", &.{ .invalid, .decimal });
}

test "float end with separator" {
    try expectTokenTags(" 0.1_ ", &.{.invalid});
}

test "float invalid digits" {
    try expectInvalidDigits(" 0.", "ABCDEF");
}

test "identifier" {
    for ('A'..'Z') |c| {
        try expectTokenTags(&[_]u8{@intCast(c)}, &.{.identifier});
    }
    for ('a'..'z') |c| {
        try expectTokenTags(&[_]u8{@intCast(c)}, &.{.identifier});
    }
    try expectTokenTags("_", &.{.identifier});
}

test "builtin" {
    for ('A'..'Z') |c| {
        try expectTokenTags(&[_]u8{ '@', @intCast(c) }, &.{.builtin});
    }
    for ('a'..'z') |c| {
        try expectTokenTags(&[_]u8{ '@', @intCast(c) }, &.{.builtin});
    }
}

test "at sign" {
    try expectTokenTags(" @ ", &.{.invalid});
    try expectTokenTags(" @ a", &.{ .invalid, .identifier });
}

test "keywords" {
    try expectTokenTags(
        " pub obj ui cmd for if else and or",
        &.{ .kw_pub, .kw_obj, .kw_ui, .kw_cmd, .kw_for, .kw_if, .kw_else, .kw_and, .kw_or },
    );
}

test "string" {
    try expectTokenTags(" \"asdf\" ", &.{.string});
}

test "string escape quote" {
    try expectTokenTags(" \"asdf\\\"jkl\" ", &.{.string});
}

test "string new line" {
    try expectTokenTags(" \"asdf\n", &.{.invalid});
}

test "string unterminated" {
    try expectTokenTags(" \"asdf", &.{.invalid});
}

test "comment" {
    try expectTokenTags("// comment", &.{.comment});
}

test "doc comment" {
    try expectTokenTags("/// doc comment", &.{.doc_comment});
}

fn expectInvalidDigits(comptime prefix: []const u8, comptime invalid_digits: []const u8) !void {
    for (invalid_digits) |d| {
        try expectTokenTags(prefix ++ &[_]u8{d}, &.{.invalid});
    }
}

fn expectInvalidFloatBase(comptime prefix: []const u8) !void {
    try expectTokenTags(prefix ++ ".1", &.{ .invalid, .decimal });
}

fn expectTokenTags(src: []const u8, tags: []const Token.Tag) !void {
    var t = Tokenizer.init(src);

    for (tags) |tag| {
        try std.testing.expectEqual(tag, t.next().tag);
    }

    try std.testing.expectEqual(.eof, t.next().tag);
}
