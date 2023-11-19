const std = @import("std");
const cy = @import("cycle");
const TypeTable = @import("TypeTable.zig");

editor_to_plugin: std.AutoHashMap(u64, u64),
plugin_to_editor: std.AutoHashMap(u64, u64),

const Self = @This();

pub fn init(allocator: std.mem.Allocator, table: *TypeTable, view: cy.chan.View([]const cy.def.ObjectScheme)) !Self {
    var editor_to_plugin = std.AutoHashMap(u64, u64).init(allocator);
    var plugin_to_editor = std.AutoHashMap(u64, u64).init(allocator);

    for (0..view.len()) |si| {
        const scheme = view.elem(si);

        const scheme_objects = scheme.field(.objects);
        for (0..scheme_objects.len()) |oi| {
            const object = scheme_objects.elem(oi);

            const object_versions = object.field(.versions);
            for (0..object_versions.len()) |vi| {
                const version = object_versions.elem(vi);

                const editor_id = try table.update(scheme.field(.name), object.field(.name), version);
                const plugin_id = cy.def.TypeId{
                    .scheme = @intCast(si),
                    .name = @intCast(oi),
                    .version = @intCast(vi),
                };

                try editor_to_plugin.put(@bitCast(editor_id), @bitCast(plugin_id));
                try plugin_to_editor.put(@bitCast(plugin_id), @bitCast(editor_id));
            }
        }
    }

    return Self{
        .editor_to_plugin = editor_to_plugin,
        .plugin_to_editor = plugin_to_editor,
    };
}

pub fn pluginId(self: *const Self, editor_id: cy.def.TypeId) cy.def.TypeId {
    return @bitCast(self.editor_to_plugin.get(@bitCast(editor_id)).?);
}

pub fn editorId(self: *const Self, plugin_id: cy.def.TypeId) cy.def.TypeId {
    return @bitCast(self.plugin_to_editor.get(@bitCast(plugin_id)).?);
}

pub fn deinit(self: *Self) void {
    self.editor_to_plugin.deinit();
    self.plugin_to_editor.deinit();
    self.* = undefined;
}

test {
    const allocator = std.testing.allocator;

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    var table = TypeTable.init(allocator);
    defer table.deinit();

    {
        const schemes: []const cy.def.ObjectScheme = &.{
            cy.def.ObjectScheme.from(cy.def.Scheme("scheme1", .{
                cy.def.Object("Obj1", .{ u8, bool }),
                cy.def.Object("Obj2", .{ u8, bool }),
            })),
            cy.def.ObjectScheme.from(cy.def.Scheme("scheme2", .{
                cy.def.Object("Obj1", .{ u8, bool }),
                cy.def.Object("Obj2", .{ u8, bool }),
            })),
        };
        try cy.chan.write(schemes, &buf);

        var index = try Self.init(allocator, &table, cy.chan.read([]const cy.def.ObjectScheme, buf.items));
        defer index.deinit();

        // the plugin type ids should match the editor type ids
        var expected = cy.def.TypeId{ .scheme = 0, .name = 0, .version = 0 };
        try std.testing.expectEqualDeep(expected, index.pluginId(expected));
        try std.testing.expectEqualDeep(expected, index.editorId(expected));

        expected = cy.def.TypeId{ .scheme = 0, .name = 0, .version = 1 };
        try std.testing.expectEqualDeep(expected, index.pluginId(expected));
        try std.testing.expectEqualDeep(expected, index.editorId(expected));

        expected = cy.def.TypeId{ .scheme = 0, .name = 1, .version = 0 };
        try std.testing.expectEqualDeep(expected, index.pluginId(expected));
        try std.testing.expectEqualDeep(expected, index.editorId(expected));

        expected = cy.def.TypeId{ .scheme = 0, .name = 1, .version = 1 };
        try std.testing.expectEqualDeep(expected, index.pluginId(expected));
        try std.testing.expectEqualDeep(expected, index.editorId(expected));

        expected = cy.def.TypeId{ .scheme = 1, .name = 0, .version = 0 };
        try std.testing.expectEqualDeep(expected, index.pluginId(expected));
        try std.testing.expectEqualDeep(expected, index.editorId(expected));

        expected = cy.def.TypeId{ .scheme = 1, .name = 0, .version = 1 };
        try std.testing.expectEqualDeep(expected, index.pluginId(expected));
        try std.testing.expectEqualDeep(expected, index.editorId(expected));

        expected = cy.def.TypeId{ .scheme = 1, .name = 1, .version = 0 };
        try std.testing.expectEqualDeep(expected, index.pluginId(expected));
        try std.testing.expectEqualDeep(expected, index.editorId(expected));

        expected = cy.def.TypeId{ .scheme = 1, .name = 1, .version = 1 };
        try std.testing.expectEqualDeep(expected, index.pluginId(expected));
        try std.testing.expectEqualDeep(expected, index.editorId(expected));
    }

    buf.clearRetainingCapacity();

    {
        const schemes: []const cy.def.ObjectScheme = &.{
            cy.def.ObjectScheme.from(cy.def.Scheme("scheme2", .{
                cy.def.Object("Obj2", .{ bool, u8 }),
                cy.def.Object("Obj1", .{ bool, u8 }),
            })),
            cy.def.ObjectScheme.from(cy.def.Scheme("scheme1", .{
                cy.def.Object("Obj2", .{ bool, u8 }),
                cy.def.Object("Obj1", .{ bool, u8 }),
            })),
        };
        try cy.chan.write(schemes, &buf);

        var index = try Self.init(allocator, &table, cy.chan.read([]const cy.def.ObjectScheme, buf.items));
        defer index.deinit();

        try expectOppositeTypeIds(index, true, true, true);
        try expectOppositeTypeIds(index, true, true, false);

        try expectOppositeTypeIds(index, true, false, true);
        try expectOppositeTypeIds(index, true, false, false);

        try expectOppositeTypeIds(index, false, true, true);
        try expectOppositeTypeIds(index, false, true, false);

        try expectOppositeTypeIds(index, false, false, true);
        try expectOppositeTypeIds(index, false, false, false);
    }
}

fn expectOppositeTypeIds(index: Self, scheme: bool, name: bool, version: bool) !void {
    try std.testing.expectEqualDeep(
        cy.def.TypeId{
            .scheme = @intFromBool(scheme),
            .name = @intFromBool(name),
            .version = @intFromBool(version),
        },
        index.pluginId(cy.def.TypeId{
            .scheme = @intFromBool(!scheme),
            .name = @intFromBool(!name),
            .version = @intFromBool(!version),
        }),
    );
    try std.testing.expectEqualDeep(
        cy.def.TypeId{
            .scheme = @intFromBool(!scheme),
            .name = @intFromBool(!name),
            .version = @intFromBool(!version),
        },
        index.editorId(cy.def.TypeId{
            .scheme = @intFromBool(scheme),
            .name = @intFromBool(name),
            .version = @intFromBool(version),
        }),
    );
}
