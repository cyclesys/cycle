const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub fn serialize(comptime Type: type, value: Type, out: *ArrayList(u8)) !void {
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
            try out.append(if (value) 1 else 0);
        },
        .Int => |info| {
            const size = @sizeOf(Type);
            const IntCast = @Type(.{
                .Int = .{
                    .signedness = info.signedness,
                    .bits = size * 8,
                },
            });

            const cast_value = @intCast(IntCast, value);
            try out.appendSlice(&@bitCast([size]u8, cast_value));
        },
        .Float => {
            const size = @sizeOf(Type);
            const FloatCast = @Type(.{
                .Float = .{
                    .bits = size * 8,
                },
            });
            const cast_value = @floatCast(FloatCast, value);
            try out.appendSlice(&@bitCast([size]u8, cast_value));
        },
        .Pointer => |info| {
            switch (info.size) {
                .One, .Many, .C => @compileError("cannot serialize pointer type: " ++ @typeName(Type)),
                .Slice => {},
            }

            try out.appendSlice(&@bitCast([@sizeOf(usize)]u8, value.len));

            for (value) |elem| {
                try serialize(info.child, elem, out);
            }
        },
        .Array => |info| {
            for (value) |elem| {
                try serialize(info.child, elem, out);
            }
        },
        .Struct => |info| {
            inline for (info.fields) |field| {
                if (field.is_comptime) {
                    @compileError("cannot serialize comptime struct fields");
                }

                try serialize(field.type, @field(value, field.name), out);
            }
        },
        .Optional => |info| {
            if (value == null) {
                try out.append(0);
            } else {
                try out.append(1);
                try serialize(info.child, value.?, out);
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
            try out.appendSlice(&@bitCast([size]u8, cast_value));
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

                try out.appendSlice(&@bitCast([tag_size]u8, tag_value));

                inline for (info.fields) |field| {
                    if (mem.eql(u8, field.name, @tagName(value))) {
                        try serialize(field.type, @field(value, field.name), out);
                    }
                }
            }
        },
    }
}

const DeserializeState = struct {
    allocator: Allocator,
    buf: []const u8,
    pos: usize = 0,

    fn read(self: *DeserializeState, comptime size: comptime_int) ![size]u8 {
        if (self.pos + size > self.buf.len) {
            return error.OutOfBytes;
        }

        var out: [size]u8 = undefined;
        @memcpy(&out, @ptrCast([*]const u8, self.buf[self.pos..(self.pos + size)]), size);

        self.pos += size;

        return out;
    }
};

pub fn deserialize(comptime Type: type, state: *DeserializeState) !Type {
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
        .Int => |info| {
            const size = @sizeOf(Type);
            const IntCast = @Type(.{
                .Int = .{
                    .signedness = info.signedness,
                    .bits = size * 8,
                },
            });

            const cast_value = @bitCast(IntCast, try state.read(size));

            return @intCast(Type, cast_value);
        },
        .Float => {
            const size = @sizeOf(Type);
            const FloatCast = @Type(.{
                .Float = .{
                    .bits = size * 8,
                },
            });
            const cast_value = @bitCast(FloatCast, try state.read(size));
            return @floatCast(Type, cast_value);
        },
        .Pointer => |info| {
            switch (info.size) {
                .One, .Many, .C => @compileError("can't deserialize pointer type: " ++ @typeName(Type)),
                .Slice => {},
            }

            const len = @bitCast(usize, try state.read(@sizeOf(usize)));
            var out = try ArrayList(info.child).initCapacity(state.allocator, len);
            errdefer out.deinit();

            for (0..len) |_| {
                try out.append(try deserialize(info.child, state));
            }

            return out.toOwnedSlice();
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
                const tag_size = @sizeOf(info.tag_type.?);
                const IntCast = @Type(.{
                    .Int = .{
                        .signedness = .unsigned,
                        .bits = tag_size * 8,
                    },
                });
                const tag_value = @bitCast(IntCast, try state.read(tag_size));
                const tag_int = @typeInfo(info.tag_type.?).Enum.tag_type;
                const tag_name = @tagName(@intToEnum(info.tag_type.?, @intCast(tag_int, tag_value)));

                inline for (info.fields) |field| {
                    if (mem.eql(u8, field.name, tag_name)) {
                        return @unionInit(Type, field.name, try deserialize(field.type, state));
                    }
                }

                return error.DeserializeInvalidTaggedUnion;
            }
        },
    }
}

const testing = std.testing;

fn serde(comptime Type: type, value: Type) !Type {
    var buf = ArrayList(u8).init(testing.allocator);
    defer buf.deinit();
    try serialize(Type, value, &buf);
    return deserialize(Type, &DeserializeState{ .allocator = testing.allocator, .buf = buf.items });
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

test "slice serde" {
    const slice = try serde([]const u8, &[_]u8{ 10, 50, 100, 150, 200 });
    defer testing.allocator.free(slice);
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
