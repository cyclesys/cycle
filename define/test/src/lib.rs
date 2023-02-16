#[test]
fn define_test() {
    cyder_define::define! {
        struct Struct {
            #[rem(2)]
            signed_int8: i8,

            signed_int16: i16,
            signed_int32: i32,
            signed_int64: i64,

            unsigned_int8: u8,
            unsigned_int16: u16,
            unsigned_int32: u32,
            unsigned_int64: u64,

            #[rem(2)]
            signed_unsigned: i8,
            #[add(2)]
            signed_unsigned: u8,

            float32: f32,
            float64: f64,

            boolean: bool,
            string: str,
            optional: opt<str>,

            array: [bool; 10],
            slice: [u8],
            tuple: (str, bool),

            #[add(3)]
            new_signed_int8: i8,
        }

        enum Enum {
            Kind1,
            Kind2,

            #[add(2)]
            Kind3,
        }

        enum ValEnum {
            #[rem(2)]
            Val1 = 100,
            #[add(2), rem(3)]
            Val1 = 200,
            #[add(3)]
            Val1 = 300,

            #[rem(2)]
            Val2,

            Val3,

            #[add(2)]
            Val2,

            #[add(3)]
            Val4,
        }

        enum TagEnum {
            Tag1 {
                #[rem(2)]
                f1: bool,

                #[add(2)]
                f2: str,
            },
            Tag2(u8, u8),
        }

        node Child {
            f1: Struct,
            f2: ValEnum,
            f3: TagEnum,
        }

        node Parent {
            child: ref<Child>,
            children: [ref<Child>],
            parents: [ref<Parent>; 2],
            any_parents: [ref<any>],
        }

        #[add(2)]
        struct StructTwo {
            f1: Struct,
        }

        #[add(2), rem(3)]
        struct AddedV2RemovedV3 {
            f1: u8,
        }
    }
}
