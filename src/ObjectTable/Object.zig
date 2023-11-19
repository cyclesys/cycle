const std = @import("std");
const cy = @import("cycle");

type_id: cy.def.TypeId,
type: cy.def.Type,
state: State,

const State = union(enum) {
    String: struct {
        len: usize,
    },
    Array: []const State,
    Optional: union(enum) {
        Some: *State,
        None: void,
    },
    List: union(enum) {
        Len: usize,
        Items: std.ArrayList(State),
    },
    Map: std.StringHashMap(State),
    Struct: []const State,
    Tuple: []const State,
    Union: struct {
        tag: u16,
        child: *State,
    },
};

const Self = @This();

pub fn init(allocator: std.mem.Allocator, type_id: cy.def.TypeId, typ: cy.def.Type, bytes: []const u8) !Self {
    return Self{
        .type_id = type_id,
        .type = typ,
        .state = try initState(allocator, typ, bytes),
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    if (typeHasState(self.type)) {
        deinitState(allocator, self.type, self.state);
    }
}

pub fn update(self: *Self, allocator: std.mem.Allocator, bytes: []const u8) !void {
    _ = self;
    _ = allocator;
    _ = bytes;
}

fn initState(allocator: std.mem.Allocator, t: cy.def.Type, bytes: []const u8) !State {
    return switch (t) {
        .Void, .Bool, .Int, .Float, .Enum, .Ref, .Any => undefined,
        .String => blk: {
            const str = cy.chan.read([]const u8, bytes);
            break :blk State{
                .String = .{ .len = str.len },
            };
        },
        .Optional => |info| blk: {
            if (cy.chan.read(?[]const u8, bytes)) |child_bytes| {
                var child: *State = undefined;
                if (typeHasState(info.child.*)) {
                    child = try allocator.create(State);
                    child.* = initState(allocator, info.child.*, child_bytes);
                }
                return State{
                    .Optional = .{
                        .Some = child,
                    },
                };
            }

            break :blk State{
                .Optional = .None,
            };
        },
        .List => |info| blk: {
            const sizes = cy.chan.read([]const usize, bytes);
            if (typeHasState(info.child.*)) {
                const len = sizes.len();
                const elems_offset = (len + 1) * @sizeOf(usize);
                const elems_bytes = bytes[elems_offset..];

                const elems = try std.ArrayList(State).initCapacity(allocator, len);

                var offset = 0;
                for (0..len) |i| {
                    const size = sizes.elem(i);
                    const elem = elems_bytes[offset..][0..size];
                    try elems.append(try initState(allocator, info.child.*, elem));
                    offset += size;
                }

                return State{
                    .List = .{
                        .List = elems,
                    },
                };
            }
            break :blk State{
                .List = .{
                    .Len = sizes.len(),
                },
            };
        },
        .Map => |info| blk: {
            const sizes = cy.chan.read([]const usize, bytes);
            const len = sizes.len();
            const entries_offset = (len + 1) * @sizeOf(usize);
            const entries_bytes = bytes[entries_offset..];

            var map = std.StringHashMap(State).init(allocator);
            try map.ensureUnusedCapacity(len);

            var entry_offset = 0;
            for (0..len) |i| {
                const entry_size = sizes.elem(i);
                const entry_bytes = entries_bytes[entry_offset..][0..entry_size];

                const entry_key = cy.chan.read([]const u8, entry_bytes);
                const entry_value = cy.chan.read([]const u8, entry_bytes[entry_key.len..]);

                if (typeHasState(info.value.*)) {
                    try map.put(entry_key, try initState(allocator, info.value.*, entry_value));
                } else {
                    try map.put(entry_key, undefined);
                }

                entry_offset += entry_size;
            }

            break :blk State{
                .Map = map,
            };
        },
        .Struct => |info| try initStructState(allocator, info, bytes),
        .Tuple => |info| initStructState(allocator, info, bytes),
        .Union => |info| blk: {
            var tag: u16 = undefined;
            var union_bytes: []const u8 = undefined;
            if (info.fields.len > 255) {
                tag = bytes[0];
                union_bytes = bytes[1..];
            } else {
                if (info.fields > 65535) {
                    return error.UnionFieldsExceededLimit;
                }
                tag = cy.chan.read(u16, bytes);
                union_bytes = bytes[2..];
            }

            const field = info.fields[tag];
            var child: *State = undefined;
            if (typeHasState(field.type)) {
                child = try allocator.create(State);
                child.* = try initState(allocator, field.type, union_bytes);
            }

            break :blk State{
                .Union = .{
                    .tag = tag,
                    .child = child,
                },
            };
        },
    };
}

fn initStructState(allocator: std.mem.Allocator, info: anytype, bytes: []const u8) !State {
    var num_states: usize = 0;
    for (info.fields) |f| {
        if (typeHasState(f.type)) {
            num_states += 1;
        }
    }

    const states = try allocator.alloc(State, num_states);

    var i = 0;
    var offset: usize = 0;
    for (info.fields) |f| {
        const field_bytes = cy.chan.read([]const u8, bytes[offset..]);
        if (typeHasState(f.type)) {
            states[i] = try initState(allocator, f.type, field_bytes);
            i += 1;
        }
        offset += @sizeOf(usize);
        offset += field_bytes.len;
    }

    return State{
        .Struct = states,
    };
}

fn deinitState(allocator: std.mem.Allocator, t: cy.def.Type, state: State) void {
    switch (t) {
        .Void, .Bool, .String, .Int, .Float, .Enum, .Ref, .Any => {},
        .Optional => |info| {
            switch (state.Optional) {
                .Some => |child| {
                    deinitState(allocator, info.child.*, child);
                },
                .None => {},
            }
        },
        .List => |info| {
            switch (state.List) {
                .Len => {},
                .Items => |list| {
                    for (list.items) |elem_state| {
                        deinitState(allocator, info.child.*, elem_state);
                    }
                    list.deinit();
                },
            }
        },
        .Map => |info| {
            var map = state.Map;
            var iter = map.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                deinitState(allocator, info.value.*, entry.value_ptr.*);
            }
            map.deinit();
        },
        .Array => |info| {
            const array = state.Array;
            for (0..info.len) |i| {
                deinitState(allocator, info.child.*, array[i]);
            }
            allocator.free(array);
        },
        .Struct, .Tuple => |info| {
            const field_states = state.Struct;
            var i = 0;
            for (info.fields) |f| {
                if (typeHasState(f.type)) {
                    deinitState(allocator, f.type, field_states[i]);
                    i += 1;
                    if (i == field_states.len) break;
                }
            }
            allocator.free(field_states);
        },
        .Union => |info| {
            const val = state.Union;
            const f = info.fields[val.tag];
            if (typeHasState(f.type)) {
                deinitState(allocator, f.type, val.child.*);
            }
        },
    }
}

fn typeHasState(t: cy.def.Type) bool {
    return switch (t) {
        .Void, .Bool, .Int, .Float, .Enum, .Ref, .Any => false,
        .String, .Optional, .List, .Map => true,
        .Array => |info| typeHasState(info.child.*),
        .Struct => |info| for (info.fields) |f| {
            if (typeHasState(f.type)) break true;
        } else false,
        .Tuple => |info| for (info.fields) |f| {
            if (typeHasState(f)) break true;
        } else false,
        .Union => |info| for (info.fields) |f| {
            if (typeHasState(f.type)) break true;
        } else false,
    };
}
