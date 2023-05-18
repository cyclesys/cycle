const std = @import("std");

pub const Error = error{
    BufferOverCapacity,
    OutOfBytes,
    DeserializeInvalidBool,
    DeserializeInvalidOptional,
    DeserializeInvalidTaggedUnion,
} || std.mem.Allocator.Error;

const ByteList = std.ArrayList(u8);

const SerializeState = union(enum) {
    list: *ByteList,
    fixed: struct {
        buf: []u8,
        len: usize = 0,
    },

    fn write(self: *SerializeState, byte: u8) !void {
        switch (self.*) {
            .list => |list| {
                try list.append(byte);
            },
            .fixed => |*fixed| {
                if (fixed.len + 1 > fixed.buf.len) {
                    return error.BufferOverCapacity;
                }

                fixed.buf[fixed.len] = byte;
                fixed.len += 1;
            },
        }
    }

    fn writeSlice(self: *SerializeState, bytes: []const u8) !void {
        switch (self.*) {
            .list => |list| {
                try list.appendSlice(bytes);
            },
            .fixed => |*fixed| {
                if (fixed.len + bytes.len > fixed.buf.len) {
                    return error.BufferOverCapacity;
                }

                const start = fixed.len;
                const end = fixed.len + bytes.len;
                @memcpy(fixed.buf[start..end], bytes);
                fixed.len += bytes.len;
            },
        }
    }
};

pub fn serialize(comptime Type: type, value: Type, state: *SerializeState) Error!void {
    switch (@typeInfo(Type)) {
        .Type,
        .NoReturn,
        .ComptimeFloat,
        .ComptimeInt,
        .Undefined,
        .Null,
        .ErrorUnion,
        .ErrorSet,
        .Fn,
        .Opaque,
        .Frame,
        .AnyFrame,
        .Vector,
        .EnumLiteral,
        => @compileError("cannot serialize type: " ++ @typeName(Type)),
        .Void => {
            // do nothing
        },
        .Bool => {
            try state.write(if (value) 1 else 0);
        },
        .Int, .Float => {
            var slice: []const u8 = undefined;
            slice.ptr = @ptrCast([*]const u8, &value);
            slice.len = @sizeOf(Type);
            try state.writeSlice(slice);
        },
        .Pointer => |info| {
            switch (info.size) {
                .Many, .C => @compileError("cannot serialize pointer type: " ++ @typeName(Type)),
                .One => {
                    try serialize(info.child, value.*, state);
                },
                .Slice => {
                    try state.writeSlice(&@bitCast([@sizeOf(usize)]u8, value.len));

                    if (info.child == u8) {
                        try state.writeSlice(value);
                    } else {
                        for (value) |elem| {
                            try serialize(info.child, elem, state);
                        }
                    }
                },
            }
        },
        .Array => |info| {
            for (value) |elem| {
                try serialize(info.child, elem, state);
            }
        },
        .Struct => |info| {
            inline for (info.fields) |field| {
                if (field.is_comptime) {
                    @compileError("cannot serialize comptime struct fields");
                }

                try serialize(field.type, @field(value, field.name), state);
            }
        },
        .Optional => |info| {
            if (value == null) {
                try state.write(0);
            } else {
                try state.write(1);
                try serialize(info.child, value.?, state);
            }
        },
        .Enum => {
            const size = @sizeOf(Type);
            const IntCast = @Type(.{
                .Int = .{
                    .signedness = .unsigned,
                    .bits = size * 8,
                },
            });
            const cast_value = @intCast(IntCast, @enumToInt(value));
            try state.writeSlice(&@bitCast([size]u8, cast_value));
        },
        .Union => |info| {
            if (info.tag_type == null) {
                @compileError("cannot serialize untagged union types");
            } else {
                const tag_size = @sizeOf(info.tag_type.?);
                const IntCast = @Type(.{
                    .Int = .{
                        .signedness = .unsigned,
                        .bits = tag_size * 8,
                    },
                });
                const tag_value = @intCast(IntCast, @enumToInt(value));
                try state.writeSlice(&@bitCast([tag_size]u8, tag_value));

                switch (value) {
                    inline else => |val, tag| {
                        const FieldType = UnionFieldType(Type, tag);
                        try serialize(FieldType, val, state);
                    },
                }
            }
        },
    }
}

const DeserializeState = struct {
    allocator: std.mem.Allocator,
    buf: []const u8,
    pos: usize = 0,

    fn read(self: *DeserializeState, comptime size: comptime_int) ![size]u8 {
        if (self.pos + size > self.buf.len) {
            return error.OutOfBytes;
        }

        var out: [size]u8 = undefined;
        @memcpy(&out, self.buf[self.pos..(self.pos + size)]);

        self.pos += size;

        return out;
    }
};

pub fn deserialize(comptime Type: type, state: *DeserializeState) Error!Type {
    switch (@typeInfo(Type)) {
        .Type,
        .NoReturn,
        .ComptimeFloat,
        .ComptimeInt,
        .Undefined,
        .Null,
        .ErrorUnion,
        .ErrorSet,
        .Fn,
        .Opaque,
        .Frame,
        .AnyFrame,
        .Vector,
        .EnumLiteral,
        => @compileError("can't deserialize type: " ++ @typeName(Type)),
        .Void => {
            // do nothing
        },
        .Bool => {
            const value = try state.read(1);
            return switch (@bitCast(u8, value)) {
                1 => true,
                0 => false,
                else => error.DeserializeInvalidBool,
            };
        },
        .Int, .Float => {
            var bytes = try state.read(@sizeOf(Type));
            const ptr = @ptrCast(*align(1) const Type, &bytes);
            return ptr.*;
        },
        .Pointer => |info| {
            switch (info.size) {
                .Many, .C => @compileError("can't deserialize pointer type: " ++ @typeName(Type)),
                .One => {
                    var ptr = try state.allocator.create(info.child);
                    ptr.* = try deserialize(info.child, state);
                    return ptr;
                },
                .Slice => {
                    const len = @bitCast(usize, try state.read(@sizeOf(usize)));
                    var out = try std.ArrayList(info.child).initCapacity(state.allocator, len);
                    errdefer out.deinit();

                    for (0..len) |_| {
                        try out.append(try deserialize(info.child, state));
                    }

                    return out.toOwnedSlice();
                },
            }
        },
        .Array => |info| {
            var out: Type = undefined;
            for (0..info.len) |i| {
                out[i] = try deserialize(info.child, state);
            }
            return out;
        },
        .Struct => |info| {
            var out: Type = undefined;
            inline for (info.fields) |field| {
                @field(out, field.name) = try deserialize(field.type, state);
            }
            return out;
        },
        .Optional => |info| {
            return switch (@bitCast(u8, try state.read(1))) {
                0 => null,
                1 => try deserialize(info.child, state),
                else => error.DeserializeInvalidOptional,
            };
        },
        .Enum => |info| {
            const size = @sizeOf(Type);
            const IntCast = @Type(.{
                .Int = .{
                    .signedness = .unsigned,
                    .bits = size * 8,
                },
            });
            const cast_value = @bitCast(IntCast, try state.read(size));
            return @intToEnum(Type, @intCast(info.tag_type, cast_value));
        },
        .Union => |info| {
            if (info.tag_type == null) {
                @compileError("cannot deserialize untagged union types");
            } else {
                const Tag = info.tag_type.?;

                const tag_size = @sizeOf(Tag);
                const IntCast = @Type(.{
                    .Int = .{
                        .signedness = .unsigned,
                        .bits = tag_size * 8,
                    },
                });
                const tag_value = @bitCast(IntCast, try state.read(tag_size));

                const tag_info = @typeInfo(Tag).Enum;
                const TagInt = tag_info.tag_type;

                switch (@intToEnum(Tag, @intCast(TagInt, tag_value))) {
                    inline else => |tag| {
                        const FieldType = UnionFieldType(Type, tag);
                        return @unionInit(Type, @tagName(tag), try deserialize(FieldType, state));
                    },
                }
            }
        },
    }
}

pub inline fn destroy(comptime Type: type, value: Type, allocator: std.mem.Allocator) void {
    switch (@typeInfo(Type)) {
        .Type,
        .NoReturn,
        .ComptimeFloat,
        .ComptimeInt,
        .Undefined,
        .Null,
        .ErrorUnion,
        .ErrorSet,
        .Fn,
        .Opaque,
        .Frame,
        .AnyFrame,
        .Vector,
        .EnumLiteral,
        => @compileError("cannot destroy type: " ++ @typeName(Type)),

        .Void, .Bool, .Int, .Float, .Enum => {
            // nothing to do here
        },

        .Pointer => |info| {
            switch (info.size) {
                .Many, .C => @compileError("cannot destroy pointer type: " ++ @typeName(Type)),
                .One => {
                    if (allocates(info.child)) {
                        destroy(info.child, value.*, allocator);
                    }
                    allocator.destroy(value);
                },
                .Slice => {
                    if (allocates(info.child)) {
                        for (value) |elem| {
                            destroy(info.child, elem, allocator);
                        }
                    }
                    allocator.free(value);
                },
            }
        },

        .Array => |info| {
            if (allocates(info.child)) {
                for (value) |elem| {
                    destroy(info.child, elem, allocator);
                }
            }
        },

        .Struct => |info| {
            const allocating_fields = comptime blk: {
                var fields: [info.fields.len]std.builtin.Type.StructField = undefined;
                var len = 0;
                for (info.fields) |field| {
                    if (allocates(field.type)) {
                        fields[len] = field;
                        len += 1;
                    }
                }
                break :blk fields[0..len];
            };

            inline for (allocating_fields) |field| {
                destroy(field.type, @field(value, field.name), allocator);
            }
        },

        .Optional => |info| {
            if (allocates(info.child)) {
                if (value) |v| {
                    destroy(info.child, v, allocator);
                }
            }
        },

        .Union => |info| {
            if (info.tag_type == null) {
                @compileError("can't destroy untagged union types");
            }

            const resolve = struct {
                const allocating_fields = blk: {
                    var fields: [info.fields.len]std.builtin.Type.UnionField = undefined;
                    var len = 0;
                    for (info.fields) |field| {
                        if (allocates(field.type)) {
                            fields[len] = field;
                            len += 1;
                        }
                    }

                    break :blk fields[0..len];
                };

                fn fieldAllocates(comptime tag: anytype) bool {
                    for (allocating_fields) |field| {
                        if (std.mem.eql(u8, @tagName(tag), field.name)) {
                            return true;
                        }
                    }
                    return false;
                }
            };

            switch (value) {
                inline else => |val, tag| {
                    if (resolve.fieldAllocates(tag)) {
                        const FieldType = UnionFieldType(Type, tag);
                        destroy(FieldType, val, allocator);
                    }
                },
            }
        },
    }
}

fn allocates(comptime Type: type) bool {
    switch (@typeInfo(Type)) {
        .Type,
        .NoReturn,
        .ComptimeFloat,
        .ComptimeInt,
        .Undefined,
        .Null,
        .ErrorUnion,
        .ErrorSet,
        .Fn,
        .Opaque,
        .Frame,
        .AnyFrame,
        .Vector,
        .EnumLiteral,
        => @compileError("invalid type: " ++ @typeName(Type)),

        .Void, .Bool, .Int, .Float, .Enum => {
            return false;
        },

        .Pointer => {
            return true;
        },

        .Array => |info| {
            return allocates(info.child);
        },

        .Struct => |info| {
            for (info.fields) |field| {
                return allocates(field.type) orelse continue;
            }
        },

        .Optional => |info| {
            return allocates(info.child);
        },

        .Union => |info| {
            for (info.fields) |field| {
                return allocates(field.type) orelse continue;
            }
        },
    }
}

fn UnionFieldType(comptime Union: type, comptime tag: anytype) type {
    const info = @typeInfo(Union).Union;
    for (info.fields) |field| {
        if (std.mem.eql(u8, @tagName(tag), field.name)) {
            return field.type;
        }
    }

    @compileError("`tag` is not a valid tag value of " ++ @typeName(Union));
}

const testing = std.testing;

fn serde(comptime Type: type, value: Type) !Type {
    var buf = ByteList.init(testing.allocator);
    defer buf.deinit();
    try serialize(Type, value, @constCast(&.{ .list = &buf }));
    return deserialize(Type, @constCast(&DeserializeState{ .allocator = testing.allocator, .buf = buf.items }));
}

test "bool serde" {
    try testing.expectEqual(true, try serde(bool, true));
    try testing.expectEqual(false, try serde(bool, false));
}

test "int serde" {
    try testing.expectEqual(@as(i8, -10), try serde(i8, -10));
    try testing.expectEqual(@as(i16, -20), try serde(i16, -20));
    try testing.expectEqual(@as(i32, -30), try serde(i32, -30));
    try testing.expectEqual(@as(i64, -40), try serde(i64, -40));
    try testing.expectEqual(@as(i89, -50), try serde(i89, -50));

    try testing.expectEqual(@as(u8, 10), try serde(u8, 10));
    try testing.expectEqual(@as(u16, 20), try serde(u16, 20));
    try testing.expectEqual(@as(u32, 30), try serde(u32, 30));
    try testing.expectEqual(@as(u64, 40), try serde(u64, 40));
    try testing.expectEqual(@as(u89, 50), try serde(u89, 50));
}

test "float serde" {
    try testing.expectEqual(@as(f16, -10.0), try serde(f16, -10.0));
    try testing.expectEqual(@as(f32, 10.0), try serde(f32, 10.0));
    try testing.expectEqual(@as(f64, -20.0), try serde(f64, -20.0));
    try testing.expectEqual(@as(f80, 20.0), try serde(f80, 20.0));
    try testing.expectEqual(@as(f128, -30.0), try serde(f128, -30.0));
}

test "pointer serde" {
    const ptr = try serde(*const u8, &@as(u8, 10));
    defer destroy(*const u8, ptr, testing.allocator);
    try testing.expectEqual(ptr.*, 10);
}

test "slice serde" {
    const slice = try serde([]const u8, &[_]u8{ 10, 50, 100, 150, 200 });
    defer destroy([]const u8, slice, testing.allocator);
    try testing.expectEqualDeep(@as([]const u8, &[_]u8{ 10, 50, 100, 150, 200 }), slice);
}

test "array serde" {
    try testing.expectEqualDeep([_]u8{ 10, 50, 100, 150, 200 }, try serde([5]u8, [_]u8{ 10, 50, 100, 150, 200 }));
}

test "struct serde" {
    const Struct = struct {
        field1: u8,
        field2: u16,
    };
    try testing.expectEqualDeep(Struct{
        .field1 = 99,
        .field2 = 199,
    }, try serde(Struct, Struct{
        .field1 = 99,
        .field2 = 199,
    }));
}

test "optional serde" {
    try testing.expectEqual(@as(?bool, null), try serde(?bool, null));
    try testing.expectEqual(@as(?bool, true), try serde(?bool, true));
}

test "unsized enum serde" {
    const Enum = enum {
        Field1,
        Field2,
    };
    try testing.expectEqual(Enum.Field1, try serde(Enum, .Field1));
    try testing.expectEqual(Enum.Field2, try serde(Enum, .Field2));
}

test "sized enum serde" {
    const Enum = enum(u24) {
        Field1 = 100,
        Field2 = 200,
    };
    try testing.expectEqual(Enum.Field1, try serde(Enum, .Field1));
    try testing.expectEqual(Enum.Field2, try serde(Enum, .Field2));
}

test "tagged union serde" {
    const Union = union(enum) {
        Tag1: u16,
        Tag2: u32,
        Tag3: u64,
    };
    try testing.expectEqual(Union{ .Tag1 = 199 }, try serde(Union, .{ .Tag1 = 199 }));
    try testing.expectEqual(Union{ .Tag2 = 1999 }, try serde(Union, .{ .Tag2 = 1999 }));
    try testing.expectEqual(Union{ .Tag3 = 19999 }, try serde(Union, .{ .Tag3 = 19999 }));
}
