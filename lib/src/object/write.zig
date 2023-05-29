const std = @import("std");
const definition = @import("../definition.zig");
const serde = @import("../serde.zig");
const super = @import("../object.zig");
const meta = @import("meta.zig");

pub fn ObjectValue(comptime Obj: type) type {
    comptime {
        const len = Obj.def.versions.len;
        var fields: [len]std.builtin.Type.UnionField = undefined;
        for (Obj.def.versions, 0..) |Version, i| {
            const info = definition.FieldType.from(Version).?;
            const Value = FieldTypeValue(info);
            fields[i] = .{
                .name = meta.verFieldName(i),
                .type = Value,
                .alignment = @alignOf(Value),
            };
        }
        return @Type(.{
            .Union = .{
                .layout = .Auto,
                .tag_type = VersionEnum(len),
                .fields = &fields,
                .decls = &[_]std.builtin.Type.Declaration{},
            },
        });
    }
}

fn VersionEnum(comptime len: comptime_int) type {
    comptime {
        var fields: [len]std.builtin.Type.EnumField = undefined;
        for (0..len) |i| {
            fields[i] = .{
                .name = meta.verFieldName(i),
                .value = i,
            };
        }
        return @Type(.{
            .Enum = .{
                .tag_type = std.math.IntFittingRange(0, len - 1),
                .fields = &fields,
                .decls = &[_]std.builtin.Type.Declaration{},
                .is_exhaustive = true,
            },
        });
    }
}

pub fn FieldTypeValue(comptime info: definition.FieldType) type {
    return switch (info) {
        .Void => void,
        .Bool => bool,
        .Int => |int_info| @Type(.{ .Int = int_info }),
        .Float => |float_info| @Type(.{ .Float = float_info }),
        .Optional => |child_info| ?FieldTypeValue(child_info.*),
        .Ref => super.ObjectId,
        .Array => |array_info| [array_info.len]FieldTypeValue(array_info.child.*),
        .List => |child_info| std.ArrayList(FieldTypeValue(child_info.*)),
        .Map => |map_info| std.ArrayList(struct {
            key: FieldTypeValue(map_info.key.*),
            value: FieldTypeValue(map_info.value.*),
        }),
        .String => []const u8,
        .Struct => |fields| StructValue(fields),
        .Tuple => |fields| TupleValue(fields),
        .Union => |fields| UnionValue(fields),
        .Enum => |fields| meta.FieldTypeEnum(fields),
    };
}

fn StructValue(comptime fields: []const definition.FieldType.StructField) type {
    var struct_fields: [fields.len]std.builtin.Type.StructField = undefined;
    for (fields, 0..) |field, i| {
        const FieldType = FieldTypeValue(field.type);
        struct_fields[i] = .{
            .name = field.name,
            .type = FieldType,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(?FieldType),
        };
    }
    return @Type(.{
        .Struct = .{
            .layout = .Auto,
            .backing_integer = null,
            .fields = &struct_fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = false,
        },
    });
}

fn TupleValue(comptime fields: []const definition.FieldType) type {
    var struct_fields: [fields.len]std.builtin.Type.StructField = undefined;
    for (fields, 0..) |field, i| {
        const FieldType = FieldTypeValue(field);
        struct_fields[i] = .{
            .name = meta.numFieldName(i),
            .type = ?FieldType,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(?FieldType),
        };
    }
    return @Type(.{
        .Struct = .{
            .layout = .Auto,
            .backing_integer = null,
            .fields = &struct_fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = true,
        },
    });
}

fn UnionValue(comptime fields: []const definition.FieldType.UnionField) type {
    var enum_fields: [fields.len]std.builtin.Type.EnumField = undefined;
    var union_fields: [fields.len]std.builtin.Type.UnionField = undefined;
    for (fields, 0..) |field, i| {
        enum_fields[i] = .{
            .name = field.name,
            .value = i,
        };

        const FieldType = FieldTypeValue(field.type);
        union_fields[i] = .{
            .name = field.name,
            .type = FieldType,
            .alignment = @alignOf(FieldType),
        };
    }
    return @Type(.{
        .Union = .{
            .layout = .Auto,
            .tag_type = @Type(.{
                .Enum = .{
                    .tag_type = std.math.IntFittingRange(0, fields.len - 1),
                    .fields = &enum_fields,
                    .decls = &[_]std.builtin.Type.Declaration{},
                    .is_exhaustive = true,
                },
            }),
            .fields = &union_fields,
            .decls = &[_]std.builtin.Type.Declaration{},
        },
    });
}

pub fn writeValue(comptime Obj: type, value: ObjectValue(Obj), writer: anytype) !void {
    switch (value) {
        inline else => |val, tag| {
            const version = @enumToInt(tag);
            try serde.serialize(@as(usize, version), writer);

            const Version = Obj.def.versions[version];

            const info = comptime definition.FieldType.from(Version).?;
            try writeFieldType(info, val, writer);
        },
    }
}

fn writeFieldType(comptime info: definition.FieldType, value: anytype, writer: anytype) !void {
    switch (info) {
        .Void => {},
        .Bool, .Int, .Float, .Ref, .String, .Enum => {
            try serde.serialize(value, writer);
        },
        .Optional => |child_info| {
            if (value) |v| {
                try writer.writeByte(1);
                try writeFieldType(child_info.*, v, writer);
            } else {
                try writer.writeByte(0);
            }
        },
        .Array => |array_info| {
            for (value) |v| {
                try writeFieldType(array_info.child.*, v, writer);
            }
        },
        .List => |child_info| {
            try serde.serialize(value.items.len, writer);
            for (value.items) |v| {
                try writeFieldType(child_info.*, v, writer);
            }
        },
        .Map => |map_info| {
            try serde.serialize(value.items.len, writer);
            for (value.items) |v| {
                try writeFieldType(map_info.key.*, v.key, writer);
                try writeFieldType(map_info.value.*, v.value, writer);
            }
        },
        .Struct => |fields| {
            inline for (fields) |field| {
                try writeFieldType(field.type, @field(value, field.name), writer);
            }
        },
        .Tuple => |fields| {
            inline for (fields, 0..) |field, i| {
                try writeFieldType(field, value[i], writer);
            }
        },
        .Union => |fields| {
            switch (value) {
                inline else => |val, tag| {
                    const field = fields[@enumToInt(tag)];
                    try writeFieldType(field.type, val, writer);
                },
            }
        },
    }
}

const define = @import("../define.zig");
test "it compiles" {
    const Scheme = define.Scheme("sch", .{
        define.Object("Obj", .{
            struct {
                boolean: bool,
                int: u16,
                float: f16,
                ref: define.This("Obj"),
                str: define.String,
                enum_: enum {
                    Tag1,
                    Tag2,
                },
                opt: ?bool,
                array: define.Array(2, bool),
                list: define.List(bool),
                map: define.Map(u8, bool),
                tuple: struct { u8, u16 },
                union_: union(enum) {
                    Tag1: u8,
                    Tag2: u16,
                },
            },
        }),
    });
    const Obj = Scheme("Obj");

    const ObjValue = ObjectValue(Obj);

    var obj = ObjValue{ .v1 = undefined };
    var value = @TypeOf(obj.v1){
        .boolean = true,
        .int = 10,
        .float = 100.0,
        .ref = super.ObjectId{ .scheme = 0, .source = 0, .name = 0 },
        .str = "value",
        .enum_ = .Tag1,
        .opt = null,
        .array = [_]bool{ true, false },
        .list = undefined,
        .map = undefined,
        .tuple = .{ 10, 20 },
        .union_ = .{
            .Tag2 = 100,
        },
    };
    value.list = @TypeOf(value.list).init(std.testing.allocator);
    defer value.list.deinit();
    try value.list.append(true);

    value.map = @TypeOf(value.map).init(std.testing.allocator);
    defer value.map.deinit();
    try value.map.append(.{ .key = 10, .value = false });

    obj.v1 = value;

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    try writeValue(Obj, obj, buf.writer());
}
