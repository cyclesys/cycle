const std = @import("std");

pub fn FreeList(comptime T: type) type {
    return struct {
        list: std.ArrayListUnmanaged(Element) = .{},
        free: u32 = null_index,

        const null_index = std.math.maxInt(u32);
        const Element = union {
            value: T,
            next: u32,
        };
        const Self = @This();

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.list.deinit(allocator);
            self.* = undefined;
        }

        pub inline fn get(self: *Self, i: u32) *T {
            return &self.list.items[i].value;
        }

        pub fn put(self: *Self, allocator: std.mem.Allocator, value: T) !u32 {
            if (self.free != null_index) {
                const index = self.free;
                self.free = self.list.items[index].next;
                self.list.items[index] = .{ .value = value };
                return index;
            }

            const index = self.list.items.len;
            try self.list.append(allocator, .{ .value = value });
            return index;
        }

        pub fn remove(self: *Self, i: u32) void {
            self.list.items[i] = .{ .next = self.free };
            self.free = i;
        }
    };
}
