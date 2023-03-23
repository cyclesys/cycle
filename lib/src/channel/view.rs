use std::slice;

use windows::Win32::{
    Foundation::{HANDLE, WAIT_ABANDONED, WAIT_FAILED, WAIT_OBJECT_0, WAIT_TIMEOUT},
    System::{
        Memory::{MapViewOfFile, FILE_MAP_ALL_ACCESS},
        Threading::{ReleaseMutex, WaitForSingleObject},
        WindowsProgramming::INFINITE,
    },
};

use super::{Error, Result, WindowsError};

pub enum ChannelMessage<'a> {
    /// A message exists.
    Some { bytes_left: usize, bytes: &'a [u8] },

    /// No messages exist in the channel.
    /// The consumer must set the channel to this state once it has consumed a posted message.
    None,
}

pub struct ChannelView {
    file: HANDLE,
    mutex: HANDLE,
    locked: bool,
    ptr: *mut u8,
}

impl ChannelView {
    pub fn file(&self) -> HANDLE {
        self.file
    }

    pub fn mutex(&self) -> HANDLE {
        self.mutex
    }
}

impl ChannelView {
    pub const SIZE: usize = 4 * 1024;
    // channel_size - message_state - write_size - bytes_left = 4085
    pub const MAX_WRITE: usize = Self::SIZE - 1 - 2 - 8;

    pub fn create(file: HANDLE, mutex: HANDLE) -> Result<Self> {
        let ptr = unsafe { MapViewOfFile(file, FILE_MAP_ALL_ACCESS, 0, 0, Self::SIZE) };
        if ptr.is_null() {
            return Err(Error::Windows(WindowsError::from_win32()));
        }
        Ok(Self {
            file,
            mutex,
            locked: false,
            ptr: ptr.cast(),
        })
    }

    pub fn lock(&mut self) -> Result<()> {
        if self.locked {
            return Err(Error::ChannelLockFailed(None));
        }

        match unsafe { WaitForSingleObject(self.mutex, INFINITE) } {
            WAIT_OBJECT_0 => {
                self.locked = true;
                Ok(())
            }
            WAIT_TIMEOUT => Err(Error::ChannelLockFailed(None)),
            WAIT_ABANDONED => Err(Error::ChannelTerminated),
            WAIT_FAILED => Err(Error::ChannelLockFailed(Some(WindowsError::from_win32()))),
            _ => unreachable!(),
        }
    }

    pub fn unlock(&mut self) -> Result<()> {
        if !self.locked {
            return Err(Error::ChannelUnlockFailed(None));
        }

        if unsafe { ReleaseMutex(self.mutex) } == false {
            Err(Error::ChannelUnlockFailed(Some(WindowsError::from_win32())))
        } else {
            self.locked = false;
            Ok(())
        }
    }

    pub fn read(&self) -> Result<ChannelMessage> {
        if !self.locked {
            return Err(Error::ChannelUsedUnlocked);
        }

        let bytes = unsafe { slice::from_raw_parts(self.ptr, Self::SIZE) };
        let mut cursor: usize = 0;
        let mut read_bytes = |size: usize| -> &[u8] {
            let bytes = &bytes[cursor..(cursor + size)];
            cursor += size;
            bytes
        };

        let message_state = read_bytes(1)[0];
        match message_state {
            0 => Ok(ChannelMessage::None),
            1 => {
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

                Ok(ChannelMessage::Some {
                    bytes_left,
                    bytes: read_bytes(write_size),
                })
            }
            _ => Err(Error::ChannelInvalidState),
        }
    }

    pub fn write(&mut self, message: ChannelMessage) -> Result<()> {
        if !self.locked {
            return Err(Error::ChannelUsedUnlocked);
        }

        let bytes = unsafe { slice::from_raw_parts_mut(self.ptr, Self::SIZE) };
        let mut cursor: usize = 0;
        let mut write_bytes = |new_bytes: &[u8]| {
            bytes[cursor..(cursor + new_bytes.len())].copy_from_slice(new_bytes);
            cursor += new_bytes.len();
        };

        match message {
            ChannelMessage::Some {
                bytes_left,
                bytes: msg_bytes,
            } => {
                if msg_bytes.len() > Self::MAX_WRITE {
                    return Err(Error::ChannelInvalidWrite);
                }

                write_bytes(&[1]);

                let write_size = msg_bytes.len() as u16;
                write_bytes(&write_size.to_le_bytes());

                write_bytes(&bytes_left.to_le_bytes());
                write_bytes(msg_bytes);
            }
            ChannelMessage::None => {
                write_bytes(&[0]);
            }
        }

        Ok(())
    }
}
