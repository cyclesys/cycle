const std = @import("std");
const cy = @import("cycle");
const TypeTable = @import("TypeTable.zig");
const Object = @import("ObjectTable/Object.zig");

allocator: std.mem.Allocator,
schemes: Schemes,

const Schemes = std.StringArrayHashMap(Sources);
const Sources = std.StringArrayHashMap(Objects);
const Objects = std.StringArrayHashMap(Object);

const Self = @This();

pub fn init(allocator: std.mem.Allocator) Self {
    return Self{
        .allocator = allocator,
        .schemes = Schemes.init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    var scheme_iter = self.schemes.iterator();
    while (scheme_iter.next()) |scheme| {
        var source_iter = scheme.value_ptr.iterator();
        while (source_iter.next()) |source| {
            var object_iter = source.value_ptr.iterator();
            while (object_iter.next()) |object| {
                self.allocator.free(object.key_ptr.*);
            }
            source.deinit();
            self.allocator.free(source.key_ptr.*);
        }
        scheme.deinit();
        self.allocator.free(scheme.key_ptr.*);
    }
    self.schemes.deinit();
    self.* = undefined;
}

pub fn update(
    self: *Self,
    scheme_name: []const u8,
    source_name: []const u8,
    object_name: []const u8,
    type_table: *const TypeTable,
    bytes: []const u8,
) !void {
    const scheme_gop = try self.schemes.getOrPut(scheme_name);
    if (!scheme_gop.found_existing) {
        scheme_gop.key_ptr.* = try self.allocator.dupe(u8, scheme_name);
        scheme_gop.value_ptr.* = Sources.init(self.allocator);
    }
    const sources: *Sources = scheme_gop.value_ptr;

    const source_gop = try sources.getOrPut(source_name);
    if (!source_gop.found_existing) {
        source_gop.key_ptr.* = try self.allocator.dupe(u8, source_name);
        source_gop.value_ptr.* = Objects.init(self.allocator);
    }
    const objects: *Objects = source_gop.value_ptr;

    const object_gop = try objects.getOrPut(object_name);
    if (!object_gop.found_existing) {
        object_gop.key_ptr.* = try self.allocator.dupe(u8, object_name);
        object_gop.value_ptr.* = Object{};
    }

    try Object.update(object_gop.value_ptr, self.allocator, type_table, bytes);
}

pub fn remove(
    self: *Self,
) !void {
    _ = self;
}
