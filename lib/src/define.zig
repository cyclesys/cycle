const std = @import("std");

const DefKind = enum {
    scheme,
    object,
    function,
    command,
    this,
    ref,
    array,
    list,
    map,
    string,
};

const SchemeFn = fn (comptime anytype) type;

pub fn Scheme(comptime name: []const u8, comptime types: anytype) SchemeFn {
    if (types.len == 0) {
        @compileError("`types` cannot be empty");
    }

    comptime var kind: ?DefKind = null;
    for (types) |Type| {
        if (!@hasDecl(Type, "def_kind")) {
            @compileError("`types` can only contain `Object`, `Function`, or `Command` types");
        }

        switch (Type.def_kind) {
            .object, .function, .command => {},
            else => @compileError("`types` can only contain `Object`, `Function`, or `Command` types"),
        }

        if (kind != null and (Type.def_kind != kind.?)) {
            @compileError("`types` can only types of the same kind " ++
                "(i.e. if it has `Object` types it can only contain `Object` types, etc.)");
        }

        kind = Type.def_kind;
    }

    for (types) |Type| {
        switch (Type.def_kind) {
            .object => checkObject(Type.type_versions, types),
            .function => checkFunction(Type.type_versions),
            .command => checkCommandFieldType(Type.field),
            else => unreachable,
        }
    }

    return struct {
        pub const def_kind = DefKind.scheme;
        pub const scheme_kind = kind.?;
        pub const scheme_name = name;
        pub const scheme_types = types;

        const Self = @This();

        fn get(comptime arg: anytype) type {
            if (@TypeOf(arg) == @TypeOf(This) and arg == This) {
                return Self;
            }

            for (types) |Type| {
                if (std.mem.eql(u8, Type.type_name, arg)) {
                    return struct {
                        pub const def_kind = DefKind.ref;
                        pub const type_def = Type;
                        pub const type_scheme = Self;
                    };
                }
            }

            @compileError(arg ++ " is not defined in this scheme");
        }
    }.get;
}

pub fn Object(
    comptime name: []const u8,
    comptime versions: anytype,
) type {
    return struct {
        pub const def_kind = DefKind.object;
        pub const type_name = name;
        pub const type_versions = versions;
    };
}

pub fn Function(
    comptime name: []const u8,
    comptime versions: anytype,
) type {
    return struct {
        pub const def_kind = DefKind.function;
        pub const type_name = name;
        pub const type_versions = versions;
    };
}

pub fn Command(comptime name: []const u8, comptime Field: type) type {
    return struct {
        pub const def_kind = DefKind.command;
        pub const type_name = name;
        pub const field = Field;
    };
}

pub fn This(comptime name: []const u8) type {
    return struct {
        pub const def_kind = DefKind.this;
        pub const type_name = name;
    };
}

pub fn Array(comptime size: comptime_int, comptime Element: type) type {
    return struct {
        pub const def_kind = DefKind.array;
        pub const array_size = size;
        pub const element = Element;
    };
}

pub fn List(comptime Element: type) type {
    return struct {
        pub const def_kind = DefKind.list;
        pub const element = Element;
    };
}

pub fn Map(comptime Key: type, comptime Value: type) type {
    return struct {
        pub const def_kind = DefKind.map;
        pub const key = Key;
        pub const value = Value;
    };
}

pub const String = struct {
    pub const def_kind = DefKind.string;
};

fn checkObject(comptime versions: anytype, comptime scheme_types: anytype) void {
    for (versions) |Ver| {
        checkFieldType(Ver, scheme_types);
    }
}

fn checkFunction(comptime versions: anytype) void {
    for (versions) |Ver| {
        switch (@typeInfo(Ver)) {
            .Fn => |fn_info| {
                for (fn_info.params) |param_info| {
                    if (param_info.type == null) {
                        @compileError("field type is invalid");
                    }

                    checkFieldType(param_info.type.?, .{});
                }

                checkFieldType(fn_info.return_type.?, .{});
            },
            else => @compileError("`Function` type can only contain `fn` types"),
        }
    }
}

fn checkCommandFieldType(comptime Field: type) void {
    const err = struct {
        fn invoke() void {
            @compileError("invalid `Command` field type");
        }
    };
    switch (@typeInfo(Field)) {
        .Struct => |info| {
            if (@hasDecl(Field, "def_kind")) {
                switch (Field.def_kind) {
                    .array => {
                        checkCommandFieldType(Field.element);
                    },
                    .list => {
                        checkCommandFieldType(Field.element);
                    },
                    .ref => {
                        checkRefType(Field);
                    },
                    else => {
                        err.invoke();
                    },
                }
            } else {
                for (info.fields) |field_info| {
                    checkCommandFieldType(field_info.type);
                }
            }
        },
        .Union => |info| {
            if (info.tag_type == null) {
                err.invoke();
            }

            for (info.fields) |field_info| {
                checkCommandFieldType(field_info.type);
            }
        },
        else => err.invoke(),
    }
}

fn checkFieldType(
    comptime Field: type,
    comptime scheme_types: anytype,
) void {
    switch (@typeInfo(Field)) {
        .Type => @compileError("field type cannot be type."),
        .NoReturn => @compileError("field type cannot be noreturn"),
        .Pointer => @compileError("field type cannot be pointer"),
        .Array => @compileError("field type cannot be native array, use `Array` type instead."),
        .ComptimeFloat => @compileError("field type cannot be comptime_float"),
        .ComptimeInt => @compileError("field type cannot be comptime_int"),
        .Undefined => @compileError("field type cannot be undefined"),
        .Null => @compileError("field type cannot be null"),
        .ErrorUnion => @compileError("field type cannot be error union"),
        .ErrorSet => @compileError("field type cannot be error set"),
        .Fn => @compileError("field type cannot be fn"),
        .Opaque => @compileError("field type cannot be opaque"),
        .Frame => @compileError("field type cannot be frame"),
        .AnyFrame => @compileError("field type cannot be anyframe"),
        .Vector => @compileError("field type cannot be vector"),
        .EnumLiteral => @compileError("field type cannot be enum literal"),
        .Void, .Bool, .Int, .Float, .Enum => {
            // these types are valid
        },
        .Optional => |info| {
            checkFieldType(info.child, scheme_types);
        },
        .Struct => |info| {
            if (@hasDecl(Field, "def_kind")) {
                switch (Field.def_kind) {
                    .scheme => @compileError("field type cannot be `Scheme` type"),
                    .object => @compileError("field type cannot be `Object` type"),
                    .function => @compileError("field type cannot be `Function` type"),
                    .command => @compileError("field type cannot be `Command` type"),
                    .this => {
                        if (scheme_types.len == 0) {
                            @compileError("field type cannot be `This` type");
                        }

                        for (scheme_types) |T| {
                            if (std.mem.eql(u8, T.type_name, Field.type_name)) {
                                break;
                            }
                        } else {
                            @compileError(Field.type_name ++ " is not defined in the scheme referenced by `This`.");
                        }
                    },
                    .ref => {
                        checkRefType(Field);
                    },
                    .array => {
                        checkFieldType(Field.element, scheme_types);
                    },
                    .list => {
                        checkFieldType(Field.element, scheme_types);
                    },
                    .map => {
                        checkFieldType(Field.key, scheme_types);
                        checkFieldType(Field.value, scheme_types);
                    },
                    .string => {
                        // valid
                    },
                }
            } else {
                for (info.fields) |field_info| {
                    if (field_info.is_comptime) {
                        @compileError("struct fields cannot be comptime.");
                    }

                    checkFieldType(field_info.type, scheme_types);
                }
            }
        },
        .Union => |info| {
            for (info.fields) |field_info| {
                checkFieldType(field_info.type, scheme_types);
            }
        },
    }
}

fn checkRefType(comptime Ref: type) void {
    switch (Ref.type_def.def_kind) {
        .object => {
            // valid
        },
        .function => {
            @compileError("field type cannot be `Function` ref type");
        },
        .command => {
            @compileError("field type cannot be `Command` ref type");
        },
        else => unreachable,
    }
}
