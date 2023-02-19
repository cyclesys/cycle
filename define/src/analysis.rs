use proc_macro2::Span;
use std::collections::HashMap;
use syn::{Error, Result};

use crate::parse::{
    Enum, EnumField, EnumFieldValue, Primitive, Struct, StructField, Type, Value, ValueType,
    Version, VersionItem,
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

            Self::check_name_repeat(type_index, |index| match &self.type_defs[index] {
                Type::Node(node_def) => (
                    node_def.version.as_ref(),
                    &node_def.name,
                    &node_def.name_span,
                ),
                Type::Struct(struct_def) => (
                    struct_def.version.as_ref(),
                    &struct_def.name,
                    &struct_def.name_span,
                ),
                Type::Enum(enum_def) => (
                    enum_def.version.as_ref(),
                    &enum_def.name,
                    &enum_def.name_span,
                ),
            })?;
        }

        self.check_modules()?;

        Ok(())
    }

    fn add_struct(&mut self, struct_index: usize, struct_def: &'a Struct) -> Result<()> {
        let (struct_add, struct_rem) = self.add_type(struct_index, struct_def.version.as_ref())?;
        for field_index in 0..struct_def.fields.len() {
            let field_def = &struct_def.fields[field_index];
            self.add_field(
                field_index,
                field_def.version.as_ref(),
                (struct_add, struct_rem),
                false,
            )?;

            Self::check_name_repeat(field_index, |index| {
                let field_def = &struct_def.fields[index];
                (
                    field_def.version.as_ref(),
                    &field_def.name,
                    &field_def.name_span,
                )
            })?;
        }
        Ok(())
    }

    fn add_enum(&mut self, enum_index: usize, enum_def: &'a Enum) -> Result<()> {
        let (enum_add, enum_rem) = self.add_type(enum_index, enum_def.version.as_ref())?;

        #[derive(PartialEq, Eq)]
        enum Variant {
            StructOrTuple,
            Int,
            None,
        }
        let mut variant = Variant::None;

        for field_index in 0..enum_def.fields.len() {
            let field_def = &enum_def.fields[field_index];

            let mut check_variant = |new_variant| {
                if variant == Variant::None {
                    variant = new_variant;
                } else if variant != new_variant {
                    return Err(Error::new(
                        field_def.name_span,
                        "Enums cannot have variants with both integer values, and tuple or struct values",
                    ));
                }

                Ok(())
            };

            let mut add_field = |is_struct_field| -> Result<(u32, Option<u32>)> {
                let (field_add, field_rem) = self.add_field(
                    field_index,
                    field_def.version.as_ref(),
                    (enum_add, enum_rem),
                    is_struct_field,
                )?;
                Self::check_name_repeat(field_index, |index| {
                    let field_def = &enum_def.fields[index];
                    (
                        field_def.version.as_ref(),
                        &field_def.name,
                        &field_def.name_span,
                    )
                })?;
                Ok((field_add, field_rem))
            };

            match field_def.value {
                EnumFieldValue::Struct(ref struct_fields) => {
                    check_variant(Variant::StructOrTuple)?;
                    let (field_add, field_rem) = add_field(true)?;
                    for struct_field_index in 0..struct_fields.len() {
                        let struct_field_def = &struct_fields[struct_field_index];
                        let (struct_field_add, struct_field_rem) = Self::check_version(
                            struct_field_def.version.as_ref(),
                            Some((field_add, field_rem)),
                        )?;
                        Self::check_name_repeat(struct_field_index, |index| {
                            let struct_field_def = &struct_fields[index];
                            (
                                struct_field_def.version.as_ref(),
                                &struct_field_def.name,
                                &struct_field_def.name_span,
                            )
                        })?;

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
                }
                EnumFieldValue::Int { .. } => {
                    check_variant(Variant::Int)?;
                    add_field(false)?;
                }
                EnumFieldValue::Tuple(_) => {
                    check_variant(Variant::StructOrTuple)?;
                    add_field(false)?;
                }
                EnumFieldValue::None => {
                    add_field(false)?;
                }
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
                while self.modules.len() < (add as usize) {
                    self.push_new_module();
                }
                self.current.push(TypeIndex::new(index));
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
                while self.modules.len() < (add as usize) {
                    self.push_new_module();
                }

                self.current
                    .last_mut()
                    .unwrap()
                    .fields
                    .push(new_field_index());

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
                            if added.num < 1 {
                                return Err(Error::new(
                                    added.num_span,
                                    "add value must be at least 1",
                                ));
                            }

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
                            if removed.num < 2 {
                                return Err(Error::new(
                                    removed.num_span,
                                    "rem value must be at least 2",
                                ));
                            }

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

    fn check_name_repeat(
        item_index: usize,
        item_at: impl Fn(usize) -> (Option<&'a Version>, &'a String, &'a Span),
    ) -> Result<()> {
        let (item_ver, item_name, item_name_span) = item_at(item_index);
        for i in 0..item_index {
            let (prev_item_ver, prev_item_name, _) = item_at(i);
            if prev_item_name == item_name {
                Self::check_version_overlap(prev_item_ver, item_ver, item_name_span)?;
            }
        }
        Ok(())
    }

    fn check_version_overlap(
        left: Option<&Version>,
        right: Option<&Version>,
        name_span: &Span,
    ) -> Result<()> {
        let error = || {
            Err(Error::new(
                *name_span,
                "Item overlaps with a previously defined item. Items that share the same name must exist in different versions",
            ))
        };

        if left.is_none() || right.is_none() {
            return error();
        }

        let left = left.unwrap();
        let right = right.unwrap();

        let check_version_overlap_inner = |added_first: &Version, added_after: &VersionItem| {
            match added_first.removed.as_ref() {
                Some(added_first_removed) => {
                    if added_after.num < added_first_removed.num {
                        return error();
                    }
                }
                None => {
                    return error();
                }
            }
            Ok(())
        };

        match left.added.as_ref() {
            Some(left_added) => match right.added.as_ref() {
                Some(right_added) => {
                    if left_added.num < right_added.num {
                        check_version_overlap_inner(left, right_added)?;
                    } else if right_added.num < left_added.num {
                        check_version_overlap_inner(right, left_added)?;
                    } else {
                        return error();
                    }
                }
                None => {
                    if left_added.num == 1 {
                        return error();
                    }
                    check_version_overlap_inner(right, left_added)?;
                }
            },
            None => match right.added.as_ref() {
                Some(right_added) => {
                    if right_added.num == 1 {
                        return error();
                    }
                    check_version_overlap_inner(left, right_added)?;
                }
                None => {
                    return error();
                }
            },
        }

        Ok(())
    }

    fn check_modules(&self) -> Result<()> {
        enum TypeNameState<'a> {
            Found {
                is_node: bool,
            },
            Used {
                name_span: &'a Span,
                expects_node: bool,
            },
        }
        struct CheckModuleState<'a> {
            type_names: HashMap<&'a str, TypeNameState<'a>>,
        }
        impl<'a> CheckModuleState<'a> {
            fn check_name_found(&mut self, name: &'a str, is_node: bool) -> Result<()> {
                if let Some(old_state) = self
                    .type_names
                    .insert(name, TypeNameState::Found { is_node })
                {
                    let TypeNameState::Used { name_span, expects_node } = old_state else {
                        unreachable!();
                    };

                    if is_node && !expects_node {
                        return Err(Error::new(
                            *name_span,
                            "node types must be enclosed by a ref type",
                        ));
                    }
                }
                Ok(())
            }

            fn check_name_used(
                &mut self,
                name: &'a str,
                name_span: &'a Span,
                expects_node: bool,
            ) -> Result<()> {
                if let Some(old_state) = self.type_names.get_mut(name) {
                    match old_state {
                        TypeNameState::Found { is_node } => {
                            if expects_node && !*is_node {
                                return Err(Error::new(
                                    *name_span,
                                    "only node types may be enclosed by a ref type",
                                ));
                            }
                        }
                        TypeNameState::Used { .. } => {
                            *old_state = TypeNameState::Used {
                                name_span,
                                expects_node,
                            };
                        }
                    }
                } else {
                    self.type_names.insert(
                        name,
                        TypeNameState::Used {
                            name_span,
                            expects_node,
                        },
                    );
                }
                Ok(())
            }

            fn check_struct_fields(
                &mut self,
                struct_index: &TypeIndex,
                struct_def: &'a Struct,
            ) -> Result<()> {
                for field_index in &struct_index.fields {
                    let FieldIndex::Index(field_index) = field_index else {
                        unreachable!();
                    };
                    let field_def = &struct_def.fields[*field_index];
                    self.check_value(&field_def.value, false)?;
                }

                Ok(())
            }

            fn check_enum_fields(
                &mut self,
                enum_index: &TypeIndex,
                enum_def: &'a Enum,
            ) -> Result<()> {
                struct EnumIntState {
                    last: u32,
                    increment: u32,
                }
                let mut enum_int_state: Option<EnumIntState> = None;

                for field_index in &enum_index.fields {
                    match field_index {
                        FieldIndex::Index(field_index) => {
                            let field_def = &enum_def.fields[*field_index];
                            match &field_def.value {
                                EnumFieldValue::Int { num_span, num } => {
                                    if let Some(state) = enum_int_state.as_mut() {
                                        if *num <= state.last + state.increment {
                                            return Err(Error::new(
                                                *num_span,
                                                "Enum discriminant must be greater than the last discriminant value + any increment values",
                                            ));
                                        }
                                    }
                                    enum_int_state = Some(EnumIntState {
                                        last: *num,
                                        increment: 0,
                                    });
                                }
                                EnumFieldValue::Tuple(values) => {
                                    for value in values {
                                        self.check_value(value, false)?;
                                    }
                                }
                                EnumFieldValue::None => {
                                    if let Some(state) = enum_int_state.as_mut() {
                                        state.increment += 1;
                                    }
                                }
                                EnumFieldValue::Struct(_) => {
                                    unreachable!();
                                }
                            }
                        }
                        FieldIndex::EnumStruct(field_index, struct_field_indices) => {
                            let field_def = &enum_def.fields[*field_index];
                            let EnumFieldValue::Struct(struct_fields) = &field_def.value else {
                                unreachable!();
                            };

                            for struct_field_index in struct_field_indices {
                                let struct_field_def = &struct_fields[*struct_field_index];
                                self.check_value(&struct_field_def.value, false)?;
                            }
                        }
                    }
                }
                Ok(())
            }

            fn check_value(&mut self, value: &'a Value, expects_node: bool) -> Result<()> {
                if expects_node {
                    let error = || Err(Error::new(value.span, "expected node type"));
                    match &value.value_type {
                        ValueType::Composite(name) => {
                            self.check_name_used(name.as_str(), &value.span, true)?;
                        }
                        ValueType::Primitive(primitive) => {
                            if *primitive != Primitive::Any {
                                return error();
                            }
                        }
                        _ => {
                            return error();
                        }
                    }
                } else {
                    match &value.value_type {
                        ValueType::Composite(name) => {
                            self.check_name_used(name.as_str(), &value.span, false)?;
                        }
                        ValueType::Optional(value) => {
                            self.check_value(value.as_ref(), false)?;
                        }
                        ValueType::Reference(value) => {
                            self.check_value(value.as_ref(), true)?;
                        }
                        ValueType::Array(value, _) => {
                            self.check_value(value.as_ref(), false)?;
                        }
                        ValueType::Slice(value) => {
                            self.check_value(value.as_ref(), false)?;
                        }
                        ValueType::Tuple(values) => {
                            for value in values {
                                self.check_value(value, false)?;
                            }
                        }
                        ValueType::Primitive(primitive) => {
                            if *primitive == Primitive::Any {
                                return Err(Error::new(
                                    value.span,
                                    "any types must be enclosed by a ref type",
                                ));
                            }
                        }
                    }
                }
                Ok(())
            }
        }
        let mut state = CheckModuleState::<'a> {
            type_names: HashMap::new(),
        };

        for mi in 0..self.modules.len() {
            let module = &self.modules[mi];
            if module.types.is_empty() {
                return Err(Error::new(
                    Span::call_site(),
                    format!("version {} is empty", mi + 1),
                ));
            }

            for ti in 0..module.types.len() {
                let type_index = &module.types[ti];

                match &self.type_defs[type_index.index] {
                    Type::Node(node_def) => {
                        state.check_name_found(node_def.name.as_str(), true)?;
                        state.check_struct_fields(type_index, node_def)?;
                    }
                    Type::Struct(struct_def) => {
                        state.check_name_found(struct_def.name.as_str(), false)?;
                        state.check_struct_fields(type_index, struct_def)?;
                    }
                    Type::Enum(enum_def) => {
                        state.check_name_found(enum_def.name.as_str(), false)?;
                        state.check_enum_fields(type_index, enum_def)?;
                    }
                }
            }

            for type_name_state in state.type_names.values() {
                if let TypeNameState::Used { name_span, .. } = *type_name_state {
                    return Err(Error::new(
                        *name_span,
                        format!("type does not exist in version {}", mi + 1),
                    ));
                }
            }
            state.type_names.clear();
        }

        Ok(())
    }
}
