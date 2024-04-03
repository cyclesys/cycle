//! A contiguous growable list of items with a runtime known size and alignment.
// This is essentially a `std.ArrayList` adjusted for dynamic size and alignment items.
bytes: [*]u8 = undefined,
len: u32 = 0,
capacity: u32 = 0,

item_size: u32,
item_alignment: u8,

const max_capacity = std.math.maxInt(u32);

pub const Error = error{
    OutOfCapacity,
} || std.mem.Allocator.Error;

const std = @import("std");
const RawList = @This();

pub fn deinit(self: *RawList, allocator: std.mem.Allocator) void {
    if (self.capacity != 0) {
        const byte_count = self.capacity * self.item_size;
        self.free(allocator, self.bytes[0..byte_count]);
    }
    self.* = undefined;
}

pub inline fn get(self: RawList, i: u32) [*]u8 {
    return self.getRange(i, 1);
}

pub fn getRange(self: RawList, start: u32, len: u32) [*]u8 {
    return self.bytes[start * self.item_size ..][0 .. len * self.item_size].ptr;
}

pub inline fn append(self: *RawList) [*]u8 {
    return self.appendRange(1);
}

pub fn appendRange(self: *RawList, len: u32) [*]u8 {
    const items = self.getRange(self.len, len);
    self.len += len;
    return items;
}

pub inline fn insert(self: *RawList, i: u32) [*]u8 {
    return self.insertRange(i, 1);
}

pub fn insertRange(self: *RawList, i: u32, len: u32) [*]u8 {
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
    return self.getRange(i, len);
}

pub inline fn remove(self: *RawList, i: u32) void {
    self.removeRange(i, 1);
}

pub fn removeRange(self: *RawList, start: u32, len: u32) void {
    const dest_start = start * self.item_size;
    const dest_end = dest_start + (len * self.item_size);
    const src_start = (start + len) * self.item_size;
    const src_end = self.len * self.item_size;
    std.mem.copyForwards(
        u8,
        self.bytes[dest_start..dest_end],
        self.bytes[src_start..src_end],
    );
    self.len -= len;
}

pub fn resize(self: *RawList, allocator: std.mem.Allocator, new_capacity: u32) Error!void {
    const new_byte_count = new_capacity * self.item_size;
    if (self.capacity == 0) {
        self.bytes = try self.allocate(allocator, new_byte_count);
        self.capacity = new_capacity;
        @memset(self.bytes[0..new_byte_count], undefined);
        return;
    }

    const old_byte_count = self.capacity * self.item_size;
    const old_memory = self.bytes[0..old_byte_count];
    if (allocator.rawResize(old_memory, self.item_alignment, new_byte_count, @returnAddress())) {
        self.capacity = new_capacity;
        return;
    }
    defer self.free(allocator, old_memory);

    const new_memory = try self.allocate(allocator, new_byte_count);
    @memcpy(new_memory[0..self.len], old_memory);
    @memset(new_memory[self.len..new_byte_count], undefined);
    self.bytes = new_memory;
    self.capacity = new_capacity;
}

inline fn allocate(self: RawList, allocator: std.mem.Allocator, len: usize) ![*]u8 {
    return allocator.rawAlloc(len, self.item_alignment, @returnAddress()) orelse error.OutOfMemory;
}

inline fn free(self: RawList, allocator: std.mem.Allocator, buf: []u8) void {
    @memset(buf, undefined);
    allocator.rawFree(buf, self.item_alignment, @returnAddress());
}

test "initial resize" {
    const allocator = std.testing.allocator;
    var list = testList();
    defer list.deinit(allocator);

    try list.resize(allocator, 8);
    try std.testing.expectEqual(@as(u32, 8), list.capacity);
}

test "appendRange" {
    const allocator = std.testing.allocator;
    var list = testList();
    defer list.deinit(allocator);

    try list.resize(allocator, 2);

    _ = list.appendRange(2);
    try expectWriteAndRead(list, 0, .{ .f1 = 10, .f2 = 10 });
    try expectWriteAndRead(list, 1, .{ .f1 = 20, .f2 = 20 });
}

test "insertRange" {
    const allocator = std.testing.allocator;
    var list = testList();
    defer list.deinit(allocator);

    try list.resize(allocator, 4);

    _ = list.appendRange(2);
    writeTestItem(list, 0, .{ .f1 = 10, .f2 = 10 });
    writeTestItem(list, 1, .{ .f1 = 40, .f2 = 40 });

    _ = list.insertRange(1, 2);
    try expectItem(list, 0, .{ .f1 = 10, .f2 = 10 });
    try expectItem(list, 3, .{ .f1 = 40, .f2 = 40 });
}

test "removeRange" {
    const allocator = std.testing.allocator;
    var list = testList();
    defer list.deinit(allocator);

    try list.resize(allocator, 4);

    _ = list.appendRange(4);
    writeTestItem(list, 0, .{ .f1 = 10, .f2 = 10 });
    writeTestItem(list, 3, .{ .f1 = 20, .f2 = 20 });

    list.removeRange(1, 2);
    try expectItem(list, 0, .{ .f1 = 10, .f2 = 10 });
    try expectItem(list, 1, .{ .f1 = 20, .f2 = 20 });
}

test "grow" {
    const allocator = std.testing.allocator;
    var list = testList();
    defer list.deinit(allocator);

    try list.resize(allocator, 8);
    try std.testing.expectEqual(@as(u32, 8), list.capacity);
    writeTestItem(list, 4, .{ .f1 = 11, .f2 = 22 });

    try list.resize(allocator, 16);
    try std.testing.expectEqual(@as(u32, 16), list.capacity);
    try expectItem(list, 4, .{ .f1 = 11, .f2 = 22 });
}

test "shrink" {
    const allocator = std.testing.allocator;
    var list = testList();
    defer list.deinit(allocator);

    try list.resize(allocator, 16);
    try std.testing.expectEqual(@as(u32, 16), list.capacity);
    writeTestItem(list, 7, .{ .f1 = 11, .f2 = 22 });

    try list.resize(allocator, 8);
    try std.testing.expectEqual(@as(u32, 8), list.capacity);
    try expectItem(list, 7, .{ .f1 = 11, .f2 = 22 });
}

fn testList() RawList {
    return RawList{
        .item_size = @sizeOf(TestItem),
        .item_alignment = @alignOf(TestItem),
    };
}

fn expectWriteAndRead(list: RawList, i: u32, item: TestItem) !void {
    writeTestItem(list, i, item);
    try expectItem(list, i, item);
}

fn expectItem(list: RawList, i: u32, expected: TestItem) !void {
    const bytes = list.get(i);
    const actual: *TestItem = @ptrCast(@alignCast(bytes));
    try std.testing.expectEqualDeep(expected, actual.*);
}

fn writeTestItem(list: RawList, i: u32, value: TestItem) void {
    const bytes = list.get(i);
    const item: *TestItem = @ptrCast(@alignCast(bytes));
    item.f1 = value.f1;
    item.f2 = value.f2;
}

const TestItem = struct {
    f1: u8,
    f2: u64,
};
