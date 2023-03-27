use serde::{de::DeserializeOwned, Serialize};
use std::{
    env,
    error::Error as StdError,
    fmt::{Display, Formatter, Result as FmtResult},
    marker::PhantomData,
};

pub use windows::core::{Error as WindowsError, Result as WindowsResult};
use windows::Win32::{
    Foundation::{HANDLE, INVALID_HANDLE_VALUE},
    System::{
        Memory::{CreateFileMappingW, PAGE_READWRITE},
        Threading::CreateEventW,
    },
};

mod de;
use de::ChannelDeserializer;

mod messages;
pub use messages::{PluginMessage, SystemMessage};

mod ser;
use ser::ChannelSerializer;

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

fn result_from_windows<T>(result: WindowsResult<T>) -> Result<T> {
    match result {
        Ok(t) => Ok(t),
        Err(err) => Err(Error::Windows(err)),
    }
}

pub struct InputChannel<T: DeserializeOwned> {
    sync: ChannelSync,
    view: ChannelView,
    _phantom: PhantomData<T>,
}

impl<T: DeserializeOwned> InputChannel<T> {
    pub fn new(sync: ChannelSync, view: ChannelView) -> Self {
        Self {
            sync,
            view,
            _phantom: PhantomData,
        }
    }

    pub fn read(&self) -> Result<T> {
        let mut buf: Option<Vec<u8>> = None;
        loop {
            self.sync.wait()?;
            let msg = self.view.read()?;
            self.sync.signal()?;

            let buf = match buf.as_mut() {
                Some(buf) => buf,
                None => {
                    buf = Some(Vec::with_capacity(msg.bytes.len() + msg.bytes_left));
                    buf.as_mut().unwrap()
                }
            };

            buf.extend_from_slice(msg.bytes);

            if msg.bytes_left == 0 {
                break;
            }
        }
        ChannelDeserializer::deserialize(&buf.unwrap())
    }
}

pub struct OutputChannel<T: Serialize> {
    sync: ChannelSync,
    view: ChannelView,
    _phantom: PhantomData<T>,
}

impl<T: Serialize> OutputChannel<T> {
    pub fn new(sync: ChannelSync, view: ChannelView) -> Self {
        Self {
            sync,
            view,
            _phantom: PhantomData,
        }
    }

    pub fn write(&self, msg: T) -> Result<()> {
        let msg_bytes = ChannelSerializer::serialize(&msg)?;

        let mut bytes_left = msg_bytes.len();
        let mut cursor = 0;
        while bytes_left > ChannelView::MAX_WRITE {
            bytes_left -= ChannelView::MAX_WRITE;

            self.sync.wait()?;
            self.view.write(ChannelMessage {
                bytes_left,
                bytes: &msg_bytes[cursor..(cursor + ChannelView::MAX_WRITE)],
            })?;
            self.sync.signal()?;

            cursor += ChannelView::MAX_WRITE;
        }

        if bytes_left > 0 {
            self.sync.wait()?;
            self.view.write(ChannelMessage {
                bytes_left: 0,
                bytes: &msg_bytes[cursor..(cursor + bytes_left)],
            })?;
            self.sync.signal()?;
        }

        Ok(())
    }
}

/// Opens the channels created by the system for the plugin.
pub fn open_channels() -> Result<(InputChannel<SystemMessage>, OutputChannel<PluginMessage>)> {
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
        InputChannel::new(
            ChannelSync::new(input_wait_event, input_signal_event),
            ChannelView::create(input_file)?,
        ),
        OutputChannel::new(
            ChannelSync::new(output_wait_event, output_signal_event),
            ChannelView::create(output_file)?,
        ),
    ))
}

pub fn create_channel(initial_state: bool) -> Result<(ChannelSync, ChannelView)> {
    unsafe {
        let view = ChannelView::create(result_from_windows(CreateFileMappingW(
            INVALID_HANDLE_VALUE,
            None,
            PAGE_READWRITE,
            0,
            ChannelView::SIZE as u32,
            None,
        ))?)?;

        let sync = ChannelSync::new(
            result_from_windows(CreateEventW(None, true, initial_state, None))?,
            result_from_windows(CreateEventW(None, true, !initial_state, None))?,
        );

        Ok((sync, view))
    }
}

pub fn format_cmd_line(
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
    use super::{
        de::ChannelDeserializer, ser::ChannelSerializer, sync::ChannelSync, view::ChannelView,
        InputChannel, OutputChannel,
    };
    use serde::{Deserialize, Serialize};
    use std::{collections::HashMap, thread};

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

        let values = vec![1u8, 2u8, 3u8];
        let mut map = HashMap::new();
        map.insert("one".to_string(), &values[0..1]);
        map.insert("two".to_string(), &values[1..2]);
        map.insert("three".to_string(), &values[2..3]);
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

    #[test]
    fn channel_input_output() {
        #[derive(Serialize, Deserialize)]
        struct Message {
            s: Option<String>,
        }

        fn write_and_read_back(
            output: &OutputChannel<Message>,
            input: &InputChannel<Message>,
            s: String,
        ) {
            output.write(Message { s: Some(s.clone()) }).unwrap();
            let message: Message = input.read().unwrap();
            assert_eq!(message.s.unwrap(), s);
        }

        let (input_sync, input_view) = super::create_channel(false).unwrap();
        let (output_sync, output_view) = super::create_channel(true).unwrap();

        let handle = {
            let input_wait = output_sync.signal_event();
            let input_signal = output_sync.wait_event();
            let input_file = output_view.file();
            let output_wait = input_sync.signal_event();
            let output_signal = input_sync.wait_event();
            let output_file = input_view.file();

            // spawn a thread that just writes back the same message
            thread::spawn(move || {
                let input = InputChannel::new(
                    ChannelSync::new(input_wait, input_signal),
                    ChannelView::create(input_file).unwrap(),
                );
                let output = OutputChannel::new(
                    ChannelSync::new(output_wait, output_signal),
                    ChannelView::create(output_file).unwrap(),
                );

                loop {
                    let message: Message = input.read().unwrap();
                    if message.s.is_none() {
                        break;
                    }

                    output
                        .write(Message {
                            s: Some(message.s.unwrap()),
                        })
                        .unwrap();
                }
            })
        };

        let input = InputChannel::new(input_sync, input_view);
        let output = OutputChannel::new(output_sync, output_view);

        write_and_read_back(&output, &input, "Hello".to_string());
        write_and_read_back(&output, &input, "world".to_string());
        write_and_read_back(&output, &input, "!".to_string());
        output.write(Message { s: None }).unwrap();

        handle.join().unwrap();
    }
}
