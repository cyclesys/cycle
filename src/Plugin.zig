const std = @import("std");
const cy = @import("cycle");
const win = @import("windows.zig");
const LibVersion = @import("LibVersion.zig");
const TypeIndex = @import("TypeIndex.zig");
const TypeTable = @import("TypeTable.zig");

allocator: std.mem.Allocator,
exe_path: []const u8,
generation: u32 = 0,
instance: ?*Instance = null,

pub const Error = error{
    PluginError,
    PluginUnresponsive,
};

pub const Version = struct {
    major: u16,
    minor: u16,
};

pub const Instance = struct {
    ref_count: std.atomic.Atomic(usize),
    proc_info: win.PROCESS_INFORMATION,
    version: Version,
    index: TypeIndex,
};

pub const Ref = struct {
    ptr: *Plugin,
    generation: u32,

    pub const RefInstance = union(enum) {
        Current: *Instance,
        New: *Instance,
        Inactive,
    };

    pub fn instance(self: *Ref) RefInstance {
        if (self.ptr.instance) |inst| {
            if (self.ptr.instance == null) {
                return .Inactive;
            }

            if (self.generation != self.ptr.generation) {
                self.generation = self.ptr.generation;
                return RefInstance{
                    .New = inst,
                };
            }
        }

        return .active;
    }
};

const Plugin = @This();

pub const InitChannel = Channel(cy.init_mod.PluginMessage, cy.init_mod.SystemMessage);

fn Channel(comptime Read: type, comptime Write: type) type {
    return struct {
        reader: Reader,
        writer: Writer,

        const Reader = cy.chan.Reader(Read);
        const Writer = cy.chan.Writer(Write);
        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) !Self {
            const read = try cy.chan.Channel.init(false);
            const write = try cy.chan.Channel.init(true);
            return .{
                .reader = Reader.init(allocator, read),
                .writer = Writer.init(allocator, write),
            };
        }

        fn deinit(self: Self) void {
            self.reader.deinit();
            self.writer.deinit();
        }
    };
}

pub fn deinit(self: *Plugin) void {
    if (self.init_channel) |ic| {
        ic.deinit();
    }
    self.allocator.free(self.exe_path);
    self.* = undefined;
}

pub fn reset(self: *Plugin) void {
    if (self.init_channel) |ic| {
        ic.deinit();
        self.init_channel = null;
    }
    self.proc_info = null;
}

pub fn run(self: *Plugin, table: *TypeTable) !void {
    std.debug.assert(self.instance == null);

    var init_channel = try InitChannel.init(self.allocator);
    errdefer init_channel.deinit();

    const plugin_read = init_channel.writer.chan.reversed();
    const plugin_write = init_channel.reader.chan.reversed();

    var command_line_bytes = std.ArrayList(u8).init(self.allocator);
    defer command_line_bytes.deinit();

    try std.fmt.format(command_line_bytes.writer(), "{s} {x} {x} {x} {x} {x} {x}", .{
        self.exe_path,
        @intFromPtr(plugin_read.wait_ev),
        @intFromPtr(plugin_read.signal_ev),
        @intFromPtr(plugin_read.mem.handle),
        @intFromPtr(plugin_write.wait_ev),
        @intFromPtr(plugin_write.signal_ev),
        @intFromPtr(plugin_write.mem.handle),
    });

    const command_line = try std.unicode.utf8ToUtf16LeWithNull(self.allocator, command_line_bytes.items);
    defer self.allocator.free(command_line);

    const instance = try self.allocator.create(Instance);
    errdefer self.allocator.destroy(instance);

    var startup_info = std.mem.zeroInit(win.STARTUPINFOW, .{});
    var proc_info: win.PROCESS_INFORMATION = undefined;
    try win.CreateProcessW(
        null,
        command_line,
        null,
        null,
        win.TRUE,
        0,
        null,
        null,
        &startup_info,
        &proc_info,
    );
    instance.proc_info = proc_info;

    var initialized: struct {
        version: bool = false,
        index: bool = false,
    } = .{};

    errdefer {
        win.TerminateProcess(proc_info.hProcess, 1) catch |e| {
            std.log.err("error terminating plugin process: {}", .{e});
        };

        if (initialized.index) {
            instance.index.deinit();
        }
        self.allocator.destroy(instance);
    }

    while (true) {
        // NOTE: for the time being, we give plugins 5 seconds to respond with the initialization messages.
        // In the future, this may be adjusted to give plugins indefinite.
        const msg_timeout = 5000;

        if (try init_channel.reader.readFor(msg_timeout)) |msg| {
            switch (msg.tag()) {
                .SetVersion => {
                    const ver = msg.value(.SetVersion);
                    if (initialized.version) {
                        return error.PluginError;
                    }

                    instance.version = Version{
                        .major = ver.field(.major),
                        .minor = ver.field(.minor),
                    };
                    initialized.version = true;
                },
                .SetIndex => {
                    const schemes = msg.value(.SetIndex);
                    if (!initialized.version or initialized.index) {
                        return error.PluginError;
                    }

                    instance.index = try TypeIndex.init(self.allocator, table, schemes);
                    initialized.index = true;
                },
                .Finalize => {
                    break;
                },
            }
        } else {
            return error.PluginUnresponsive;
        }
    }

    if (!initialized.version or !initialized.index) {
        return error.PluginError;
    }

    self.instance = instance;
}
