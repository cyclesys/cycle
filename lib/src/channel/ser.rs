use std::{fmt::Display, mem};

use serde::{
    ser::{
        Error as SerializeError, SerializeMap, SerializeSeq, SerializeStruct,
        SerializeStructVariant, SerializeTuple, SerializeTupleStruct, SerializeTupleVariant,
    },
    Serialize, Serializer,
};

use super::{Error, Result};

impl SerializeError for Error {
    fn custom<T: Display>(msg: T) -> Self {
        Error::InvalidChannelMessage(msg.to_string())
    }
}

pub(crate) struct ChannelSerializer {
    output: Vec<u8>,
}

impl ChannelSerializer {
    pub fn serialize<T: Serialize>(message: &T) -> Result<Box<[u8]>> {
        let mut serializer = Self { output: Vec::new() };
        message.serialize(&mut serializer)?;
        Ok(serializer.output.into_boxed_slice())
    }

    fn serialize_usize(&mut self, value: usize) {
        self.output.extend_from_slice(&value.to_le_bytes());
    }
}

impl<'a> Serializer for &'a mut ChannelSerializer {
    type Ok = ();
    type Error = Error;
    type SerializeSeq = SeqMapSerializer<'a>;
    type SerializeTuple = &'a mut ChannelSerializer;
    type SerializeTupleStruct = &'a mut ChannelSerializer;
    type SerializeTupleVariant = &'a mut ChannelSerializer;
    type SerializeMap = SeqMapSerializer<'a>;
    type SerializeStruct = &'a mut ChannelSerializer;
    type SerializeStructVariant = &'a mut ChannelSerializer;

    fn serialize_bool(self, value: bool) -> Result<()> {
        self.output.push(if value { 1 } else { 0 });
        Ok(())
    }

    fn serialize_i8(self, value: i8) -> Result<()> {
        self.output.push(value as u8);
        Ok(())
    }

    fn serialize_i16(self, value: i16) -> Result<()> {
        self.output.extend_from_slice(&value.to_le_bytes());
        Ok(())
    }

    fn serialize_i32(self, value: i32) -> Result<()> {
        self.output.extend_from_slice(&value.to_le_bytes());
        Ok(())
    }

    fn serialize_i64(self, value: i64) -> Result<()> {
        self.output.extend_from_slice(&value.to_le_bytes());
        Ok(())
    }

    fn serialize_i128(self, value: i128) -> Result<()> {
        self.output.extend_from_slice(&value.to_le_bytes());
        Ok(())
    }

    fn serialize_u8(self, value: u8) -> Result<()> {
        self.output.push(value);
        Ok(())
    }

    fn serialize_u16(self, value: u16) -> Result<()> {
        self.output.extend_from_slice(&value.to_le_bytes());
        Ok(())
    }

    fn serialize_u32(self, value: u32) -> Result<()> {
        self.output.extend_from_slice(&value.to_le_bytes());
        Ok(())
    }

    fn serialize_u64(self, value: u64) -> Result<()> {
        self.output.extend_from_slice(&value.to_le_bytes());
        Ok(())
    }

    fn serialize_u128(self, value: u128) -> Result<()> {
        self.output.extend_from_slice(&value.to_le_bytes());
        Ok(())
    }

    fn serialize_f32(self, value: f32) -> Result<()> {
        self.output.extend_from_slice(&value.to_le_bytes());
        Ok(())
    }

    fn serialize_f64(self, value: f64) -> Result<()> {
        self.output.extend_from_slice(&value.to_le_bytes());
        Ok(())
    }

    fn serialize_char(self, value: char) -> Result<()> {
        let len = value.len_utf8();
        self.serialize_usize(len);

        let mut buf = vec![0; len];
        value.encode_utf8(&mut buf);
        self.output.append(&mut buf);

        Ok(())
    }

    fn serialize_str(self, value: &str) -> Result<()> {
        self.serialize_usize(value.len());
        self.output.extend_from_slice(value.as_bytes());
        Ok(())
    }

    fn serialize_bytes(self, value: &[u8]) -> Result<()> {
        self.serialize_usize(value.len());
        self.output.extend_from_slice(value);
        Ok(())
    }

    fn serialize_none(self) -> Result<()> {
        self.output.push(0);
        Ok(())
    }

    fn serialize_some<T: ?Sized + Serialize>(self, value: &T) -> Result<()> {
        self.output.push(1);
        value.serialize(self)
    }

    fn serialize_unit(self) -> Result<()> {
        Ok(())
    }

    fn serialize_unit_struct(self, _name: &'static str) -> Result<()> {
        Ok(())
    }

    fn serialize_unit_variant(
        self,
        _name: &'static str,
        variant_index: u32,
        _variant: &'static str,
    ) -> Result<()> {
        self.serialize_u32(variant_index)
    }

    fn serialize_newtype_struct<T: ?Sized + Serialize>(
        self,
        _name: &'static str,
        value: &T,
    ) -> Result<()> {
        value.serialize(self)
    }

    fn serialize_newtype_variant<T: ?Sized + Serialize>(
        self,
        _name: &'static str,
        variant_index: u32,
        _variant: &'static str,
        value: &T,
    ) -> Result<()> {
        self.serialize_u32(variant_index)?;
        value.serialize(self)
    }

    fn serialize_seq(self, len: Option<usize>) -> Result<Self::SerializeSeq> {
        Ok(SeqMapSerializer::new(self, len))
    }

    fn serialize_tuple(self, _len: usize) -> Result<Self> {
        Ok(self)
    }

    fn serialize_tuple_struct(self, _name: &'static str, _len: usize) -> Result<Self> {
        Ok(self)
    }

    fn serialize_tuple_variant(
        self,
        _name: &'static str,
        variant_index: u32,
        _variant: &'static str,
        _len: usize,
    ) -> Result<Self> {
        self.serialize_u32(variant_index)?;
        Ok(self)
    }

    fn serialize_map(self, len: Option<usize>) -> Result<Self::SerializeMap> {
        Ok(SeqMapSerializer::new(self, len))
    }

    fn serialize_struct(self, _name: &'static str, _len: usize) -> Result<Self> {
        Ok(self)
    }

    fn serialize_struct_variant(
        self,
        _name: &'static str,
        variant_index: u32,
        _variant: &'static str,
        _len: usize,
    ) -> Result<Self> {
        self.serialize_u32(variant_index)?;
        Ok(self)
    }

    fn is_human_readable(&self) -> bool {
        false
    }
}

impl SerializeTuple for &mut ChannelSerializer {
    type Ok = ();
    type Error = Error;

    fn serialize_element<T: ?Sized + Serialize>(&mut self, value: &T) -> Result<()> {
        value.serialize(&mut **self)
    }

    fn end(self) -> Result<()> {
        Ok(())
    }
}

impl SerializeTupleStruct for &mut ChannelSerializer {
    type Ok = ();
    type Error = Error;

    fn serialize_field<T: ?Sized + Serialize>(&mut self, value: &T) -> Result<()> {
        value.serialize(&mut **self)
    }

    fn end(self) -> Result<()> {
        Ok(())
    }
}

impl SerializeTupleVariant for &mut ChannelSerializer {
    type Ok = ();
    type Error = Error;

    fn serialize_field<T: ?Sized + Serialize>(&mut self, value: &T) -> Result<()> {
        value.serialize(&mut **self)
    }

    fn end(self) -> Result<()> {
        Ok(())
    }
}

impl SerializeStruct for &mut ChannelSerializer {
    type Ok = ();
    type Error = Error;

    fn serialize_field<T: ?Sized + Serialize>(
        &mut self,
        _key: &'static str,
        value: &T,
    ) -> Result<()> {
        value.serialize(&mut **self)
    }

    fn end(self) -> Result<()> {
        Ok(())
    }
}

impl SerializeStructVariant for &mut ChannelSerializer {
    type Ok = ();
    type Error = Error;

    fn serialize_field<T: ?Sized + Serialize>(
        &mut self,
        _key: &'static str,
        value: &T,
    ) -> Result<()> {
        value.serialize(&mut **self)
    }

    fn end(self) -> Result<()> {
        Ok(())
    }
}

pub(crate) struct SeqMapSerializer<'a> {
    ser: &'a mut ChannelSerializer,
    length_calculation: Option<(usize, usize)>,
}

impl<'a> SeqMapSerializer<'a> {
    fn new(ser: &'a mut ChannelSerializer, len: Option<usize>) -> Self {
        let length_calculation = if let Some(len) = len {
            ser.serialize_usize(len);
            None
        } else {
            let idx = ser.output.len();
            let len: usize = 0;
            ser.output.extend_from_slice(&len.to_le_bytes());
            Some((idx, 0))
        };

        Self {
            ser,
            length_calculation,
        }
    }

    fn increment(&mut self) {
        if let Some((_, len)) = self.length_calculation.as_mut() {
            *len += 1;
        }
    }

    fn serialize_len(self) {
        if let Some((idx, len)) = self.length_calculation {
            let output_slice = &mut self.ser.output[idx..(idx + mem::size_of::<usize>())];
            output_slice.copy_from_slice(&len.to_le_bytes());
        }
    }
}

impl<'a> SerializeSeq for SeqMapSerializer<'a> {
    type Ok = ();
    type Error = Error;

    fn serialize_element<T: ?Sized + Serialize>(&mut self, value: &T) -> Result<()> {
        self.increment();
        value.serialize(&mut *self.ser)
    }

    fn end(self) -> Result<()> {
        self.serialize_len();
        Ok(())
    }
}

impl<'a> SerializeMap for SeqMapSerializer<'a> {
    type Ok = ();
    type Error = Error;

    fn serialize_key<T: ?Sized + Serialize>(&mut self, key: &T) -> Result<()> {
        self.increment();
        key.serialize(&mut *self.ser)
    }

    fn serialize_value<T: ?Sized + Serialize>(&mut self, value: &T) -> Result<()> {
        value.serialize(&mut *self.ser)
    }

    fn end(self) -> Result<()> {
        self.serialize_len();
        Ok(())
    }
}
