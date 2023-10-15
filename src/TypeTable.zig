const std = @import("std");
const lib = @import("lib");

allocator: std.mem.Allocator,
schemes: std.StringHashMap(SchemeObjects),

const SchemeObjects = std.StringHashMap(ObjectTypes);
const ObjectTypes = std.ArrayList(lib.def.Type);
const Self = @This();

pub fn init(allocator: std.mem.Allocator) Self {
    return Self{
        .allocator = allocator,
        .schemes = std.StringHashMap(SchemeObjects).init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    var scheme_iter = self.schemes.iterator();
    while (scheme_iter.next()) |scheme| {
        var object_iter = scheme.value_ptr.iterator();
        while (object_iter.next()) |object| {
            for (object.value_ptr.items) |t| {
                destroyType(self.allocator, t);
            }
            object.value_ptr.deinit();
            self.allocator.free(object.key_ptr.*);
        }
        scheme.value_ptr.deinit();
        self.allocator.free(scheme.key_ptr.*);
    }
    self.schemes.deinit();
    self.* = undefined;
}

pub fn update(self: *Self, scheme_name: []const u8, object_name: []const u8, view: lib.chan.View(lib.def.Type)) !usize {
    const scheme_kv = try self.schemes.getOrPut(scheme_name);
    if (!scheme_kv.found_existing) {
        scheme_kv.key_ptr.* = try self.allocator.dupe(u8, scheme_name);
        scheme_kv.value_ptr.* = SchemeObjects.init(self.allocator);
    }
    const scheme_objects: *SchemeObjects = scheme_kv.value_ptr;

    const object_kv = try scheme_objects.getOrPut(object_name);
    if (!object_kv.found_existing) {
        object_kv.key_ptr.* = try self.allocator.dupe(u8, object_name);
        object_kv.value_ptr.* = ObjectTypes.init(self.allocator);
    }
    const object_types: *ObjectTypes = object_kv.value_ptr;

    return indexOf(object_types.items, view) orelse {
        const t = try createType(self.allocator, view);
        try object_types.append(t);
        return object_types.items.len - 1;
    };
}

fn indexOf(types: []const lib.def.Type, view: lib.chan.View(lib.def.Type)) ?usize {
    for (types, 0..) |t, i| {
        if (typeEql(t, view)) return i;
    }
    return null;
}

fn typeEql(t: lib.def.Type, view: lib.chan.View(lib.def.Type)) bool {
    const tag = view.tag();
    if (t != tag) {
        return false;
    }

    return switch (t) {
        .Void, .Bool, .String => true,
        .Int => |left| blk: {
            const right = view.value(.Int);
            break :blk left.signedness == right.field(.signedness) and
                left.bits == right.field(.bits);
        },
        .Float => |left| blk: {
            const right = view.value(.Float);
            break :blk left.bits == right.field(.bits);
        },
        .Optional => |left| blk: {
            const right = view.value(.Optional);
            break :blk typeEql(left.child.*, right.field(.child));
        },
        .Array => |left| blk: {
            const right = view.value(.Array);
            break :blk left.len == right.field(.len) and
                typeEql(left.child.*, right.field(.child));
        },
        .List => |left| blk: {
            const right = view.value(.List);
            break :blk typeEql(left.child.*, right.field(.child));
        },
        .Map => |left| blk: {
            const right = view.value(.Map);
            break :blk typeEql(left.key.*, right.field(.key)) and
                typeEql(left.value.*, right.field(.value));
        },
        .Struct => |left| blk: {
            const right = view.value(.Struct);
            const right_fields = right.field(.fields);
            break :blk left.fields.len == right_fields.len() and
                // TODO: should struct equivalence be field-order independent?
                for (left.fields, 0..) |lf, i|
            {
                const rf = right_fields.elem(i);
                if (!std.mem.eql(u8, lf.name, rf.field(.name)) or
                    !typeEql(lf.type, rf.field(.type)))
                {
                    break false;
                }
            } else true;
        },
        .Tuple => |left| blk: {
            const right = view.value(.Tuple);
            const right_fields = right.field(.fields);
            break :blk left.fields.len == right_fields.len() and
                for (left.fields, 0..) |lf, i|
            {
                const rf = right_fields.elem(i);
                if (!typeEql(lf, rf)) {
                    break false;
                }
            } else true;
        },
        .Union => |left| blk: {
            const right = view.value(.Union);
            const right_fields = right.field(.fields);
            break :blk left.fields.len == right_fields.len() and
                // TODO: should union equivalence be field-order independent?
                for (left.fields, 0..) |lf, i|
            {
                const rf = right_fields.elem(i);
                if (!std.mem.eql(u8, lf.name, rf.field(.name)) or
                    !typeEql(lf.type, rf.field(.type)))
                {
                    break false;
                }
            } else true;
        },
        .Enum => |left| blk: {
            const right = view.value(.Enum);
            const right_fields = right.field(.fields);
            break :blk left.fields.len == right_fields.len() and
                for (left.fields, 0..) |lf, i|
            {
                const rf = right_fields.elem(i);
                if (!std.mem.eql(u8, lf.name, rf.field(.name))) {
                    break false;
                }
            } else true;
        },
        .Ref => |left| blk: {
            const right = view.value(.Ref);
            const rt = right.tag();
            break :blk left == rt and switch (left) {
                .Internal => |li| std.mem.eql(u8, li.name, right.value(.Internal).field(.name)),
                .External => |le| std.mem.eql(u8, le.scheme, right.value(.External).field(.scheme)) and
                    std.mem.eql(u8, le.name, right.value(.External).field(.name)),
            };
        },
    };
}

fn createType(allocator: std.mem.Allocator, view: lib.chan.View(lib.def.Type)) std.mem.Allocator.Error!lib.def.Type {
    const tag = view.tag();
    return switch (tag) {
        .Void => .Void,
        .Bool => .Bool,
        .String => .String,
        .Int => blk: {
            const value = view.value(.Int);
            break :blk lib.def.Type{
                .Int = lib.def.Type.Int{
                    .signedness = value.field(.signedness),
                    .bits = value.field(.bits),
                },
            };
        },
        .Float => blk: {
            const value = view.value(.Float);
            break :blk lib.def.Type{
                .Float = lib.def.Type.Float{
                    .bits = value.field(.bits),
                },
            };
        },
        .Optional => blk: {
            const value = view.value(.Optional);
            break :blk lib.def.Type{
                .Optional = lib.def.Type.Optional{
                    .child = try allocType(allocator, value.field(.child)),
                },
            };
        },
        .Array => blk: {
            const value = view.value(.Array);
            break :blk lib.def.Type{
                .Array = lib.def.Type.Array{
                    .len = value.field(.len),
                    .child = try allocType(allocator, value.field(.child)),
                },
            };
        },
        .List => blk: {
            const value = view.value(.List);
            break :blk lib.def.Type{
                .List = lib.def.Type.List{
                    .child = try allocType(allocator, value.field(.child)),
                },
            };
        },
        .Map => blk: {
            const value = view.value(.Map);
            break :blk lib.def.Type{
                .Map = lib.def.Type.Map{
                    .key = try allocType(allocator, value.field(.key)),
                    .value = try allocType(allocator, value.field(.value)),
                },
            };
        },
        .Struct => blk: {
            const value = view.value(.Struct);
            const fields_view = value.field(.fields);
            const fields = try allocator.alloc(lib.def.Type.Struct.Field, fields_view.len());
            for (0..fields_view.len()) |i| {
                const field = fields_view.elem(i);
                fields[i] = lib.def.Type.Struct.Field{
                    .name = try allocator.dupe(u8, field.field(.name)),
                    .type = try createType(allocator, field.field(.type)),
                };
            }
            break :blk lib.def.Type{
                .Struct = lib.def.Type.Struct{
                    .fields = fields,
                },
            };
        },
        .Tuple => blk: {
            const value = view.value(.Tuple);
            const fields_view = value.field(.fields);
            const fields = try allocator.alloc(lib.def.Type, fields_view.len());
            for (0..fields_view.len()) |i| {
                fields[i] = try createType(allocator, fields_view.elem(i));
            }
            break :blk lib.def.Type{
                .Tuple = lib.def.Type.Tuple{
                    .fields = fields,
                },
            };
        },
        .Union => blk: {
            const value = view.value(.Union);
            const fields_view = value.field(.fields);
            const fields = try allocator.alloc(lib.def.Type.Union.Field, fields_view.len());
            for (0..fields_view.len()) |i| {
                const field = fields_view.elem(i);
                fields[i] = lib.def.Type.Union.Field{
                    .name = try allocator.dupe(u8, field.field(.name)),
                    .type = try createType(allocator, field.field(.type)),
                };
            }
            break :blk lib.def.Type{
                .Union = lib.def.Type.Union{
                    .fields = fields,
                },
            };
        },
        .Enum => blk: {
            const value = view.value(.Union);
            const fields_view = value.field(.fields);
            const fields = try allocator.alloc(lib.def.Type.Enum.Field, fields_view.len());
            for (0..fields_view.len()) |i| {
                const field = fields_view.elem(i);
                fields[i] = lib.def.Type.Enum.Field{
                    .name = try allocator.dupe(u8, field.field(.name)),
                };
            }
            break :blk lib.def.Type{
                .Enum = lib.def.Type.Enum{
                    .fields = fields,
                },
            };
        },
        .Ref => blk: {
            const value = view.value(.Ref);
            break :blk lib.def.Type{
                .Ref = switch (value.tag()) {
                    .Internal => lib.def.Type.Ref{
                        .Internal = lib.def.Type.Ref.Internal{
                            .name = try allocator.dupe(u8, value.value(.Internal).field(.name)),
                        },
                    },
                    .External => lib.def.Type.Ref{
                        .External = lib.def.Type.Ref.External{
                            .scheme = try allocator.dupe(u8, value.value(.External).field(.scheme)),
                            .name = try allocator.dupe(u8, value.value(.External).field(.name)),
                        },
                    },
                },
            };
        },
    };
}

fn allocType(allocator: std.mem.Allocator, view: lib.chan.View(lib.def.Type)) !*lib.def.Type {
    const child = try allocator.create(lib.def.Type);
    child.* = try createType(allocator, view);
    return child;
}

fn destroyType(allocator: std.mem.Allocator, t: lib.def.Type) void {
    switch (t) {
        // non-allocating
        .Void, .Bool, .String, .Int, .Float => {},
        .Optional => |info| {
            destroyType(allocator, info.child.*);
            allocator.destroy(info.child);
        },
        .Array => |info| {
            destroyType(allocator, info.child.*);
            allocator.destroy(info.child);
        },
        .List => |info| {
            destroyType(allocator, info.child.*);
            allocator.destroy(info.child);
        },
        .Map => |info| {
            destroyType(allocator, info.key.*);
            allocator.destroy(info.key);

            destroyType(allocator, info.value.*);
            allocator.destroy(info.value);
        },
        .Struct => |info| {
            for (info.fields) |f| {
                allocator.free(f.name);
                destroyType(allocator, f.type);
            }
            allocator.free(info.fields);
        },
        .Tuple => |info| {
            for (info.fields) |f| {
                destroyType(allocator, f);
            }
            allocator.free(info.fields);
        },
        .Union => |info| {
            for (info.fields) |f| {
                allocator.free(f.name);
                destroyType(allocator, f.type);
            }
            allocator.free(info.fields);
        },
        .Enum => |info| {
            for (info.fields) |f| {
                allocator.free(f.name);
            }
            allocator.free(info.fields);
        },
        .Ref => |info| {
            switch (info) {
                .Internal => |ref| {
                    allocator.free(ref.name);
                },
                .External => |ref| {
                    allocator.free(ref.scheme);
                    allocator.free(ref.name);
                },
            }
        },
    }
}

const TestScheme = lib.def.Scheme("scheme", .{
    lib.def.Object("ObjOne", .{
        struct {
            f1: void,
            f2: bool,
            f3: lib.def.String,
            f4: u32,
            f5: f32,
            f6: ?f32,
            f7: lib.def.Array(12, u32),
        },
        enum {
            f1,
            f2,
        },
    }),
    lib.def.Object("ObjTwo", .{
        struct {
            lib.def.List(bool),
            lib.def.Map(lib.def.String, u32),
        },
        union(enum) {
            f1: lib.def.This("ObjOne"),
            f2: lib.def.This("ObjTwo"),
        },
    }),
});

const test_scheme = lib.def.ObjectScheme.from(TestScheme(lib.def.This));

test {
    const allocator = std.testing.allocator;

    var table = Self.init(allocator);
    defer table.deinit();

    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();

    try lib.chan.write(test_scheme, &out);

    const view = lib.chan.read(lib.def.ObjectScheme, out.items);
    const scheme_name = view.field(.name);
    const scheme_objects = view.field(.objects);

    const obj_one = scheme_objects.elem(0);

    var index = try table.update(scheme_name, obj_one.field(.name), obj_one.field(.versions).elem(0));
    try std.testing.expectEqual(@as(usize, 0), index);

    index = try table.update(scheme_name, obj_one.field(.name), obj_one.field(.versions).elem(1));
    try std.testing.expectEqual(@as(usize, 1), index);

    index = try table.update(scheme_name, obj_one.field(.name), obj_one.field(.versions).elem(0));
    try std.testing.expectEqual(@as(usize, 0), index);

    index = try table.update(scheme_name, obj_one.field(.name), obj_one.field(.versions).elem(1));
    try std.testing.expectEqual(@as(usize, 1), index);

    const obj_two = scheme_objects.elem(1);

    index = try table.update(scheme_name, obj_two.field(.name), obj_two.field(.versions).elem(0));
    try std.testing.expectEqual(@as(usize, 0), index);

    index = try table.update(scheme_name, obj_one.field(.name), obj_one.field(.versions).elem(1));
    try std.testing.expectEqual(@as(usize, 1), index);

    index = try table.update(scheme_name, obj_two.field(.name), obj_two.field(.versions).elem(0));
    try std.testing.expectEqual(@as(usize, 0), index);

    index = try table.update(scheme_name, obj_one.field(.name), obj_one.field(.versions).elem(1));
    try std.testing.expectEqual(@as(usize, 1), index);
}
