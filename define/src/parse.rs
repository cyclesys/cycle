use proc_macro2::Span;
use syn::{
    braced, bracketed,
    ext::IdentExt,
    parenthesized,
    parse::{Parse, ParseStream},
    token::{Brace, Bracket, Paren},
    Error, Ident, LitFloat, LitInt, LitStr, Result, Token,
};

mod kw {
    syn::custom_keyword!(sch);
    syn::custom_keyword!(ver);
    syn::custom_keyword!(add);
    syn::custom_keyword!(rem);
    syn::custom_keyword!(obj);
    syn::custom_keyword!(cmd);
    syn::custom_keyword!(any);
}

#[derive(Debug, PartialEq)]
pub struct Scheme {
    name: String,
    uses: Vec<Use>,
    types: Vec<Type>,
}

impl Parse for Scheme {
    fn parse(input: ParseStream) -> Result<Self> {
        let name = {
            let _: kw::sch = input.parse()?;
            let name: LitStr = input.parse()?;
            let _: Token![;] = input.parse()?;
            name.value()
        };

        let mut uses = Vec::new();
        let mut types = Vec::new();
        while !input.is_empty() {
            let lookahead = input.lookahead1();
            if lookahead.peek(Token![use]) {
                let _: Token![use] = input.parse()?;
                uses.push(Use::parse(input)?);
                continue;
            }

            if !lookahead.peek(Token![@]) {
                return Err(lookahead.error());
            }

            let _: Token![@] = input.parse()?;
            let _: kw::ver = input.parse()?;
            let version = MajorVersion::parse(input)?;

            let type_def = {
                let lookahead = input.lookahead1();
                if lookahead.peek(kw::obj) {
                    let _: kw::obj = input.parse()?;
                    let object = Object::parse(input, version)?;
                    Type::Object(object)
                } else if lookahead.peek(Token![struct]) {
                    let _: Token![struct] = input.parse()?;
                    let struct_ = Struct::parse(input, version)?;
                    Type::Struct(struct_)
                } else if lookahead.peek(Token![union]) {
                    let _: Token![union] = input.parse()?;
                    let union_ = Union::parse(input, version)?;
                    Type::Union(union_)
                } else if lookahead.peek(Token![enum]) {
                    let _: Token![enum] = input.parse()?;
                    let enum_ = Enum::parse(input, version)?;
                    Type::Enum(enum_)
                } else if lookahead.peek(Token![fn]) {
                    let _: Token![fn] = input.parse()?;
                    let fn_ = Function::parse(input, version)?;
                    Type::Function(fn_)
                } else if lookahead.peek(kw::cmd) {
                    let _: kw::cmd = input.parse()?;
                    let cmd_ = Command::parse(input, version)?;
                    Type::Command(cmd_)
                } else {
                    return Err(lookahead.error());
                }
            };

            types.push(type_def);
        }

        Ok(Self { name, uses, types })
    }
}

#[derive(Debug, PartialEq)]
pub struct Use {
    segments: Vec<String>,
    alias: Option<String>,
}

impl Use {
    fn parse(input: ParseStream) -> Result<Self> {
        let mut segments = Vec::new();
        let mut alias = None;

        segments.push(input.call(Ident::parse_any)?.to_string());

        if input.is_empty() {
            return Err(input.error("expected ';', or '::identifier'"));
        }

        while !input.is_empty() {
            if input.peek(Token![;]) {
                let _: Token![;] = input.parse()?;
                break;
            } else if input.peek(Token![as]) {
                let _: Token![as] = input.parse()?;
                alias = Some(input.parse::<Ident>()?.to_string());
                let _: Token![;] = input.parse()?;
                break;
            }

            let _: Token![:] = input.parse()?;
            let _: Token![:] = input.parse()?;

            segments.push(input.parse::<Ident>()?.to_string());
        }

        Ok(Self { segments, alias })
    }
}

#[derive(Debug, PartialEq)]
pub enum Type {
    Object(Object),
    Struct(Struct),
    Union(Union),
    Enum(Enum),
    Function(Function),
    Command(Command),
}

#[derive(Debug, PartialEq)]
pub enum Object {
    Struct(Struct),
    Union(Union),
    Enum(Enum),
}

impl Object {
    fn parse(input: ParseStream, version: MajorVersion) -> Result<Self> {
        let kind_input;
        parenthesized!(kind_input in input);

        let lookahead = kind_input.lookahead1();
        if lookahead.peek(Token![struct]) {
            Ok(Self::Struct(Struct::parse(input, version)?))
        } else if lookahead.peek(Token![union]) {
            Ok(Self::Union(Union::parse(input, version)?))
        } else if lookahead.peek(Token![enum]) {
            Ok(Self::Enum(Enum::parse(input, version)?))
        } else {
            Err(lookahead.error())
        }
    }
}

#[derive(Debug)]
pub struct Struct {
    pub version: MajorVersion,
    pub name_span: Span,
    pub name: String,
    pub body: StructBody,
}

impl Struct {
    fn parse(input: ParseStream, version: MajorVersion) -> Result<Self> {
        let name_ident: Ident = input.parse()?;
        Ok(Self {
            version,
            name_span: name_ident.span(),
            name: name_ident.to_string(),
            body: StructBody::parse(input, false)?,
        })
    }
}

impl PartialEq<Struct> for Struct {
    fn eq(&self, other: &Struct) -> bool {
        self.version == other.version && self.name == other.name && self.body == other.body
    }
}

#[derive(Debug)]
pub struct Union {
    pub version: MajorVersion,
    pub name_span: Span,
    pub name: String,
    pub fields: Vec<UnionField>,
}

impl Union {
    fn parse(input: ParseStream, version: MajorVersion) -> Result<Self> {
        let name_ident: Ident = input.parse()?;

        let items_input;
        braced!(items_input in input);
        let input = &items_input;

        let mut fields = Vec::new();
        while !input.is_empty() {
            let version = MinorVersion::maybe_parse(input, false, "union fields")?;
            fields.push(UnionField::parse(input, version)?);

            if !input.is_empty() {
                let _: Token![,] = input.parse()?;
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

impl PartialEq<Union> for Union {
    fn eq(&self, other: &Union) -> bool {
        self.version == other.version && self.name == other.name && self.fields == other.fields
    }
}

#[derive(Debug)]
pub struct UnionField {
    pub version: Option<MinorVersion>,
    pub name_span: Span,
    pub name: String,
    pub body: StructBody,
}

impl UnionField {
    fn parse(input: ParseStream, version: Option<MinorVersion>) -> Result<Self> {
        if !input.peek(Ident::peek_any) {
            return Err(input.error("expected union field name"));
        }

        let name_ident: Ident = input.parse()?;
        let body = StructBody::parse(input, true)?;

        Ok(Self {
            version,
            name_span: name_ident.span(),
            name: name_ident.to_string(),
            body,
        })
    }
}

impl PartialEq<UnionField> for UnionField {
    fn eq(&self, other: &UnionField) -> bool {
        self.version == other.version && self.name == other.name && self.body == other.body
    }
}

#[derive(Debug, PartialEq)]
pub enum StructBody {
    Fields(Vec<StructField>),
    Tuple(Tuple),
    Unit,
}

impl StructBody {
    fn parse(input: ParseStream, is_union_field: bool) -> Result<Self> {
        let lookahead = input.lookahead1();
        let peek_closing_char = || {
            if is_union_field {
                lookahead.peek(Token![,])
            } else {
                lookahead.peek(Token![;])
            }
        };

        if lookahead.peek(Brace) {
            let fields_input;
            braced!(fields_input in input);
            Ok(Self::Fields(parse_struct_fields(
                &fields_input,
                "struct fields",
            )?))
        } else if lookahead.peek(Paren) {
            Ok(Self::Tuple(Tuple::parse(input)?))
        } else if peek_closing_char() {
            if input.peek(Token![;]) {
                let _: Token![;] = input.parse()?;
            }
            Ok(Self::Unit)
        } else {
            Err(lookahead.error())
        }
    }
}

fn parse_struct_fields(input: ParseStream, invalid_for: &str) -> Result<Vec<StructField>> {
    let mut fields = Vec::new();
    while !input.is_empty() {
        let version = MinorVersion::maybe_parse(input, true, invalid_for)?;
        fields.push(StructField::parse(input, version)?);
        if !input.is_empty() {
            let _: Token![,] = input.parse()?;
        }
    }
    Ok(fields)
}

#[derive(Debug)]
pub struct StructField {
    pub version: Option<MinorVersion>,
    pub name_span: Span,
    pub name: String,
    pub field_type: FieldType,
}

impl StructField {
    fn parse(input: ParseStream, version: Option<MinorVersion>) -> Result<Self> {
        if !input.peek(Ident::peek_any) {
            return Err(input.error("expected struct field name"));
        }

        let name_ident: Ident = input.parse()?;
        let _: Token![:] = input.parse()?;
        let field_type = FieldType::parse(input)?;

        Ok(Self {
            version,
            name_span: name_ident.span(),
            name: name_ident.to_string(),
            field_type,
        })
    }
}

impl PartialEq<StructField> for StructField {
    fn eq(&self, other: &StructField) -> bool {
        self.version == other.version
            && self.name == other.name
            && self.field_type == other.field_type
    }
}

#[derive(Debug, PartialEq)]
pub struct Tuple(Vec<TupleField>);

impl Tuple {
    fn parse(input: ParseStream) -> Result<Self> {
        let fields_input;
        parenthesized!(fields_input in input);
        let input = &fields_input;

        let mut fields = Vec::new();
        while !input.is_empty() {
            let version = MinorVersion::maybe_parse(input, true, "tuple fields")?;
            fields.push(TupleField {
                version,
                field_type: FieldType::parse(input)?,
            });
            if !input.is_empty() {
                let _: Token![,] = input.parse()?;
            }
        }

        Ok(Self(fields))
    }
}

#[derive(Debug, PartialEq)]
pub struct TupleField {
    pub version: Option<MinorVersion>,
    pub field_type: FieldType,
}

#[derive(Debug)]
pub struct Enum {
    pub version: MajorVersion,
    pub name_span: Span,
    pub name: String,
    pub fields: Vec<EnumField>,
}

impl Enum {
    fn parse(input: ParseStream, version: MajorVersion) -> Result<Self> {
        let name_ident: Ident = input.parse()?;

        let fields_input;
        braced!(fields_input in input);
        let input = &fields_input;

        let mut fields = Vec::new();
        while !input.is_empty() {
            let version = MinorVersion::maybe_parse(input, false, "enum fields")?;
            fields.push(EnumField::parse(input, version)?);
            if !input.is_empty() {
                let _: Token![,] = input.parse()?;
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

impl PartialEq<Enum> for Enum {
    fn eq(&self, other: &Enum) -> bool {
        self.version == other.version && self.name == other.name && self.fields == other.fields
    }
}

#[derive(Debug)]
pub struct EnumField {
    pub version: Option<MinorVersion>,
    pub name_span: Span,
    pub name: String,
    pub value: Option<u32>,
}

impl EnumField {
    fn parse(input: ParseStream, version: Option<MinorVersion>) -> Result<Self> {
        let name_ident: Ident = input.parse()?;

        let value = if input.peek(Token![=]) {
            let _: Token![=] = input.parse()?;
            let int_lit: LitInt = input.parse()?;
            let value = parse_int_lit(&int_lit, "invalid enum int literal")?;
            Some(value)
        } else {
            None
        };

        Ok(Self {
            version,
            name_span: name_ident.span(),
            name: name_ident.to_string(),
            value,
        })
    }
}

impl PartialEq<EnumField> for EnumField {
    fn eq(&self, other: &EnumField) -> bool {
        self.version == other.version && self.name == other.name && self.value == other.value
    }
}

#[derive(Debug)]
pub struct Function {
    pub version: MajorVersion,
    pub name_span: Span,
    pub name: String,
    pub fields: Vec<StructField>,
    pub return_type: Option<FieldType>,
}

impl Function {
    fn parse(input: ParseStream, version: MajorVersion) -> Result<Self> {
        let name_ident: Ident = input.parse()?;

        let fields_input;
        parenthesized!(fields_input in input);
        let fields = parse_struct_fields(&fields_input, "function params")?;

        let return_type = if input.peek(Token![->]) {
            let _: Token![->] = input.parse()?;
            Some(FieldType::parse(input)?)
        } else {
            None
        };

        Ok(Self {
            version,
            name_span: name_ident.span(),
            name: name_ident.to_string(),
            fields,
            return_type,
        })
    }
}

impl PartialEq<Function> for Function {
    fn eq(&self, other: &Function) -> bool {
        self.version == other.version
            && self.name == other.name
            && self.fields == other.fields
            && self.return_type == other.return_type
    }
}

#[derive(Debug)]
pub struct Command {
    pub version: MajorVersion,
    pub name_span: Span,
    pub name: String,
    pub fields: Vec<StructField>,
}

impl Command {
    fn parse(input: ParseStream, version: MajorVersion) -> Result<Self> {
        let name_ident: Ident = input.parse()?;

        let fields_input;
        parenthesized!(fields_input in input);
        let fields = parse_struct_fields(&fields_input, "command params")?;

        Ok(Self {
            version,
            name_span: name_ident.span(),
            name: name_ident.to_string(),
            fields,
        })
    }
}

impl PartialEq<Command> for Command {
    fn eq(&self, other: &Command) -> bool {
        self.version == other.version && self.name == other.name && self.fields == other.fields
    }
}

#[derive(Debug, PartialEq)]
pub struct MajorVersion(u16);

impl MajorVersion {
    fn parse(input: ParseStream) -> Result<Self> {
        let value_input;
        parenthesized!(value_input in input);
        let input = &value_input;

        let int_lit: LitInt = input.parse()?;
        let value = int_lit.to_string();
        let Ok(major) = u16::from_str_radix(&value, 10) else {
            return Err(Error::new(int_lit.span(), "major version must be valid u16 value"));
        };

        Ok(Self(major))
    }
}

#[derive(Debug, PartialEq)]
pub struct MinorVersion(u16, u16);

impl MinorVersion {
    fn maybe_parse(
        input: ParseStream,
        add_is_valid: bool,
        invalid_for: &str,
    ) -> Result<Option<Self>> {
        if input.peek(Token![@]) {
            let _: Token![@] = input.parse()?;
            if add_is_valid {
                if input.peek(kw::add) {
                    let _: kw::add = input.parse()?;
                } else if input.peek(kw::rem) {
                    return Err(
                        input.error(format!("@rem directive is not allowed for {}", invalid_for))
                    );
                }
            } else {
                if input.peek(kw::rem) {
                    let _: kw::rem = input.parse()?;
                } else if input.peek(kw::add) {
                    return Err(
                        input.error(format!("@add directive is not allowed for {}", invalid_for))
                    );
                }
            }

            let version_input;
            parenthesized!(version_input in input);
            let input = &version_input;

            let float_lit: LitFloat = input.parse()?;
            let value = float_lit.to_string();
            let (major, minor) = value.split_once('.').unwrap();

            let parse_version_num = |num: &str| -> Result<u16> {
                match u16::from_str_radix(num, 10) {
                    Ok(num) => Ok(num),
                    Err(_) => Err(Error::new(
                        float_lit.span(),
                        "major and minor versions must be valid u16 values",
                    )),
                }
            };
            let major = parse_version_num(major)?;
            let minor = parse_version_num(minor)?;

            Ok(Some(Self(major, minor)))
        } else {
            Ok(None)
        }
    }
}

#[derive(Debug)]
pub enum FieldType {
    Primitive(Span, Primitive),
    Type(Span, String, Option<String>, Option<MajorVersion>),
    Optional(Span, Box<FieldType>),
    Reference(Span, Box<FieldType>),
    Array(Span, Box<FieldType>, u32),
    List(Span, Box<FieldType>),
    Map(Span, Box<FieldType>, Box<FieldType>),
    Tuple(Span, Tuple),
}

#[derive(Debug, PartialEq, Eq)]
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
    Bytes,

    Any,
}

impl FieldType {
    fn parse(input: ParseStream) -> Result<Self> {
        let lookahead = input.lookahead1();
        if lookahead.peek(Ident::peek_any) {
            let span = input.span();
            let ident: Ident = input.parse()?;
            let ident = ident.to_string();
            match ident.as_str() {
                "i8" => Ok(FieldType::Primitive(span, Primitive::Int8)),
                "i16" => Ok(FieldType::Primitive(span, Primitive::Int16)),
                "i32" => Ok(FieldType::Primitive(span, Primitive::Int32)),
                "i64" => Ok(FieldType::Primitive(span, Primitive::Int64)),
                "u8" => Ok(FieldType::Primitive(span, Primitive::UInt8)),
                "u16" => Ok(FieldType::Primitive(span, Primitive::UInt16)),
                "u32" => Ok(FieldType::Primitive(span, Primitive::UInt32)),
                "u64" => Ok(FieldType::Primitive(span, Primitive::UInt64)),
                "f32" => Ok(FieldType::Primitive(span, Primitive::Float32)),
                "f64" => Ok(FieldType::Primitive(span, Primitive::Float64)),
                "bool" => Ok(FieldType::Primitive(span, Primitive::Boolean)),
                "str" => Ok(FieldType::Primitive(span, Primitive::String)),
                "bytes" => Ok(FieldType::Primitive(span, Primitive::Bytes)),
                "any" => Ok(FieldType::Primitive(span, Primitive::Any)),
                _ => {
                    let second_ident = if input.peek(Token![:]) {
                        let _: Token![:] = input.parse()?;
                        let _: Token![:] = input.parse()?;

                        let ident: Ident = input.parse()?;
                        Some(ident.to_string())
                    } else {
                        None
                    };

                    let version = if input.peek(Token![@]) {
                        let _: Token![@] = input.parse()?;
                        let _: kw::ver = input.parse()?;
                        Some(MajorVersion::parse(input)?)
                    } else {
                        None
                    };

                    Ok(Self::Type(span, ident, second_ident, version))
                }
            }
        } else if lookahead.peek(Token![?]) {
            let qm: Token![?] = input.parse()?;
            Ok(Self::Optional(qm.span, Box::new(Self::parse(input)?)))
        } else if lookahead.peek(Token![&]) {
            let amp: Token![&] = input.parse()?;
            Ok(Self::Reference(amp.span, Box::new(Self::parse(input)?)))
        } else if lookahead.peek(Bracket) {
            let bracket_span = input.span();

            let bracketed_input;
            bracketed!(bracketed_input in input);
            let input = &bracketed_input;

            let element_type = Self::parse(input)?;
            if !input.is_empty() {
                let lookahead = input.lookahead1();
                if lookahead.peek(Token![;]) {
                    let _: Token![;] = input.parse()?;
                    let size: LitInt = input.parse()?;
                    expect_empty(input)?;

                    Ok(Self::Array(
                        bracket_span,
                        Box::new(element_type),
                        parse_int_lit(&size, "invalid array size literal")?,
                    ))
                } else if lookahead.peek(Token![:]) {
                    let key_type = element_type;

                    let _: Token![:] = input.parse()?;
                    let value_type = Self::parse(input)?;
                    expect_empty(input)?;

                    Ok(Self::Map(
                        bracket_span,
                        Box::new(key_type),
                        Box::new(value_type),
                    ))
                } else {
                    Err(lookahead.error())
                }
            } else {
                Ok(Self::List(bracket_span, Box::new(element_type)))
            }
        } else if lookahead.peek(Paren) {
            let paren_span = input.span();
            let tuple = Tuple::parse(input)?;
            Ok(Self::Tuple(paren_span, tuple))
        } else {
            Err(lookahead.error())
        }
    }
}

impl PartialEq<FieldType> for FieldType {
    fn eq(&self, other: &FieldType) -> bool {
        match self {
            Self::Primitive(_, primitive) => {
                if let Self::Primitive(_, other_primitive) = other {
                    primitive == other_primitive
                } else {
                    false
                }
            }
            Self::Type(_, ident, extra_ident, version) => {
                if let Self::Type(_, other_ident, other_extra_ident, other_version) = other {
                    ident == other_ident
                        && extra_ident == other_extra_ident
                        && version == other_version
                } else {
                    false
                }
            }
            Self::Optional(_, field_type) => {
                if let Self::Optional(_, other_field_type) = other {
                    field_type == other_field_type
                } else {
                    false
                }
            }
            Self::Reference(_, field_type) => {
                if let Self::Reference(_, other_field_type) = other {
                    field_type == other_field_type
                } else {
                    false
                }
            }
            Self::Array(_, element_type, size) => {
                if let Self::Array(_, other_element_type, other_size) = other {
                    element_type == other_element_type && size == other_size
                } else {
                    false
                }
            }
            Self::List(_, element_type) => {
                if let Self::List(_, other_element_type) = other {
                    element_type == other_element_type
                } else {
                    false
                }
            }
            Self::Map(_, key_type, value_type) => {
                if let Self::Map(_, other_key_type, other_value_type) = other {
                    key_type == other_key_type && value_type == other_value_type
                } else {
                    false
                }
            }
            Self::Tuple(_, tuple) => {
                if let Self::Tuple(_, other_tuple) = other {
                    tuple == other_tuple
                } else {
                    false
                }
            }
        }
    }
}

fn parse_int_lit(int_lit: &LitInt, msg: &str) -> Result<u32> {
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

#[cfg(test)]
mod tests {
    use super::*;
    use quote::quote;

    #[test]
    fn parse_scheme_name() {
        let scheme: Scheme = syn::parse2(quote! {
            sch "scheme/name";
        })
        .unwrap();
        assert_eq!(
            scheme,
            Scheme {
                name: "scheme/name".to_string(),
                uses: Vec::new(),
                types: Vec::new(),
            }
        );
    }

    #[test]
    fn parse_missing_scheme_name() {
        let result = syn::parse2::<Scheme>(quote! {
            use extern_crate::types;

            obj(struct) Object {
                object: &types::Object,
            }
        });
        assert!(result.is_err());
    }

    #[test]
    fn parse_use() {
        let scheme: Scheme = syn::parse2(quote! {
            sch "scheme/name";

            use extern_crate::types as extern_types;
            use super::types as super_types;
            use crate::types;
        })
        .unwrap();
        assert_eq!(
            scheme,
            Scheme {
                name: "scheme/name".to_string(),
                uses: vec![
                    Use {
                        segments: vec!["extern_crate".to_string(), "types".to_string(),],
                        alias: Some("extern_types".to_string()),
                    },
                    Use {
                        segments: vec!["super".to_string(), "types".to_string(),],
                        alias: Some("super_types".to_string()),
                    },
                    Use {
                        segments: vec!["crate".to_string(), "types".to_string(),],
                        alias: None
                    },
                ],
                types: Vec::new(),
            }
        );
    }

    #[test]
    fn parse_regular_struct() {
        let scheme: Scheme = syn::parse2(quote! {
            sch "scheme/name";

            use crate::types;

            @ver(1)
            struct Struct {
                signed_int8: i8,
                signed_int16: i16,
                signed_int32: i32,
                signed_int64: i64,

                @add(1.1)
                unsigned_int8: u8,

                @add(1.2)
                unsigned_int16: u16,

                @add(1.3)
                unsigned_int32: u32,

                @add(1.4)
                unsigned_int64: u64,

                float32: f32,
                float64: f64,

                boolean: bool,
                string: str,
                optional: ?str,

                array: [u8; 32],
                list: [u8],
                map: [u8: u8],
                tuple: (u8, u8),
                byte_list: bytes,

                @add(1.5)
                extern_struct: types::Struct@ver(1),

                @add(1.6)
                extern_object: &types::Object,

                @add(1.7)
                any_object: &any,
            }
        })
        .unwrap();
        let dummy_span = Span::call_site();
        assert_eq!(
            scheme,
            Scheme {
                name: "scheme/name".to_string(),
                uses: vec![Use {
                    segments: vec!["crate".to_string(), "types".to_string()],
                    alias: None,
                },],
                types: vec![Type::Struct(Struct {
                    version: MajorVersion(1),
                    name_span: dummy_span,
                    name: "Struct".to_string(),
                    body: StructBody::Fields(vec![
                        StructField {
                            version: None,
                            name_span: dummy_span,
                            name: "signed_int8".to_string(),
                            field_type: FieldType::Primitive(dummy_span, Primitive::Int8),
                        },
                        StructField {
                            version: None,
                            name_span: dummy_span,
                            name: "signed_int16".to_string(),
                            field_type: FieldType::Primitive(dummy_span, Primitive::Int16),
                        },
                        StructField {
                            version: None,
                            name_span: dummy_span,
                            name: "signed_int32".to_string(),
                            field_type: FieldType::Primitive(dummy_span, Primitive::Int32),
                        },
                        StructField {
                            version: None,
                            name_span: dummy_span,
                            name: "signed_int64".to_string(),
                            field_type: FieldType::Primitive(dummy_span, Primitive::Int64),
                        },
                        StructField {
                            version: Some(MinorVersion(1, 1)),
                            name_span: dummy_span,
                            name: "unsigned_int8".to_string(),
                            field_type: FieldType::Primitive(dummy_span, Primitive::UInt8),
                        },
                        StructField {
                            version: Some(MinorVersion(1, 2)),
                            name_span: dummy_span,
                            name: "unsigned_int16".to_string(),
                            field_type: FieldType::Primitive(dummy_span, Primitive::UInt16),
                        },
                        StructField {
                            version: Some(MinorVersion(1, 3)),
                            name_span: dummy_span,
                            name: "unsigned_int32".to_string(),
                            field_type: FieldType::Primitive(dummy_span, Primitive::UInt32),
                        },
                        StructField {
                            version: Some(MinorVersion(1, 4)),
                            name_span: dummy_span,
                            name: "unsigned_int64".to_string(),
                            field_type: FieldType::Primitive(dummy_span, Primitive::UInt64),
                        },
                        StructField {
                            version: None,
                            name_span: dummy_span,
                            name: "float32".to_string(),
                            field_type: FieldType::Primitive(dummy_span, Primitive::Float32),
                        },
                        StructField {
                            version: None,
                            name_span: dummy_span,
                            name: "float64".to_string(),
                            field_type: FieldType::Primitive(dummy_span, Primitive::Float64),
                        },
                        StructField {
                            version: None,
                            name_span: dummy_span,
                            name: "boolean".to_string(),
                            field_type: FieldType::Primitive(dummy_span, Primitive::Boolean),
                        },
                        StructField {
                            version: None,
                            name_span: dummy_span,
                            name: "string".to_string(),
                            field_type: FieldType::Primitive(dummy_span, Primitive::String),
                        },
                        StructField {
                            version: None,
                            name_span: dummy_span,
                            name: "optional".to_string(),
                            field_type: FieldType::Optional(
                                dummy_span,
                                Box::new(FieldType::Primitive(dummy_span, Primitive::String))
                            ),
                        },
                        StructField {
                            version: None,
                            name_span: dummy_span,
                            name: "array".to_string(),
                            field_type: FieldType::Array(
                                dummy_span,
                                Box::new(FieldType::Primitive(dummy_span, Primitive::UInt8)),
                                32
                            ),
                        },
                        StructField {
                            version: None,
                            name_span: dummy_span,
                            name: "list".to_string(),
                            field_type: FieldType::List(
                                dummy_span,
                                Box::new(FieldType::Primitive(dummy_span, Primitive::UInt8)),
                            ),
                        },
                        StructField {
                            version: None,
                            name_span: dummy_span,
                            name: "map".to_string(),
                            field_type: FieldType::Map(
                                dummy_span,
                                Box::new(FieldType::Primitive(dummy_span, Primitive::UInt8)),
                                Box::new(FieldType::Primitive(dummy_span, Primitive::UInt8)),
                            ),
                        },
                        StructField {
                            version: None,
                            name_span: dummy_span,
                            name: "tuple".to_string(),
                            field_type: FieldType::Tuple(
                                dummy_span,
                                Tuple(vec![
                                    TupleField {
                                        version: None,
                                        field_type: FieldType::Primitive(
                                            dummy_span,
                                            Primitive::UInt8
                                        ),
                                    },
                                    TupleField {
                                        version: None,
                                        field_type: FieldType::Primitive(
                                            dummy_span,
                                            Primitive::UInt8
                                        ),
                                    },
                                ]),
                            ),
                        },
                        StructField {
                            version: None,
                            name_span: dummy_span,
                            name: "byte_list".to_string(),
                            field_type: FieldType::Primitive(dummy_span, Primitive::Bytes),
                        },
                        StructField {
                            version: Some(MinorVersion(1, 5)),
                            name_span: dummy_span,
                            name: "extern_struct".to_string(),
                            field_type: FieldType::Type(
                                dummy_span,
                                "types".to_string(),
                                Some("Struct".to_string()),
                                Some(MajorVersion(1))
                            ),
                        },
                        StructField {
                            version: Some(MinorVersion(1, 6)),
                            name_span: dummy_span,
                            name: "extern_object".to_string(),
                            field_type: FieldType::Reference(
                                dummy_span,
                                Box::new(FieldType::Type(
                                    dummy_span,
                                    "types".to_string(),
                                    Some("Object".to_string()),
                                    None,
                                )),
                            ),
                        },
                        StructField {
                            version: Some(MinorVersion(1, 7)),
                            name_span: dummy_span,
                            name: "any_object".to_string(),
                            field_type: FieldType::Reference(
                                dummy_span,
                                Box::new(FieldType::Primitive(dummy_span, Primitive::Any))
                            ),
                        },
                    ]),
                }),],
            }
        );
    }

    #[test]
    fn parse_unit_struct() {
        let scheme: Scheme = syn::parse2(quote! {
            sch "scheme/name";

            @ver(1)
            struct UnitStruct;
        })
        .unwrap();
        assert_eq!(
            scheme,
            Scheme {
                name: "scheme/name".to_string(),
                uses: Vec::new(),
                types: vec![Type::Struct(Struct {
                    version: MajorVersion(1),
                    name_span: Span::call_site(),
                    name: "UnitStruct".to_string(),
                    body: StructBody::Unit,
                }),],
            },
        );
    }

    #[test]
    fn parse_tuple_struct() {
        let scheme: Scheme = syn::parse2(quote! {
            sch "scheme/name";

            @ver(1)
            struct TupleStruct(u8, @add(1.1) u8)
        })
        .unwrap();
        let dummy_span = Span::call_site();
        assert_eq!(
            scheme,
            Scheme {
                name: "scheme/name".to_string(),
                uses: Vec::new(),
                types: vec![Type::Struct(Struct {
                    version: MajorVersion(1),
                    name_span: dummy_span,
                    name: "TupleStruct".to_string(),
                    body: StructBody::Tuple(Tuple(vec![
                        TupleField {
                            version: None,
                            field_type: FieldType::Primitive(dummy_span, Primitive::UInt8)
                        },
                        TupleField {
                            version: Some(MinorVersion(1, 1)),
                            field_type: FieldType::Primitive(dummy_span, Primitive::UInt8)
                        },
                    ])),
                }),],
            },
        );
    }

    #[test]
    fn parse_union() {
        let scheme: Scheme = syn::parse2(quote! {
            sch "scheme/name";

            use crate::types;

            @ver(1)
            union Union {
                NewType(u8),

                @rem(1.1)
                Tuple(u8, u16),

                Struct {
                    object: &types::Object,
                },

                @rem(1.2)
                Unit,
            }
        })
        .unwrap();
        let dummy_span = Span::call_site();
        assert_eq!(
            scheme,
            Scheme {
                name: "scheme/name".to_string(),
                uses: vec![Use {
                    segments: vec!["crate".to_string(), "types".to_string()],
                    alias: None,
                },],
                types: vec![Type::Union(Union {
                    version: MajorVersion(1),
                    name_span: dummy_span,
                    name: "Union".to_string(),
                    fields: vec![
                        UnionField {
                            version: None,
                            name_span: dummy_span,
                            name: "NewType".to_string(),
                            body: StructBody::Tuple(Tuple(vec![TupleField {
                                version: None,
                                field_type: FieldType::Primitive(dummy_span, Primitive::UInt8)
                            },])),
                        },
                        UnionField {
                            version: Some(MinorVersion(1, 1)),
                            name_span: dummy_span,
                            name: "Tuple".to_string(),
                            body: StructBody::Tuple(Tuple(vec![
                                TupleField {
                                    version: None,
                                    field_type: FieldType::Primitive(dummy_span, Primitive::UInt8),
                                },
                                TupleField {
                                    version: None,
                                    field_type: FieldType::Primitive(dummy_span, Primitive::UInt16),
                                }
                            ]))
                        },
                        UnionField {
                            version: None,
                            name_span: dummy_span,
                            name: "Struct".to_string(),
                            body: StructBody::Fields(vec![StructField {
                                version: None,
                                name_span: dummy_span,
                                name: "object".to_string(),
                                field_type: FieldType::Reference(
                                    dummy_span,
                                    Box::new(FieldType::Type(
                                        dummy_span,
                                        "types".to_string(),
                                        Some("Object".to_string()),
                                        None
                                    ))
                                ),
                            },]),
                        },
                        UnionField {
                            version: Some(MinorVersion(1, 2)),
                            name_span: dummy_span,
                            name: "Unit".to_string(),
                            body: StructBody::Unit,
                        },
                    ],
                }),],
            }
        );
    }

    #[test]
    fn parse_enum() {
        let scheme: Scheme = syn::parse2(quote! {
            sch "scheme/name";

            @ver(1)
            enum Enum {
                @rem(1.1)
                Zero,

                One = 10,
                Two = 20,
                Three = 30,

                @rem(1.2)
                Four = 40,
            }
        })
        .unwrap();
        let dummy_span = Span::call_site();
        assert_eq!(
            scheme,
            Scheme {
                name: "scheme/name".to_string(),
                uses: Vec::new(),
                types: vec![Type::Enum(Enum {
                    version: MajorVersion(1),
                    name_span: dummy_span,
                    name: "Enum".to_string(),
                    fields: vec![
                        EnumField {
                            version: Some(MinorVersion(1, 1)),
                            name_span: dummy_span,
                            name: "Zero".to_string(),
                            value: None,
                        },
                        EnumField {
                            version: None,
                            name_span: dummy_span,
                            name: "One".to_string(),
                            value: Some(10),
                        },
                        EnumField {
                            version: None,
                            name_span: dummy_span,
                            name: "Two".to_string(),
                            value: Some(20),
                        },
                        EnumField {
                            version: None,
                            name_span: dummy_span,
                            name: "Three".to_string(),
                            value: Some(30),
                        },
                        EnumField {
                            version: Some(MinorVersion(1, 2)),
                            name_span: dummy_span,
                            name: "Four".to_string(),
                            value: Some(40),
                        },
                    ],
                }),],
            }
        );
    }

    #[test]
    fn parse_function() {
        let scheme: Scheme = syn::parse2(quote! {
            sch "scheme/name";

            use crate::types;

            @ver(1)
            fn Function(object: &types::Object)

            @ver(2)
            fn Function(
                object: &types::Object,
                struct_: types::Struct@ver(1),
            ) -> types::Union@ver(1)
        })
        .unwrap();
        let dummy_span = Span::call_site();
        assert_eq!(
            scheme,
            Scheme {
                name: "scheme/name".to_string(),
                uses: vec![Use {
                    segments: vec!["crate".to_string(), "types".to_string()],
                    alias: None,
                }],
                types: vec![
                    Type::Function(Function {
                        version: MajorVersion(1),
                        name_span: dummy_span,
                        name: "Function".to_string(),
                        fields: vec![StructField {
                            version: None,
                            name_span: dummy_span,
                            name: "object".to_string(),
                            field_type: FieldType::Reference(
                                dummy_span,
                                Box::new(FieldType::Type(
                                    dummy_span,
                                    "types".to_string(),
                                    Some("Object".to_string()),
                                    None,
                                ))
                            ),
                        },],
                        return_type: None,
                    }),
                    Type::Function(Function {
                        version: MajorVersion(2),
                        name_span: dummy_span,
                        name: "Function".to_string(),
                        fields: vec![
                            StructField {
                                version: None,
                                name_span: dummy_span,
                                name: "object".to_string(),
                                field_type: FieldType::Reference(
                                    dummy_span,
                                    Box::new(FieldType::Type(
                                        dummy_span,
                                        "types".to_string(),
                                        Some("Object".to_string()),
                                        None,
                                    ))
                                ),
                            },
                            StructField {
                                version: None,
                                name_span: dummy_span,
                                name: "struct_".to_string(),
                                field_type: FieldType::Type(
                                    dummy_span,
                                    "types".to_string(),
                                    Some("Struct".to_string()),
                                    Some(MajorVersion(1))
                                ),
                            }
                        ],
                        return_type: Some(FieldType::Type(
                            dummy_span,
                            "types".to_string(),
                            Some("Union".to_string()),
                            Some(MajorVersion(1))
                        )),
                    }),
                ],
            },
        );
    }

    #[test]
    fn parse_command() {
        let scheme: Scheme = syn::parse2(quote! {
            sch "scheme/name";

            use crate::types;

            @ver(1)
            cmd Command(
                object: &Object,
                extern_object: &types::Object,
            )
        })
        .unwrap();
        let dummy_span = Span::call_site();
        assert_eq!(
            scheme,
            Scheme {
                name: "scheme/name".to_string(),
                uses: vec![Use {
                    segments: vec!["crate".to_string(), "types".to_string()],
                    alias: None,
                }],
                types: vec![Type::Command(Command {
                    version: MajorVersion(1),
                    name_span: dummy_span,
                    name: "Command".to_string(),
                    fields: vec![
                        StructField {
                            version: None,
                            name_span: dummy_span,
                            name: "object".to_string(),
                            field_type: FieldType::Reference(
                                dummy_span,
                                Box::new(FieldType::Type(
                                    dummy_span,
                                    "Object".to_string(),
                                    None,
                                    None
                                ))
                            ),
                        },
                        StructField {
                            version: None,
                            name_span: dummy_span,
                            name: "extern_object".to_string(),
                            field_type: FieldType::Reference(
                                dummy_span,
                                Box::new(FieldType::Type(
                                    dummy_span,
                                    "types".to_string(),
                                    Some("Object".to_string()),
                                    None
                                ))
                            ),
                        },
                    ],
                })],
            }
        );
    }
}
