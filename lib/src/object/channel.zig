const std = @import("std");
const windows = struct {
    const mod = @import("win32");
    usingnamespace mod.foundation;
};
const channel = @import("../channel.zig");
const serde = @import("../serde.zig");
const SharedMem = @import("../SharedMem.zig");

const super = @import("../object.zig");
const write = @import("write.zig");

pub const Sync = enum {
    read,
    write,
};

pub fn ObjectChannel(comptime Index: type) type {
    return struct {
        allocator: std.mem.Allocator,
        reader: ObjectChannelReader,
        writer: ObjectChannelWriter,
        index: Index,
        state: ?Sync,

        const Self = @This();

        pub fn init(
            allocator: std.mem.Allocator,
            reader: ObjectChannelReader,
            writer: ObjectChannelWriter,
            index: Index,
        ) Self {
            return Self{
                .allocator = allocator,
                .reader = reader,
                .writer = writer,
                .index = index,
                .state = null,
            };
        }

        pub fn sync(self: *Self, state: Sync) !void {
            try self.unsync();
            try self.writer.write(.{ .Sync = state });
            var msg = try self.reader.read();
            while (msg != .Synced) {
                switch (msg) {
                    .IndexObject => |info| {
                        try self.index.put(try info.into());
                    },
                    .ForgetObject => |info| {
                        try self.index.remove(info.type, info.id);
                    },
                    else => unreachable,
                }
                msg = try self.reader.read();
            }
            self.state = state;
        }

        pub fn unsync(self: *Self) !void {
            if (self.state != null) {
                try self.writer.write(.Unsync);
                self.state = null;
            }
        }

        pub fn set(
            self: *Self,
            comptime Obj: type,
            id: super.ObjectId,
            value: write.ObjectValue(Obj),
        ) !void {
            if (self.state == null or self.state.? != .write) {
                return error.InvalidSyncState;
            }

            var bytes = std.ArrayList(u8).init(self.allocator);
            defer bytes.deinit();

            try write.writeValue(Obj, value, bytes.writer());
            try self.writer.write(.{
                .Set = .{
                    .id = id,
                    .bytes = bytes.items,
                },
            });
        }

        pub fn mut(
            self: *Self,
            comptime Obj: type,
            id: super.ObjectId,
            value: write.ObjectMut(Obj),
        ) !void {
            if (self.state == null or self.state.? != .write) {
                return error.InvalidSyncState;
            }

            var bytes = std.ArrayList(u8).init(self.allocator);
            defer bytes.deinit();

            try write.writeMut(Obj, value, bytes.writer());
            try self.writer.write(.{
                .Mut = .{
                    .id = id,
                    .bytes = bytes.items,
                },
            });
        }
    };
}

pub const ObjectChannelReader = channel.Reader(SystemMessage);
pub const ObjectChannelWriter = channel.Writer(PluginMessage);

pub const SystemMessage = struct {
    IndexObject: IndexObjectInfo,
    ForgetObject: ForgetObjectInfo,
    Synced: void,

    pub const IndexObjectInfo = struct {
        id: super.ObjectId,
        type: super.ObjectType,
        mem: SharedMemInfo,

        pub fn into(self: *const IndexObjectInfo) SharedMem.Error!super.Object {
            return super.Object{
                .id = self.id,
                .type = self.type,
                .mem = try self.mem.into(),
            };
        }
    };

    pub const ForgetObjectInfo = struct {
        type: super.TypeId,
        id: super.ObjectId,
    };

    pub const SharedMemInfo = struct {
        handle: usize,
        size: usize,

        pub fn into(self: *const SharedMemInfo) SharedMem.Error!SharedMem {
            const handle = @intToPtr(windows.HANDLE, self.handle);
            return SharedMem.import(handle, self.size);
        }
    };
};

pub const PluginMessage = union(enum) {
    Sync: Sync,
    Unsync: void,
    Set: struct {
        id: super.ObjectId,
        bytes: []const u8,
    },
    Mut: struct {
        id: super.ObjectId,
        bytes: []const u8,
    },
};
