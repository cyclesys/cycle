const windows = struct {
    const mod = @import("win32");
    usingnamespace mod.foundation;
    usingnamespace mod.system.memory;
};

const SharedMem = @This();

pub const Error = error{
    CreateMemFailed,
    MapMemFailed,
};

handle: windows.HANDLE,
view: []u8,

pub fn init(size: usize) Error!SharedMem {
    const handle = windows.CreateFileMappingW(
        windows.INVALID_HANDLE_VALUE,
        null,
        windows.PAGE_READWRITE,
        0,
        @intCast(u32, size),
        null,
    );
    if (handle == null) {
        return error.CreateMemFailed;
    }

    const view = try mapView(handle.?, size);

    return SharedMem{
        .handle = handle.?,
        .view = view,
    };
}

pub fn import(handle: windows.HANDLE, size: usize) Error!SharedMem {
    const view = try mapView(handle, size);
    return SharedMem{
        .handle = handle,
        .view = view,
    };
}

fn mapView(handle: windows.HANDLE, size: usize) Error![]u8 {
    const ptr = windows.MapViewOfFile(handle, windows.FILE_MAP_ALL_ACCESS, 0, 0, size);
    if (ptr == null) {
        return error.MapMemFailed;
    }

    var view: []u8 = undefined;
    view.ptr = @ptrCast([*]u8, ptr.?);
    view.len = size;

    return view;
}

pub fn deinit(self: *SharedMem) void {
    _ = windows.UnmapViewOfFile(self.view.ptr);
    self.view.ptr = undefined;
    self.view.len = 0;

    _ = windows.CloseHandle(self.handle);
}
