const std = @import("std");
const cy = @import("cycle");

pub const NewList = Slice(void);
pub const NewMap = Slice(MapEntry);

pub const MutateOptional = Union(cy.obj.MutateOptional(void));

pub const MutateArray = Slice(MutateArrayOp);
pub const MutateArrayOp = Struct(cy.obj.MutateArrayOp(void));

pub const MutateList = Slice(MutateListOp);
pub const MutateListOp = Union(cy.obj.MutateListOp(VoidChild));
pub const MutateListInsertOp = Struct(cy.obj.MutateListOp(VoidChild).Insert);
pub const MutateListMutateOp = Struct(cy.obj.MutateListOp(VoidChild).Mutate);

pub const MutateMap = Slice(MutateMapOp);
pub const MutateMapOp = Union(cy.obj.MutateMapOp(VoidKV));

pub const MutateUnionField = Union(cy.obj.MutateUnionField(void));

pub const MapEntry = Struct(struct {
    key: void,
    value: void,
});

const VoidChild = struct {
    pub const child = void;
};

const VoidKV = struct {
    pub const key = void;
    pub const value = void;
};

pub fn Slice(comptime Elem: type) type {
    return struct {
        bytes: []const u8,

        const Self = @This();
        const elem_offset = @sizeOf(usize);

        pub fn init(bytes: []const u8) Self {
            return Self{ .bytes = bytes };
        }

        pub fn len(self: Self) usize {
            return cy.chan.read(usize, self.bytes);
        }

        pub fn elem(self: Self, i: usize) Elem {
            return Elem.init(readElem(self.bytes[elem_offset..], i));
        }

        pub fn elemValue(self: Self, i: usize) cy.chan.View(Elem) {
            return cy.chan.read(Elem, readElem(self.bytes[elem_offset..], i));
        }

        pub fn elemBytes(self: Self, i: usize) []const u8 {
            return readElem(self.bytes[elem_offset..], i);
        }
    };
}

pub fn Struct(comptime Type: type) type {
    return struct {
        bytes: []const u8,

        const Self = @This();

        pub fn init(bytes: []const u8) Self {
            return Self{ .bytes = bytes };
        }

        pub fn fieldValue(self: Self, field: std.meta.FieldEnum(Type)) std.meta.FieldType(Type, field) {
            return cy.chan.read(std.meta.FieldType(Type, field), readElem(self.bytes, @intFromEnum(field)));
        }

        pub fn fieldBytes(self: Self, field: std.meta.FieldEnum(Type)) []const u8 {
            return readElem(self.bytes, @intFromEnum(field));
        }
    };
}

pub fn Union(comptime Type: type) type {
    return struct {
        bytes: []const u8,

        const Tag = std.meta.FieldEnum(Type);
        const Self = @This();

        pub fn init(bytes: []const u8) Self {
            return Self{ .bytes = bytes };
        }

        pub fn tag(self: Self) Tag {
            return @enumFromInt(self.tagValue());
        }

        pub fn tagValue(self: Self) u16 {
            return cy.chan.read(u16, self.bytes);
        }

        pub fn fieldValue(self: Self, comptime t: Tag) std.meta.FieldType(Type, t) {
            return cy.chan.read(std.meta.FieldType(Type, t), self.fieldBytes());
        }

        pub fn fieldBytes(self: Self) []const u8 {
            const offset = @sizeOf(u16);
            return cy.chan.read([]const u8, self.bytes[offset..]);
        }
    };
}

pub fn readOptional(bytes: []const u8) ?[]const u8 {
    if (bytes[0] == 1) {
        return bytes[1..];
    }
    return null;
}

pub fn readElem(bytes: []const u8, i: usize) []const u8 {
    var offset: usize = 0;
    for (0..i) |_| {
        const field_size = cy.chan.read(usize, bytes[offset..]);
        offset += @sizeOf(usize);
        offset += field_size;
    }
    return cy.chan.read([]const u8, bytes[offset..]);
}
