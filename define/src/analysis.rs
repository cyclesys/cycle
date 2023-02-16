use std::collections::HashMap;
use syn::{Error, Result};

use crate::parse::{
    Enum, EnumField, EnumFieldValue, Struct, StructField, Type, Version, VersionItem,
};

pub struct Module {
    types: Vec<TypeIndex>,
}

#[derive(Clone)]
pub struct TypeIndex {
    index: usize,
    fields: Vec<FieldIndex>,
}

#[derive(Clone)]
pub enum FieldIndex {
    Index(usize),
    // Used for Enum types with a struct field
    EnumStruct(usize, Vec<usize>),
}

impl Module {
    #[inline]
    fn new() -> Self {
        Self { types: Vec::new() }
    }
}

impl TypeIndex {
    #[inline]
    fn new(index: usize) -> Self {
        Self {
            index,
            fields: Vec::new(),
        }
    }
}

pub struct Analyzer<'a> {
    type_defs: &'a [Type],
    modules: Vec<Module>,
    current: Vec<TypeIndex>,
}

impl<'a> Analyzer<'a> {
    pub fn run(type_defs: &'a [Type]) -> Result<Vec<Module>> {
        let mut analyzer = Self {
            type_defs,
            modules: Vec::new(),
            current: Vec::new(),
        };
        analyzer.run_self()?;
        Ok(analyzer.modules)
    }

    fn run_self(&mut self) -> Result<()> {
        for type_index in 0..self.type_defs.len() {
            let type_def = &self.type_defs[type_index];
            match type_def {
                Type::Node(node_def) => {
                    self.add_struct(type_index, node_def)?;
                }
                Type::Struct(struct_def) => {
                    self.add_struct(type_index, struct_def)?;
                }
                Type::Enum(enum_def) => {
                    self.add_enum(type_index, enum_def)?;
                }
            }
        }

        Ok(())
    }

    fn add_struct(&mut self, struct_index: usize, struct_def: &Struct) -> Result<()> {
        let (struct_add, struct_rem) = self.add_type(struct_index, struct_def.version.as_ref())?;
        for field_index in 0..struct_def.fields.len() {
            let field_def = &struct_def.fields[field_index];
            self.add_field(
                field_index,
                field_def.version.as_ref(),
                (struct_add, struct_rem),
                false,
            )?;
        }
        Ok(())
    }

    fn add_enum(&mut self, enum_index: usize, enum_def: &Enum) -> Result<()> {
        let (enum_add, enum_rem) = self.add_type(enum_index, enum_def.version.as_ref())?;

        #[derive(PartialEq, Eq)]
        enum Variant {
            StructOrTuple,
            Int,
            None,
        }
        let mut variant = Variant::None;
        let mut check_variant = |new_variant, span| {
            if variant == Variant::None {
                variant = new_variant;
            } else if variant != new_variant {
                return Err(Error::new(
                    span,
                    "Enums cannot have variants with both integer values, and tuple or struct values",
                ));
            }

            Ok(())
        };

        for field_index in 0..enum_def.fields.len() {
            let field_def = &enum_def.fields[field_index];

            if let EnumFieldValue::Struct(ref struct_fields) = field_def.value {
                check_variant(Variant::StructOrTuple, field_def.name_span)?;
                let (field_add, field_rem) = self.add_field(
                    field_index,
                    field_def.version.as_ref(),
                    (enum_add, enum_rem),
                    true,
                )?;

                for struct_field_index in 0..struct_fields.len() {
                    let struct_field_def = &struct_fields[struct_field_index];
                    let (struct_field_add, struct_field_rem) = Self::check_version(
                        struct_field_def.version.as_ref(),
                        Some((field_add, field_rem)),
                    )?;

                    let begin = (struct_field_add - 1) as usize;
                    let end = match struct_field_rem {
                        Some(struct_field_rem) => {
                            while self.modules.len() < (struct_field_rem as usize) {
                                self.push_new_module();
                            }
                            (struct_field_rem - 1) as usize
                        }
                        None => {
                            let field_index =
                                self.current.last_mut().unwrap().fields.last_mut().unwrap();
                            let FieldIndex::EnumStruct(_, struct_field_indices) = field_index else {
                                unreachable!();
                            };
                            struct_field_indices.push(struct_field_index);

                            while self.modules.len() < (struct_field_add as usize) {
                                self.push_new_module();
                            }

                            self.modules.len()
                        }
                    };

                    for i in begin..end {
                        let field_index = self.modules[i]
                            .types
                            .last_mut()
                            .unwrap()
                            .fields
                            .last_mut()
                            .unwrap();

                        let FieldIndex::EnumStruct(_, ref mut indices) = field_index else {
                            unreachable!();
                        };

                        indices.push(struct_field_index);
                    }
                }
            } else {
                match field_def.value {
                    EnumFieldValue::Int { num_span, .. } => {
                        check_variant(Variant::Int, num_span)?;
                    }
                    EnumFieldValue::Tuple(_) => {
                        check_variant(Variant::StructOrTuple, field_def.name_span)?;
                    }
                    _ => {}
                }

                self.add_field(
                    field_index,
                    field_def.version.as_ref(),
                    (enum_add, enum_rem),
                    false,
                )?;
            }
        }

        Ok(())
    }

    fn add_type(&mut self, index: usize, version: Option<&Version>) -> Result<(u32, Option<u32>)> {
        let (add, rem) = Self::check_version(version, None)?;
        let begin = (add - 1) as usize;
        let end = match rem {
            Some(rem) => {
                while self.modules.len() < (rem as usize) {
                    self.push_new_module();
                }
                (rem - 1) as usize
            }
            None => {
                self.current.push(TypeIndex::new(index));
                while self.modules.len() < (add as usize) {
                    self.push_new_module();
                }
                self.modules.len()
            }
        };

        for i in begin..end {
            self.modules[i].types.push(TypeIndex::new(index));
        }

        Ok((add, rem))
    }

    fn add_field(
        &mut self,
        field_index: usize,
        field_version: Option<&Version>,
        type_version: (u32, Option<u32>),
        is_enum_struct_field: bool,
    ) -> Result<(u32, Option<u32>)> {
        let new_field_index = || {
            if is_enum_struct_field {
                FieldIndex::EnumStruct(field_index, Vec::new())
            } else {
                FieldIndex::Index(field_index)
            }
        };

        let (add, rem) = Self::check_version(field_version, Some(type_version))?;

        let begin = (add - 1) as usize;
        let end = match rem {
            Some(rem) => {
                while self.modules.len() < (rem as usize) {
                    self.push_new_module();
                }
                (rem - 1) as usize
            }
            None => {
                self.current
                    .last_mut()
                    .unwrap()
                    .fields
                    .push(new_field_index());

                while self.modules.len() < (add as usize) {
                    self.push_new_module();
                }

                self.modules.len()
            }
        };

        for i in begin..end {
            self.modules[i]
                .types
                .last_mut()
                .unwrap()
                .fields
                .push(new_field_index());
        }

        Ok((add, rem))
    }

    fn push_new_module(&mut self) {
        self.modules.push(Module::new());
        let module = self.modules.last_mut().unwrap();
        for type_index in &self.current {
            module.types.push(type_index.clone());
        }
    }

    fn check_version(
        version: Option<&Version>,
        container_version: Option<(u32, Option<u32>)>,
    ) -> Result<(u32, Option<u32>)> {
        #[inline]
        fn ensure_rem_greater_than_add(added: u32, removed: &VersionItem) -> Result<()> {
            if removed.num <= added {
                Err(Error::new(
                    removed.num_span,
                    "rem value is less than or equal to the add value",
                ))
            } else {
                Ok(())
            }
        }

        match version {
            Some(version) => match container_version {
                Some(container_version) => {
                    let added = match version.added {
                        Some(ref added) => {
                            if added.num < container_version.0 {
                                return Err(Error::new(
                                    added.num_span,
                                    "add value is less than the container type's add value",
                                ));
                            }

                            if let Some(container_removed) = container_version.1 {
                                if added.num >= container_removed {
                                    return Err(Error::new(
                                        added.num_span,
                                        "add value is greater than or equal to the container type's rem value",
                                    ));
                                }
                            }

                            added.num
                        }
                        None => container_version.0,
                    };

                    let removed = match version.removed {
                        Some(ref removed) => {
                            ensure_rem_greater_than_add(added, removed)?;

                            if removed.num <= container_version.0 {
                                return Err(Error::new(
                                    removed.num_span,
                                    "rem value is less than or equal to the container type's add value",
                                ));
                            }

                            if let Some(container_removed) = container_version.1 {
                                if removed.num > container_removed {
                                    return Err(Error::new(
                                        removed.num_span,
                                        "rem value is greater than the container type's rem value",
                                    ));
                                }
                            }

                            Some(removed.num)
                        }
                        None => container_version.1,
                    };

                    Ok((added, removed))
                }
                None => {
                    let added = match version.added {
                        Some(ref added) => added.num,
                        None => 1,
                    };
                    let removed = match version.removed {
                        Some(ref removed) => {
                            ensure_rem_greater_than_add(added, removed)?;
                            Some(removed.num)
                        }
                        None => None,
                    };
                    Ok((added, removed))
                }
            },
            None => match container_version {
                Some(container_version) => Ok(container_version),
                None => Ok((1, None)),
            },
        }
    }
}
