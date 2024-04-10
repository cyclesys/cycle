//! Store for sources, types, and sources.
source_index: SourceIndex = .{},
sources: GenList(StoreSource) = .{},
type_index: TypeIndex = .{},
types: GenList(StoreType) = .{},
object_index: ObjectIndex = .{},
objects: GenList(StoreObject) = .{},

pub const SourceIndex = std.StringHashMapUnmanaged(Id);
pub const StoreSource = std.ArrayListUnmanaged(Id);

/// Maps type ids to their `StoredType`s.
/// There can be multiple `StoredType`s per type id (different versions of the same type).
pub const TypeIndex = std.StringHashMapUnmanaged(TypeIds);
pub const TypeIds = std.ArrayListUnmanaged(Id);
pub const StoreType = struct {
    type: Type,
    layout: TypeLayout,
};

pub const ObjectIndex = std.StringHashMapUnmanaged(Id);
pub const StoreObject = struct {
    source: ?Id,
    type: Id,
    data: [*]u8,
};

pub const Id = gen_list.Id;

const std = @import("std");
const Type = @import("Type.zig");
const TypeLayout = @import("TypeLayout.zig");
const gen_list = @import("gen_list.zig");
const GenList = gen_list.GenList;
const Store = @This();

pub fn deinit(self: *Store, allocator: std.mem.Allocator) void {
    var iter = self.type_index.iterator();
    while (iter.next()) |entry| {
        const list = entry.value_ptr;
        list.deinit(allocator);
    }
    self.type_index.deinit(allocator);
    self.types.deinit(allocator);
    self.objects.deinit(allocator);
}

pub fn addSource(self: *Store, allocator: std.mem.Allocator, name: []const u8) !Id {
    const gop = try self.source_index.getOrPut(allocator, name);
    if (gop.found_existing) {
        return gop.value_ptr.*;
    }
    gop.key_ptr.* = try allocator.dupe(u8, name);
    const source_id = try self.sources.put(StoreSource{});
    gop.value_ptr.* = source_id;
    return source_id;
}

pub fn addType(self: *Store, allocator: std.mem.Allocator, name: []const u8, ty: Type) !Id {
    const gop = try self.type_index.getOrPut(allocator, name);
    if (!gop.found_existing) {
        const type_id = try self.types.put(allocator, StoreType{
            .type = ty,
            .layout = try TypeLayout.init(allocator, ty),
        });
        const str: *[]const u8 = gop.key_ptr;
        str.* = try allocator.dupe(u8, name);
        const ids: *TypeIds = gop.value_ptr;
        ids.* = .{};
        try ids.append(allocator, type_id);
        return type_id;
    }

    const ids: *TypeIds = gop.value_ptr;

    for (ids.items) |id| {
        const stored_type = self.types.get(id).?;
        if (stored_type.type.eql(ty)) {
            return id;
        }
    }

    const type_id = try self.types.put(allocator, StoreType{
        .type = ty,
        .layut = try TypeLayout.init(allocator, ty),
    });
    try ids.append(allocator, type_id);
    return type_id;
}

pub fn addObject(self: *Store, allocator: std.mem.Allocator, source_id: ?Id, type_id: Id) !Id {
    const typ = self.types.get(type_id).?;
    const data = try typ.layout.create(allocator);
    const object_id = try self.objects.put(allocator, StoreObject{
        .source = source_id,
        .type = type_id,
        .data = data,
    });
    if (source_id) |sid| {
        const source = self.sources.get(sid).?;
        try source.append(allocator, object_id);
    }
    return object_id;
}
