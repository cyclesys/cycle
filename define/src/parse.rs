use syn::{
    braced, bracketed,
    ext::IdentExt,
    parenthesized,
    parse::{Parse, ParseStream},
    token::{Brace, Bracket, Paren},
    Ident, LitInt, Result, Token,
};

mod kw {
    syn::custom_keyword!(node);
    syn::custom_keyword!(any);
    syn::custom_keyword!(add);
    syn::custom_keyword!(rem);
}

pub struct Definition(Vec<DefinitionItem>);

impl Parse for Definition {
    fn parse(input: ParseStream) -> Result<Self> {
        let mut items = Vec::new();
        while !input.is_empty() {
            items.push(input.parse()?);
        }
        Ok(Self(items))
    }
}

pub enum DefinitionItem {
    Version(Version),
    Node(Struct),
    Struct(Struct),
    Enum(Enum),
}

impl Parse for DefinitionItem {
    fn parse(input: ParseStream) -> Result<Self> {
        let lookahead = input.lookahead1();
        if lookahead.peek(Token![#]) {
            Ok(Self::Version(input.parse()?))
        } else if lookahead.peek(kw::node) {
            Ok(Self::Node(input.parse()?))
        } else if lookahead.peek(Token![struct]) {
            Ok(Self::Struct(input.parse()?))
        } else if lookahead.peek(Token![enum]) {
            Ok(Self::Enum(input.parse()?))
        } else {
            Err(lookahead.error())
        }
    }
}

pub struct Version(Vec<VersionItem>);

impl Parse for Version {
    fn parse(input: ParseStream) -> Result<Self> {
        let _: Token![#] = input.parse()?;

        let version_input;
        bracketed!(version_input in input);

        let mut items = Vec::new();
        while !version_input.is_empty() {
            if items.len() > 0 {
                let _: Token![,] = version_input.parse()?;
            }
            items.push(version_input.parse()?);
        }
        Ok(Self(items))
    }
}

pub enum VersionItem {
    Add(LitInt),
    Rem(LitInt),
}

impl Parse for VersionItem {
    fn parse(input: ParseStream) -> Result<Self> {
        let lookahead = input.lookahead1();
        if lookahead.peek(kw::add) {
            let _: kw::add = input.parse()?;

            let add_input;
            parenthesized!(add_input in input);

            let ver: LitInt = add_input.parse()?;
            expect_empty(&add_input)?;
            Ok(Self::Add(ver))
        } else if lookahead.peek(kw::rem) {
            let _: kw::rem = input.parse()?;

            let rem_input;
            parenthesized!(rem_input in input);

            let ver: LitInt = rem_input.parse()?;
            expect_empty(&rem_input)?;
            Ok(Self::Rem(ver))
        } else {
            Err(lookahead.error())
        }
    }
}

pub struct Struct {
    name: Ident,
    items: Vec<StructItem>,
}

impl Parse for Struct {
    fn parse(input: ParseStream) -> Result<Self> {
        if input.peek(Token![struct]) {
            let _: Token![struct] = input.parse()?;
        } else {
            let _: kw::node = input.parse()?;
        }

        let name: Ident = input.parse()?;

        let struct_input;
        braced!(struct_input in input);

        let mut items = Vec::new();
        while !struct_input.is_empty() {
            items.push(struct_input.parse()?);
        }

        Ok(Self { name, items })
    }
}

pub enum StructItem {
    Version(Version),
    Field(StructField),
}

impl Parse for StructItem {
    fn parse(input: ParseStream) -> Result<Self> {
        let lookahead = input.lookahead1();
        if lookahead.peek(Token![#]) {
            Ok(Self::Version(input.parse()?))
        } else if lookahead.peek(Ident::peek_any) {
            Ok(Self::Field(input.parse()?))
        } else {
            Err(lookahead.error())
        }
    }
}

pub struct StructField {
    name: Ident,
    value: Value,
}

impl Parse for StructField {
    fn parse(input: ParseStream) -> Result<Self> {
        let name = input.parse()?;
        let _: Token![:] = input.parse()?;
        let value = input.parse()?;
        let _: Token![,] = input.parse()?;

        Ok(Self { name, value })
    }
}

pub struct Enum {
    name: Ident,
    items: Vec<EnumItem>,
}

impl Parse for Enum {
    fn parse(input: ParseStream) -> Result<Self> {
        let _: Token![enum] = input.parse()?;
        let name = input.parse()?;

        let enum_input;
        braced!(enum_input in input);

        let mut items = Vec::new();
        while !enum_input.is_empty() {
            items.push(enum_input.parse()?);
        }

        Ok(Self { name, items })
    }
}

pub enum EnumItem {
    Version(Version),
    Field(EnumField),
}

impl Parse for EnumItem {
    fn parse(input: ParseStream) -> Result<Self> {
        let lookahead = input.lookahead1();
        if lookahead.peek(Token![#]) {
            Ok(Self::Version(input.parse()?))
        } else if lookahead.peek(Ident::peek_any) {
            Ok(Self::Field(input.parse()?))
        } else {
            Err(lookahead.error())
        }
    }
}

pub enum EnumField {
    Ident(Ident),
    Int(Ident, LitInt),
    Tuple(Ident, Vec<Value>),
    Struct(Ident, Vec<StructField>),
}

impl Parse for EnumField {
    fn parse(input: ParseStream) -> Result<Self> {
        let ident = input.parse()?;

        let result = if input.peek(Brace) {
            let struct_input;
            braced!(struct_input in input);

            let mut fields = Vec::new();
            while !struct_input.is_empty() {
                fields.push(struct_input.parse()?);
            }

            Ok(Self::Struct(ident, fields))
        } else if input.peek(Paren) {
            let tuple_input;
            parenthesized!(tuple_input in input);

            let mut values = Vec::new();
            while !tuple_input.is_empty() {
                if values.len() > 0 {
                    let _: Token![,] = tuple_input.parse()?;
                }
                values.push(tuple_input.parse()?);
            }

            Ok(Self::Tuple(ident, values))
        } else if input.peek(Token![=]) {
            let _: Token![=] = input.parse()?;
            let int = input.parse()?;
            Ok(Self::Int(ident, int))
        } else {
            Ok(Self::Ident(ident))
        };

        let _: Token![,] = input.parse()?;
        result
    }
}

pub enum Value {
    Ident(ValueIdent),
    Array(Box<Value>, LitInt),
    Slice(Box<Value>),
    Tuple(Vec<Value>),
}

impl Parse for Value {
    fn parse(input: ParseStream) -> Result<Self> {
        let lookahead = input.lookahead1();
        if lookahead.peek(Bracket) {
            let array_input;
            bracketed!(array_input in input);

            let value: Value = array_input.parse()?;
            if !array_input.is_empty() {
                let _: Token![;] = array_input.parse()?;
                let size: LitInt = array_input.parse()?;

                Ok(Self::Array(Box::from(value), size))
            } else {
                Ok(Self::Slice(Box::from(value)))
            }
        } else if lookahead.peek(Paren) {
            let tuple_input;
            parenthesized!(tuple_input in input);

            let mut values = Vec::new();
            while !tuple_input.is_empty() {
                if values.len() > 0 {
                    let _: Token![,] = tuple_input.parse()?;
                }
                values.push(tuple_input.parse()?);
            }

            Ok(Self::Tuple(values))
        } else if lookahead.peek(Ident::peek_any) {
            Ok(Self::Ident(input.parse()?))
        } else {
            Err(lookahead.error())
        }
    }
}

pub enum ValueIdent {
    Ident(Ident),
    // `ref` is a keyword in rust, which means syn treats it as a keyword and not an identifier,
    // thus we can't use Self::Wrapper for `ref<type>` values like we can for `opt<type>`.
    Ref(Box<Value>),
    Wrapper(Ident, Box<Value>),
}

impl Parse for ValueIdent {
    fn parse(input: ParseStream) -> Result<Self> {
        let ident: Option<Ident> = if input.peek(Token![ref]) {
            let _: Token![ref] = input.parse()?;
            None
        } else {
            Some(input.parse()?)
        };

        if input.peek(Token![<]) {
            let _: Token![<] = input.parse()?;
            let value: Value = input.parse()?;
            let _: Token![>] = input.parse()?;

            match ident {
                Some(ident) => Ok(Self::Wrapper(ident, Box::from(value))),
                None => Ok(Self::Ref(Box::from(value))),
            }
        } else {
            match ident {
                Some(ident) => Ok(Self::Ident(ident)),
                None => Err(input.error("expected a <type> specifier for ref")),
            }
        }
    }
}

fn expect_empty(input: ParseStream) -> Result<()> {
    if input.is_empty() {
        Ok(())
    } else {
        Err(input.error("expected nothing here"))
    }
}
