use std::{
    env,
    error::Error as StdError,
    fmt::{Display, Formatter, Result as FmtResult},
};

pub use windows::core::Error as WindowsError;
use windows::Win32::Foundation::HANDLE;

mod de;

mod messages;
pub use messages::{PluginMessage, SystemMessage};

mod ser;

mod sync;
pub use sync::ChannelSync;

mod view;
pub use view::{ChannelMessage, ChannelView};

#[derive(Debug)]
pub enum Error {
    InvalidCmdLine,
    ChannelWaitFailed(Option<WindowsError>),
    ChannelSignalFailed(WindowsError),
    ChannelTerminated,
    ChannelInvalidState,
    ChannelInvalidWrite,
    InvalidChannelMessage(String),
    Windows(WindowsError),
}

impl Display for Error {
    fn fmt(&self, f: &mut Formatter<'_>) -> FmtResult {
        write!(f, "{:?}", self)
    }
}

impl StdError for Error {}

pub type Result<T> = std::result::Result<T, Error>;

pub struct InputChannel {
    sync: ChannelSync,
    view: ChannelView,
}

impl InputChannel {
    pub fn read(&mut self) -> Result<SystemMessage> {
        let mut buf: Option<Vec<u8>> = None;
        loop {
            self.sync.wait()?;
            let message = self.view.read()?;
            self.sync.signal()?;

            let buf = match buf.as_mut() {
                Some(buf) => buf,
                None => {
                    buf = Some(Vec::with_capacity(message.bytes.len() + message.bytes_left));
                    buf.as_mut().unwrap()
                }
            };

            buf.extend_from_slice(message.bytes);

            if message.bytes_left == 0 {
                break;
            }
        }

        let buf = buf.unwrap();

        todo!()
    }
}

pub struct OutputChannel {
    sync: ChannelSync,
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
    let mut handle_idx = 1;
    let mut read_handle = || -> Result<HANDLE> {
        if !(handle_idx < args.len()) {
            return Err(Error::InvalidCmdLine);
        }

        if let Ok(handle) = isize::from_str_radix(args[handle_idx].as_str(), 16) {
            handle_idx += 1;
            Ok(HANDLE(handle))
        } else {
            Err(Error::InvalidCmdLine)
        }
    };

    let output_signal_event = read_handle()?;
    let output_wait_event = read_handle()?;
    let output_file = read_handle()?;
    let input_signal_event = read_handle()?;
    let input_wait_event = read_handle()?;
    let input_file = read_handle()?;

    Ok((
        InputChannel {
            sync: ChannelSync::new(input_wait_event, input_signal_event),
            view: ChannelView::create(input_file)?,
        },
        OutputChannel {
            sync: ChannelSync::new(output_wait_event, output_signal_event),
            view: ChannelView::create(output_file)?,
        },
    ))
}

pub fn create_cmd_line(
    exe: String,
    input_sync: &ChannelSync,
    input_view: &ChannelView,
    output_sync: &ChannelSync,
    output_view: &ChannelView,
) -> String {
    format!(
        "{} {:x} {:x} {:x} {:x} {:x} {:x}",
        exe,
        input_sync.wait_event().0,
        input_sync.signal_event().0,
        input_view.file().0,
        output_sync.wait_event().0,
        output_sync.signal_event().0,
        output_view.file().0,
    )
}
