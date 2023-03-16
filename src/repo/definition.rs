use std::path::Path;

use libcycle::define::{
    Definition, Enum, EnumField, EnumFieldType, EnumIntType, FieldType, Object, Primitive,
    Reference, Struct, StructField, Type,
};

use super::{Error, ReadState, Result};

pub struct StoredDefinition {
    pub hash: [u8; 32],
    pub definition: Definition,
}

enum TypeKind {
    Object,
    Struct,
    Enum,
}

impl TypeKind {
    fn from_u8(v: u8) -> Option<TypeKind> {
        match v {
            0 => Some(TypeKind::Object),
            1 => Some(TypeKind::Struct),
            2 => Some(TypeKind::Enum),
            _ => None,
        }
    }
}

enum EnumFieldKind {
    None,
    Int,
    Struct,
    Tuple,
}

impl EnumFieldKind {
    fn from_u8(v: u8) -> Option<EnumFieldKind> {
        match v {
            0 => Some(EnumFieldKind::None),
            1 => Some(EnumFieldKind::Int),
            2 => Some(EnumFieldKind::Tuple),
            3 => Some(EnumFieldKind::Struct),
            _ => None,
        }
    }
}

enum EnumIntKind {
    Int8,
    Int16,
    Int32,
    Int64,

    UInt8,
    UInt16,
    UInt32,
    UInt64,
}

impl EnumIntKind {
    fn from_u8(v: u8) -> Option<EnumIntKind> {
        match v {
            0 => Some(EnumIntKind::Int8),
            1 => Some(EnumIntKind::Int16),
            2 => Some(EnumIntKind::Int32),
            3 => Some(EnumIntKind::Int64),

            4 => Some(EnumIntKind::UInt8),
            5 => Some(EnumIntKind::UInt16),
            6 => Some(EnumIntKind::UInt32),
            7 => Some(EnumIntKind::UInt64),
            _ => None,
        }
    }
}

pub fn read_definition_file(
    path: &Path,
    hash: [u8; 32],
    definitions: &mut Vec<StoredDefinition>,
) -> Result<()> {
    let bytes = super::decode_file(path)?;
    let mut state = ReadState {
        bytes: bytes.as_slice(),
        cursor: 0,
    };

    let url = state.read_string()?;
    let version = state.read_u16()?;

    let num_types = state.read_u16()?;

    let mut types = Vec::with_capacity(num_types as usize);
    for _ in 0..num_types {
        let Some(type_kind) = TypeKind::from_u8(state.read_u8()?) else {
            return Err(Error::CorruptFile);
        };

        let type_name = state.read_string()?;
        let num_fields = state.read_u16()?;

        match type_kind {
            TypeKind::Object | TypeKind::Struct => {
                let mut fields = Vec::with_capacity(num_fields as usize);
                for _ in 0..num_fields {
                    fields.push(read_struct_field(&mut state)?);
                }
                if let TypeKind::Object = type_kind {
                    types.push(Type::Object(Object {
                        name: type_name,
                        fields: fields.into_boxed_slice(),
                    }));
                } else {
                    types.push(Type::Struct(Struct {
                        name: type_name,
                        fields: fields.into_boxed_slice(),
                    }));
                }
            }
            TypeKind::Enum => {
                let mut fields = Vec::new();
                for _ in 0..num_fields {
                    let field_name = state.read_string()?;
                    let Some(field_kind) = EnumFieldKind::from_u8(state.read_u8()?) else {
                        return Err(Error::CorruptFile);
                    };

                    // TODO: Should there be some kind of validation here so that
                    // EnumFieldKind::Int kinds and EnumFieldKind::Tuple/Struct kinds
                    // aren't mixed?
                    //
                    // This is already checked for in cycle_define, but it's probably a
                    // good idea to validate it at this stage as well.
                    let field_type = match field_kind {
                        EnumFieldKind::None => EnumFieldType::None,
                        EnumFieldKind::Int => {
                            let Some(int_kind) = EnumIntKind::from_u8(state.read_u8()?) else {
                                return Err(Error::CorruptFile);
                            };

                            let enum_int_type = match int_kind {
                                EnumIntKind::Int8 => EnumIntType::Int8(state.read_u8()? as i8),
                                EnumIntKind::Int16 => EnumIntType::Int16(state.read_u16()? as i16),
                                EnumIntKind::Int32 => EnumIntType::Int32(state.read_u32()? as i32),
                                EnumIntKind::Int64 => EnumIntType::Int64(state.read_u64()? as i64),

                                EnumIntKind::UInt8 => EnumIntType::UInt8(state.read_u8()?),
                                EnumIntKind::UInt16 => EnumIntType::UInt16(state.read_u16()?),
                                EnumIntKind::UInt32 => EnumIntType::UInt32(state.read_u32()?),
                                EnumIntKind::UInt64 => EnumIntType::UInt64(state.read_u64()?),
                            };

                            EnumFieldType::Int(enum_int_type)
                        }
                        EnumFieldKind::Tuple => {
                            let field_types = read_tuple_field_types(&mut state)?;
                            EnumFieldType::Tuple(field_types)
                        }
                        EnumFieldKind::Struct => {
                            let num_struct_fields = state.read_u16()?;
                            let mut struct_fields = Vec::new();
                            for _ in 0..num_struct_fields {
                                struct_fields.push(read_struct_field(&mut state)?);
                            }
                            EnumFieldType::Struct(struct_fields.into_boxed_slice())
                        }
                    };

                    fields.push(EnumField {
                        name: field_name,
                        field_type,
                    });
                }

                types.push(Type::Enum(Enum {
                    name: type_name,
                    fields: fields.into_boxed_slice(),
                }));
            }
        }
    }

    definitions.push(StoredDefinition {
        hash,
        definition: Definition {
            url,
            version,
            types: types.into_boxed_slice(),
        },
    });

    Ok(())
}

fn read_struct_field(state: &mut ReadState) -> Result<StructField> {
    let field_name = state.read_string()?;
    let field_type = read_field_type(state)?;
    Ok(StructField {
        name: field_name,
        field_type,
    })
}

enum FieldKind {
    Type,
    Optional,
    Reference,
    Array,
    Slice,
    Tuple,
    Primitive,
}

impl FieldKind {
    fn from_u8(v: u8) -> Option<FieldKind> {
        match v {
            0 => Some(FieldKind::Type),
            1 => Some(FieldKind::Optional),
            2 => Some(FieldKind::Reference),
            3 => Some(FieldKind::Array),
            4 => Some(FieldKind::Slice),
            5 => Some(FieldKind::Tuple),
            6 => Some(FieldKind::Primitive),
            _ => None,
        }
    }
}

enum ReferenceKind {
    Object,
    Any,
}

impl ReferenceKind {
    fn from_u8(v: u8) -> Option<ReferenceKind> {
        match v {
            0 => Some(ReferenceKind::Object),
            1 => Some(ReferenceKind::Any),
            _ => None,
        }
    }
}

fn primitive_from_u8(v: u8) -> Option<Primitive> {
    match v {
        0 => Some(Primitive::Int8),
        1 => Some(Primitive::Int16),
        2 => Some(Primitive::Int32),
        3 => Some(Primitive::Int64),

        4 => Some(Primitive::UInt8),
        5 => Some(Primitive::UInt16),
        6 => Some(Primitive::UInt32),
        7 => Some(Primitive::UInt64),

        8 => Some(Primitive::Float32),
        9 => Some(Primitive::Float64),

        10 => Some(Primitive::Boolean),
        11 => Some(Primitive::String),
        _ => None,
    }
}

fn read_field_type(state: &mut ReadState) -> Result<FieldType> {
    let Some(field_kind) = FieldKind::from_u8(state.read_u8()?) else {
        return Err(Error::CorruptFile);
    };

    let field_type = match field_kind {
        FieldKind::Type => {
            let type_idx = state.read_u16()?;
            FieldType::Type(type_idx as usize)
        }
        FieldKind::Optional => {
            let optional_field_type = read_field_type(state)?;
            FieldType::Optional(Box::new(optional_field_type))
        }
        FieldKind::Reference => {
            let Some(reference_kind) = ReferenceKind::from_u8(state.read_u8()?) else {
                return Err(Error::CorruptFile);
            };
            match reference_kind {
                ReferenceKind::Object => {
                    let type_idx = state.read_u16()?;
                    FieldType::Reference(Reference::Object(type_idx as usize))
                }
                ReferenceKind::Any => FieldType::Reference(Reference::Any),
            }
        }
        FieldKind::Array => {
            let element_type = read_field_type(state)?;
            let size = state.read_u64()?;
            FieldType::Array {
                element_type: Box::new(element_type),
                size,
            }
        }
        FieldKind::Slice => {
            let element_type = read_field_type(state)?;
            FieldType::Slice(Box::new(element_type))
        }
        FieldKind::Tuple => {
            let field_types = read_tuple_field_types(state)?;
            FieldType::Tuple(field_types)
        }
        FieldKind::Primitive => {
            let Some(primitive) = primitive_from_u8(state.read_u8()?) else {
                return Err(Error::CorruptFile);
            };
            FieldType::Primitive(primitive)
        }
    };

    Ok(field_type)
}

fn read_tuple_field_types(state: &mut ReadState) -> Result<Box<[FieldType]>> {
    let num_field_types = state.read_u16()?;
    let mut field_types = Vec::with_capacity(num_field_types as usize);
    for _ in 0..num_field_types {
        field_types.push(read_field_type(state)?);
    }
    Ok(field_types.into_boxed_slice())
}
