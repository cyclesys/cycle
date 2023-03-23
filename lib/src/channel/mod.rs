use std::env;

pub use windows::core::Error as WindowsError;
use windows::Win32::Foundation::HANDLE;

mod messages;
pub use messages::{PluginMessage, SystemMessage};

mod view;
pub use view::ChannelView;

pub enum Error {
    InvalidCmdLineArgs,
    ChannelLockFailed(Option<WindowsError>),
    ChannelUnlockFailed(Option<WindowsError>),
    ChannelTerminated,
    ChannelUsedUnlocked,
    ChannelInvalidState,
    ChannelInvalidWrite,
    Windows(WindowsError),
}

pub type Result<T> = std::result::Result<T, Error>;

pub struct InputChannel {
    view: ChannelView,
}

impl InputChannel {
    pub fn read(&mut self) -> Result<SystemMessage> {
        todo!()
    }
}

pub struct OutputChannel {
    view: ChannelView,
}

impl OutputChannel {
    pub fn write(&mut self, msg: PluginMessage) -> Result<()> {
        todo!()
    }
}

/// Opens the channels created by the system for the plugin.
pub fn open() -> Result<(InputChannel, OutputChannel)> {
    let args: Vec<String> = env::args().collect();

    let handle = |idx: usize| -> Result<HANDLE> {
        if let Ok(handle) = isize::from_str_radix(args[idx].as_str(), 16) {
            Ok(HANDLE(handle))
        } else {
            Err(Error::InvalidCmdLineArgs)
        }
    };

    if args.len() != 9 {
        Err(Error::InvalidCmdLineArgs)
    } else {
        let output_file = handle(1)?;
        let output_mutex = handle(2)?;
        let input_file = handle(3)?;
        let input_mutex = handle(4)?;
        Ok((
            InputChannel {
                view: ChannelView::create(input_file, input_mutex)?,
            },
            OutputChannel {
                view: ChannelView::create(output_file, output_mutex)?,
            },
        ))
    }
}

pub fn create_cmd_line(exe: String, input: &ChannelView, output: &ChannelView) -> String {
    format!(
        "{} {:x} {:x} {:x} {:x}",
        exe,
        input.file().0,
        input.mutex().0,
        output.file().0,
        output.mutex().0,
    )
}
