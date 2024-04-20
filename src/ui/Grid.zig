//!
cells: std.ArrayListUnmanaged(Cell),
elements: FreeList(Element),
nodes: FreeList(Node),

num_cols: u32,
num_rows: u32,

const Cell = struct {
    // The first element in this cell
    head: u32,
};

// A single entry in a cell.
const Element = struct {
    node: u32,
    next: u32,
};

const Node = struct {
    id: Store.Id,
};

// cells have a fixed size of 48x48.
const cell_size = 48;
const null_index = std.math.maxInt(u32);

const std = @import("std");
const FreeList = @import("../free_list.zig").FreeList;
const Store = @import("../Store.zig");
const Grid = @This();

pub fn init(allocator: std.mem.Allocator, width: f32, height: f32) !Grid {
    const num_cols: u32 = @intFromFloat(@ceil(width / cell_size));
    const num_rows: u32 = @intFromFloat(@ceil(height / cell_size));

    var cells = std.ArrayListUnmanaged(Cell){};
    try cells.resize(allocator, num_cols * num_rows);
    @memset(cells.items, Cell{ .head = null_index });

    return Grid{
        .cells = cells,
        .elements = .{},
        .nodes = .{},
        .num_cols = num_cols,
        .num_rows = num_rows,
    };
}

pub fn deinit(self: *Grid, allocator: std.mem.Allocator) void {
    self.cells.deinit(allocator);
    self.elements.deinit(allocator);
    self.ids.deinit(allocator);
    self.* = undefined;
}

pub fn insert(
    self: *Grid,
    allocator: std.mem.Allocator,
    id: Store.Id,
    left: f32,
    top: f32,
    width: f32,
    height: f32,
) !void {
    const right = left + width;
    const bottom = top + height;

    const first_row = @min(
        @as(u32, @intFromFloat(@floor(top / cell_size))),
        self.num_rows - 1,
    );
    const last_row = @min(
        @as(u32, @intFromFloat(@floor(bottom / cell_size))),
        self.num_rows - 1,
    );

    const first_col = @min(
        @as(u32, @intFromFloat(@floor(left / cell_size))),
        self.num_cols - 1,
    );
    const last_col = @min(
        @as(u32, @intFromFloat(@floor(right / cell_size))),
        self.num_cols - 1,
    );

    const node_index = try self.nodes.put(allocator, Node{
        .id = id,
        .left = left,
        .top = top,
    });

    for (first_row..(last_row + 1)) |ri| {
        const row_cells = self.cells.items[ri * self.num_cols ..];
        for (first_col..(last_col + 1)) |ci| {
            const cell_index = ri + ci;
            const element_index = try self.elements.put(allocator, Element{
                .node = node_index,
                .next = row_cells[cell_index].head,
            });
            row_cells[cell_index].head = element_index;
        }
    }
}

pub fn cellAtPoint(self: Grid, x: f32, y: f32) u32 {
    const col_i: u32 = @intFromFloat(@floor(x / cell_size));
    const row_i: u32 = @intFromFloat(@floor(y / cell_size));
    const cell_index = (row_i * self.num_cols) + col_i;
    return cell_index;
}
