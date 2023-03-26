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

#[cfg(test)]
mod tests {
    use super::{de::ChannelDeserializer, ser::ChannelSerializer};
    use serde::{Deserialize, Serialize};
    use std::collections::HashMap;

    #[test]
    fn channel_serde() {
        #[derive(Serialize, Deserialize, Debug, PartialEq)]
        struct UnitStruct;

        #[derive(Serialize, Deserialize, Debug, PartialEq)]
        struct NewTypeStruct(u8);

        #[derive(Serialize, Deserialize, Debug, PartialEq)]
        enum Enum {
            NewType(u32),
            Tuple(u8, u16),
            Struct { string: String, seq: [u8; 32] },
            Unit,
        }

        #[derive(Serialize, Deserialize, Debug, PartialEq)]
        struct Struct {
            unit_struct: UnitStruct,
            new_type_struct: NewTypeStruct,
            sub_enum: Enum,
        }

        #[derive(Serialize, Deserialize, Debug, PartialEq)]
        struct Message<'a> {
            true_bool: bool,
            false_bool: bool,
            int8: i8,
            int16: i16,
            int32: i32,
            int64: i64,
            int128: i128,
            signed_size: isize,

            uint8: u8,
            uint16: u16,
            uint32: u32,
            uint64: u64,
            uint128: u128,
            unsigned_size: usize,

            character: char,
            str_ref: &'a str,
            string: String,

            bytes: &'a [u8],

            none: Option<u8>,
            some: Option<u8>,

            unit: (),

            unit_struct: UnitStruct,
            new_type_struct: NewTypeStruct,

            seq: Vec<String>,
            tuple: (bool, u8),
            map: HashMap<String, &'a [u8]>,

            enum_new_type_variant: Enum,
            enum_tuple_variant: Enum,
            enum_struct_variant: Enum,
            enum_unit_variant: Enum,

            sub_struct: Struct,
        }

        let map = HashMap::new();
        let ser_message = Message {
            true_bool: true,
            false_bool: false,

            int8: -100,
            int16: -1_000,
            int32: -10_000,
            int64: -100_000,
            int128: -1_000_000,
            signed_size: -10_000_000,

            uint8: 100,
            uint16: 1_000,
            uint32: 10_000,
            uint64: 100_000,
            uint128: 1_000_000,
            unsigned_size: 10_000_000,

            character: 'A',
            str_ref: "Hello",
            string: "World".to_string(),

            bytes: &[10, 20, 30, 40, 50],

            none: None,
            some: Some(10),

            unit: (),

            unit_struct: UnitStruct,
            new_type_struct: NewTypeStruct(200),

            seq: vec!["foo".to_string(), "bar".to_string()],
            tuple: (true, 25),
            map,

            enum_new_type_variant: Enum::NewType(30_000),
            enum_tuple_variant: Enum::Tuple(64, 128),
            enum_struct_variant: Enum::Struct {
                string: "string".to_string(),
                seq: [16; 32],
            },
            enum_unit_variant: Enum::Unit,

            sub_struct: Struct {
                unit_struct: UnitStruct,
                new_type_struct: NewTypeStruct(150),
                sub_enum: Enum::Struct {
                    string: "sub_enum".to_string(),
                    seq: [32; 32],
                },
            },
        };

        let bytes = ChannelSerializer::serialize(&ser_message).unwrap();
        let de_message: Message = ChannelDeserializer::deserialize(&bytes).unwrap();
        assert_eq!(de_message, ser_message);
    }
}
