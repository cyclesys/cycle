const std = @import("std");
const define = @import("../define.zig");
const definition = @import("../definition.zig");
const serde = @import("../serde.zig");
const super = @import("../object.zig");
const SharedMem = @import("../SharedMem.zig");

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
                    object_slot_types[ii] = MemMap;
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

                    for (sch.objects) |info| {
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
                        for (sch.objects, 0..) |obj, ii| {
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

        const MemMap = std.AutoHashMap(u64, SharedMem);
        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            var slots: Slots = undefined;
            inline for (schemes, 0..) |scheme, i| {
                const SchemeSlot = @typeInfo(Slots).Struct.fields[i].type;
                var slot: SchemeSlot = undefined;
                inline for (0..scheme.objects.len) |ii| {
                    slot[ii] = MemMap.init(allocator);
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

        pub fn put(self: *Self, obj: super.Object) Error!void {
            var old_mem = try self.putMem(obj);
            if (old_mem) |mem| {
                mem.deinit();
            }
        }

        fn putMem(self: *Self, obj: super.Object) Error!?SharedMem {
            const map = try self.getMap(obj.type);
            const old = try map.fetchPut(@bitCast(u64, obj.id), obj.mem);
            if (old) |kv| {
                return kv.value;
            }
            return null;
        }

        pub fn remove(self: *Self, type_id: super.TypeId, obj_id: super.ObjectId) Error!void {
            const map = try self.getMap(type_id);
            const removed = map.fetchRemove(@bitCast(u64, obj_id));
            if (removed) |kv| {
                kv.value.deinit();
            }
        }

        fn getMap(self: *Self, id: super.TypeId) Error!*MemMap {
            if (id.scheme >= schemes.len) {
                return error.SchemeNotDefined;
            }

            const SchemeEnum = IndexEnum(schemes.len);
            switch (@intToEnum(SchemeEnum, id.scheme)) {
                inline else => |scheme_val| {
                    const scheme_slot = @enumToInt(scheme_val);
                    const scheme = schemes[scheme_slot];
                    if (id.name >= scheme.objects.len) {
                        return error.ObjectNotDefined;
                    }

                    const TypeEnum = IndexEnum(scheme.objects.len);
                    switch (@intToEnum(TypeEnum, id.name)) {
                        inline else => |type_val| {
                            const type_slot = @enumToInt(type_val);
                            return &self.slots[scheme_slot][type_slot];
                        },
                    }
                },
            }
        }

        pub fn get(self: *Self, comptime Obj: type, id: super.ObjectId) ?View(Obj) {
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

        pub fn iterator(self: *Self, comptime Obj: type) Iterator(Obj) {
            const slot = comptime objTypeSlot(Obj);
            const map = &self.slots[slot.scheme][slot.type];
            return .{
                .index = self,
                .iter = map.iterator(),
            };
        }

        pub fn View(comptime Obj: type) type {
            return ObjectView(Self, Obj.scheme.name, Obj.def.name);
        }

        pub fn Iterator(comptime Obj: type) type {
            return ObjectIterator(Self, Obj.scheme.name, Obj.def.name);
        }

        pub fn Entry(comptime Obj: type) type {
            return ObjectIterator(Self, Obj.scheme.name, Obj.def.name).Entry;
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

fn ObjectIterator(comptime Index: type, comptime scheme: []const u8, comptime name: []const u8) type {
    return struct {
        index: *Index,
        iter: Index.MemMap.Iterator,

        const Self = @This();

        pub const Entry = struct {
            id: super.ObjectId,
            view: ObjectView(Index, scheme, name),
        };

        pub fn next(self: *Self) ?Entry {
            if (self.iter.next()) |entry| {
                const id = @bitCast(super.ObjectId, entry.key_ptr.*);

                const mem = entry.value_ptr;
                const view = readObject(Index, scheme, name, self.index, mem.view);

                return .{
                    .id = id,
                    .view = view,
                };
            }
            return null;
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
        const tag_name = verFieldName(i + 1);
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
                .name = verFieldName(i + 1),
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
        ends: []align(1) const usize,
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

            if (comptime fieldTypeSize(info.child.*)) |child_size| {
                const start = child_size * idx;
                const end = start + child_size;
                return readFieldType(ChildView, info.child.*, self.index, self.bytes[start..end]).value;
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
        ends: []align(1) const usize,
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
    ends: []align(1) const usize,
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
        ends: []align(1) const usize,
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
                key_start = (key_size.? + value_size.?) * idx;
                key_end = key_start + key_size.?;
                value_end = key_end + value_size.?;
            } else if (key_size) |ks| {
                key_start = if (idx == 0) 0 else self.ends[idx - 1];
                key_end = key_start + ks;
                value_end = self.ends[idx];
            } else if (value_size) |vs| {
                key_start = if (idx == 0) 0 else (self.ends[idx - 1] + vs);
                key_end = self.ends[idx];
                value_end = key_end + vs;
            } else {
                const end_idx = idx * 2;
                key_start = if (end_idx == 0) 0 else self.ends[end_idx - 1];
                key_end = self.ends[end_idx];
                value_end = self.ends[end_idx + 1];
            }

            const key = readFieldType(
                KeyView,
                info.key.*,
                if (comptime fieldTypeNeedsIndex(info.key.*)) self.index else undefined,
                self.bytes[key_start..key_end],
            ).value;

            const value = readFieldType(
                ValueView,
                info.value.*,
                if (comptime fieldTypeNeedsIndex(info.value.*)) self.index else undefined,
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

    const TagIndex = IndexEnum(info.versions.len);
    // contains `info.versions.len + 1` fields, hence the need for `TagIndex`.
    const VersionTag = VersionEnum(info.versions.len);
    switch (@intToEnum(TagIndex, version)) {
        inline else => |tag_idx| {
            // this would index out of bounds if converting a `VerTag`, hence
            // the need for `TagIndex`.
            const field = info.versions[@enumToInt(tag_idx)];

            // convert the `TagIndex` value to the actual tag value
            const tag = @intToEnum(VersionTag, @enumToInt(tag_idx));

            var view = @unionInit(View, @tagName(tag), undefined);
            const FieldType = @TypeOf(@field(view, @tagName(tag)));

            const read_field = readFieldType(
                FieldType,
                field,
                if (comptime fieldTypeNeedsIndex(field)) index else undefined,
                read_bytes,
            );
            @field(view, @tagName(tag)) = read_field.value;

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
        .Array => |array_info| blk: {
            break :blk readArray(FieldType, array_info, index, bytes);
        },
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
    const ptr = @ptrCast(*align(1) const Num, bytes);
    return .{
        .value = ptr.*,
        .bytes = bytes[@sizeOf(Num)..],
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
            const read_child = readFieldType(
                Child,
                child_info,
                index,
                read_opt.bytes,
            );
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
    if (info.len == 0) {
        return .{
            .value = View{
                .index = index,
                .ends = undefined,
                .bytes = undefined,
            },
            .bytes = bytes,
        };
    }

    var ends: []align(1) const usize = undefined;
    var start: usize = 0;
    var end: usize = 0;
    if (comptime fieldTypeSize(info.child.*)) |child_size| {
        end = info.len * child_size;
    } else {
        ends.ptr = @ptrCast([*]align(1) const usize, bytes.ptr);
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

    var ends: []align(1) const usize = undefined;
    var start: usize = 0;
    var end: usize = 0;
    if (len > 0) {
        if (comptime fieldTypeSize(child_info)) |child_size| {
            end = child_size * len;
        } else {
            ends.ptr = @ptrCast([*]align(1) const usize, read_bytes.ptr);
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

    var ends: []align(1) const usize = undefined;
    var start: usize = 0;
    var end: usize = 0;
    if (len > 0) {
        const key_size = comptime fieldTypeSize(info.key.*);
        const value_size = comptime fieldTypeSize(info.value.*);

        if (key_size != null and value_size != null) {
            end = (key_size.? + value_size.?) * len;
        } else {
            ends.ptr = @ptrCast([*]align(1) const usize, read_bytes.ptr);

            if (key_size != null or value_size != null) {
                ends.len = len;
                start = @sizeOf(usize) * len;
                end = if (key_size != null)
                    ends[len - 1]
                else
                    ends[len - 1] + value_size.?;
            } else {
                ends.len = len * 2;
                start = @sizeOf(usize) * ends.len;
                end = ends[ends.len - 1];
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
    const len = read_len.value;
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
        const read_field = readFieldType(
            FieldType,
            field.type,
            if (comptime fieldTypeNeedsIndex(field.type)) index else undefined,
            read_bytes,
        );
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
        const read_field = readFieldType(
            FieldType,
            field,
            if (comptime fieldTypeNeedsIndex(field)) index else undefined,
            read_bytes,
        );
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
                if (comptime fieldTypeNeedsIndex(field.type)) index else undefined,
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

fn fieldTypeSize(comptime info: definition.FieldType) ?usize {
    comptime {
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
}

fn fieldsSize(fields: anytype) ?usize {
    comptime {
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
}

fn fieldTypeNeedsIndex(comptime info: definition.FieldType) bool {
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

test "bool view" {
    const Scheme = testScheme(bool);
    var index = try testIndex(Scheme, bool, true);
    defer deinitTestIndex(&index, null);

    const view = index.get(Scheme("Obj"), test_obj).?;

    try std.testing.expectEqual(true, view.v1);
}

test "int view" {
    const Scheme = testScheme(u24);
    var index = try testIndex(Scheme, u24, 19810);
    defer deinitTestIndex(&index, null);

    const view = index.get(Scheme("Obj"), test_obj).?;
    try std.testing.expectEqual(@as(u32, 19810), view.v1);
}

test "float view" {
    const Scheme = testScheme(f32);
    var index = try testIndex(Scheme, f32, 1908.12);
    defer deinitTestIndex(&index, null);

    const view = index.get(Scheme("Obj"), test_obj).?;
    try std.testing.expectEqual(@as(f32, 1908.12), view.v1);
}

test "optional view with some" {
    const Scheme = testScheme(?bool);
    var index = try testIndex(Scheme, ?bool, @as(?bool, true));
    defer deinitTestIndex(&index, null);

    const view = index.get(Scheme("Obj"), test_obj).?;
    try std.testing.expectEqual(@as(?bool, true), view.v1);
}

test "optional view with null" {
    const Scheme = testScheme(?bool);
    var index = try testIndex(Scheme, ?bool, @as(?bool, null));
    defer deinitTestIndex(&index, null);

    const view = index.get(Scheme("Obj"), test_obj).?;
    try std.testing.expectEqual(@as(?bool, null), view.v1);
}

test "ref view" {
    const Scheme = testScheme(define.This("Obj"));
    const ref_id = super.ObjectId{ .scheme = 0, .source = 0, .name = 1 };
    var index = try testIndex(
        Scheme,
        define.This("Obj"),
        ref_id,
    );
    defer deinitTestIndex(&index, &.{ref_id});

    const ref = index.get(Scheme("Obj"), test_obj).?.v1;
    try std.testing.expectEqual(@bitCast(u64, ref_id), ref.id);

    var ref_view = ref.read();
    try std.testing.expect(ref_view == null);

    try putObj(&index, ref_id, u64, @bitCast(u64, test_obj), 0);
    ref_view = ref.read();
    try std.testing.expect(ref_view != null);
    try std.testing.expectEqual(@bitCast(u64, test_obj), ref_view.?.v1.id);
}

test "string view" {
    const Scheme = testScheme(define.String);
    var index = try testIndex(Scheme, define.String, "string view");
    defer deinitTestIndex(&index, null);

    const view = index.get(Scheme("Obj"), test_obj).?;
    try std.testing.expectEqualDeep(@as([]const u8, "string view"), view.v1);
}

test "array view with sized child" {
    const Scheme = testScheme(define.Array(2, u8));
    const values = [_]u8{ 10, 20 };
    var index = try testIndex(Scheme, define.Array(2, u8), values);
    defer deinitTestIndex(&index, null);

    const view = index.get(Scheme("Obj"), test_obj).?;
    try std.testing.expectEqual(values[0], view.v1.read(0));
    try std.testing.expectEqual(values[1], view.v1.read(1));
}

test "array view with unsized child" {
    const Scheme = testScheme(define.Array(2, define.String));
    const values = [_][]const u8{ "Hello", "world!" };

    var index = try testIndex(Scheme, define.Array(2, define.String), values);
    defer deinitTestIndex(&index, null);

    const view = index.get(Scheme("Obj"), test_obj).?;
    try std.testing.expectEqualDeep(values[0], view.v1.read(0));
    try std.testing.expectEqualDeep(values[1], view.v1.read(1));
}

test "list view with sized child" {
    const Scheme = testScheme(define.List(u8));
    const values = [_]u8{ 10, 20 };

    var index = try testIndex(Scheme, define.List(u8), values);
    defer deinitTestIndex(&index, null);

    const view = index.get(Scheme("Obj"), test_obj).?;
    try std.testing.expectEqual(values[0], view.v1.read(0));
    try std.testing.expectEqual(values[1], view.v1.read(1));
}

test "list view with unsized child" {
    const Scheme = testScheme(define.List(define.String));
    const values = [_][]const u8{ "Hello", "world", "!" };

    var index = try testIndex(Scheme, define.List(define.String), values);
    defer deinitTestIndex(&index, null);

    const view = index.get(Scheme("Obj"), test_obj).?;
    try std.testing.expectEqualDeep(values[0], view.v1.read(0));
    try std.testing.expectEqualDeep(values[1], view.v1.read(1));
    try std.testing.expectEqualDeep(values[2], view.v1.read(2));
}

test "map view with sized key and value" {
    const Scheme = testScheme(define.Map(u8, u8));
    const values = [_]struct { u8, u8 }{ .{ 10, 20 }, .{ 30, 40 } };

    var index = try testIndex(Scheme, define.Map(u8, u8), values);
    defer deinitTestIndex(&index, null);

    const view = index.get(Scheme("Obj"), test_obj).?;
    try std.testing.expectEqual(values[0][0], view.v1.read(0).key);
    try std.testing.expectEqual(values[0][1], view.v1.read(0).value);
    try std.testing.expectEqual(values[1][0], view.v1.read(1).key);
    try std.testing.expectEqual(values[1][1], view.v1.read(1).value);
}

test "map view with sized key" {
    const Scheme = testScheme(define.Map(u8, define.String));
    const values = [_]struct { u8, []const u8 }{ .{ 10, "Hello" }, .{ 30, "world" } };

    var index = try testIndex(Scheme, define.Map(u8, define.String), values);
    defer deinitTestIndex(&index, null);

    const view = index.get(Scheme("Obj"), test_obj).?;
    try std.testing.expectEqual(values[0][0], view.v1.read(0).key);
    try std.testing.expectEqualDeep(values[0][1], view.v1.read(0).value);
    try std.testing.expectEqual(values[1][0], view.v1.read(1).key);
    try std.testing.expectEqualDeep(values[1][1], view.v1.read(1).value);
}

test "map view with sized value" {
    const Scheme = testScheme(define.Map(define.String, u8));
    const values = [_]struct { []const u8, u8 }{ .{ "Hello", 10 }, .{ "world", 30 } };

    var index = try testIndex(Scheme, define.Map(define.String, u8), values);
    defer deinitTestIndex(&index, null);

    const view = index.get(Scheme("Obj"), test_obj).?;
    try std.testing.expectEqualDeep(values[0][0], view.v1.read(0).key);
    try std.testing.expectEqual(values[0][1], view.v1.read(0).value);
    try std.testing.expectEqualDeep(values[1][0], view.v1.read(1).key);
    try std.testing.expectEqual(values[1][1], view.v1.read(1).value);
}

test "map view unsized key and value" {
    const Scheme = testScheme(define.Map(define.String, define.String));
    const values = [_]struct { []const u8, []const u8 }{ .{ "Hello", "cruel" }, .{ "world", "!" } };

    var index = try testIndex(Scheme, define.Map(define.String, define.String), values);
    defer deinitTestIndex(&index, null);

    const view = index.get(Scheme("Obj"), test_obj).?;
    try std.testing.expectEqualDeep(values[0][0], view.v1.read(0).key);
    try std.testing.expectEqualDeep(values[0][1], view.v1.read(0).value);
    try std.testing.expectEqualDeep(values[1][0], view.v1.read(1).key);
    try std.testing.expectEqualDeep(values[1][1], view.v1.read(1).value);
}

test "struct view" {
    const Struct = struct {
        int: u8,
        str: define.String,
        ref: define.This("Obj"),
    };
    const Scheme = testScheme(Struct);

    const value = .{
        .int = @as(u8, 10),
        .str = @as([]const u8, "string"),
        .ref = test_obj,
    };
    var index = try testIndex(Scheme, Struct, value);
    defer deinitTestIndex(&index, null);

    const view = index.get(Scheme("Obj"), test_obj).?;
    try std.testing.expectEqual(value.int, view.v1.int);
    try std.testing.expectEqualDeep(value.str, view.v1.str);
    try std.testing.expectEqual(@bitCast(u64, value.ref), view.v1.ref.id);
}

test "tuple view" {
    const Tup = struct {
        u8,
        define.String,
        define.This("Obj"),
    };
    const Scheme = testScheme(Tup);

    const value = .{
        @as(u8, 10),
        @as([]const u8, "string"),
        test_obj,
    };
    var index = try testIndex(Scheme, Tup, value);
    defer deinitTestIndex(&index, null);

    const view = index.get(Scheme("Obj"), test_obj).?;
    try std.testing.expectEqual(value[0], view.v1[0]);
    try std.testing.expectEqualDeep(value[1], view.v1[1]);
    try std.testing.expectEqual(@bitCast(u64, value[2]), view.v1[2].id);
}

test "union view" {
    const Union = union(enum) {
        Int: u8,
        Str: define.String,
        Ref: define.This("Obj"),
    };
    const Scheme = testScheme(Union);
    const Value = union(enum) {
        Int: u8,
        Str: []const u8,
        Ref: super.ObjectId,
    };

    var value = Value{
        .Int = 10,
    };
    var index = try testIndex(Scheme, Union, value);
    defer deinitTestIndex(&index, null);
    var view = index.get(Scheme("Obj"), test_obj).?;
    try std.testing.expectEqualDeep(@tagName(value), @tagName(view.v1));
    try std.testing.expectEqual(value.Int, view.v1.Int);

    value = Value{
        .Str = "string",
    };
    try putObj(&index, test_obj, Union, value, 0);
    view = index.get(Scheme("Obj"), test_obj).?;
    try std.testing.expectEqualDeep(@tagName(value), @tagName(view.v1));
    try std.testing.expectEqualDeep(value.Str, view.v1.Str);

    value = Value{
        .Ref = test_obj,
    };
    try putObj(&index, test_obj, Union, value, 0);
    view = index.get(Scheme("Obj"), test_obj).?;
    try std.testing.expectEqualDeep(@tagName(value), @tagName(view.v1));
    try std.testing.expectEqualDeep(@bitCast(u64, value.Ref), view.v1.Ref.id);
}

test "enum view" {
    const Enum = enum {
        zero,
        one,
        two,
    };
    const Scheme = testScheme(Enum);

    var index = try testIndex(Scheme, Enum, Enum.two);
    defer deinitTestIndex(&index, null);

    const view = index.get(Scheme("Obj"), test_obj).?;
    try std.testing.expectEqualDeep(@as([]const u8, @tagName(Enum.two)), @tagName(view.v1));
}

test "multiple versions" {
    const Scheme = define.Scheme("Objs", .{
        define.Object("Obj", .{ u8, u16 }),
    });

    var index = try testIndex(Scheme, u8, 10);
    defer deinitTestIndex(&index, null);

    var view = index.get(Scheme("Obj"), test_obj).?;
    try std.testing.expectEqual(@as(u8, 10), view.v1);

    try putObj(&index, test_obj, u16, 20, 1);
    view = index.get(Scheme("Obj"), test_obj).?;
    try std.testing.expectEqual(@as(u16, 20), view.v2);

    try putObj(&index, test_obj, u32, 30, 2);
    view = index.get(Scheme("Obj"), test_obj).?;
    try std.testing.expect(view == .unknown);
}

test "iterator" {
    const Scheme = testScheme(u8);

    var index = try testIndex(Scheme, u8, 0);
    defer deinitTestIndex(&index, null);

    var id = super.ObjectId{
        .scheme = 0,
        .source = 0,
        .name = 1,
    };
    try putObj(&index, id, u8, 1, 0);
    defer deinitObjectMem(&index, .{ .scheme = 0, .source = 0, .name = 1 });

    id.name = 2;
    try putObj(&index, id, u8, 2, 0);
    defer deinitObjectMem(&index, .{ .scheme = 0, .source = 0, .name = 2 });

    id.name = 3;
    try putObj(&index, id, u8, 3, 0);
    defer deinitObjectMem(&index, .{ .scheme = 0, .source = 0, .name = 3 });

    var iter = index.iterator(Scheme("Obj"));
    var len: usize = 0;
    while (iter.next()) |entry| : (len += 1) {
        try std.testing.expectEqual(entry.id, .{ .scheme = 0, .source = 0, .name = entry.view.v1 });
    }
    try std.testing.expectEqual(@as(usize, 4), len);
}

fn testScheme(comptime Type: type) define.SchemeFn {
    return define.Scheme("Objs", .{
        define.Object("Obj", .{Type}),
    });
}

const test_type = super.TypeId{
    .scheme = 0,
    .name = 0,
};

const test_obj = super.ObjectId{
    .scheme = 0,
    .source = 0,
    .name = 0,
};

fn testIndex(comptime Scheme: define.SchemeFn, comptime Type: type, value: anytype) !ObjectIndex(.{Scheme}) {
    const Index = ObjectIndex(.{Scheme});
    var index = Index.init(std.testing.allocator);
    _ = try index.putMem(.{
        .type = test_type,
        .id = test_obj,
        .mem = try createObjMem(Type, value, 0),
    });
    return index;
}

fn deinitTestIndex(index: anytype, extra_objs: ?[]const super.ObjectId) void {
    if (extra_objs) |ids| {
        for (ids) |id| {
            deinitObjectMem(index, id);
        }
    }
    deinitObjectMem(index, test_obj);
    index.deinit();
}

fn putObj(index: anytype, id: super.ObjectId, comptime Type: type, value: anytype, version: u16) !void {
    const old = try index.putMem(.{
        .type = test_type,
        .id = id,
        .mem = try createObjMem(Type, value, version),
    });
    if (old) |mem| {
        std.testing.allocator.free(mem.view);
    }
}

fn createObjMem(comptime Type: type, value: anytype, version: u16) !SharedMem {
    var obj_bytes = std.ArrayList(u8).init(std.testing.allocator);

    _ = try writeNum(u16, version, &obj_bytes);
    _ = try writeFieldType(definition.FieldType.from(Type).?, value, &obj_bytes);

    return SharedMem{
        .handle = undefined,
        .view = @constCast(try obj_bytes.toOwnedSlice()),
    };
}

fn deinitObjectMem(index: anytype, id: super.ObjectId) void {
    const mem = index.getMem("Objs", "Obj", @bitCast(u64, id)).?;
    std.testing.allocator.free(mem.view);
}

fn writeFieldType(comptime info: definition.FieldType, value: anytype, buf: *std.ArrayList(u8)) !usize {
    switch (info) {
        .Void => return 0,
        .Bool => {
            try buf.append(if (value) 1 else 0);
            return 1;
        },
        .Int => |int_info| {
            return writeNum(@Type(.{ .Int = int_info }), value, buf);
        },
        .Float => |float_info| {
            return writeNum(@Type(.{ .Float = float_info }), value, buf);
        },
        .Optional => |child_info| {
            var child_size: usize = 0;
            if (value) |v| {
                try buf.append(1);
                child_size = try writeFieldType(child_info.*, v, buf);
            } else {
                try buf.append(0);
            }
            return 1 + child_size;
        },
        .Ref => {
            return writeNum(u64, @bitCast(u64, value), buf);
        },
        .Array => |array_info| {
            if (comptime fieldTypeSize(array_info.child.*)) |child_size| {
                for (value) |v| {
                    _ = try writeFieldType(array_info.child.*, v, buf);
                }
                return child_size * array_info.len;
            } else {
                var ends: [array_info.len]usize = undefined;
                var data = std.ArrayList(u8).init(buf.allocator);
                defer data.deinit();

                var size: usize = 0;
                for (value, 0..) |v, i| {
                    size += try writeFieldType(array_info.child.*, v, &data);
                    ends[i] = size;
                }

                size += try writeSlice(usize, &ends, buf);
                try buf.appendSlice(data.items);

                return size;
            }
        },
        .List => |child_info| {
            var size = try writeNum(usize, value.len, buf);
            if (comptime fieldTypeSize(child_info.*)) |child_size| {
                for (value) |v| {
                    _ = try writeFieldType(child_info.*, v, buf);
                }
                size += child_size * value.len;
            } else {
                var ends = try std.ArrayList(usize).initCapacity(buf.allocator, value.len);
                defer ends.deinit();

                var data = std.ArrayList(u8).init(buf.allocator);
                defer data.deinit();

                var data_size: usize = 0;
                for (value) |v| {
                    data_size += try writeFieldType(child_info.*, v, &data);
                    try ends.append(data_size);
                }

                size += try writeSlice(usize, ends.items, buf);
                try buf.appendSlice(data.items);
                size += data_size;
            }
            return size;
        },
        .Map => |map_info| {
            var size = try writeNum(usize, value.len, buf);

            const key_size = comptime fieldTypeSize(map_info.key.*);
            const value_size = comptime fieldTypeSize(map_info.value.*);

            if (key_size != null and value_size != null) {
                for (value) |v| {
                    _ = try writeFieldType(map_info.key.*, v[0], buf);
                    _ = try writeFieldType(map_info.value.*, v[1], buf);
                }
                size += key_size.? * value.len;
                size += value_size.? * value.len;
            } else {
                var ends = try std.ArrayList(usize).initCapacity(
                    buf.allocator,
                    value.len * if (key_size != null or value_size != null) 1 else 2,
                );
                defer ends.deinit();

                const initial_capacity = if (key_size) |ks|
                    ks * value.len
                else if (value_size) |vs|
                    vs * value.len
                else
                    0;

                var data = try std.ArrayList(u8).initCapacity(
                    buf.allocator,
                    initial_capacity,
                );
                defer data.deinit();

                var data_size: usize = 0;
                for (value) |v| {
                    data_size += try writeFieldType(map_info.key.*, v[0], &data);
                    if (key_size == null) {
                        try ends.append(data_size);
                    }

                    data_size += try writeFieldType(map_info.value.*, v[1], &data);
                    if (value_size == null) {
                        try ends.append(data_size);
                    }
                }

                size += try writeSlice(usize, ends.items, buf);
                try buf.appendSlice(data.items);
                size += data_size;
            }

            return size;
        },
        .String => {
            var size = try writeNum(usize, value.len, buf);
            try buf.appendSlice(value);
            size += value.len;
            return size;
        },
        .Struct => |fields| {
            var size: usize = 0;
            inline for (fields) |field| {
                size += try writeFieldType(field.type, @field(value, field.name), buf);
            }
            return size;
        },
        .Tuple => |fields| {
            var size: usize = 0;
            inline for (fields, 0..) |field, i| {
                size += try writeFieldType(field, value[i], buf);
            }
            return size;
        },
        .Union => |fields| {
            switch (value) {
                inline else => |val, tag| {
                    const field = fields[@enumToInt(tag)];
                    var size = try writeNum(usize, @enumToInt(tag), buf);
                    size += try writeFieldType(field.type, val, buf);
                    return size;
                },
            }
        },
        .Enum => {
            return writeNum(usize, @enumToInt(value), buf);
        },
    }
}

fn writeNum(comptime Num: type, value: Num, buf: *std.ArrayList(u8)) !usize {
    var slice: []const u8 = undefined;
    slice.ptr = @ptrCast([*]const u8, &value);
    slice.len = @sizeOf(Num);
    try buf.appendSlice(slice);
    return @sizeOf(Num);
}

fn writeSlice(comptime Child: type, slice: []const Child, buf: *std.ArrayList(u8)) !usize {
    var bytes: []const u8 = undefined;
    bytes.ptr = @ptrCast([*]const u8, @alignCast(@alignOf(u8), slice.ptr));
    bytes.len = @sizeOf(Child) * slice.len;
    try buf.appendSlice(bytes);
    return bytes.len;
}
