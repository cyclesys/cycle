use std::mem::{self, MaybeUninit};

pub use windows::core::Error as WindowsError;
use windows::{
    core::PWSTR,
    Win32::{
        Foundation::{SetHandleInformation, HANDLE, HANDLE_FLAGS, HANDLE_FLAG_INHERIT},
        System::Threading::{
            CreateProcessW, PROCESS_CREATION_FLAGS, PROCESS_INFORMATION, STARTUPINFOW,
        },
    },
};

pub use libcycle::channel::Error as ChannelError;
use libcycle::channel::{
    self, ChannelSync, ChannelView, InputChannel, OutputChannel, PluginMessage, SystemMessage,
};

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
    input: InputChannel<PluginMessage>,
    output: OutputChannel<SystemMessage>,
}

pub struct Launcher {
    children: Vec<Child>,
}

impl Launcher {
    pub fn launch(&mut self, exe: String) -> Result<()> {
        fn set_handle_inheritable(handle: HANDLE, inheritable: bool) -> Result<()> {
            if unsafe {
                SetHandleInformation(
                    handle,
                    HANDLE_FLAG_INHERIT.0,
                    HANDLE_FLAGS(inheritable.into()),
                )
            } == false
            {
                Err(Error::Windows(windows::core::Error::from_win32()))
            } else {
                Ok(())
            }
        }
        fn setup_channel_resource_handles(sync: &ChannelSync, view: &ChannelView) -> Result<()> {
            set_handle_inheritable(sync.wait_event(), true)?;
            set_handle_inheritable(sync.signal_event(), true)?;
            set_handle_inheritable(view.file(), true)
        }
        fn cleanup_channel_resource_handles(sync: &ChannelSync, view: &ChannelView) -> Result<()> {
            set_handle_inheritable(sync.wait_event(), false)?;
            set_handle_inheritable(sync.signal_event(), false)?;
            set_handle_inheritable(view.file(), false)
        }

        // The input channel should start out owned by the plugin, hence the wait_event starts out
        // unsignaled, and the signal_event starts out signaled.
        let (input_sync, input_view) = result_from_channel(channel::create_channel(false))?;
        setup_channel_resource_handles(&input_sync, &input_view)?;

        // The output channel should start out owned by the system, hence the wait_event starts out
        // signaled, and the signal_event starts out unsignaled.
        let (output_sync, output_view) = result_from_channel(channel::create_channel(true))?;
        setup_channel_resource_handles(&output_sync, &output_view)?;

        let info = unsafe {
            let mut cmd_line: Vec<u16> =
                channel::format_cmd_line(exe, &input_sync, &input_view, &output_sync, &output_view)
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
            input: InputChannel::new(input_sync, input_view),
            output: OutputChannel::new(output_sync, output_view),
        });

        Ok(())
    }
}
