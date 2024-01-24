const windows = @import("std").os.windows;

pub const TRUE = windows.TRUE;
pub const FALSE = windows.FALSE;

pub const PROCESS_INFORMATION = windows.PROCESS_INFORMATION;
pub const STARTUPINFOW = windows.STARTUPINFOW;

pub const CreateProcessW = windows.CreateProcessW;
pub const TerminateProcess = windows.TerminateProcess;
