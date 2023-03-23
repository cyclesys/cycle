use std::env;

pub use windows::core::Error as WindowsError;
use windows::Win32::Foundation::HANDLE;

mod messages;
pub use messages::{PluginMessage, SystemMessage};

mod view;
pub use view::ChannelView;

pub enum Error {
    InvalidCmdLineArgs,
    ChannelWaitFailed(Option<WindowsError>),
    ChannelTerminated,
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
        let output_wait_event = handle(3)?;
        let output_signal_event = handle(4)?;
        let input_file = handle(5)?;
        let input_mutex = handle(6)?;
        let input_wait_event = handle(7)?;
        let input_signal_event = handle(8)?;
        Ok((
            InputChannel {
                view: ChannelView::create(
                    input_file,
                    input_mutex,
                    input_wait_event,
                    input_signal_event,
                )?,
            },
            OutputChannel {
                view: ChannelView::create(
                    output_file,
                    output_mutex,
                    output_wait_event,
                    output_signal_event,
                )?,
            },
        ))
    }
}

pub fn create_cmd_line(exe: String, input: &ChannelView, output: &ChannelView) -> String {
    format!(
        "{} {:x} {:x} {:x} {:x} {:x} {:x} {:x} {:x}",
        exe,
        input.file.0,
        input.mutex.0,
        input.wait_event.0,
        input.signal_event.0,
        output.file.0,
        output.mutex.0,
        output.wait_event.0,
        output.signal_event.0
    )
}
