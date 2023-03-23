use windows::{
    core::Error as WindowsError,
    Win32::{
        Foundation::HANDLE,
        System::Memory::{MapViewOfFile, FILE_MAP_ALL_ACCESS},
    },
};

use super::{Error, Result};

pub enum ViewState {
    Some,
    None,
}

pub struct ChannelView {
    pub file: HANDLE,
    pub mutex: HANDLE,
    pub wait_event: HANDLE,
    pub signal_event: HANDLE,
    ptr: *mut u8,
}

impl ChannelView {
    pub const SIZE: u32 = 4 * 1024;

    pub fn create(
        file: HANDLE,
        mutex: HANDLE,
        wait_event: HANDLE,
        signal_event: HANDLE,
    ) -> Result<Self> {
        let ptr = unsafe { MapViewOfFile(file, FILE_MAP_ALL_ACCESS, 0, 0, Self::SIZE as usize) };
        if ptr.is_null() {
            return Err(Error::Windows(WindowsError::from_win32()));
        }
        Ok(Self {
            file,
            mutex,
            wait_event,
            signal_event,
            ptr: ptr.cast(),
        })
    }

    pub fn acquire(&mut self) -> Result<()> {
        Ok(())
    }
}
