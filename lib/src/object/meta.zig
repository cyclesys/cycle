const std = @import("std");
const definition = @import("../definition.zig");

pub fn NumEnum(comptime num: comptime_int) type {
    comptime {
        var fields: [num]std.builtin.Type.EnumField = undefined;
        for (0..num) |i| {
            fields[i] = .{
                .name = numFieldName(i),
                .value = i,
            };
        }
        return @Type(.{
            .Enum = .{
                .tag_type = std.math.IntFittingRange(0, num - 1),
                .fields = &fields,
                .decls = &[_]std.builtin.Type.Declaration{},
                .is_exhaustive = true,
            },
        });
    }
}

pub fn Tuple(comptime types: anytype) type {
    comptime {
        var fields: [types.len]std.builtin.Type.StructField = undefined;
        for (types, 0..) |T, i| {
            fields[i] = .{
                .name = numFieldName(i),
                .type = T,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(T),
            };
        }
        return @Type(.{
            .Struct = .{
                .layout = .Auto,
                .backing_integer = null,
                .fields = &fields,
                .decls = &[_]std.builtin.Type.Declaration{},
                .is_tuple = true,
            },
        });
    }
}

pub fn FieldTypeEnum(comptime fields: []const definition.FieldType.EnumField) type {
    var enum_fields: [fields.len]std.builtin.Type.EnumField = undefined;
    for (fields, 0..) |field, i| {
        enum_fields[i] = .{
            .name = field.name,
            .value = i,
        };
    }
    return @Type(.{
        .Enum = .{
            .tag_type = std.math.IntFittingRange(0, fields.len - 1),
            .fields = &enum_fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_exhaustive = true,
        },
    });
}

pub fn verFieldName(comptime num: comptime_int) []const u8 {
    comptime {
        return "v" ++ numFieldName(num + 1);
    }
}

pub fn numFieldName(comptime num: comptime_int) []const u8 {
    comptime {
        var field_name_size = std.fmt.count("{d}", .{num});
        var field_name: [field_name_size]u8 = undefined;
        _ = std.fmt.formatIntBuf(&field_name, num, 10, .lower, .{});
        return &field_name;
    }
}
