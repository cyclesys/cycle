const std = @import("std");
const windows = struct {
    const mod = @import("win32");
    usingnamespace mod.foundation;
    usingnamespace mod.system.memory;
    usingnamespace mod.system.threading;
    usingnamespace mod.system.windows_programming;
};

const serde = @import("serde.zig");
const SharedMem = @import("SharedMem.zig");

pub const Error = error{
    CreateChannelFailed,
    ChannelInvalid,
} || serde.Error || SharedMem.Error;

const ByteList = std.ArrayList(u8);

pub fn Reader(comptime Message: type) type {
    return struct {
        chan: Channel,
        buf: ByteList,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, channel: Channel) Self {
            return Self{
                .chan = channel,
                .buf = ByteList.init(allocator),
            };
        }

        pub fn deinit(self: *const Self) void {
            self.buf.deinit();
        }

        pub fn read(self: *Self, allocator: std.mem.Allocator) Error!Message {
            return self.readImpl(null, allocator);
        }

        pub fn readFor(self: *Self, timeout: u32, allocator: std.mem.Allocator) Error!?Message {
            return self.readImpl(timeout, allocator);
        }

        fn readImpl(
            self: *Self,
            timeout: anytype,
            allocator: std.mem.Allocator,
        ) Error!if (timeout == null) Message else ?Message {
            self.buf.clearRetainingCapacity();
            while (true) {
                const first_wait = self.chan.first_wait;
                const result = try self.chan.wait(timeout);
                if (timeout != null and !result) {
                    return null;
                }

                const remaining = try serde.deserialize(usize, @constCast(&.{
                    // it shouldn't allocate any memory to deserialize a `usize`
                    .allocator = undefined,
                    .buf = self.chan.mem.view,
                }));

                if (first_wait) {
                    try self.buf.ensureTotalCapacity(Cursor.msg_size + remaining);
                }

                try self.buf.appendSlice(self.chan.mem.view[Cursor.msg_start..]);
                try self.chan.signal();

                if (remaining == 0) {
                    break;
                }
            }

            self.chan.reset();

            const msg = try serde.deserialize(Message, @constCast(&.{
                .allocator = allocator,
                .buf = self.buf.items,
            }));

            return msg;
        }
    };
}

pub fn Writer(comptime Message: type) type {
    return struct {
        chan: Channel,
        buf: ByteList,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, channel: Channel) Self {
            return Self{
                .chan = channel,
                .buf = ByteList.init(allocator),
            };
        }

        pub fn deinit(self: *const Self) void {
            self.buf.deinit();
        }

        pub fn write(self: *Self, msg: Message) Error!void {
            try self.writeImpl(null, msg);
        }

        pub fn writeFor(self: *Self, timeout: u32, msg: Message) Error!bool {
            return self.writeImpl(timeout, msg);
        }

        fn writeImpl(
            self: *Self,
            timeout: anytype,
            msg: Message,
        ) Error!if (timeout == null) void else bool {
            self.buf.clearRetainingCapacity();
            try serde.serialize(Message, msg, @constCast(&.{
                .list = &self.buf,
            }));

            var remaining = self.buf.items.len;
            var cursor = Cursor{
                .dest = self.chan.mem.view,
                .source = self.buf.items,
            };

            while (remaining > Cursor.msg_size) {
                remaining -= Cursor.msg_size;

                const can_write = try self.chan.wait(timeout);
                if (timeout != null and !can_write) {
                    return false;
                }

                try cursor.write(remaining, Cursor.msg_size);
                try self.chan.signal();
            }

            if (remaining > 0) {
                const can_write = try self.chan.wait(timeout);
                if (timeout != null and !can_write) {
                    return false;
                }

                try cursor.write(0, remaining);
                try self.chan.signal();
            }

            self.chan.reset();
        }
    };
}

const Cursor = struct {
    dest: []u8,
    source: []const u8,
    pos: usize = 0,

    const msg_start = @sizeOf(usize);
    const msg_size = Channel.size - msg_start;

    fn write(self: *Cursor, remaining: usize, len: usize) !void {
        try serde.serialize(usize, remaining, @constCast(&.{
            .fixed = .{ .buf = self.dest },
        }));

        const msg_bytes = self.source[self.pos..(self.pos + len)];
        self.pos += len;

        std.mem.copy(u8, self.dest[msg_start..], msg_bytes);
    }
};

pub const Channel = struct {
    wait_ev: windows.HANDLE,
    signal_ev: windows.HANDLE,
    mem: SharedMem,
    first_wait: bool = true,

    const size = 1 * 1024;

    pub fn init(start_owned: bool) Error!Channel {
        const wait_ev = windows.CreateEventW(
            null,
            1,
            @intCast(windows.BOOL, @boolToInt(start_owned)),
            null,
        );
        const signal_ev = windows.CreateEventW(
            null,
            1,
            @intCast(windows.BOOL, @boolToInt(!start_owned)),
            null,
        );

        if (wait_ev == null or signal_ev == null) {
            return error.CreateChannelFailed;
        }

        const mem = try SharedMem.init(size);

        return Channel{
            .wait_ev = wait_ev.?,
            .signal_ev = signal_ev.?,
            .mem = mem,
        };
    }

    pub fn import(
        wait_ev: windows.HANDLE,
        signal_ev: windows.HANDLE,
        file: windows.HANDLE,
    ) Error!Channel {
        const mem = try SharedMem.import(file, size);
        return Channel{
            .wait_ev = wait_ev,
            .signal_ev = signal_ev,
            .mem = mem,
        };
    }

    pub fn deinit(self: *Channel) !void {
        _ = windows.CloseHandle(self.wait_ev);
        _ = windows.CloseHandle(self.signal_ev);
        self.mem.deinit();
    }

    pub fn reversed(self: *const Channel) Channel {
        return Channel{
            .wait_ev = self.signal_ev,
            .signal_ev = self.wait_ev,
            .mem = self.mem,
            .first_wait = true,
        };
    }

    fn wait(self: *Channel, timeout: ?u32) Error!bool {
        const wait_for = if (timeout != null and self.first_wait) timeout.? else windows.INFINITE;
        self.first_wait = false;

        const result = windows.WaitForSingleObject(self.wait_ev, wait_for);
        return switch (result) {
            windows.WAIT_OBJECT_0 => true,
            @enumToInt(windows.WAIT_TIMEOUT) => if (timeout == null) false else error.ChannelInvalid,
            windows.WAIT_ABANDONED => error.ChannelInvalid,
            @enumToInt(windows.WAIT_FAILED) => error.ChannelInvalid,
            else => unreachable,
        };
    }

    fn signal(self: *Channel) Error!void {
        if (windows.ResetEvent(self.wait_ev) == 0 or
            windows.SetEvent(self.signal_ev) == 0)
        {
            return error.ChannelInvalid;
        }
    }

    fn reset(self: *Channel) void {
        self.first_wait = true;
    }
};

const testing = std.testing;
const StrMessage = struct {
    str: ?[]const u8,

    fn deinit(self: StrMessage) void {
        serde.destroy(StrMessage, self, testing.allocator);
    }
};
const MessageReader = Reader(StrMessage);
const MessageWriter = Writer(StrMessage);
const Child = struct {
    reader: MessageReader,
    writer: MessageWriter,

    fn run(self: *Child) !void {
        while (true) {
            const msg = try self.reader.read(testing.allocator);
            defer msg.deinit();

            if (msg.str == null) {
                break;
            }

            try self.writer.write(msg);
        }

        self.reader.deinit();
        self.writer.deinit();
    }
};

test "channel io without timeout" {
    var reader = MessageReader.init(testing.allocator, try Channel.init(false));
    var writer = MessageWriter.init(testing.allocator, try Channel.init(true));

    const child = try std.Thread.spawn(.{}, Child.run, .{@constCast(&Child{
        .reader = MessageReader.init(testing.allocator, writer.chan.reversed()),
        .writer = MessageWriter.init(testing.allocator, reader.chan.reversed()),
    })});

    for (0..3) |i| {
        const str: ?[]const u8 = switch (i) {
            0 => "Hello",
            1 => "World",
            2 => null,
            else => unreachable,
        };
        try writer.write(StrMessage{ .str = str });
        if (str != null) {
            const msg = try reader.read(testing.allocator);
            defer msg.deinit();
            try testing.expectEqualDeep(str, msg.str);
        }
    }

    child.join();

    try reader.chan.deinit();
    try writer.chan.deinit();
    reader.deinit();
    writer.deinit();
}
