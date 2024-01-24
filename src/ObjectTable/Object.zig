const std = @import("std");
const cy = @import("cycle");
const serde = @import("serde.zig");

type_id: cy.def.TypeId,
type: cy.def.Type,
state: State,

const State = union(enum) {
    String: struct {
        len: usize,
    },
    Optional: union(enum) {
        Some: *State,
        None: void,
    },
    Array: []State,
    List: union(enum) {
        Len: usize,
        Items: std.ArrayList(State),
    },
    Map: std.StringHashMap(State),
    Struct: []State,
    Tuple: []State,
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

fn initState(allocator: std.mem.Allocator, t: cy.def.Type, bytes: []const u8) !State {
    switch (t) {
        .Void, .Bool, .Int, .Float, .Enum, .Ref, .Any => {
            return undefined;
        },
        .String => {
            const str = cy.chan.read([]const u8, bytes);
            return State{
                .String = .{ .len = str.len },
            };
        },
        .Optional => |info| {
            if (serde.readOptional(bytes)) |child_bytes| {
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
            return State{
                .Optional = .None,
            };
        },
        .Array => |info| {
            var states: []const State = undefined;
            if (typeHasState(info.child.*)) {
                states = try allocator.alloc(State, @intCast(info.len));

                for (0..info.len) |i| {
                    const elem = serde.readElem(bytes, i);
                    states[i] = try initState(allocator, info.child.*, elem);
                }
            }
            return State{
                .Array = states,
            };
        },
        .List => |info| {
            const elems = serde.NewList.init(bytes);
            if (typeHasState(info.child.*)) {
                var list = try std.ArrayList(State).initCapacity(allocator, elems.len());
                for (0..elems.len()) |i| {
                    const elem = elems.elemBytes(i);
                    try list.append(try initState(allocator, info.child.*, elem));
                }
                return State{
                    .List = .{
                        .List = list,
                    },
                };
            }
            return State{
                .List = .{
                    .Len = elems.len(),
                },
            };
        },
        .Map => |info| {
            const entries = serde.NewMap.init(bytes);
            var map = std.StringHashMap(State).init(allocator);
            try map.ensureUnusedCapacity(entries.len());

            for (0..entries.len()) |i| {
                const entry = entries.elem(i);
                const entry_key = entry.fieldBytes(.key);
                const entry_value = entry.fieldBytes(.value);

                if (typeHasState(info.value.*)) {
                    try map.put(entry_key, try initState(allocator, info.value.*, entry_value));
                } else {
                    try map.put(entry_key, undefined);
                }
            }

            return State{
                .Map = map,
            };
        },
        .Struct => |info| try initStructState(allocator, info, bytes),
        .Tuple => |info| try initStructState(allocator, info, bytes),
        .Union => |info| {
            const val = serde.Union(void).init(bytes);
            const tag = val.tagValue();
            if (tag >= info.fields.len) {
                return error.InvalidUnion;
            }
            const field = info.fields[tag];

            var child: *State = undefined;
            if (typeHasState(field.type)) {
                child = try allocator.create(State);
                child.* = try initState(allocator, field.type, val.fieldBytes());
            }

            return State{
                .Union = .{
                    .tag = tag,
                    .child = child,
                },
            };
        },
    }
}

fn initStructState(allocator: std.mem.Allocator, info: anytype, bytes: []const u8) !State {
    var num_states: usize = 0;
    for (info.fields) |f| {
        if (typeHasState(f.type)) {
            num_states += 1;
        }
    }

    const states = try allocator.alloc(State, num_states);

    var si: usize = 0;
    for (info.fields, 0..) |f, fi| {
        const field_bytes = serde.readElem(bytes, fi);
        if (typeHasState(f.type)) {
            states[si] = try initState(allocator, f.type, field_bytes);
            si += 1;
        }
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
            if (typeHasState(info.child.*)) {
                const array = state.Array;
                for (0..info.len) |i| {
                    deinitState(allocator, info.child.*, array[i]);
                }

                allocator.free(array);
            }
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

pub fn update(self: *Self, allocator: std.mem.Allocator, bytes: []const u8) !bool {
    if (updateIsValid(self.type, self.state, bytes)) {
        try updateState(allocator, self.type, &self.state, bytes);
        return true;
    }
    return false;
}

fn updateIsValid(t: cy.def.Type, state: State, bytes: []const u8) bool {
    switch (t) {
        .Void, .Bool, .Int, .Float, .Enum, .Ref, .Any => {},
        .String => {
            const ops = cy.chan.read(cy.obj.MutateString, bytes);
            for (0..ops.len()) |i| {
                const op = ops.elem(i);
                switch (op.tag()) {
                    .Append, .Prepend => {},
                    .Insert => {
                        const ins = op.value(.Insert);
                        const index = ins.field(.index);
                        if (index > state.String.len) {
                            return false;
                        }
                    },
                    .Delete => {
                        const del = op.value(.Delete);
                        const index = del.field(.index);
                        const len = del.field(.len);
                        if (index >= state.String.len or
                            (index + len) > state.String.len)
                        {
                            return false;
                        }
                    },
                }
            }
        },
        .Optional => |info| {
            const opt = serde.MutateOptional.init(bytes);
            switch (opt.tag()) {
                .New, .None => {},
                .Mutate => {
                    if (typeHasState(info.child.*)) {
                        switch (state.Optional) {
                            .Some => |child_state| {
                                return updateIsValid(info.child.*, child_state.*, opt.fieldBytes());
                            },
                            .None => {
                                return false;
                            },
                        }
                    }
                },
            }
        },
        .Array => |info| {
            const ops = serde.MutateArray.init(bytes);
            for (0..ops.len()) |i| {
                const op = ops.elem(i);
                const index = op.fieldValue(.index);

                if (index < info.len) {
                    return false;
                }

                if (typeHasState(info.child.*)) {
                    if (!updateIsValid(info.child.*, state.Array[index], op.fieldBytes(.elem))) {
                        return false;
                    }
                }
            }
        },
        .List => |info| {
            const ops = serde.MutateList.init(bytes);
            for (0..ops.len()) |i| {
                const op = ops.elem(i);
                switch (op.tag()) {
                    .Append, .Prepend => {},
                    .Insert => {
                        const ins = serde.MutateListInsertOp.init(op.fieldBytes());
                        const index = ins.fieldValue(.index);
                        return switch (state.List) {
                            .Items => |list| index <= list.items.len,
                            .Len => |len| index <= len,
                        };
                    },
                    .Delete => {
                        const index = op.fieldValue(.Delete);
                        return switch (state.List) {
                            .Items => |list| index < list.items.len,
                            .Len => |len| index < len,
                        };
                    },
                    .Mutate => {
                        const mut = serde.MutateListMutateOp.init(op.fieldBytes());
                        const index = mut.fieldValue(.index);
                        const elem = mut.fieldBytes(.elem);
                        return switch (state.List) {
                            .Items => |list| index < list.items.len and
                                updateIsValid(info.child.*, list.items[index], elem),
                            .Len => |len| index < len,
                        };
                    },
                }
            }
        },
        .Map => |info| {
            const ops = serde.MutateMap.init(bytes);
            for (0..ops.len()) |i| {
                const op = ops.elem(i);
                switch (op.tag()) {
                    .Put => {},
                    .Remove => {
                        const key = op.fieldBytes();
                        if (!state.Map.contains(key)) {
                            return false;
                        }
                    },
                    .Mutate => {
                        const entry = serde.MapEntry.init(op.fieldBytes());
                        const key = entry.fieldBytes(.key);
                        const value = entry.fieldBytes(.value);
                        if (state.Map.get(key)) |value_state| {
                            if (typeHasState(info.value.*)) {
                                if (!updateIsValid(info.value.*, value_state, value)) {
                                    return false;
                                }
                            }
                        } else {
                            return false;
                        }
                    },
                }
            }
        },
        .Struct => |info| {
            return structUpdateIsValid(info, state.Struct, bytes);
        },
        .Tuple => |info| {
            return structUpdateIsValid(info, state.Tuple, bytes);
        },
        .Union => |info| {
            const mut = serde.Union(void).init(bytes);
            const tag = mut.tagValue();
            if (tag >= info.fields.len) {
                return false;
            }

            const field_info = info.fields[tag];
            const field = serde.MutateUnionField.init(mut.fieldBytes());

            switch (field.tag()) {
                .New => {},
                .Mutate => {
                    if (state.Union.tag != tag or
                        !updateIsValid(field_info.type, state.Union.child.*, field.fieldBytes()))
                    {
                        return false;
                    }
                },
            }
        },
    }
    return true;
}

fn structUpdateIsValid(info: anytype, state: []const State, bytes: []const u8) bool {
    var i: usize = 0;
    for (info.fields, 0..) |f, fi| {
        if (typeHasState(f.type)) {
            const field_bytes = serde.readElem(bytes, fi);
            if (serde.readOptional(field_bytes)) |upd_bytes| {
                if (!updateIsValid(f.type, state[i], upd_bytes)) {
                    return false;
                }
            }
            i += 1;
        }
    }
    return true;
}

fn updateState(allocator: std.mem.Allocator, t: cy.def.Type, state: *State, bytes: []const u8) !bool {
    switch (t) {
        .Void, .Bool, .Int, .Float, .Enum, .Ref, .Any => {},
        .String => {
            const ops = cy.chan.read(serde.MutateString, bytes);
            for (0..ops.len()) |i| {
                const op = ops.elem(i);
                switch (op.tag()) {
                    .Append => {
                        const str = op.value(.Append);
                        state.String.len += str.len;
                    },
                    .Prepend => {
                        const str = op.value(.Prepend);
                        state.String.len += str.len;
                    },
                    .Insert => {
                        const ins = op.value(.Insert);
                        const elem = ins.field(.elem);
                        state.String.len += elem.len;
                    },
                    .Delete => {
                        const del = op.value(.Delete);
                        const len = del.field(.len);
                        state.String.len -= len;
                    },
                }
            }
        },
        .Optional => |info| {
            const upd = serde.MutateOptional.init(bytes);
            switch (upd.tag()) {
                .New => |new_bytes| {
                    if (typeHasState(info.child.*)) {
                        switch (state.Optional) {
                            .Some => |child_state| {
                                deinitState(allocator, info.child.*, child_state.*);
                                child_state.* = try initState(allocator, info.child.*, new_bytes);
                            },
                            .None => {
                                const child_state = try allocator.create(State);
                                child_state.* = try initState(allocator, info.child.*, new_bytes);
                                state.Optional = .{ .Some = child_state };
                            },
                        }
                    } else {
                        state.Optional = .{ .Some = undefined };
                    }
                },
                .Mutate => |mut_bytes| {
                    if (typeHasState(info.child.*)) {
                        return try updateState(allocator, info.child.*, state.Optional.Some, mut_bytes);
                    }
                },
                .None => {
                    if (typeHasState(info.child.*) and state.Optional == .Some) {
                        deinitState(allocator, info.child.*, state.Optional.Some);
                        allocator.free(state.Optional.Some);
                    }
                    state.Optional = .None;
                },
            }
        },
        .Array => |info| {
            const ops = serde.MutateArray.init(bytes);
            for (0..ops.len()) |i| {
                const op = ops.elem(i);
                const index = op.field(.index);
                const elem = op.field(.elem);
                if (typeHasState(info.child.*)) {
                    return try updateState(allocator, info.child.*, &state.Array[index], elem);
                }
            }
        },
        .List => |info| {
            const ops = serde.MutateList.init(bytes);
            for (0..ops.len()) |i| {
                const op = ops.elem(i);
                switch (op.tag()) {
                    .Append => {
                        const elem = op.value(.Append);
                        if (typeHasState(info.child.*)) {
                            try state.List.Items.append(try initState(allocator, info.child.*, elem));
                        } else {
                            state.List.Len += 1;
                        }
                    },
                    .Prepend => {
                        const elem = op.value(.Prepend);
                        if (typeHasState(info.child.*)) {
                            try state.List.Items.insert(0, try initState(allocator, info.child.*, elem));
                        } else {
                            state.List.Len += 1;
                        }
                    },
                    .Insert => {
                        const ins = op.value(.Insert);
                        const index = ins.field(.index);
                        const elem = ins.field(.elem);
                        if (typeHasState(info.child.*)) {
                            try state.List.Items.insert(@intCast(index), try initState(allocator, info.child.*, elem));
                        } else {
                            state.List.Len += 1;
                        }
                    },
                    .Delete => {
                        const index = op.value(.Delete);
                        if (typeHasState(info.child.*)) {
                            const elem = state.List.Items.orderedRemove(index);
                            deinitState(allocator, info.child.*, elem);
                        } else {
                            state.List.Len -= 1;
                        }
                    },
                    .Mutate => {
                        const mut = op.value(.Mutate);
                        const index = mut.field(.index);
                        const elem = mut.field(.elem);
                        if (typeHasState(info.child.*)) {
                            try updateState(allocator, info.child.*, &state.List.Items.items[index], elem);
                        }
                    },
                }
            }
        },
        .Map => |info| {
            const ops = serde.MutateMap.init(bytes);
            for (0..ops.len()) |i| {
                const op = ops.elem(i);
                switch (op.tag()) {
                    .Put => {
                        const put = op.value(.Put);
                        const key = put.field(.key);
                        const value = put.field(.value);
                        const gop = try state.Map.getOrPut(key);
                        if (typeHasState(info.value.*)) {
                            if (gop.found_existing) {
                                deinitState(allocator, info.value.*, gop.value_ptr.*);
                            }
                            gop.value_ptr.* = try initState(allocator, info.value.*, value);
                        }

                        if (!gop.found_existing) {
                            gop.key_ptr.* = try allocator.dupe(u8, key);
                        }
                    },
                    .Remove => {
                        const key = op.value(.Remove);
                        const kv = state.Map.fetchRemove(key).?;
                        allocator.free(kv.key);
                        if (typeHasState(info.value.*)) {
                            deinitState(allocator, info.value.*, kv.value);
                        }
                    },
                    .Mutate => {
                        const mut = op.value(.Mutate);
                        const key = mut.field(.key);
                        const value = mut.field(.value);
                        const ptr = state.Map.getPtr(key).?;
                        if (typeHasState(info.value.*)) {
                            try updateState(allocator, info.value.*, ptr, value);
                        }
                    },
                }
            }
        },
        .Struct => |info| try updateStructState(allocator, info, state.Struct, bytes),
        .Tuple => |info| try updateStructState(allocator, info, state.Tuple, bytes),
        .Union => |info| {
            const mut = serde.Union(void).init(bytes);
            const tag = mut.tagValue();

            const field_info = info.fields[tag];
            const value = serde.MutateUnionField.init(mut.fieldBytes());

            switch (value.tag()) {
                .New => {
                    const current_field_info = info.fields[state.Union.tag];
                    if (typeHasState(current_field_info.type)) {
                        deinitState(allocator, current_field_info.type, state.Union.child.*);
                        state.Union.child.* = undefined;
                    }

                    state.Union.tag = tag;
                    if (typeHasState(field_info.type)) {
                        state.Union.child.* = try initState(allocator, field_info.type, value.fieldBytes());
                    }
                },
                .Mutate => {
                    try updateState(allocator, field_info.type, state.Union.child, value.fieldBytes());
                },
            }
        },
    }
}

fn updateStructState(allocator: std.mem.Allocator, info: anytype, state: []State, bytes: []const u8) !void {
    var si: usize = 0;
    for (info.fields, 0..) |field, fi| {
        if (typeHasState(field.type)) {
            const field_bytes = serde.readElem(bytes, fi);
            if (serde.readOptional(field_bytes)) |value| {
                try updateState(allocator, field.type, &state[si], value);
            }
            si += 1;
        }
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
