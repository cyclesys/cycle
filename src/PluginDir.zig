const std = @import("std");
const kf = @import("known_folders");
const Plugin = @import("Plugin.zig");

allocator: std.mem.Allocator,
dir_path: []const u8,
plugins: []Plugin,
mutex: std.Thread.Mutex,

const PluginDir = @This();

pub fn init(allocator: std.mem.Allocator) !PluginDir {
    const home_dir_path = (try kf.getPath(allocator, .home)).?;
    defer allocator.free(home_dir_path);

    const dir_path = try std.fs.path.join(allocator, &.{ home_dir_path, ".cycle" });

    var dir = try std.fs.openIterableDirAbsolute(home_dir_path, .{});
    defer dir.close();

    var dir_iter = dir.iterate();

    var plugins = std.ArrayList(Plugin).init(allocator);
    while (try dir_iter.next()) |entry| {
        if (entry.kind != .file) continue;
        const exe_path = try std.fs.path.join(allocator, &.{ home_dir_path, entry.name });

        try plugins.append(Plugin{
            .allocator = allocator,
            .exe_path = exe_path,
        });
    }

    return PluginDir{
        .allocator = allocator,
        .dir_path = dir_path,
        .plugins = try plugins.toOwnedSlice(),
    };
}

pub fn deinit(self: *PluginDir) void {
    self.allocator.free(self.dir_path);
    self.allocator.free(self.plugins);
    self.* = undefined;
}
