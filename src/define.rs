pub struct Definition {
    pub url: String,
    pub version: u16,
    pub types: Box<[Type]>,
}

pub enum Type {
    Object(Object),
    Struct(Struct),
    Enum(Enum),
}

pub struct Object {
    pub name: String,
    pub fields: Box<[StructField]>,
}

pub struct Struct {
    pub name: String,
    pub fields: Box<[StructField]>,
}

pub struct StructField {
    pub name: String,
    pub field_type: FieldType,
}

pub struct Enum {
    pub name: String,
    pub fields: Box<[EnumField]>,
}

pub struct EnumField {
    pub name: String,
    pub field_type: EnumFieldType,
}

pub enum EnumFieldType {
    None,
    Int(EnumIntType),
    Tuple(Box<[FieldType]>),
    Struct(Box<[StructField]>),
}

pub enum EnumIntType {
    Int8(i8),
    Int16(i16),
    Int32(i32),
    Int64(i64),

    UInt8(u8),
    UInt16(u16),
    UInt32(u32),
    UInt64(u64),
}

// General field type for both structs, and enum tuple variants.
pub enum FieldType {
    // An index to the type definition.
    Type(usize),
    Optional(Box<FieldType>),
    Reference(Reference),
    Array {
        element_type: Box<FieldType>,
        size: u64,
    },
    Slice(Box<FieldType>),
    Tuple(Box<[FieldType]>),
    Primitive(Primitive),
}

pub enum Reference {
    // An index to the object definition that's being referenced.
    Object(usize),
    Any,
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
