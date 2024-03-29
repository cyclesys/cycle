const std = @import("std");

nodes: NodeList.Slice,
idents: IdentList.Slice,

pub const NodeList = std.MultiArrayList(Node);
pub const Node = struct {
    tag: Tag,
    data: Data,

    pub const Tag = enum {
        void,

        i8,
        i16,
        i32,
        i64,
        i128,

        u8,
        u16,
        u32,
        u64,
        u128,

        f16,
        f32,
        f64,
        f128,

        bool,
        str,
        ref,

        opt,
        list,
        array,
        map,

        @"struct",
        tuple,
        @"enum",
        @"union",

        field,
        ident,
    };

    pub const Data = packed struct(u64) {
        lhs: u32,
        rhs: u32,
    };
};
pub const IdentList = std.ArrayListUnmanaged(u8);
pub const Index = u32;
const Type = @This();

pub fn deinit(ty: Type, allocator: std.mem.Allocator) void {
    var typ = ty;
    typ.nodes.deinit(allocator);
    allocator.free(typ.idents);
}
