use std::env;

use windows::Win32::Foundation::HANDLE;

pub(crate) type Result<T> = std::result::Result<T, Error>;

pub enum Error {
    InvalidCmdLine,
    InvalidArg,
}

pub(crate) struct ChannelArgs {
    pub exe: String,
    pub file: HANDLE,
    pub mutex: HANDLE,
    pub wait_event: HANDLE,
    pub signal_event: HANDLE,
}

impl ChannelArgs {
    pub fn from_cmd_line() -> Result<Self> {
        let args: Vec<String> = env::args().collect();

        fn handle_from_arg(arg: &String) -> Result<HANDLE> {
            if let Ok(handle) = isize::from_str_radix(arg.as_str(), 16) {
                Ok(HANDLE(handle))
            } else {
                Err(Error::InvalidArg)
            }
        }

        if args.len() != 5 {
            Err(Error::InvalidCmdLine)
        } else {
            Ok(Self {
                exe: args[0].clone(),
                file: handle_from_arg(&args[1])?,
                mutex: handle_from_arg(&args[2])?,
                wait_event: handle_from_arg(&args[3])?,
                signal_event: handle_from_arg(&args[4])?,
            })
        }
    }

    pub fn to_cmd_line(&self) -> String {
        format!(
            "{} {:X} {:X} {:X} {:X}",
            self.exe, self.file.0, self.mutex.0, self.wait_event.0, self.signal_event.0,
        )
    }
}
