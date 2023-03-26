use std::{fmt::Display, mem, str};

use serde::{
    de::{
        DeserializeSeed, EnumAccess, Error as DeserializeError, IntoDeserializer, MapAccess,
        SeqAccess, VariantAccess, Visitor,
    },
    Deserialize, Deserializer,
};

use super::{Error, Result};

impl DeserializeError for Error {
    fn custom<T: Display>(msg: T) -> Self {
        Error::InvalidChannelMessage(msg.to_string())
    }
}

pub(crate) struct ChannelDeserializer<'de> {
    bytes: &'de [u8],
    cursor: usize,
}

impl<'de> ChannelDeserializer<'de> {
    pub fn deserialize<T: Deserialize<'de>>(bytes: &'de [u8]) -> Result<T> {
        let mut deserializer = ChannelDeserializer { bytes, cursor: 0 };
        T::deserialize(&mut deserializer)
    }
}

impl<'de> ChannelDeserializer<'de> {
    fn read_byte(&mut self) -> Result<u8> {
        if self.cursor + 1 > self.bytes.len() {
            Err(Error::InvalidChannelMessage("missing bytes".to_string()))
        } else {
            let byte = self.bytes[self.cursor];
            self.cursor += 1;
            Ok(byte)
        }
    }

    fn read_byte_slice(&mut self, len: usize) -> Result<&'de [u8]> {
        if self.cursor + len > self.bytes.len() {
            Err(Error::InvalidChannelMessage("missing bytes".to_string()))
        } else {
            let bytes = &self.bytes[self.cursor..(self.cursor + len)];
            self.cursor += len;
            Ok(bytes)
        }
    }

    fn read_bytes_into(&mut self, buf: &mut [u8]) -> Result<()> {
        if self.cursor + buf.len() > self.bytes.len() {
            Err(Error::InvalidChannelMessage("missing bytes".to_string()))
        } else {
            buf.copy_from_slice(&self.bytes[self.cursor..(self.cursor + buf.len())]);
            self.cursor += buf.len();
            Ok(())
        }
    }

    fn read_two_bytes(&mut self) -> Result<[u8; 2]> {
        let mut bytes = [0; 2];
        self.read_bytes_into(&mut bytes)?;
        Ok(bytes)
    }

    fn read_four_bytes(&mut self) -> Result<[u8; 4]> {
        let mut bytes = [0; 4];
        self.read_bytes_into(&mut bytes)?;
        Ok(bytes)
    }

    fn read_eight_bytes(&mut self) -> Result<[u8; 8]> {
        let mut bytes = [0; 8];
        self.read_bytes_into(&mut bytes)?;
        Ok(bytes)
    }

    fn read_sixteen_bytes(&mut self) -> Result<[u8; 16]> {
        let mut bytes = [0; 16];
        self.read_bytes_into(&mut bytes)?;
        Ok(bytes)
    }

    fn read_usize(&mut self) -> Result<usize> {
        let mut bytes = [0; mem::size_of::<usize>()];
        self.read_bytes_into(&mut bytes)?;
        Ok(usize::from_le_bytes(bytes))
    }
}

impl<'de, 'a> Deserializer<'de> for &'a mut ChannelDeserializer<'de> {
    type Error = Error;

    fn deserialize_any<V: Visitor<'de>>(self, _visitor: V) -> Result<V::Value> {
        Err(Error::InvalidChannelMessage(
            "unsupported deserialization type".to_string(),
        ))
    }

    fn deserialize_bool<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        let value = match self.read_byte()? {
            0 => false,
            1 => true,
            _ => return Err(Error::InvalidChannelMessage("invalid bool".to_string())),
        };
        visitor.visit_bool(value)
    }

    fn deserialize_i8<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        let value = self.read_byte()?;
        visitor.visit_i8(value as i8)
    }

    fn deserialize_i16<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        let bytes = self.read_two_bytes()?;
        visitor.visit_i16(i16::from_le_bytes(bytes))
    }

    fn deserialize_i32<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        let bytes = self.read_four_bytes()?;
        visitor.visit_i32(i32::from_le_bytes(bytes))
    }

    fn deserialize_i64<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        let bytes = self.read_eight_bytes()?;
        visitor.visit_i64(i64::from_le_bytes(bytes))
    }

    fn deserialize_i128<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        let bytes = self.read_sixteen_bytes()?;
        visitor.visit_i128(i128::from_le_bytes(bytes))
    }

    fn deserialize_u8<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        let value = self.read_byte()?;
        visitor.visit_u8(value)
    }

    fn deserialize_u16<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        let bytes = self.read_two_bytes()?;
        visitor.visit_u16(u16::from_le_bytes(bytes))
    }

    fn deserialize_u32<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        let bytes = self.read_four_bytes()?;
        visitor.visit_u32(u32::from_le_bytes(bytes))
    }

    fn deserialize_u64<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        let bytes = self.read_eight_bytes()?;
        visitor.visit_u64(u64::from_le_bytes(bytes))
    }

    fn deserialize_u128<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        let bytes = self.read_sixteen_bytes()?;
        visitor.visit_u128(u128::from_le_bytes(bytes))
    }

    fn deserialize_f32<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        let bytes = self.read_four_bytes()?;
        visitor.visit_f32(f32::from_le_bytes(bytes))
    }

    fn deserialize_f64<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        let bytes = self.read_eight_bytes()?;
        visitor.visit_f64(f64::from_le_bytes(bytes))
    }

    fn deserialize_char<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        let len = self.read_usize()?;
        let char_bytes = self.read_byte_slice(len)?;
        match str::from_utf8(char_bytes) {
            Ok(s) => {
                let mut chars = s.chars();
                let Some(c) = chars.next() else {
                    return Err(Error::InvalidChannelMessage("invalid char".to_string()));
                };
                if let Some(_) = chars.next() {
                    Err(Error::InvalidChannelMessage("invalid char".to_string()))
                } else {
                    visitor.visit_char(c)
                }
            }
            Err(_) => Err(Error::InvalidChannelMessage("invalid char".to_string())),
        }
    }

    fn deserialize_str<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        let len = self.read_usize()?;
        let str_bytes = self.read_byte_slice(len)?;
        match str::from_utf8(str_bytes) {
            Ok(s) => visitor.visit_borrowed_str(s),
            Err(_) => Err(Error::InvalidChannelMessage("invalid str".to_string())),
        }
    }

    fn deserialize_string<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        let len = self.read_usize()?;
        let str_bytes = self.read_byte_slice(len)?;
        match str::from_utf8(str_bytes) {
            Ok(s) => visitor.visit_string(s.to_string()),
            Err(_) => Err(Error::InvalidChannelMessage("invalid string".to_string())),
        }
    }

    fn deserialize_bytes<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        let len = self.read_usize()?;
        let bytes = self.read_byte_slice(len)?;
        visitor.visit_borrowed_bytes(bytes)
    }

    fn deserialize_byte_buf<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        let len = self.read_usize()?;
        let bytes = self.read_byte_slice(len)?;
        visitor.visit_byte_buf(bytes.to_vec())
    }

    fn deserialize_option<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        let variant = self.read_byte()?;
        match variant {
            0 => visitor.visit_none(),
            1 => visitor.visit_some(self),
            _ => Err(Error::InvalidChannelMessage("invalid option".to_string())),
        }
    }

    fn deserialize_unit<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        visitor.visit_unit()
    }

    fn deserialize_unit_struct<V: Visitor<'de>>(
        self,
        _name: &'static str,
        visitor: V,
    ) -> Result<V::Value> {
        visitor.visit_unit()
    }

    fn deserialize_newtype_struct<V: Visitor<'de>>(
        self,
        _name: &'static str,
        visitor: V,
    ) -> Result<V::Value> {
        visitor.visit_newtype_struct(self)
    }

    fn deserialize_seq<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        let len = self.read_usize()?;
        visitor.visit_seq(SeqMapAccess { de: self, len })
    }

    fn deserialize_tuple<V: Visitor<'de>>(self, len: usize, visitor: V) -> Result<V::Value> {
        visitor.visit_seq(SeqMapAccess { de: self, len })
    }

    fn deserialize_tuple_struct<V: Visitor<'de>>(
        self,
        _name: &'static str,
        len: usize,
        visitor: V,
    ) -> Result<V::Value> {
        self.deserialize_tuple(len, visitor)
    }

    fn deserialize_map<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        let len = self.read_usize()?;
        visitor.visit_map(SeqMapAccess { de: self, len })
    }

    fn deserialize_struct<V: Visitor<'de>>(
        self,
        _name: &'static str,
        fields: &'static [&'static str],
        visitor: V,
    ) -> Result<V::Value> {
        self.deserialize_tuple(fields.len(), visitor)
    }

    fn deserialize_enum<V: Visitor<'de>>(
        self,
        _name: &'static str,
        _variants: &'static [&'static str],
        visitor: V,
    ) -> Result<V::Value> {
        visitor.visit_enum(self)
    }

    fn deserialize_identifier<V: Visitor<'de>>(self, _visitor: V) -> Result<V::Value> {
        Err(Error::InvalidChannelMessage(
            "unsupported deserialization type".to_string(),
        ))
    }

    fn deserialize_ignored_any<V: Visitor<'de>>(self, _visitor: V) -> Result<V::Value> {
        Err(Error::InvalidChannelMessage(
            "unsupported deserialization type".to_string(),
        ))
    }

    fn is_human_readable(&self) -> bool {
        false
    }
}

impl<'de, 'a> EnumAccess<'de> for &'a mut ChannelDeserializer<'de> {
    type Error = Error;
    type Variant = Self;

    fn variant_seed<V: DeserializeSeed<'de>>(self, seed: V) -> Result<(V::Value, Self::Variant)> {
        let value = {
            let bytes = self.read_four_bytes()?;
            let variant = u32::from_le_bytes(bytes);
            seed.deserialize(variant.into_deserializer())?
        };
        Ok((value, self))
    }
}

impl<'de, 'a> VariantAccess<'de> for &'a mut ChannelDeserializer<'de> {
    type Error = Error;

    fn unit_variant(self) -> Result<()> {
        Ok(())
    }

    fn newtype_variant_seed<T: DeserializeSeed<'de>>(self, seed: T) -> Result<T::Value> {
        seed.deserialize(self)
    }

    fn tuple_variant<V: Visitor<'de>>(self, len: usize, visitor: V) -> Result<V::Value> {
        self.deserialize_tuple(len, visitor)
    }

    fn struct_variant<V: Visitor<'de>>(
        self,
        fields: &'static [&'static str],
        visitor: V,
    ) -> Result<V::Value> {
        self.deserialize_tuple(fields.len(), visitor)
    }
}

struct SeqMapAccess<'a, 'de> {
    de: &'a mut ChannelDeserializer<'de>,
    len: usize,
}

impl<'de, 'a> SeqAccess<'de> for SeqMapAccess<'a, 'de> {
    type Error = Error;

    fn next_element_seed<T: DeserializeSeed<'de>>(&mut self, seed: T) -> Result<Option<T::Value>> {
        if self.len > 0 {
            self.len -= 1;
            let value = seed.deserialize(&mut *self.de)?;
            Ok(Some(value))
        } else {
            Ok(None)
        }
    }

    fn size_hint(&self) -> Option<usize> {
        Some(self.len)
    }
}

impl<'de, 'a> MapAccess<'de> for SeqMapAccess<'a, 'de> {
    type Error = Error;

    fn next_key_seed<K: DeserializeSeed<'de>>(&mut self, seed: K) -> Result<Option<K::Value>> {
        if self.len > 0 {
            self.len -= 1;
            Ok(Some(seed.deserialize(&mut *self.de)?))
        } else {
            Ok(None)
        }
    }

    fn next_value_seed<V: DeserializeSeed<'de>>(&mut self, seed: V) -> Result<V::Value> {
        seed.deserialize(&mut *self.de)
    }

    fn size_hint(&self) -> Option<usize> {
        Some(self.len)
    }
}
