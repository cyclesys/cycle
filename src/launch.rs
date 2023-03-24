use std::{
    mem::{self, MaybeUninit},
    ptr,
};

pub use windows::core::Error as WindowsError;
use windows::{
    core::PWSTR,
    Win32::{
        Foundation::{
            SetHandleInformation, HANDLE, HANDLE_FLAGS, HANDLE_FLAG_INHERIT, INVALID_HANDLE_VALUE,
        },
        Security::SECURITY_ATTRIBUTES,
        System::{
            Memory::{CreateFileMappingW, PAGE_READWRITE},
            Threading::{
                CreateEventW, CreateProcessW, PROCESS_CREATION_FLAGS, PROCESS_INFORMATION,
                STARTUPINFOW,
            },
        },
    },
};

pub use libcycle::channel::Error as ChannelError;
use libcycle::channel::{self, ChannelSync, ChannelView};

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
    input_sync: ChannelSync,
    input_view: ChannelView,
    output_sync: ChannelSync,
    output_view: ChannelView,
}

pub struct Launcher {
    children: Vec<Child>,
}

impl Launcher {
    pub fn launch(&mut self, exe: String) -> Result<()> {
        fn create_channel_resources(initial_state: bool) -> Result<(ChannelSync, ChannelView)> {
            unsafe {
                // The handles are inheritable by child processes
                let handle_attr: SECURITY_ATTRIBUTES = SECURITY_ATTRIBUTES {
                    nLength: mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
                    lpSecurityDescriptor: ptr::null_mut(),
                    bInheritHandle: true.into(),
                };

                let view = result_from_channel(ChannelView::create(result_from_windows(
                    CreateFileMappingW(
                        INVALID_HANDLE_VALUE,
                        Some(&handle_attr),
                        PAGE_READWRITE,
                        0,
                        ChannelView::SIZE as u32,
                        None,
                    ),
                )?))?;

                let sync = ChannelSync::new(
                    result_from_windows(CreateEventW(
                        Some(&handle_attr),
                        true,
                        initial_state,
                        None,
                    ))?,
                    result_from_windows(CreateEventW(
                        Some(&handle_attr),
                        true,
                        !initial_state,
                        None,
                    ))?,
                );

                Ok((sync, view))
            }
        }
        fn cleanup_channel_resource_handles(sync: &ChannelSync, view: &ChannelView) -> Result<()> {
            fn make_handle_uninheritable(handle: HANDLE) -> Result<()> {
                if unsafe { SetHandleInformation(handle, HANDLE_FLAG_INHERIT.0, HANDLE_FLAGS(0)) }
                    == false
                {
                    Err(Error::Windows(windows::core::Error::from_win32()))
                } else {
                    Ok(())
                }
            }
            make_handle_uninheritable(sync.wait_event())?;
            make_handle_uninheritable(sync.signal_event())?;
            make_handle_uninheritable(view.file())?;
            Ok(())
        }

        // The input channel should start out owned by the plugin, hence the wait_event starts out
        // unsignaled, and the signal_event starts out signaled.
        let (input_sync, input_view) = create_channel_resources(false)?;

        // The output channel should start out owned by the system, hence the wait_event starts out
        // signaled, and the signal_event starts out unsignaled.
        let (output_sync, output_view) = create_channel_resources(true)?;

        let info = unsafe {
            let mut cmd_line: Vec<u16> =
                channel::create_cmd_line(exe, &input_sync, &input_view, &output_sync, &output_view)
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

        cleanup_channel_resource_handles(&input_sync, &input_view)?;
        cleanup_channel_resource_handles(&output_sync, &output_view)?;

        self.children.push(Child {
            info,
            input_sync,
            input_view,
            output_sync,
            output_view,
        });

        Ok(())
    }
}
