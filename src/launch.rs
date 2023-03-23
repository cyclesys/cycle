use std::{
    mem::{self, MaybeUninit},
    ptr,
};

pub use windows::core::Error as WindowsError;
use windows::{
    core::{w, PWSTR},
    Win32::{
        Foundation::{
            SetHandleInformation, BOOL, HANDLE, HANDLE_FLAGS, HANDLE_FLAG_INHERIT,
            INVALID_HANDLE_VALUE,
        },
        Security::SECURITY_ATTRIBUTES,
        System::{
            Memory::{CreateFileMappingW, PAGE_READWRITE},
            Threading::{
                CreateEventW, CreateMutexW, CreateProcessW, PROCESS_CREATION_FLAGS,
                PROCESS_INFORMATION, STARTUPINFOW,
            },
        },
    },
};

pub use libcycle::channel::Error as ChannelError;
use libcycle::channel::{self, ChannelView};

pub enum Error {
    Channel(ChannelError),
    Windows(WindowsError),
}

pub type Result<T> = std::result::Result<T, Error>;

#[inline]
fn result_from_channel<T>(result: channel::Result<T>) -> Result<T> {
    match result {
        Ok(res) => Ok(res),
        Err(err) => Err(Error::Channel(err)),
    }
}

#[inline]
fn result_from_windows<T>(result: windows::core::Result<T>) -> Result<T> {
    match result {
        Ok(res) => Ok(res),
        Err(err) => Err(Error::Windows(err)),
    }
}

struct Child {
    info: PROCESS_INFORMATION,
    input: ChannelView,
    output: ChannelView,
}

pub struct Launcher {
    children: Vec<Child>,
}

impl Launcher {
    pub fn launch(&mut self, exe: String) -> Result<()> {
        fn create_channel_view() -> Result<ChannelView> {
            // The handles are inheritable by child processes
            let handle_attr: SECURITY_ATTRIBUTES = SECURITY_ATTRIBUTES {
                nLength: mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
                lpSecurityDescriptor: ptr::null_mut(),
                bInheritHandle: true.into(),
            };

            let view = unsafe {
                ChannelView::create(
                    result_from_windows(CreateFileMappingW(
                        INVALID_HANDLE_VALUE,
                        Some(&handle_attr),
                        PAGE_READWRITE,
                        0,
                        ChannelView::SIZE as u32,
                        None,
                    ))?,
                    result_from_windows(CreateMutexW(Some(&handle_attr), true, None))?,
                )
            };
            result_from_channel(view)
        }
        fn cleanup_channel_view_handles(view: &ChannelView) -> Result<()> {
            fn make_handle_uninheritable(handle: HANDLE) -> Result<()> {
                if unsafe { SetHandleInformation(handle, HANDLE_FLAG_INHERIT.0, HANDLE_FLAGS(0)) }
                    == false
                {
                    Err(Error::Windows(windows::core::Error::from_win32()))
                } else {
                    Ok(())
                }
            }
            make_handle_uninheritable(view.file())?;
            make_handle_uninheritable(view.mutex())?;
            Ok(())
        }

        let input = create_channel_view()?;
        let output = create_channel_view()?;

        let info = unsafe {
            let mut cmd_line: Vec<u16> = channel::create_cmd_line(exe, &input, &output)
                .encode_utf16()
                .collect();
            cmd_line.push(0); // null terminator

            let mut info = MaybeUninit::<PROCESS_INFORMATION>::uninit();

            if CreateProcessW(
                None,
                PWSTR(cmd_line.as_mut_ptr()),
                None,
                None,
                true,
                PROCESS_CREATION_FLAGS::default(),
                None,
                None,
                &STARTUPINFOW {
                    cb: mem::size_of::<STARTUPINFOW>() as u32,
                    ..Default::default()
                },
                info.as_mut_ptr(),
            ) == false
            {
                return Err(Error::Windows(windows::core::Error::from_win32()));
            }

            info.assume_init()
        };

        cleanup_channel_view_handles(&input)?;
        cleanup_channel_view_handles(&output)?;

        self.children.push(Child {
            info,
            input,
            output,
        });

        Ok(())
    }
}
