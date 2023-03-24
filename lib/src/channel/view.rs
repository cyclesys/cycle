use std::slice;

use windows::Win32::{
    Foundation::HANDLE,
    System::Memory::{MapViewOfFile, FILE_MAP_ALL_ACCESS},
};

use super::{Error, Result, WindowsError};

pub struct ChannelMessage<'a> {
    pub bytes_left: usize,
    pub bytes: &'a [u8],
}

pub struct ChannelView {
    file: HANDLE,
    ptr: *mut u8,
}

impl ChannelView {
    pub fn file(&self) -> HANDLE {
        self.file
    }
}

impl ChannelView {
    pub const SIZE: usize = 4 * 1024;
    // channel_size - message_state - write_size - bytes_left = 4085
    pub const MAX_WRITE: usize = Self::SIZE - 1 - 2 - 8;

    pub fn create(file: HANDLE) -> Result<Self> {
        let ptr = unsafe { MapViewOfFile(file, FILE_MAP_ALL_ACCESS, 0, 0, Self::SIZE) };
        if ptr.is_null() {
            return Err(Error::Windows(WindowsError::from_win32()));
        }
        Ok(Self {
            file,
            ptr: ptr.cast(),
        })
    }

    pub fn read(&self) -> Result<ChannelMessage> {
        let bytes = unsafe { slice::from_raw_parts(self.ptr, Self::SIZE) };
        let mut cursor: usize = 0;
        let mut read_bytes = |size: usize| -> &[u8] {
            let bytes = &bytes[cursor..(cursor + size)];
            cursor += size;
            bytes
        };

        let write_size = {
            let mut payload_size = [0; 2];
            payload_size.copy_from_slice(read_bytes(2));
            u16::from_le_bytes(payload_size) as usize
        };

        if write_size > Self::MAX_WRITE {
            return Err(Error::ChannelInvalidState);
        }

        let bytes_left = {
            let mut bytes_left = [0; 8];
            bytes_left.copy_from_slice(read_bytes(8));
            usize::from_le_bytes(bytes_left)
        };

        Ok(ChannelMessage {
            bytes_left,
            bytes: read_bytes(write_size),
        })
    }

    pub fn write(&mut self, message: ChannelMessage) -> Result<()> {
        let bytes = unsafe { slice::from_raw_parts_mut(self.ptr, Self::SIZE) };
        let mut cursor: usize = 0;
        let mut write_bytes = |new_bytes: &[u8]| {
            bytes[cursor..(cursor + new_bytes.len())].copy_from_slice(new_bytes);
            cursor += new_bytes.len();
        };

        if message.bytes.len() > Self::MAX_WRITE {
            return Err(Error::ChannelInvalidWrite);
        }

        let write_size = message.bytes.len() as u16;
        write_bytes(&write_size.to_le_bytes());
        write_bytes(&message.bytes_left.to_le_bytes());
        write_bytes(message.bytes);

        Ok(())
    }
}
