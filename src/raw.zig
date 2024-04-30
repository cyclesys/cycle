const std = @import("std");

pub const ByteList = extern struct {
    buf: [*]u8 = undefined,
    len: u32 = 0,
    capacity: u32 = 0,

    const max_capacity = std.math.maxInt(u32);

    pub fn append(self: *ByteList, byte: u8) void {
        self.buf[self.len] = byte;
        self.len += 1;
    }

    pub fn appendSlice(self: *ByteList, bytes: []const u8) void {
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    pub fn insert(self: *ByteList, i: u32, byte: u8) void {
        std.mem.copyBackwards(
            u8,
            self.buf[i + 1 .. self.len + 1],
            self.buf[i..self.len],
        );
        self.buf[i] = byte;
        self.len += 1;
    }

    pub fn insertSlice(self: *ByteList, i: u32, bytes: []const u8) void {
        const dest_start = i + 1;
        const dest_end = dest_start + bytes.len;
        const src_start = i;
        const src_end = i + bytes.len;
        std.mem.copyBackwards(
            u8,
            self.buf[dest_start..dest_end],
            self.buf[src_start..src_end],
        );
        @memcpy(self.buf[i..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    pub fn remove(self: *ByteList, i: u32) void {
        std.mem.copyForwards(
            u8,
            self.buf[i..self.len],
            self.buf[i + 1 .. self.len],
        );
        self.len -= 1;
    }

    pub fn removeRange(self: *ByteList, start: u32, len: u32) void {
        const dest_start = start;
        const dest_end = dest_start + self.len;
        const src_start = start + len;
        const src_end = self.len;
        std.mem.copyForwards(
            u8,
            self.buf[dest_start..dest_end],
            self.buf[src_start..src_end],
        );
        self.len -= len;
    }

    pub fn ensureAvailable(self: *ByteList, allocator: std.mem.Allocator, necessary: u32) !void {
        if ((self.capacity - self.len) < necessary) {
            const necessary_capacity = self.len + necessary;
            if (necessary_capacity > max_capacity) {
                return error.OutOfCapacity;
            }

            var new_capacity = @max(self.capacity, 8);
            while (new_capacity < necessary_capacity) {
                new_capacity +|= new_capacity / 4 + 8;
            }
            try self.resize(allocator, new_capacity);
        }
    }

    pub fn resize(self: *ByteList, allocator: std.mem.Allocator, new_capacity: u32) !void {
        if (self.capacity == 0) {
            self.buf = try allocator.alloc(u8, new_capacity);
            self.capacity = new_capacity;
            return;
        }

        const old_memory = self.buf[0..self.capacity];
        if (allocator.resize(old_memory, new_capacity)) {
            self.capacity = new_capacity;
            return;
        }
        defer allocator.free(old_memory);

        const new_memory = try allocator.alloc(u8, new_capacity);
        @memcpy(new_memory[0..self.len], old_memory);
        @memset(new_memory[self.len..], undefined);
        self.buf = new_memory.ptr;
        self.capacity = new_capacity;
    }
};

/// A contigious growable list of items with a runtime known size and alignment.
// extern makes it compatible with zig generated types.
pub const List = extern struct {
    bytes: [*]u8 = undefined,
    len: Index = 0,
    available: Index = 0,

    item_size: Index,
    item_alignment: u8,

    pub const Index = u32;
    pub const Error = error{
        OutOfCapacity,
    } || std.mem.Allocator.Error;
    const max_capacity = std.math.maxInt(Index);
    const Self = @This();

    inline fn capacity(self: Self) u32 {
        return self.len + self.available;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        const cap = self.capacity();
        if (cap != 0) {
            const byte_count = cap * self.item_size;
            rawFree(allocator, self.bytes[0..byte_count], self.item_alignment);
        }
        self.* = undefined;
    }

    pub inline fn get(self: Self, i: Index) [*]u8 {
        return self.getRange(i, 1);
    }

    pub fn getRange(self: Self, start: Index, len: Index) [*]u8 {
        return self.bytes[start * self.item_size ..][0 .. len * self.item_size].ptr;
    }

    pub inline fn append(self: *Self) [*]u8 {
        return self.appendRange(1);
    }

    pub fn appendRange(self: *Self, len: Index) [*]u8 {
        const items = self.getRange(self.len, len);
        self.len += len;
        self.available -= len;
        return items;
    }

    pub inline fn insert(self: *Self, i: Index) [*]u8 {
        return self.insertRange(i, 1);
    }

    pub fn insertRange(self: *Self, i: Index, len: Index) [*]u8 {
        const dest_start = (i + len) * self.item_size;
        const dest_end = dest_start + (len * self.item_size);
        const src_start = i * self.item_size;
        const src_end = src_start + (len * self.item_size);
        std.mem.copyBackwards(
            u8,
            self.bytes[dest_start..dest_end],
            self.bytes[src_start..src_end],
        );
        self.len += len;
        self.available -= len;
        return self.getRange(i, len);
    }

    pub inline fn remove(self: *Self, i: Index) void {
        self.removeRange(i, 1);
    }

    pub fn removeRange(self: *Self, start: Index, len: Index) void {
        const dest_start = start * self.item_size;
        const dest_end = dest_start + (self.len * self.item_size);
        const src_start = (start + len) * self.item_size;
        const src_end = self.len * self.item_size;
        std.mem.copyForwards(
            u8,
            self.bytes[dest_start..dest_end],
            self.bytes[src_start..src_end],
        );
        self.len -= len;
        self.available += len;
    }

    pub fn ensureAvailable(self: *Self, allocator: std.mem.Allocator, necessary: Index) !void {
        if (self.available < necessary) {
            const necessary_capacity = self.len + necessary;
            if (necessary_capacity > max_capacity) {
                return error.OutOfCapacity;
            }

            var new_capacity = @max(self.capacity(), 8);
            while (new_capacity < necessary_capacity) {
                new_capacity +|= new_capacity / 4 + 8;
            }

            try self.resize(allocator, new_capacity);
        }
    }

    pub fn resize(self: *Self, allocator: std.mem.Allocator, new_capacity: Index) Error!void {
        const new_byte_count = new_capacity * self.item_size;
        if (self.capacity() == 0) {
            self.bytes = try rawAlloc(allocator, new_byte_count, self.item_alignment);
            self.available = new_capacity;
            @memset(self.bytes[0..new_byte_count], undefined);
            return;
        }

        const old_byte_count = self.capacity() * self.item_size;
        const old_memory = self.bytes[0..old_byte_count];
        if (rawResize(allocator, old_memory, new_byte_count, self.item_alignment)) {
            self.available = new_capacity - self.len;
            return;
        }
        defer rawFree(allocator, old_memory, self.item_alignment);

        const new_memory = try rawAlloc(allocator, new_byte_count, self.item_alignment);
        @memcpy(new_memory[0..self.len], old_memory);
        @memset(new_memory[self.len..new_byte_count], undefined);
        self.bytes = new_memory;
        self.available = new_capacity - self.len;
    }
};

inline fn rawAlloc(allocator: std.mem.Allocator, len: usize, alignment: u8) ![*]u8 {
    const bytes = allocator.rawAlloc(len, alignment, @returnAddress()) orelse return error.OutOfMemory;
    @memset(bytes[0..len], undefined);
    return bytes;
}

inline fn rawResize(allocator: std.mem.Allocator, buf: []u8, new_len: usize, alignment: u8) bool {
    return allocator.rawResize(buf, alignment, new_len, @returnAddress());
}

inline fn rawFree(allocator: std.mem.Allocator, buf: []u8, alignment: u8) void {
    @memset(buf, undefined);
    allocator.rawFree(buf, alignment, @returnAddress());
}

test "list initial resize" {
    const allocator = std.testing.allocator;
    var list = testList();
    defer list.deinit(allocator);

    try list.resize(allocator, 8);
    try std.testing.expectEqual(@as(u32, 8), list.capacity());
}

test "list appendRange" {
    const allocator = std.testing.allocator;
    var list = testList();
    defer list.deinit(allocator);

    try list.resize(allocator, 2);

    _ = list.appendRange(2);
    try expectListWriteAndRead(list, 0, .{ .f1 = 10, .f2 = 10 });
    try expectListWriteAndRead(list, 1, .{ .f1 = 20, .f2 = 20 });
}

test "list insertRange" {
    const allocator = std.testing.allocator;
    var list = testList();
    defer list.deinit(allocator);

    try list.resize(allocator, 4);

    _ = list.appendRange(2);
    writeTestItem(list, 0, .{ .f1 = 10, .f2 = 10 });
    writeTestItem(list, 1, .{ .f1 = 40, .f2 = 40 });

    _ = list.insertRange(1, 2);
    try expectListItem(list, 0, .{ .f1 = 10, .f2 = 10 });
    try expectListItem(list, 3, .{ .f1 = 40, .f2 = 40 });
}

test "list removeRange" {
    const allocator = std.testing.allocator;
    var list = testList();
    defer list.deinit(allocator);

    try list.resize(allocator, 4);

    _ = list.appendRange(4);
    writeTestItem(list, 0, .{ .f1 = 10, .f2 = 10 });
    writeTestItem(list, 3, .{ .f1 = 20, .f2 = 20 });

    list.removeRange(1, 2);
    try expectListItem(list, 0, .{ .f1 = 10, .f2 = 10 });
    try expectListItem(list, 1, .{ .f1 = 20, .f2 = 20 });
}

test "list grow" {
    const allocator = std.testing.allocator;
    var list = testList();
    defer list.deinit(allocator);

    try list.resize(allocator, 8);
    try std.testing.expectEqual(@as(u32, 8), list.capacity());
    writeTestItem(list, 4, .{ .f1 = 11, .f2 = 22 });

    try list.resize(allocator, 16);
    try std.testing.expectEqual(@as(u32, 16), list.capacity());
    try expectListItem(list, 4, .{ .f1 = 11, .f2 = 22 });
}

test "list shrink" {
    const allocator = std.testing.allocator;
    var list = testList();
    defer list.deinit(allocator);

    try list.resize(allocator, 16);
    try std.testing.expectEqual(@as(u32, 16), list.capacity());
    writeTestItem(list, 7, .{ .f1 = 11, .f2 = 22 });

    try list.resize(allocator, 8);
    try std.testing.expectEqual(@as(u32, 8), list.capacity());
    try expectListItem(list, 7, .{ .f1 = 11, .f2 = 22 });
}

// default to greatest alignment list for tests.
fn testList() List {
    return List{
        .item_size = @sizeOf(TestListItem),
        .item_alignment = @alignOf(TestListItem),
    };
}

fn expectListWriteAndRead(list: List, i: u32, item: TestListItem) !void {
    writeTestItem(list, i, item);
    try expectListItem(list, i, item);
}

fn expectListItem(list: List, i: u32, expected: TestListItem) !void {
    const bytes = list.get(i);
    const actual: *TestListItem = @ptrCast(@alignCast(bytes));
    try std.testing.expectEqualDeep(expected, actual.*);
}

fn writeTestItem(list: List, i: u32, value: TestListItem) void {
    const bytes = list.get(i);
    const item: *TestListItem = @ptrCast(@alignCast(bytes));
    item.f1 = value.f1;
    item.f2 = value.f2;
}

const TestListItem = struct {
    f1: u8,
    f2: u64,
};
