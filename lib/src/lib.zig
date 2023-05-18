pub const define = @import("define.zig");
pub const definition = @import("definition.zig");
pub const render = @import("render.zig");

pub const CommandScheme = definition.CommandScheme;
pub const FunctionScheme = definition.FunctionScheme;

test {
    _ = @import("channel.zig");
    _ = @import("definition.zig");
    _ = @import("object.zig");
    _ = @import("serde.zig");
}
