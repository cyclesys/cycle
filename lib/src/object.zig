const std = @import("std");
const define = @import("define.zig");
const definition = @import("definition.zig");
const SharedMem = @import("SharedMem.zig");

pub const TypeId = packed struct {
    scheme: u16,
    version: u16,
    name: u32,
};

pub const ObjectId = packed struct {
    scheme: u16,
    source: u16,
    name: u32,
};

pub const Object = struct {
    type: TypeId,
    id: ObjectId,
    mem: SharedMem,
};

pub const Error = error{
    SchemeNotDefined,
    ObjectNotDefined,
} || std.mem.Allocator.Error;

pub fn ObjectIndex(comptime scheme_fns: anytype) type {
    return struct {
        allocator: std.mem.Allocator,
        slots: Slots,

        const Self = @This();

        pub const schemes = blk: {
            var scheme_types: []const type = &[_]type{};
            for (scheme_fns) |SchemeFn| {
                const Scheme = SchemeFn(define.This);
                scheme_types = definition.ObjectScheme.mergeTypes(scheme_types, &.{Scheme});

                const dependencies = definition.ObjectScheme.dependencies(Scheme);
                scheme_types = definition.ObjectScheme.mergeTypes(scheme_types, dependencies);
            }

            var obj_schemes: [scheme_types.len]definition.ObjectScheme = undefined;
            for (scheme_types, 0..) |Scheme, i| {
                obj_schemes[i] = definition.ObjectScheme.from(Scheme);
            }

            break :blk definition.ObjectScheme.mergeSchemes(obj_schemes[0..]);
        };

        const Slots = blk: {
            var field_types: [schemes.len]type = undefined;
            for (schemes, 0..) |scheme, i| {
                field_types[i] = Tuple(scheme.objects.len, .{ObjectMap});
            }

            break :blk Tuple(schemes.len, field_types);
        };

        fn Tuple(comptime num_fields: comptime_int, comptime field_types: anytype) type {
            var fields: [num_fields]std.builtin.Type.StructField = undefined;
            for (0..num_fields) |i| {
                var field_name_size = std.fmt.count("{d}", .{i});
                var field_name: [field_name_size]u8 = undefined;
                _ = std.fmt.formatIntBuf(&field_name, i, 10, .lower, .{});

                const FieldType = if (field_types.len == num_fields)
                    field_types[i]
                else
                    field_types[0];

                fields[i] = .{
                    .name = &field_name,
                    .type = FieldType,
                    .default_value = null,
                    .is_comptime = false,
                    .alignment = @alignOf(FieldType),
                };
            }
            return @Type(.{
                .Struct = .{
                    .layout = .Auto,
                    .backing_integer = null,
                    .fields = fields,
                    .decls = &[_]std.builtin.Type.Declaration{},
                    .is_tuple = true,
                },
            });
        }

        fn refType(comptime Container: type, comptime info: definition.Ref) type {
            const scheme_name = info.scheme_name orelse Container.type_scheme.scheme_name;
            const type_name = Container.type_def.type_name;
            for (scheme_fns) |SchemeFn| {
                const Scheme = SchemeFn(define.This);
                if (!std.mem.eql(u8, Scheme.scheme_name, scheme_name))
                    continue;

                for (Scheme.scheme_types) |Type| {
                    if (std.mem.eql(u8, Type.type_name, type_name)) {
                        return SchemeFn(type_name);
                    }
                }
            }

            @compileError(type_name ++ " in " ++ scheme_name ++ " is not defined within this ObjectIndex");
        }

        fn objIndex(comptime ObjectType: type) struct {
            sch: usize,
            obj: usize,
        } {
            comptime {
                const object_name = ObjectType.type_def_type_name;
                const scheme_name = ObjectType.type_scheme.scheme_name;
                for (schemes, 0..) |scheme, i| {
                    if (std.mem.eql(u8, scheme.name, scheme_name)) {
                        for (scheme.objects, 0..) |object, ii| {
                            if (std.mem.eql(u8, object.name, object_name)) {
                                return .{
                                    .sch = i,
                                    .obj = ii,
                                };
                            }
                        }
                    }
                }

                @compileError(object_name ++ " is not defined wihtin this ObjectIndex.");
            }
        }

        fn objMap(self: *Self, id: TypeId) Error!*ObjectMap {
            inline for (schemes, 0..) |scheme, i| {
                if (i == id.scheme) {
                    inline for (0..scheme.objects.len) |ii| {
                        if (ii == id.name) {
                            return &self.slots[i][ii];
                        }
                    }
                }
            }

            return error.ObjectNotDefined;
        }

        pub fn init(allocator: std.mem.Allocator) ObjectIndex {
            var slots: Slots = undefined;
            inline for (schemes, 0..) |scheme, i| {
                const SchemeSlot = std.meta.fields(Slots)[i].type;
                var slot: SchemeSlot = undefined;
                inline for (0..scheme.objects.len) |ii| {
                    slot[ii] = ObjectMap.init(allocator);
                }
                slots[i] = slot;
            }
            return ObjectIndex{
                .allocator = allocator,
                .slots = slots,
            };
        }

        pub fn deinit(self: *Self) void {
            inline for (schemes, 0..) |scheme, i| {
                inline for (0..scheme.objects.len) |ii| {
                    self.slots[i][ii].deinit();
                }
            }
        }

        pub fn put(self: *Self, obj: Object) Error!void {
            if (obj.type.scheme > self.slots.len) {
                return error.SchemeNotDefined;
            }
        }

        pub fn get(self: *Self, comptime Obj: type, id: ObjectId) ?ObjectView(Self, Obj) {
            const idx = comptime objIndex(Obj);
            const object = self.slots[idx.sch][idx.obj].get(@bitCast(u64, id));
            if (object) |obj| {
                return ObjectView(Self, Obj).init(self, obj);
            }

            return null;
        }

        pub fn iter(self: *Self, comptime Obj: type) !ObjectIterator(Self, Obj) {
            const idx = comptime objIndex(Obj);
            const map = self.slots[idx.sch][idx.obj];
            return ObjectIterator(Self, Obj).init(self, map);
        }
    };
}

const ObjectMap = std.AutoHashMap(u64, IndexedObject);

const IndexedObject = struct {
    version: u16,
    mem: SharedMem,
};

fn ObjectIterator(comptime Index: type, comptime Obj: type) type {
    return struct {
        const Self = @This();
        const View = ObjectView(Index, Obj);

        pub fn next(self: *Self) View {
            _ = self;
        }
    };
}

fn ObjectView(comptime Index: type, comptime Obj: type) type {
    const ObjDef = Obj.type_def;
    var enum_fields: [ObjDef.type_versions.len]std.builtin.Type.EnumField = undefined;
    var union_fields: [ObjDef.type_versions.len]std.builtin.Type.UnionField = undefined;
    for (ObjDef.type_versions, 0..) |Version, i| {
        const tag_name = verTagName(i);
        enum_fields[i] = .{
            .name = tag_name,
            .value = i,
        };

        const VersionField = VersionView(Index, Version);
        union_fields[i] = .{
            .name = tag_name,
            .type = VersionField,
            .alignment = @alignOf(VersionField),
        };
    }
    return @Type(.{
        .Union = .{
            .layout = .Auto,
            .tag_type = @Type(.{
                .Enum = .{
                    .tag_type = std.math.IntFittingRange(0, ObjDef.type_verions.len),
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

fn verTagName(comptime num: comptime_int) []const u8 {
    comptime {
        var size = std.fmt.count("{d}", .{num});
        var buf: [size]u8 = undefined;
        _ = std.fmt.formatIntBuf(&buf, num, 10, .lower, .{});
        return "v" ++ &buf;
    }
}

fn VersionView(comptime Index: type, comptime Version: type) type {
    _ = Index;
    return switch (definition.FieldType.from(Version).?) {
        .Void => void,
        .Bool => BoolView,
        .Int => |info| IntView(info),
        .Float => |info| FloatView(info),
        .Optional => |info| OptionalView(info.*),
        .Ref => |info| {
            _ = info;
        },
        .Array => {},
        .List => {},
        .Map => {},
        .String => {},
        .Struct => {},
        .Tuple => {},
        .Union => {},
        .Enum => {},
    };
}

fn FieldTypeView(comptime Index: type, comptime Obj: type, comptime info: definition.FieldType) type {
    return switch (info) {
        .Void => void,
        .Bool => bool,
        .Int => |int_info| @Type(int_info),
        .Float => |float_info| @Type(float_info),
        .Optional => |child_info| OptionalView(Index, Obj, child_info.*),
        .Ref => |ref_info| ObjectView(Index, Index.refType(Obj, ref_info)),
        .Array => |array_info| ArrayView(Index, Obj, array_info),
        .List => |child_info| ListView(Index, Obj, child_info.*),
        .Map => |map_info| MapView(Index, Obj, map_info),
        .String => []const u8,
        .Struct => |fields| StructView(Index, Obj, fields),
        .Tuple => |fields| TupleView(Index, Obj, fields),
        .Union => |fields| UnionView(Index, Obj, fields),
        .Enum => |fields| EnumView(fields),
    };
}

const BoolView = struct {
    bytes: []const u8,

    pub fn read(self: *const BoolView) bool {
        return readBool(self.bytes);
    }
};

fn IntView(comptime info: std.builtin.Type.Int) type {
    const Int = @Type(info);
    return struct {
        bytes: []const u8,

        const Self = @This();

        pub fn read(self: *const Self) Int {
            return readInt(Int, self.bytes);
        }
    };
}

fn FloatView(comptime info: std.builtin.Type.Float) type {
    const Float = @Type(info);
    return struct {
        bytes: []const u8,

        const Self = @This();

        pub fn init(mem: *const SharedMem) Self {
            return Self{ .mem = mem };
        }

        pub fn read(self: *const Self) Float {
            return readFloat(Float, self.bytes);
        }
    };
}

fn OptionalView(comptime Index: type, comptime Obj: type, comptime child_info: definition.FieldType) type {
    return struct {
        index: *Index,
        bytes: []const u8,

        const Self = @This();

        pub fn read(self: *const Self) ?FieldTypeView(child_info) {
            switch (self.bytes[0]) {
                0 => return null,
                1 => {},
                else => unreachable,
            }

            return readFieldType(Index, Obj, self.index, self.bytes[1..]);
        }
    };
}

fn ArrayView(comptime Index: type, comptime Obj: type, comptime info: definition.FieldType.Array) type {
    const needs_index = fieldTypeNeedsIndex(info.child.*);
    _ = Obj;
    return struct {
        index: if (needs_index) *Index else void,
        bytes: []const u8,
    };
}

fn ListView(comptime child: definition.FieldType) type {
    _ = child;
    return struct {};
}

fn MapView(comptime info: definition.FieldType.Map) type {
    _ = info;
    return struct {};
}

const StringView = struct {};

fn StructView(comptime fields: []const definition.FieldType.StructField) type {
    _ = fields;
    return struct {};
}

fn TupleView(comptime fields: []const definition.FieldType) type {
    _ = fields;
    return struct {};
}

fn UnionView(comptime info: definition.FieldType.Union) type {
    _ = info;
    return struct {};
}

fn EnumView(comptime info: definition.FieldType.Enum) type {
    _ = info;
    return struct {};
}

fn readFieldType(
    comptime Index: type,
    comptime Obj: type,
    comptime info: definition.FieldType,
    index: *Index,
    bytes: []const u8,
) FieldTypeView(info) {
    const Type = FieldTypeView(info);
    return switch (info) {
        .Void => {},
        .Bool => readBool(bytes),
        .Int => readInt(Type, bytes),
        .Float => readFloat(Type, bytes),
        .Optional => Type{ .index = index, .bytes = bytes },
        .Ref => |ref_info| readRef(Index, Index.refType(Obj, ref_info), index, bytes),
    };
}

fn readBool(view: []const u8) bool {
    return switch (view[0]) {
        0 => false,
        1 => true,
        else => unreachable,
    };
}

fn readInt(comptime Int: type, bytes: []const u8) Int {
    const size = @sizeOf(Int);
    const IntBytes = @Type(.{
        .Int = .{
            .signedness = .unsigned,
            .bits = size * 8,
        },
    });

    var value_bytes: [size]u8 = undefined;
    @memcpy(&value_bytes, bytes[0..size]);

    const value = @bitCast(IntBytes, value_bytes);
    return @intCast(Int, value);
}

fn readFloat(comptime Float: type, bytes: []const u8) Float {
    const size = @sizeOf(Float);
    const FloatBytes = @Type(.{
        .Float = .{
            .bits = size * 8,
        },
    });

    var value_bytes: [size]u8 = undefined;
    @memcpy(&value_bytes, bytes[0..size]);

    const value = @bitCast(FloatBytes, value_bytes);
    return @floatCast(Float, value);
}

fn readRef(
    comptime Index: type,
    comptime Obj: type,
    index: *Index,
    bytes: []const u8,
) ObjectView(Index, Obj) {
    const id = readInt(u64, bytes);
    return index.get(Obj, @bitCast(ObjectId, id));
}

fn fieldTypeNeedsIndex(comptime info: definition.FieldType) bool {
    _ = info;
}

fn fieldTypeHasFixedSize(comptime info: definition.FieldType) bool {
    _ = info;
}
