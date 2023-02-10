use std::mem;

use proc_macro2::Span;
use syn::{
    braced, bracketed,
    ext::IdentExt,
    parenthesized,
    parse::{Parse, ParseStream},
    token::{Brace, Bracket, Paren},
    Error, Ident, LitInt, Result, Token,
};

mod kw {
    syn::custom_keyword!(node);
    syn::custom_keyword!(any);
    syn::custom_keyword!(add);
    syn::custom_keyword!(rem);
}

pub struct Definition(pub Vec<Type>);

impl Parse for Definition {
    fn parse(input: ParseStream) -> Result<Self> {
        let mut types = Vec::new();

        let mut type_ver = VersionParse { version: None };
        while !input.is_empty() {
            let lookahead = input.lookahead1();
            if lookahead.peek(Token![#]) {
                type_ver.parse(input, "type def (i.e. node, struct, or enum)")?;
            } else if lookahead.peek(kw::node) {
                types.push(Type::Node(Struct::parse(input, type_ver.consume())?));
            } else if lookahead.peek(Token![struct]) {
                types.push(Type::Struct(Struct::parse(input, type_ver.consume())?));
            } else if lookahead.peek(Token![enum]) {
                types.push(Type::Enum(Enum::parse(input, type_ver.consume())?));
            } else {
                return Err(lookahead.error());
            }
        }

        Ok(Self(types))
    }
}

pub enum Type {
    Node(Struct),
    Struct(Struct),
    Enum(Enum),
}

struct VersionParse {
    version: Option<Version>,
}

impl VersionParse {
    fn parse(&mut self, input: ParseStream, expected: &str) -> Result<()> {
        if self.version.is_some() {
            return Err(input.error(format!("expected a {} after the version def", expected)));
        }
        self.version = Some(Version::parse(input)?);
        Ok(())
    }

    fn consume(&mut self) -> Option<Version> {
        mem::replace(&mut self.version, None)
    }
}

pub struct Version {
    pub pound_span: Span,
    pub added: Option<VersionItem>,
    pub removed: Option<VersionItem>,
}

pub struct VersionItem {
    pub kw_span: Span,
    pub num_span: Span,
    pub num: u32,
}

impl Version {
    fn parse(input: ParseStream) -> Result<Self> {
        let pound_tok: Token![#] = input.parse()?;

        let inner_input;
        bracketed!(inner_input in input);
        let input = inner_input;

        let parse_item = |kw_span: Span| -> Result<VersionItem> {
            let inner_input;
            parenthesized!(inner_input in input);
            let input = inner_input;

            let num_lit: LitInt = input.parse()?;
            let num = parse_int(&num_lit, "invalid version literal")?;

            expect_empty(&input)?;
            Ok(VersionItem {
                kw_span,
                num_span: num_lit.span(),
                num,
            })
        };

        let mut added: Option<VersionItem> = None;
        let mut removed: Option<VersionItem> = None;
        while !input.is_empty() {
            if added.is_some() {
                if removed.is_some() {
                    return Err(Error::new(input.span(), "expected nothing here."));
                }

                let _: Token![,] = input.parse()?;

                if input.peek(kw::rem) {
                    let rem_kw: kw::rem = input.parse()?;
                    removed = Some(parse_item(rem_kw.span)?);
                } else {
                    return Err(Error::new(
                        input.span(),
                        "expected a 'rem' specifier or nothing.",
                    ));
                }
            } else if removed.is_some() {
                return Err(Error::new(
                    input.span(),
                    if input.peek(Token![,]) && input.peek2(kw::add) {
                        "'add' specifier must come before 'rem' specifier."
                    } else {
                        "expected nothing here."
                    },
                ));
            } else {
                let lookahead = input.lookahead1();
                if lookahead.peek(kw::add) {
                    let add_kw: kw::add = input.parse()?;
                    added = Some(parse_item(add_kw.span)?);
                } else if lookahead.peek(kw::rem) {
                    let rem_kw: kw::rem = input.parse()?;
                    removed = Some(parse_item(rem_kw.span)?);
                }
            }
        }

        if added.is_none() && removed.is_none() {
            return Err(Error::new(
                pound_tok.span,
                "version def must contain at least one of 'add' or 'rem'",
            ));
        }

        Ok(Self {
            pound_span: pound_tok.span,
            added,
            removed,
        })
    }
}

pub struct Struct {
    pub version: Option<Version>,
    pub name_span: Span,
    pub name: String,
    pub fields: Vec<StructField>,
}

impl Struct {
    fn parse(input: ParseStream, version: Option<Version>) -> Result<Self> {
        if input.peek(Token![struct]) {
            let _: Token![struct] = input.parse()?;
        } else {
            let _: kw::node = input.parse()?;
        }

        let name_ident: Ident = input.parse()?;

        let inner_input;
        braced!(inner_input in input);
        let input = inner_input;

        let fields = Self::parse_fields(&input)?;

        Ok(Self {
            version,
            name_span: name_ident.span(),
            name: name_ident.to_string(),
            fields,
        })
    }

    fn parse_fields(input: ParseStream) -> Result<Vec<StructField>> {
        let mut fields = Vec::new();

        let mut field_ver = VersionParse { version: None };
        while !input.is_empty() {
            let lookahead = input.lookahead1();
            if lookahead.peek(Token![#]) {
                field_ver.parse(&input, "struct field")?;
            } else if lookahead.peek(Ident::peek_any) {
                fields.push(StructField::parse(&input, field_ver.consume())?);
            } else {
                return Err(lookahead.error());
            }
        }

        Ok(fields)
    }
}

pub struct StructField {
    pub version: Option<Version>,
    pub name_span: Span,
    pub name: String,
    pub value: Value,
}

impl StructField {
    fn parse(input: ParseStream, version: Option<Version>) -> Result<Self> {
        let name_ident: Ident = input.parse()?;
        let _: Token![:] = input.parse()?;
        let value = Value::parse(input)?;
        let _: Token![,] = input.parse()?;

        Ok(Self {
            version,
            name_span: name_ident.span(),
            name: name_ident.to_string(),
            value,
        })
    }
}

pub struct Enum {
    pub version: Option<Version>,
    pub name_span: Span,
    pub name: String,
    pub fields: Vec<EnumField>,
}

impl Enum {
    fn parse(input: ParseStream, version: Option<Version>) -> Result<Self> {
        let _: Token![enum] = input.parse()?;
        let name_ident: Ident = input.parse()?;

        let inner_input;
        braced!(inner_input in input);
        let input = inner_input;

        let mut fields = Vec::new();

        let mut field_ver = VersionParse { version: None };
        while !input.is_empty() {
            let lookahead = input.lookahead1();
            if lookahead.peek(Token![#]) {
                field_ver.parse(&input, "enum field")?;
            } else if lookahead.peek(Ident::peek_any) {
                fields.push(EnumField::parse(&input, field_ver.consume())?);
            } else {
                return Err(lookahead.error());
            }
        }

        Ok(Self {
            version,
            name_span: name_ident.span(),
            name: name_ident.to_string(),
            fields,
        })
    }
}

pub struct EnumField {
    pub version: Option<Version>,
    pub name_span: Span,
    pub name: String,
    pub value: EnumFieldValue,
}

pub enum EnumFieldValue {
    Int { num_span: Span, num: u32 },
    Struct(Vec<StructField>),
    Tuple(Vec<Value>),
    None,
}

impl EnumField {
    fn parse(input: ParseStream, version: Option<Version>) -> Result<Self> {
        let name_ident: Ident = input.parse()?;

        let value = if input.peek(Brace) {
            let inner_input;
            braced!(inner_input in input);
            let input = inner_input;

            let fields = Struct::parse_fields(&input)?;
            EnumFieldValue::Struct(fields)
        } else if input.peek(Paren) {
            let values = Value::parse_tuple(input)?;
            EnumFieldValue::Tuple(values)
        } else if input.peek(Token![=]) {
            let _: Token![=] = input.parse()?;
            let num_lit: LitInt = input.parse()?;
            let num = parse_int(&num_lit, "invalid enum int literal")?;
            EnumFieldValue::Int {
                num_span: num_lit.span(),
                num,
            }
        } else {
            EnumFieldValue::None
        };

        let _: Token![,] = input.parse()?;

        Ok(Self {
            version,
            name_span: name_ident.span(),
            name: name_ident.to_string(),
            value,
        })
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
    fn parse(input: ParseStream) -> Result<Self> {
        fn parse_wrapped(input: ParseStream) -> Result<Value> {
            let _: Token![<] = input.parse()?;
            let value = Value::parse(input)?;
            let _: Token![>] = input.parse()?;
            Ok(value)
        }

        let lookahead = input.lookahead1();
        let result = if lookahead.peek(Bracket) {
            let inner_input;
            bracketed!(inner_input in input);
            let input = inner_input;

            let value = Value::parse(&input)?;
            if !input.is_empty() {
                let _: Token![;] = input.parse()?;
                let size: LitInt = input.parse()?;
                expect_empty(&input)?;

                Self::Array(
                    Box::new(value),
                    parse_int(&size, "invalid array size literal")?,
                )
            } else {
                Self::Slice(Box::from(value))
            }
        } else if lookahead.peek(Paren) {
            let values = Self::parse_tuple(input)?;
            Self::Tuple(values)
        } else if lookahead.peek(Ident::peek_any) {
            if input.peek(Token![ref]) {
                let _: Token![ref] = input.parse()?;
                let value = parse_wrapped(input)?;
                Self::Reference(Box::new(value))
            } else {
                let ident: Ident = input.parse()?;
                let name = ident.to_string();
                match name.as_str() {
                    "i8" => Self::Primitive(Primitive::Int8),
                    "i16" => Self::Primitive(Primitive::Int16),
                    "i32" => Self::Primitive(Primitive::Int32),
                    "i64" => Self::Primitive(Primitive::Int64),
                    "u8" => Self::Primitive(Primitive::UInt8),
                    "u16" => Self::Primitive(Primitive::UInt16),
                    "u32" => Self::Primitive(Primitive::UInt32),
                    "u64" => Self::Primitive(Primitive::UInt64),
                    "f32" => Self::Primitive(Primitive::Float32),
                    "f64" => Self::Primitive(Primitive::Float64),
                    "bool" => Self::Primitive(Primitive::Boolean),
                    "str" => Self::Primitive(Primitive::String),
                    "opt" => {
                        let value = parse_wrapped(input)?;
                        Self::Optional(Box::new(value))
                    }
                    _ => Self::Composite(name),
                }
            }
        } else {
            return Err(lookahead.error());
        };

        Ok(result)
    }

    fn parse_tuple(input: ParseStream) -> Result<Vec<Value>> {
        let inner_input;
        parenthesized!(inner_input in input);
        let input = inner_input;

        let mut values = Vec::new();
        while !input.is_empty() {
            if values.len() > 0 {
                let _: Token![,] = input.parse()?;
            }
            values.push(Self::parse(&input)?);
        }

        Ok(values)
    }
}

fn parse_int(int_lit: &LitInt, msg: &str) -> Result<u32> {
    match u32::from_str_radix(&int_lit.to_string(), 10) {
        Ok(int) => Ok(int),
        Err(_) => Err(Error::new(int_lit.span(), msg)),
    }
}

fn expect_empty(input: ParseStream) -> Result<()> {
    if input.is_empty() {
        Ok(())
    } else {
        Err(input.error("expected nothing here"))
    }
}
