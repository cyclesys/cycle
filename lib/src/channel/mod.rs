use std::env;

pub use windows::core::Error as WindowsError;
use windows::Win32::Foundation::HANDLE;

mod messages;
pub use messages::{PluginMessage, SystemMessage};

mod sync;
pub use sync::ChannelSync;

mod view;
pub use view::{ChannelMessage, ChannelView};

pub enum Error {
    InvalidCmdLine,
    ChannelWaitFailed(Option<WindowsError>),
    ChannelSignalFailed(WindowsError),
    ChannelTerminated,
    ChannelInvalidState,
    ChannelInvalidWrite,
    Windows(WindowsError),
}

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

    let handle = |idx: usize| -> Result<HANDLE> {
        if let Ok(handle) = isize::from_str_radix(args[idx].as_str(), 16) {
            Ok(HANDLE(handle))
        } else {
            Err(Error::InvalidCmdLine)
        }
    };

    if args.len() != (1 + 3 + 3) {
        Err(Error::InvalidCmdLine)
    } else {
        let output_signal_event = handle(1)?;
        let output_wait_event = handle(2)?;
        let output_file = handle(3)?;
        let input_signal_event = handle(4)?;
        let input_wait_event = handle(5)?;
        let input_file = handle(6)?;
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
