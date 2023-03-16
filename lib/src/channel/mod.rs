use windows::core::Error as WindowsError;

pub mod args;
use args::ChannelArgs;

mod sync;
use sync::ChannelSync;

mod view;
use view::ChannelView;

pub enum Error {
    InvalidCmdLineArgs,
    ChannelWaitFailed(Option<WindowsError>),
    ChannelTerminated,
    Windows(WindowsError),
}

pub type Result<T> = std::result::Result<T, Error>;

pub const CHANNEL_SIZE: u32 = 8 * 1024;

pub struct Channel {
    sync: ChannelSync,
    view: ChannelView,
}

impl Channel {
    pub fn create(args: ChannelArgs) -> Result<Self> {
        Ok(Self {
            sync: ChannelSync::new(args.mutex, args.wait_event, args.signal_event),
            view: ChannelView::create(args.file)?,
        })
    }

    pub fn open() -> Result<Self> {
        let args = ChannelArgs::from_cmd_line()?;

        Ok(Self {
            sync: ChannelSync::new(args.mutex, args.wait_event, args.signal_event),
            view: ChannelView::create(args.file)?,
        })
    }
}
