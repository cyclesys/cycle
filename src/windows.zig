const windows = @import("std").os.windows;

pub usingnamespace windows.user32;
pub usingnamespace windows.kernel32;

pub const HANDLE = windows.HANDLE;
pub const HWND = windows.HWND;
