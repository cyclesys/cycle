const std = @import("std");
const define = @import("define.zig");
const definition = @import("definition.zig");
const SharedMem = @import("SharedMem.zig");

pub const TypeId = packed struct {
    scheme: u16,
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
            var scheme_slot_types: [schemes.len]type = undefined;
            for (schemes, 0..) |scheme, i| {
                var object_slot_types: [scheme.objects.len]type = undefined;
                for (0..scheme.objects.len) |ii| {
                    object_slot_types[ii] = std.AutoHashMap(u64, SharedMem);
                }
                scheme_slot_types[i] = Tuple(object_slot_types);
            }
            break :blk Tuple(scheme_slot_types);
        };

        fn objInfo(
            comptime scheme: []const u8,
            comptime name: []const u8,
        ) definition.ObjectScheme.Object {
            comptime {
                for (schemes) |sch| {
                    if (!std.mem.eql(u8, scheme, sch.name)) {
                        continue;
                    }

                    for (scheme.objects) |info| {
                        if (std.mem.eql(u8, name, info.name)) {
                            return info;
                        }
                    }
                }
            }
        }

        const ObjSlot = struct {
            scheme: comptime_int,
            type: comptime_int,
        };

        fn objTypeSlot(comptime Obj: type) ObjSlot {
            return objSlot(Obj.scheme.name, Obj.def.name);
        }

        fn objSlot(comptime scheme: []const u8, comptime name: []const u8) ObjSlot {
            comptime {
                for (schemes, 0..) |sch, i| {
                    if (std.mem.eql(u8, scheme, sch.name)) {
                        for (scheme.objects, 0..) |obj, ii| {
                            if (std.mem.eql(u8, name, obj.name)) {
                                return ObjSlot{
                                    .scheme = i,
                                    .type = ii,
                                };
                            }
                        }
                    }
                }

                @compileError(name ++ " is not defined wihtin this ObjectIndex.");
            }
        }

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            var slots: Slots = undefined;
            inline for (schemes, 0..) |scheme, i| {
                const SchemeSlot = std.meta.fields(Slots)[i].type;
                var slot: SchemeSlot = undefined;
                inline for (0..scheme.objects.len) |ii| {
                    slot[ii] = std.AutoHashMap(u64, SharedMem).init(allocator);
                }
                slots[i] = slot;
            }
            return Self{
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
            if (obj.type.scheme >= schemes.len) {
                return error.SchemeNotDefined;
            }

            const SchemeEnum = IndexEnum(schemes.len);
            switch (@intToEnum(SchemeEnum, obj.type.scheme)) {
                inline else => |scheme_val| {
                    const scheme_slot = @enumToInt(scheme_val);
                    if (obj.type.name >= schemes[scheme_slot].objects.len) {
                        return error.ObjectNotDefined;
                    }

                    const TypeEnum = IndexEnum(schemes[scheme_slot].objects.len);
                    switch (@intToEnum(TypeEnum, obj.type.name)) {
                        inline else => |type_val| {
                            const type_slot = @enumToInt(type_val);

                            const map = &self.slots[scheme_slot][type_slot];
                            try map.put(@bitCast(u64, obj.id), obj.mem);
                        },
                    }
                },
            }
        }

        pub fn get(self: *Self, comptime Obj: type, id: ObjectId) ?ObjTypeView(Obj) {
            const slot = comptime objTypeSlot(Obj);
            const map = &self.slots[slot.scheme][slot.type];
            const mem = map.getPtr(@bitCast(u64, id));
            if (mem) |m| {
                return readObject(
                    Self,
                    Obj.scheme.name,
                    Obj.def.name,
                    self,
                    m.view,
                );
            }

            return null;
        }

        fn ObjTypeView(comptime Obj: type) type {
            return ObjectView(Self, Obj.scheme.name, Obj.def.name);
        }

        fn getMem(
            self: *Self,
            comptime scheme: []const u8,
            comptime name: []const u8,
            id: u64,
        ) ?*SharedMem {
            const slot = comptime objSlot(scheme, name);
            const map = &self.slots[slot.scheme][slot.type];
            return map.getPtr(id);
        }
    };
}

fn Tuple(comptime types: anytype) type {
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

fn IndexEnum(comptime num_fields: comptime_int) type {
    comptime {
        var fields: [num_fields]std.builtin.Type.EnumField = undefined;
        for (0..num_fields) |i| {
            fields[i] = .{
                .name = numFieldName(i),
                .value = i,
            };
        }
        return @Type(.{
            .Enum = .{
                .tag_type = std.math.IntFittingRange(0, num_fields - 1),
                .fields = &fields,
                .decls = &[_]std.builtin.Type.Declaration{},
                .is_exhaustive = true,
            },
        });
    }
}

fn ObjectIterator(comptime Index: type, comptime Obj: type) type {
    _ = Index;
    _ = Obj;
    return struct {
        const Self = @This();

        pub fn next(self: *Self) void {
            _ = self;
        }
    };
}

fn ObjectView(
    comptime Index: type,
    comptime scheme: []const u8,
    comptime name: []const u8,
) type {
    const info = Index.objInfo(scheme, name);

    var union_fields: [info.versions.len + 1]std.builtin.Type.UnionField = undefined;
    for (info.versions, 0..) |ver_info, i| {
        const tag_name = verFieldName(i);
        const VersionField = FieldTypeView(Index, scheme, ver_info);
        union_fields[i] = .{
            .name = tag_name,
            .type = VersionField,
            .alignment = @alignOf(VersionField),
        };
    }
    union_fields[info.versions.len] = .{
        .name = "unknown",
        .type = void,
        .alignment = @alignOf(void),
    };

    return @Type(.{
        .Union = .{
            .layout = .Auto,
            .tag_type = VersionEnum(info.versions.len),
            .fields = &union_fields,
            .decls = &[_]std.builtin.Type.Declaration{},
        },
    });
}

fn VersionEnum(comptime num_versions: comptime_int) type {
    comptime {
        var fields: [num_versions + 1]std.builtin.Type.EnumField = undefined;
        for (0..num_versions) |i| {
            fields[i] = .{
                .name = verFieldName(i),
                .value = i,
            };
        }
        fields[num_versions] = .{
            .name = "unknown",
            .value = num_versions,
        };
        return @Type(.{
            .Enum = .{
                .tag_type = std.math.IntFittingRange(0, num_versions),
                .fields = &fields,
                .decls = &[_]std.builtin.Type.Declaration{},
                .is_exhaustive = true,
            },
        });
    }
}

fn verFieldName(comptime num: comptime_int) []const u8 {
    comptime {
        return "v" ++ numFieldName(num);
    }
}

fn numFieldName(comptime num: comptime_int) []const u8 {
    comptime {
        var field_name_size = std.fmt.count("{d}", .{num});
        var field_name: [field_name_size]u8 = undefined;
        _ = std.fmt.formatIntBuf(&field_name, num, 10, .lower, .{});
        return &field_name;
    }
}

fn FieldTypeView(
    comptime Index: type,
    comptime scheme: []const u8,
    comptime info: definition.FieldType,
) type {
    return switch (info) {
        .Void => void,
        .Bool => bool,
        .Int => |int_info| @Type(.{ .Int = int_info }),
        .Float => |float_info| @Type(.{ .Float = float_info }),
        .Optional => |child_info| ?FieldTypeView(Index, scheme, child_info.*),
        .Ref => |ref_info| RefView(
            Index,
            ref_info.scheme orelse scheme,
            ref_info.name,
        ),
        .Array => |array_info| ArrayView(Index, scheme, array_info),
        .List => |child_info| ListView(Index, scheme, child_info.*),
        .Map => |map_info| MapView(Index, scheme, map_info),
        .String => []const u8,
        .Struct => |fields| StructView(Index, scheme, fields),
        .Tuple => |fields| TupleView(Index, scheme, fields),
        .Union => |union_info| UnionView(Index, scheme, union_info),
        .Enum => |enum_info| EnumView(enum_info),
    };
}

fn RefView(
    comptime Index: type,
    comptime scheme: []const u8,
    comptime name: []const u8,
) type {
    return struct {
        index: *Index,
        id: u64,

        const Self = @This();

        const ViewType = ObjectView(Index, scheme, name);

        pub fn read(self: *const Self) ?ViewType {
            const mem = self.index.getMem(scheme, name, self.id);
            if (mem) |m| {
                return readObject(Index, scheme, name, self.index, m.view);
            }
            return null;
        }
    };
}

fn ArrayView(
    comptime Index: type,
    comptime scheme: []const u8,
    comptime info: definition.FieldType.Array,
) type {
    return struct {
        index: if (fieldTypeNeedsIndex(info.child.*)) *Index else void,
        ends: []const usize,
        bytes: []const u8,

        const Self = @This();
        const ChildView = FieldTypeView(Index, scheme, info.child.*);

        pub fn read(self: *const Self, idx: usize) ChildView {
            if (info.len == 0) {
                @compileError("cannot read zero element array");
            }

            if (idx >= info.len) {
                @panic("array index out of bounds");
            }

            return readChildAt(ChildView, info.child.*, self.index, self.ends, self.bytes, idx);
        }
    };
}

fn ListView(
    comptime Index: type,
    comptime scheme: []const u8,
    comptime child_info: definition.FieldType,
) type {
    return struct {
        index: if (fieldTypeNeedsIndex(child_info)) *Index else void,
        len: usize,
        ends: []const usize,
        bytes: []const u8,

        const Self = @This();
        const ChildView = FieldTypeView(Index, scheme, child_info);

        pub fn read(self: *const Self, idx: usize) ChildView {
            if (idx >= self.len) {
                @panic("list index out of bounds");
            }
            return readChildAt(ChildView, child_info, self.index, self.ends, self.bytes, idx);
        }
    };
}

inline fn readChildAt(
    comptime ChildView: type,
    comptime child_info: definition.FieldType,
    index: anytype,
    ends: []const usize,
    bytes: []const u8,
    idx: usize,
) ChildView {
    var start: usize = undefined;
    var end: usize = undefined;
    if (comptime fieldTypeSize(child_info)) |child_size| {
        start = child_size * idx;
        end = start + child_size;
    } else {
        start = if (idx == 0) 0 else ends[idx - 1];
        end = ends[idx];
    }
    return readFieldType(ChildView, child_info, index, bytes[start..end]).value;
}

fn MapView(
    comptime Index: type,
    comptime scheme: []const u8,
    comptime info: definition.FieldType.Map,
) type {
    return struct {
        index: if (fieldTypeNeedsIndex(info.key.*) or fieldTypeNeedsIndex(info.value.*)) *Index else void,
        len: usize,
        ends: []const usize,
        bytes: []const u8,

        const Self = @This();
        const KeyView = FieldTypeView(Index, scheme, info.key.*);
        const ValueView = FieldTypeView(Index, scheme, info.value.*);
        pub const KeyValue = struct {
            key: KeyView,
            value: ValueView,
        };

        pub fn read(self: *const Self, idx: usize) KeyValue {
            if (idx >= self.len) {
                @panic("map index out of bounds");
            }

            const key_size = comptime fieldTypeSize(info.key.*);
            const value_size = comptime fieldTypeSize(info.value.*);

            var key_start: usize = undefined;
            var key_end: usize = undefined;
            var value_end: usize = undefined;
            if (key_size != null and value_size != null) {
                key_start = key_size.? * idx;
                key_end = key_start + key_size.?;
                value_end = key_end + value_size.?;
            } else {
                if (key_size) |ks| {
                    key_start = if (idx == 0) 0 else self.ends[idx - 1];
                    key_end = key_start + ks;
                    value_end = self.ends[idx];
                } else if (value_size) |vs| {
                    key_start = if (idx == 0) 0 else (self.ends[idx - 1] + vs);
                    key_end = self.ends[idx];
                    value_end = key_end + vs;
                } else {
                    const start_idx = (idx * 2) + 1;
                    key_start = self.ends[start_idx];
                    key_end = self.ends[start_idx + 1];
                    value_end = self.ends[start_idx + 2];
                }
            }

            const key = readFieldType(
                KeyView,
                info.key.*,
                self.index,
                self.bytes[key_start..key_end],
            ).value;

            const value = readFieldType(
                ValueView,
                info.value.*,
                self.index,
                self.bytes[key_end..value_end],
            ).value;

            return KeyValue{
                .key = key,
                .value = value,
            };
        }
    };
}

fn StructView(
    comptime Index: type,
    comptime scheme: []const u8,
    comptime fields: []const definition.FieldType.StructField,
) type {
    comptime {
        var struct_fields: [fields.len]std.builtin.Type.StructField = undefined;
        for (fields, 0..) |field, i| {
            const FieldType = FieldTypeView(Index, scheme, field.type);
            struct_fields[i] = .{
                .name = field.name,
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
                .fields = &struct_fields,
                .decls = &[_]std.builtin.Type.Declaration{},
                .is_tuple = false,
            },
        });
    }
}

fn TupleView(
    comptime Index: type,
    comptime scheme: []const u8,
    comptime fields: []const definition.FieldType,
) type {
    comptime {
        var field_types: [fields.len]type = undefined;
        for (fields, 0..) |field, i| {
            field_types[i] = FieldTypeView(Index, scheme, field);
        }
        return Tuple(field_types);
    }
}

fn UnionView(
    comptime Index: type,
    comptime scheme: []const u8,
    comptime fields: []const definition.FieldType.UnionField,
) type {
    comptime {
        var enum_fields: [fields.len]std.builtin.Type.EnumField = undefined;
        var union_fields: [fields.len]std.builtin.Type.UnionField = undefined;
        for (fields, 0..) |field, i| {
            enum_fields[i] = .{
                .name = field.name,
                .value = i,
            };

            const FieldType = FieldTypeView(Index, scheme, field.type);
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
}

fn EnumView(comptime fields: []const definition.FieldType.EnumField) type {
    comptime {
        var enum_fields: [fields.len]std.builtin.EnumField = undefined;
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
}

fn Read(comptime T: type) type {
    return struct {
        value: T,
        bytes: []const u8,
    };
}

fn readObject(
    comptime Index: type,
    comptime scheme: []const u8,
    comptime name: []const u8,
    index: *Index,
    bytes: []const u8,
) ObjectView(Index, scheme, name) {
    const View = ObjectView(Index, scheme, name);
    const info = comptime Index.objInfo(scheme, name);

    const read_version = readNum(u16, bytes);
    const version = read_version.value;
    const read_bytes = read_version.bytes;
    if (version >= info.versions.len) {
        return @unionInit(View, "unknown", undefined);
    }

    const IntTagEnum = IndexEnum(info.versions.len);
    const VerTagEnum = VersionEnum(info.versions.len);
    switch (@intToEnum(IntTagEnum, version)) {
        inline else => |val| {
            const field = info.versions[@enumToInt(val)];

            const ver = @intToEnum(VerTagEnum, @enumToInt(val));
            var view = @unionInit(View, @tagName(ver), undefined);
            const FieldType = @TypeOf(@field(view, @tagName(ver)));

            const read_field = readFieldType(
                FieldType,
                field,
                if (comptime fieldTypeNeedsIndex(field)) index else undefined,
                read_bytes,
            );
            @field(view, @tagName(ver)) = read_field.value;

            return view;
        },
    }
}

fn readFieldType(
    comptime FieldType: type,
    comptime info: definition.FieldType,
    index: anytype,
    bytes: []const u8,
) Read(FieldType) {
    return switch (info) {
        .Void => {},
        .Bool => readBool(bytes),
        .Int, .Float => readNum(FieldType, bytes),
        .Optional => |child_info| readOptional(FieldType, child_info.*, index, bytes),
        .Ref => readRef(FieldType, index, bytes[0..@sizeOf(u64)]),
        .Array => |array_info| readArray(FieldType, array_info, index, bytes),
        .List => |child_info| readList(FieldType, child_info.*, index, bytes),
        .Map => |map_info| readMap(FieldType, map_info, index, bytes),
        .String => readString(bytes),
        .Struct => |fields| readStruct(FieldType, fields, index, bytes),
        .Tuple => |fields| readTuple(FieldType, fields, index, bytes),
        .Union => |fields| readUnion(FieldType, fields, index, bytes),
        .Enum => |fields| readEnum(FieldType, fields, bytes),
    };
}

fn readBool(bytes: []const u8) Read(bool) {
    return .{
        .value = switch (bytes[0]) {
            0 => false,
            1 => true,
            else => @panic("invalid bytes"),
        },
        .bytes = bytes[1..],
    };
}

fn readNum(comptime Num: type, bytes: []const u8) Read(Num) {
    const size = @sizeOf(Num);
    const ptr = @ptrCast(*const Num, @alignCast(@alignOf(Num), bytes.ptr));
    return .{
        .value = ptr.*,
        .bytes = bytes[size..],
    };
}

fn readOptional(
    comptime Optional: type,
    comptime child_info: definition.FieldType,
    index: anytype,
    bytes: []const u8,
) Read(Optional) {
    const read_opt = readNum(u8, bytes);
    switch (read_opt.value) {
        0 => {
            return .{
                .value = null,
                .bytes = read_opt.bytes,
            };
        },
        1 => {
            const Child = @typeInfo(Optional).Optional.child;
            const read_child = readFieldType(Child, child_info, index, read_opt.bytes);
            return .{
                .value = read_child.value,
                .bytes = read_child.bytes,
            };
        },
        else => @panic("invalid bytes when reading optional"),
    }
}

fn readRef(
    comptime View: type,
    index: anytype,
    bytes: []const u8,
) Read(View) {
    const read_id = readNum(u64, bytes);
    return .{
        .value = View{
            .index = index,
            .id = read_id.value,
        },
        .bytes = read_id.bytes,
    };
}

fn readArray(
    comptime View: type,
    comptime info: definition.FieldType.Array,
    index: anytype,
    bytes: []const u8,
) Read(View) {
    const child_size = comptime fieldTypeSize(info.child.*);

    if (info.len > 0) {
        return .{
            .value = View{
                .index = index,
                .ends = undefined,
                .bytes = undefined,
            },
            .bytes = bytes,
        };
    }

    var ends: []const usize = undefined;
    var start: usize = 0;
    var end: usize = 0;
    if (child_size) |cs| {
        end = info.len * cs;
    } else {
        ends.ptr = @ptrCast([*]const usize, @alignCast(@alignOf(usize), bytes.ptr));
        ends.len = info.len;

        start = @sizeOf(usize) * info.len;
        end = start + ends[info.len - 1];
    }

    return .{
        .value = View{
            .index = index,
            .ends = ends,
            .bytes = bytes[start..end],
        },
        .bytes = bytes[end..],
    };
}

fn readList(
    comptime View: type,
    comptime child_info: definition.FieldType,
    index: anytype,
    bytes: []const u8,
) Read(View) {
    const read_len = readNum(usize, bytes);
    const len = read_len.value;
    const read_bytes = read_len.bytes;

    var ends: []const usize = undefined;
    var start: usize = 0;
    var end: usize = 0;
    if (len > 0) {
        if (comptime fieldTypeSize(child_info)) |child_size| {
            end = child_size * len;
        } else {
            ends.ptr = @ptrCast([*]const usize, @alignCast(@alignOf(usize), read_bytes.ptr));
            ends.len = len;
            start = (@sizeOf(usize) * len);
            end = start + ends[len - 1];
        }
    }

    return .{
        .value = View{
            .index = index,
            .len = len,
            .ends = ends,
            .bytes = read_bytes[start..end],
        },
        .bytes = read_bytes[end..],
    };
}

fn readMap(
    comptime View: type,
    comptime info: definition.FieldType.Map,
    index: anytype,
    bytes: []const u8,
) Read(View) {
    const read_len = readNum(usize, bytes);
    const len = read_len.value;
    const read_bytes = read_len.bytes;

    var ends: []const usize = undefined;
    var start: usize = 0;
    var end: usize = 0;
    if (len > 0) {
        const key_size = comptime fieldTypeSize(info.key.*);
        const value_size = comptime fieldTypeSize(info.value.*);

        if (key_size != null and value_size != null) {
            end = (key_size.? + value_size.?) * len;
        } else {
            ends.ptr = @ptrCast([*]const usize, @alignCast(@alignOf(usize), read_bytes.ptr));

            if (key_size != null or value_size != null) {
                ends.len = len;
                start = @sizeOf(usize) * len;
                end = if (key_size != null)
                    ends[len - 1]
                else
                    ends[len - 1] + value_size.?;
            } else {
                ends.len = len * 2;
                start = @sizeOf(usize) * len * 2;
                end = ends[len - 1];
            }
            end += start;
        }
    }

    return .{
        .value = View{
            .index = index,
            .len = len,
            .ends = ends,
            .bytes = read_bytes[start..end],
        },
        .bytes = read_bytes[end..],
    };
}

fn readString(bytes: []const u8) Read([]const u8) {
    const read_len = readNum(usize, bytes);
    const len = read_len.len;
    const read_bytes = read_len.bytes;
    return .{
        .value = read_bytes[0..len],
        .bytes = read_bytes[len..],
    };
}

fn readStruct(
    comptime View: type,
    comptime fields: []const definition.FieldType.StructField,
    index: anytype,
    bytes: []const u8,
) Read(View) {
    var read_bytes = bytes;
    var view: View = undefined;
    inline for (fields) |field| {
        const FieldType = @TypeOf(@field(view, field.name));
        const read_field = readFieldType(FieldType, field.type, index, read_bytes);
        @field(view, field.name) = read_field.value;
        read_bytes = read_field.bytes;
    }
    return .{
        .value = view,
        .bytes = read_bytes,
    };
}

fn readTuple(
    comptime View: type,
    comptime fields: []const definition.FieldType,
    index: anytype,
    bytes: []const u8,
) Read(View) {
    var read_bytes = bytes;
    var view: View = undefined;
    inline for (fields, 0..) |field, i| {
        const FieldType = @TypeOf(view[i]);
        const read_field = readFieldType(FieldType, field, index, read_bytes);
        view[i] = read_field.value;
        read_bytes = read_field.bytes;
    }
    return .{
        .value = view,
        .bytes = read_bytes,
    };
}

fn readUnion(
    comptime View: type,
    comptime fields: []const definition.FieldType.UnionField,
    index: anytype,
    bytes: []const u8,
) Read(View) {
    const Tag = std.meta.Tag(View);
    const read_tag = readNum(usize, bytes);
    const tag_value = read_tag.value;
    const read_bytes = read_tag.bytes;

    if (tag_value >= fields.len) {
        @panic("invalid bytes when reading union tag");
    }

    switch (@intToEnum(Tag, tag_value)) {
        inline else => |val| {
            const field = fields[@enumToInt(val)];

            var view = @unionInit(View, field.name, undefined);
            const FieldType = @TypeOf(@field(view, field.name));

            const read_field = readFieldType(
                FieldType,
                field.type,
                index,
                read_bytes,
            );
            @field(view, field.name) = read_field.value;

            return .{
                .value = view,
                .bytes = read_field.bytes,
            };
        },
    }
}

fn readEnum(
    comptime View: type,
    comptime fields: []const definition.FieldType.EnumField,
    bytes: []const u8,
) Read(View) {
    const read_int = readNum(usize, bytes);

    if (read_int.value >= fields.len) {
        @panic("invalid bytes when reading enum");
    }

    return .{
        .value = @intToEnum(View, read_int.value),
        .bytes = read_int.bytes,
    };
}

pub fn fieldTypeSize(info: definition.FieldType) ?usize {
    return switch (info) {
        .Void => 0,
        .Bool => 1,
        .Int => |int_info| @sizeOf(@Type(.{ .Int = int_info })),
        .Float => |float_info| @sizeOf(@Type(.{ .Float = float_info })),
        .Optional => |child_info| if (fieldTypeSize(child_info.*)) |child_size|
            1 + child_size
        else
            null,
        .Ref => @sizeOf(u64),
        .Array => |array_info| if (fieldTypeSize(array_info.child.*)) |child_size|
            child_size * array_info.len
        else
            null,
        .List, .Map, .String => null,
        .Struct => |fields| fieldsSize(fields),
        .Tuple => |fields| fieldsSize(fields),
        .Union => |fields| fieldsSize(fields),
        .Enum => @sizeOf(usize),
    };
}

fn fieldsSize(fields: anytype) ?usize {
    var size: usize = 0;
    for (fields) |field| {
        const field_type = if (@hasField(@TypeOf(field), "type"))
            field.type
        else
            field;

        size += fieldTypeSize(field_type) orelse return null;
    }
    return size;
}

pub fn fieldTypeNeedsIndex(info: definition.FieldType) bool {
    return switch (info) {
        .Void, .Bool, .Int, .Float, .String, .Enum => false,
        .Optional, .List => |child_info| fieldTypeNeedsIndex(child_info.*),
        .Ref => true,
        .Array => |array_info| fieldTypeNeedsIndex(array_info.child.*),
        .Map => |map_info| fieldTypeNeedsIndex(map_info.key.*) or fieldTypeNeedsIndex(map_info.value.*),
        .Struct => |fields| fieldsNeedIndex(fields),
        .Tuple => |fields| fieldsNeedIndex(fields),
        .Union => |fields| fieldsNeedIndex(fields),
    };
}

fn fieldsNeedIndex(fields: anytype) bool {
    for (fields) |field| {
        const field_type = if (@hasField(@TypeOf(field), "type"))
            field.type
        else
            field;

        if (fieldTypeNeedsIndex(field_type)) {
            return true;
        }
    }
    return false;
}
