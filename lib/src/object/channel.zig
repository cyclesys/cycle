const std = @import("std");
const windows = struct {
    const mod = @import("win32");
    usingnamespace mod.foundation;
};
const channel = @import("../channel.zig");
const serde = @import("../serde.zig");
const super = @import("../object.zig");
const SharedMem = @import("../SharedMem.zig");

pub fn ObjectChannel(comptime Index: type) type {
    return struct {
        allocator: std.mem.Allocator,
        reader: ObjectChannelReader,
        writer: ObjectChannelReader,
        index: Index,
        synced: bool,

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
                .synced = false,
            };
        }

        pub fn sync(self: *Self) !void {
            try self.unsync();
            try self.writer.write(.Sync);
            var msg = try self.reader.read(self.allocator);
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
                msg.deinit();
                msg = try self.reader.read(self.allocator);
            }
            msg.deinit();
            self.synced = true;
        }

        pub fn unsync(self: *Self) channel.Error!void {
            if (self.synced) {
                try self.writer.write(.Unsync);
                self.synced = false;
            }
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

    pub fn deinit(self: *const SystemMessage, allocator: std.mem.Allocator) void {
        serde.detroy(SystemMessage, self.*, allocator);
    }
};

pub const PluginMessage = union(enum) {
    Sync: void,
    Unsync: void,
};
