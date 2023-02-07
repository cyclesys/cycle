use syn::{Error, Result};

use crate::parse;

pub enum Type {
    Node(Struct),
    Struct(Struct),
    Enum(Enum),
}

pub struct Struct {
    pub name: String,
    pub ver: Version,
    pub fields: Vec<StructField>,
}

impl Struct {
    fn from_parse(parse_struct: &parse::Struct, ver: Version) -> Result<Self> {
        let name = parse_struct.name.to_string();
        let fields = Self::fields_from_items(&parse_struct.items)?;
        Ok(Self { name, ver, fields })
    }

    fn fields_from_items(items: &Vec<parse::StructItem>) -> Result<Vec<StructField>> {
        let mut fields = Vec::new();
        let mut field_ver: Option<Version> = None;
        for item in items {
            match item {
                parse::StructItem::Version(parse_ver) => {
                    if field_ver.is_some() {
                        return Err(Error::new(
                            parse_ver.begin_span,
                            "expected a struct field following version header",
                        ));
                    }

                    field_ver = Some(Version::from_parse(parse_ver)?);
                }
                parse::StructItem::Field(parse_field) => {
                    let ver = match field_ver {
                        Some(consumed) => {
                            field_ver = None;
                            consumed
                        }
                        None => Version::default(),
                    };
                    fields.push(StructField::from_parse(parse_field, ver)?);
                }
            }
        }
        Ok(fields)
    }
}

pub struct StructField {
    pub name: String,
    pub ver: Version,
    pub value: Value,
}

impl StructField {
    fn from_parse(parse_field: &parse::StructField, ver: Version) -> Result<Self> {
        let name = parse_field.name.to_string();
        let value = Value::from_parse(&parse_field.value)?;
        Ok(Self { name, ver, value })
    }
}

pub struct Enum {
    pub name: String,
    pub ver: Version,
    pub fields: Vec<EnumField>,
}

impl Enum {
    fn from_parse(parse_enum: &parse::Enum, ver: Version) -> Result<Self> {
        let name = parse_enum.name.to_string();
        let mut fields = Vec::new();
        let mut field_ver: Option<Version> = None;
        for item in &parse_enum.items {
            match item {
                parse::EnumItem::Version(parse_ver) => {
                    if field_ver.is_some() {
                        return Err(Error::new(
                            parse_ver.begin_span,
                            "expected an enum field following version header",
                        ));
                    }

                    field_ver = Some(Version::from_parse(parse_ver)?);
                }
                parse::EnumItem::Field(parse_field) => {
                    let ver = match field_ver {
                        Some(consumed) => {
                            field_ver = None;
                            consumed
                        }
                        None => Version::default(),
                    };
                    fields.push(EnumField::from_parse(parse_field, ver)?);
                }
            }
        }
        Ok(Self { name, ver, fields })
    }
}

pub struct EnumField {
    pub name: String,
    pub ver: Version,
    pub value: EnumFieldValue,
}

pub enum EnumFieldValue {
    Int(u32),
    Struct(Vec<StructField>),
    Tuple(Vec<Value>),
    None,
}

impl EnumField {
    fn from_parse(parse_field: &parse::EnumField, ver: Version) -> Result<Self> {
        let name = parse_field.name.to_string();
        let value = match &parse_field.value {
            parse::EnumFieldValue::Int(parse_int) => {
                let int = match u32::from_str_radix(&parse_int.to_string(), 10) {
                    Ok(int) => int,
                    Err(_) => {
                        return Err(Error::new(parse_int.span(), "invalid enum int literal"));
                    }
                };
                EnumFieldValue::Int(int)
            }
            parse::EnumFieldValue::Struct(parse_items) => {
                let fields = Struct::fields_from_items(parse_items)?;
                EnumFieldValue::Struct(fields)
            }
            parse::EnumFieldValue::Tuple(parse_vals) => {
                let values = Value::from_parse_vals(parse_vals)?;
                EnumFieldValue::Tuple(values)
            }
            parse::EnumFieldValue::None => EnumFieldValue::None,
        };
        Ok(Self { name, ver, value })
    }
}

pub struct Version {
    // This field is required even though the user is not required to include an 'add' specifier. If
    // the user does not specify an 'add' qualifier, it will be set to 1 by default.
    pub added: u32,
    pub removed: Option<u32>,
}

impl Version {
    fn from_parse(parse_ver: &parse::Version) -> Result<Self> {
        match parse_ver.items.len() {
            0 => Err(Error::new(
                parse_ver.begin_span,
                "no version specifiers present (e.g. add(1), rem(2))",
            )),
            1 => {
                let item = &parse_ver.items[0];
                match item.kind {
                    parse::VersionItemKind::Add => Ok(Self {
                        added: Self::parse_ver_num(item)?,
                        removed: None,
                    }),
                    parse::VersionItemKind::Rem => Ok(Self {
                        removed: Some(Self::parse_ver_num(item)?),
                        ..Self::default()
                    }),
                }
            }
            2 => {
                let add_item = &parse_ver.items[0];
                let rem_item = &parse_ver.items[1];

                if add_item.kind == parse::VersionItemKind::Rem {
                    return match rem_item.kind {
                        parse::VersionItemKind::Add => Err(Error::new(
                            rem_item.kw_span,
                            "'add' specifier must come before 'rem'",
                        )),
                        parse::VersionItemKind::Rem => Err(Error::new(
                            rem_item.kw_span,
                            "version header can only contian one 'rem' specifier",
                        )),
                    };
                }

                if rem_item.kind == parse::VersionItemKind::Add {
                    return Err(Error::new(
                        rem_item.kw_span,
                        "version header can only contain one 'add' specifier",
                    ));
                }

                Ok(Self {
                    added: Self::parse_ver_num(add_item)?,
                    removed: Some(Self::parse_ver_num(rem_item)?),
                })
            }
            _ => {
                let excessive_item = &parse_ver.items[2];
                Err(Error::new(
                    excessive_item.kw_span,
                    "version header can contain at most two speciifers: an 'add' specifier, and a 'rem' specifier.",
                ))
            }
        }
    }

    fn parse_ver_num(item: &parse::VersionItem) -> Result<u32> {
        match u32::from_str_radix(&item.num.to_string(), 10) {
            Ok(num) => Ok(num),
            Err(_) => Err(Error::new(item.num.span(), "invalid version literal")),
        }
    }
}

impl Default for Version {
    fn default() -> Self {
        Self {
            added: 1,
            removed: None,
        }
    }
}

pub enum Value {
    Composite(String),
    Optional(Box<Value>),
    Reference(Box<Value>),
    Array(Box<Value>, u32),
    Slice(Box<Value>),
    Tuple(Vec<Value>),
    Primitive(Primitive),
}

pub enum Primitive {
    Int8,
    Int16,
    Int32,
    Int64,

    UInt8,
    UInt16,
    UInt32,
    UInt64,

    Float32,
    Float64,

    Boolean,
    String,
}

impl Value {
    fn from_parse(parse_val: &parse::Value) -> Result<Self> {
        match parse_val {
            parse::Value::Ident(ident) => match ident {
                parse::ValueIdent::Ident(ident) => {
                    let ident = ident.to_string();
                    match ident.as_str() {
                        "i8" => Ok(Self::Primitive(Primitive::Int8)),
                        "i16" => Ok(Self::Primitive(Primitive::Int16)),
                        "i32" => Ok(Self::Primitive(Primitive::Int32)),
                        "i64" => Ok(Self::Primitive(Primitive::Int64)),

                        "u8" => Ok(Self::Primitive(Primitive::UInt8)),
                        "u16" => Ok(Self::Primitive(Primitive::UInt16)),
                        "u32" => Ok(Self::Primitive(Primitive::UInt32)),
                        "u64" => Ok(Self::Primitive(Primitive::UInt64)),

                        "f32" => Ok(Self::Primitive(Primitive::Float32)),
                        "f64" => Ok(Self::Primitive(Primitive::Float64)),

                        "bool" => Ok(Self::Primitive(Primitive::Boolean)),
                        "str" => Ok(Self::Primitive(Primitive::String)),
                        _ => Ok(Self::Composite(ident)),
                    }
                }
                parse::ValueIdent::Ref(parse_val) => {
                    let value = Self::from_parse(parse_val.as_ref())?;
                    Ok(Self::Reference(Box::from(value)))
                }
                parse::ValueIdent::Wrapper(ident, parse_val) => {
                    let ident_str = ident.to_string();
                    match ident_str.as_str() {
                        "opt" => {
                            let value = Self::from_parse(parse_val.as_ref())?;
                            Ok(Self::Optional(Box::new(value)))
                        }
                        _ => Err(Error::new(
                            ident.span(),
                            "expected a wrapper type i.e. 'opt' or 'ref'",
                        )),
                    }
                }
            },
            parse::Value::Array(parse_val, size) => {
                let value = Self::from_parse(parse_val.as_ref())?;
                let size = match u32::from_str_radix(&size.to_string(), 10) {
                    Ok(size) => size,
                    Err(_) => {
                        return Err(Error::new(size.span(), "invalid array size literal"));
                    }
                };
                Ok(Self::Array(Box::new(value), size))
            }
            parse::Value::Slice(parse_val) => {
                let value = Self::from_parse(parse_val.as_ref())?;
                Ok(Self::Slice(Box::new(value)))
            }
            parse::Value::Tuple(parse_vals) => {
                let values = Self::from_parse_vals(parse_vals)?;
                Ok(Self::Tuple(values))
            }
        }
    }

    fn from_parse_vals(parse_vals: &Vec<parse::Value>) -> Result<Vec<Self>> {
        let mut values = Vec::new();
        for parse_val in parse_vals {
            values.push(Self::from_parse(parse_val)?);
        }
        Ok(values)
    }
}

pub fn gen(parse_def: &parse::Definition) -> Result<Vec<Type>> {
    let mut types = Vec::new();

    let mut type_ver: Option<Version> = None;
    for def_item in &parse_def.0 {
        match def_item {
            parse::DefinitionItem::Version(parse_ver) => {
                if type_ver.is_some() {
                    return Err(Error::new(
                        parse_ver.begin_span,
                        "expected a type def following version header",
                    ));
                }

                type_ver = Some(Version::from_parse(parse_ver)?);
            }
            _ => {
                let ver = match type_ver {
                    Some(consumed) => {
                        type_ver = None;
                        consumed
                    }
                    None => Version::default(),
                };

                match def_item {
                    parse::DefinitionItem::Node(parse_struct) => {
                        types.push(Type::Node(Struct::from_parse(parse_struct, ver)?));
                    }
                    parse::DefinitionItem::Struct(parse_struct) => {
                        types.push(Type::Struct(Struct::from_parse(parse_struct, ver)?));
                    }
                    parse::DefinitionItem::Enum(parse_enum) => {
                        types.push(Type::Enum(Enum::from_parse(parse_enum, ver)?));
                    }
                    _ => unreachable!(),
                }
            }
        }
    }

    Ok(types)
}
