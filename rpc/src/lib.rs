use cycle_proto::rpc::{
    store_client::StoreClient, AuthRequest, AuthResponse, GetObjectRequest, GetRootIdsRequest,
    GetTypeRequest, ObjectId as ProtoObjectId,
};
use std::{ffi::c_void, mem::MaybeUninit};
use tokio::runtime::Runtime;
use tonic::{transport::Channel, Code};

#[repr(C)]
struct Slice<T> {
    ptr: *mut T,
    len: usize,
}

impl Slice<u8> {
    fn as_string(&self) -> String {
        let slice = unsafe { std::slice::from_raw_parts(self.ptr, self.len) };
        let string = unsafe { std::str::from_utf8_unchecked(slice) };
        string.to_string()
    }
}

impl<T: Sized> Slice<T> {
    fn copy(&self, values: &[T]) {
        assert!(self.len == values.len());
        unsafe {
            std::ptr::copy(values.as_ptr(), self.ptr, self.len);
        }
    }
}

#[repr(C)]
struct Optional<T> {
    has_value: bool,
    value: MaybeUninit<T>,
}

impl<T> Optional<T> {
    fn some(value: T) -> Self {
        Optional {
            has_value: true,
            value: MaybeUninit::new(value),
        }
    }

    fn none() -> Self {
        Optional {
            has_value: false,
            value: MaybeUninit::uninit(),
        }
    }
}

#[repr(C)]
struct ObjectId {
    user_id: i64,
    obj_id: i64,
}

type TypeHash = [u8; 32];

#[repr(C)]
struct RootIds {
    user_id: i64,
    ids: Slice<i64>,
}

#[repr(C)]
struct Object {
    typ: *const TypeHash,
    data: Slice<u8>,
}

#[repr(C)]
struct Type {
    data: Slice<u8>,
}

#[repr(C)]
enum Error {
    Unknown,
    Unauthenticated,
    Unauthorized,
}

#[repr(C)]
struct ResultCallback<T> {
    ctx: *mut c_void,
    on_ok: extern "C" fn(ctx: *mut c_void, new_token: Optional<Slice<u8>>, data: T),
    on_err: extern "C" fn(ctx: *mut c_void, e: Error),
}

unsafe impl<T> Send for ResultCallback<T> {}

impl<T> ResultCallback<T> {
    fn ok(&self, new_token: Optional<Slice<u8>>, data: T) {
        (self.on_ok)(self.ctx, new_token, data);
    }

    fn err(&self, e: Error) {
        (self.on_err)(self.ctx, e);
    }
}

type Client = StoreClient<Channel>;

#[repr(C)]
#[derive(Clone, Copy)]
struct Allocator {
    raw_alloc: extern "C" fn(len: usize, alignment: usize) -> Slice<u8>,
}

impl Allocator {
    fn alloc<T: Sized>(self, count: usize) -> Slice<T> {
        let len = std::mem::size_of::<T>() * count;
        let alignment = std::mem::align_of::<T>();
        let bytes = (self.raw_alloc)(len, alignment);
        Slice {
            ptr: bytes.ptr as *mut T,
            len: count,
        }
    }
}

struct Context {
    runtime: Runtime,
    client: Client,
    allocator: Allocator,
}

#[no_mangle]
extern "C" fn cycle_rpc_init(allocator: Allocator, url: Slice<u8>) -> *mut Context {
    let url = unsafe { std::str::from_utf8(std::slice::from_raw_parts(url.ptr, url.len)).unwrap() };

    let channel = Channel::from_static(url).connect_lazy();

    let context = Box::new(Context {
        allocator,
        runtime: Runtime::new().unwrap(),
        client: StoreClient::new(channel),
    });
    Box::into_raw(context)
}

#[no_mangle]
extern "C" fn cycle_rpc_get_rood_ids(
    ctx: *mut Context,
    token: Slice<u8>,
    callback: ResultCallback<RootIds>,
) {
    let ctx = unsafe { &mut *ctx };
    let mut client = ctx.client.clone();
    let allocator = ctx.allocator;
    let token = token.as_string();
    ctx.runtime.spawn(async move {
        let result = client
            .get_root_ids(GetRootIdsRequest {
                auth: Some(AuthRequest { token }),
            })
            .await;

        if let Err(status) = result {
            callback.err(match status.code() {
                Code::Unauthenticated => Error::Unauthenticated,
                _ => Error::Unknown,
            });
            return;
        }

        let response = result.unwrap();
        let response = response.get_ref();
        let new_token = handle_auth_response(&response.auth, allocator);

        let ids = allocator.alloc::<i64>(response.ids.len());
        ids.copy(response.ids.as_slice());

        callback.ok(
            new_token,
            RootIds {
                user_id: response.main_id,
                ids,
            },
        );
    });
}

#[no_mangle]
extern "C" fn cycle_rpc_get_object(
    ctx: *mut Context,
    token: Slice<u8>,
    id: ObjectId,
    callback: ResultCallback<Object>,
) {
    let ctx = unsafe { &mut *ctx };
    let mut client = ctx.client.clone();
    let allocator = ctx.allocator;
    let token = token.as_string();
    ctx.runtime.spawn(async move {
        let result = client
            .get_object(GetObjectRequest {
                auth: Some(AuthRequest { token }),
                id: Some(ProtoObjectId {
                    user_id: id.user_id,
                    obj_id: id.obj_id,
                }),
            })
            .await;

        if let Err(status) = result {
            callback.err(match status.code() {
                Code::Unauthenticated => Error::Unauthenticated,
                _ => Error::Unknown,
            });
            return;
        }

        let response = result.unwrap();
        let response = response.get_ref();

        let new_token = handle_auth_response(&response.auth, allocator);

        if response.r#type.len() != 32 {
            callback.err(Error::Unknown);
            return;
        }

        let data = allocator.alloc::<u8>(response.data.len());
        data.copy(response.data.as_slice());

        callback.ok(
            new_token,
            Object {
                typ: response.r#type.as_ptr() as *const [u8; 32],
                data,
            },
        );
    });
}

#[no_mangle]
extern "C" fn cycle_rpc_get_type(
    ctx: *mut Context,
    token: Slice<u8>,
    hash: *const TypeHash,
    callback: ResultCallback<Type>,
) {
    let ctx = unsafe { &mut *ctx };
    let mut client = ctx.client.clone();
    let allocator = ctx.allocator;
    let token = token.as_string();
    let hash = Vec::from(unsafe { *hash });
    ctx.runtime.spawn(async move {
        let result = client
            .get_type(GetTypeRequest {
                auth: Some(AuthRequest { token }),
                hash,
            })
            .await;

        if let Err(status) = result {
            callback.err(match status.code() {
                Code::Unauthenticated => Error::Unauthenticated,
                _ => Error::Unknown,
            });
            return;
        }

        let response = result.unwrap();
        let response = response.get_ref();

        let new_token = handle_auth_response(&response.auth, allocator);

        let data = allocator.alloc::<u8>(response.data.len());
        data.copy(response.data.as_slice());

        callback.ok(new_token, Type { data });
    });
}

fn handle_auth_response(auth: &Option<AuthResponse>, allocator: Allocator) -> Optional<Slice<u8>> {
    match auth {
        Some(ref auth) => match auth.new_token {
            Some(ref new_token) => {
                let slice = allocator.alloc::<u8>(new_token.len());
                slice.copy(new_token.as_bytes());
                Optional::some(slice)
            }
            None => Optional::none(),
        },
        None => Optional::none(),
    }
}
