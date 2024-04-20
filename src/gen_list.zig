const std = @import("std");

pub const Id = u64;
const IdData = packed struct(Id) {
    generation: u32,
    index: u32,
};

inline fn idData(id: Id) IdData {
    return @as(IdData, @bitCast(id));
}

pub fn GenList(comptime V: type) type {
    return struct {
        list: std.ArrayListUnmanaged(Item) = .{},
        free: u32 = null_index,

        const null_index = std.math.maxInt(u32);

        const Item = union(enum) {
            free: struct {
                old_generation: u32,
                next: u32,
            },
            occupied: struct {
                generation: u32,
                value: V,
            },
        };
        const Self = @This();

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.list.deinit(allocator);
        }

        pub fn getPtr(self: *Self, id: Id) ?*V {
            if (!self.contains(id)) {
                return null;
            }
            return &self.list.items[idData(id).index].occupied.value;
        }

        pub fn get(self: *Self, id: Id) ?V {
            if (!self.contains(id)) {
                return null;
            }
            return self.list.items[idData(id).index].occupied.value;
        }

        pub fn contains(self: *Self, id: Id) bool {
            return idData(id).index < self.list.items.len and
                self.list.items[idData(id).index] == .occupied and
                self.list.items[idData(id).index].occupied.generation == idData(id).generation;
        }

        pub fn put(self: *Self, allocator: std.mem.Allocator, value: V) !Id {
            if (self.free != null_index) {
                const index = self.free;
                const free_data = self.list.items[index].free;
                const generation = free_data.old_generation + 1;
                self.list.items[index] = Item{
                    .occupied = .{
                        .generation = generation,
                        .value = value,
                    },
                };
                self.free = free_data.next;
                return @bitCast(IdData{
                    .generation = generation,
                    .index = index,
                });
            }

            const index = self.list.items.len;
            try self.list.append(allocator, Item{
                .occupied = .{
                    .generation = 0,
                    .value = value,
                },
            });

            return @bitCast(IdData{
                .generation = 0,
                .index = @intCast(index),
            });
        }

        pub fn remove(self: *Self, id: Id) ?V {
            if (self.get(id)) |value| {
                self.list.items[idData(id).index] = Item{
                    .free = .{
                        .old_generation = idData(id).generation,
                        .next = self.free,
                    },
                };
                self.free = idData(id).index;
                return value;
            }
            return null;
        }
    };
}

test "basic put" {
    const allocator = std.testing.allocator;
    var list = GenList(u32){};
    defer list.deinit(allocator);

    const id = try list.put(allocator, 123);
    try std.testing.expectEqual(@as(?u32, 123), list.get(id));
}

test "basic remove" {
    const allocator = std.testing.allocator;
    var list = GenList(u32){};
    defer list.deinit(allocator);

    const id = try list.put(allocator, 123);
    const removed = list.remove(id);
    try std.testing.expectEqual(@as(?u32, 123), removed);
    try std.testing.expectEqual(@as(?u32, null), list.get(id));
}

test "recycles indices" {
    const allocator = std.testing.allocator;
    var list = GenList(u32){};
    defer list.deinit(allocator);

    _ = try list.put(allocator, 123);
    const old_two = try list.put(allocator, 456);
    _ = try list.put(allocator, 789);
    const old_four = try list.put(allocator, 123);
    _ = try list.put(allocator, 456);

    _ = list.remove(old_two);
    _ = list.remove(old_four);
    const new_four = try list.put(allocator, 456);
    const new_two = try list.put(allocator, 123);
    try std.testing.expectEqual(idData(new_four).index, idData(old_four).index);
    try std.testing.expectEqual(idData(new_two).index, idData(old_two).index);
}
