use serde::{Deserialize, Serialize};
use std::{mem, slice};

use windows::Win32::{
    Foundation::HANDLE,
    System::Memory::{MapViewOfFile, FILE_MAP_ALL_ACCESS},
};

use super::{de::ChannelDeserializer, ser::ChannelSerializer, Error, Result, WindowsError};

#[derive(Serialize, Deserialize)]
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
    // channel_size - bytes_left - bytes_len
    pub const MAX_WRITE: usize = Self::SIZE - (mem::size_of::<usize>() * 2);

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
        ChannelDeserializer::deserialize(bytes)
    }

    pub fn write(&self, message: ChannelMessage) -> Result<()> {
        // TODO: serialize directly into chan_bytes
        let msg_bytes = ChannelSerializer::serialize(&message)?;
        let chan_bytes = unsafe { slice::from_raw_parts_mut(self.ptr, Self::SIZE) };
        let write_bytes = &mut chan_bytes[0..msg_bytes.len()];
        write_bytes.copy_from_slice(&msg_bytes);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{ChannelMessage, ChannelView, HANDLE};

    #[test]
    fn channel_view_read_write() {
        let mut bytes = [0; ChannelView::SIZE];
        let view = ChannelView {
            // not used
            file: HANDLE(0),
            ptr: bytes.as_mut_ptr(),
        };

        view.write(ChannelMessage {
            bytes_left: 100,
            bytes: &[10, 20, 30, 40, 50],
        })
        .unwrap();

        let message = view.read().unwrap();

        assert_eq!(message.bytes_left, 100);
        assert_eq!(message.bytes, &[10, 20, 30, 40, 50]);
    }
}
