const std = @import("std");
const define = @import("define.zig");
const definition = @import("definition.zig");
const SharedMem = @import("SharedMem.zig");

pub const TypeId = packed struct {
    scheme: u16,
    name: u32,
};

pub const ObjectId = packed struct {
    scheme: u16,
    source: u16,
    name: u32,
};

pub const Object = struct {
    type: TypeId,
    id: ObjectId,
    mem: SharedMem,
};

test {
    _ = @import("object/index.zig");
}
