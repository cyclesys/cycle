use windows::{
    core::Error as WindowsError,
    Win32::{
        Foundation::HANDLE,
        System::Memory::{MapViewOfFile, FILE_MAP_ALL_ACCESS},
    },
};

pub enum Error {
    Windows(WindowsError),
}

pub(super) type Result<T> = std::result::Result<T, Error>;

pub(super) struct ChannelView {
    raw: *mut u8,
}

impl ChannelView {
    pub fn create(file: HANDLE) -> Result<Self> {
        let result = unsafe {
            MapViewOfFile(
                file,
                FILE_MAP_ALL_ACCESS,
                0,
                0,
                super::CHANNEL_SIZE as usize,
            )
        };

        if result.is_null() {
            return Err(Error::Windows(WindowsError::from_win32()));
        }

        Ok(Self { raw: result.cast() })
    }
}
