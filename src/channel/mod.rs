mod args;
pub(crate) use args::ChannelArgs;
pub use args::Error as ArgsError;

mod sync;
use sync::ChannelSync;

mod view;
pub use view::Error as ViewError;
use view::{ChannelView, Result as ViewResult};

pub enum Error {
    Args(ArgsError),
    View(ViewError),
}

pub(crate) type Result<T> = std::result::Result<T, Error>;

fn result_from_view<T>(view_result: ViewResult<T>) -> Result<T> {
    match view_result {
        Ok(res) => Ok(res),
        Err(view_error) => Err(Error::View(view_error)),
    }
}

pub(crate) const CHANNEL_SIZE: u32 = 8 * 1024;

pub(crate) struct Channel {
    sync: ChannelSync,
    view: ChannelView,
}

impl Channel {
    pub(crate) fn create(args: ChannelArgs) -> Result<Self> {
        Ok(Self {
            sync: ChannelSync::new(args.mutex, args.wait_event, args.signal_event),
            view: result_from_view(ChannelView::create(args.file))?,
        })
    }

    pub fn open() -> Result<Self> {
        let args = match ChannelArgs::from_cmd_line() {
            Ok(args) => args,
            Err(args_error) => {
                return Err(Error::Args(args_error));
            }
        };

        Ok(Self {
            sync: ChannelSync::new(args.mutex, args.wait_event, args.signal_event),
            view: result_from_view(ChannelView::create(args.file))?,
        })
    }
}
