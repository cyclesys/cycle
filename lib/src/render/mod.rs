use std::{
    ffi::c_void,
    mem::{self, MaybeUninit},
    ptr, slice,
};

use windows::{
    core::{s, Interface, ManuallyDrop, Result},
    Win32::{
        Foundation::{HANDLE, HWND, RECT},
        Graphics::{
            Direct3D::{
                Fxc::D3DCompile, ID3DBlob, D3D_FEATURE_LEVEL_12_0,
                D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST,
            },
            Direct3D12::{
                D3D12CreateDevice, D3D12GetDebugInterface, D3D12SerializeRootSignature,
                ID3D12CommandAllocator, ID3D12CommandQueue, ID3D12Debug1, ID3D12DescriptorHeap,
                ID3D12Device2, ID3D12Fence, ID3D12GraphicsCommandList, ID3D12PipelineState,
                ID3D12Resource2, ID3D12RootSignature, D3D12_BLEND_DESC, D3D12_BLEND_ONE,
                D3D12_BLEND_OP_ADD, D3D12_BLEND_ZERO, D3D12_COLOR_WRITE_ENABLE_ALL,
                D3D12_COMMAND_LIST_TYPE_DIRECT, D3D12_COMMAND_QUEUE_DESC,
                D3D12_CPU_DESCRIPTOR_HANDLE, D3D12_CULL_MODE_NONE, D3D12_DEPTH_STENCIL_DESC,
                D3D12_DESCRIPTOR_HEAP_DESC, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, D3D12_FENCE_FLAG_NONE,
                D3D12_FILL_MODE_SOLID, D3D12_GRAPHICS_PIPELINE_STATE_DESC, D3D12_HEAP_FLAG_NONE,
                D3D12_HEAP_PROPERTIES, D3D12_HEAP_TYPE_UPLOAD,
                D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, D3D12_INPUT_ELEMENT_DESC,
                D3D12_INPUT_LAYOUT_DESC, D3D12_LOGIC_OP_NOOP, D3D12_MAX_DEPTH, D3D12_MIN_DEPTH,
                D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE, D3D12_RASTERIZER_DESC,
                D3D12_RENDER_TARGET_BLEND_DESC, D3D12_RESOURCE_BARRIER, D3D12_RESOURCE_BARRIER_0,
                D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES, D3D12_RESOURCE_BARRIER_FLAG_NONE,
                D3D12_RESOURCE_BARRIER_TYPE_TRANSITION, D3D12_RESOURCE_DESC,
                D3D12_RESOURCE_DIMENSION_BUFFER, D3D12_RESOURCE_STATE_GENERIC_READ,
                D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_RENDER_TARGET,
                D3D12_RESOURCE_TRANSITION_BARRIER, D3D12_ROOT_SIGNATURE_DESC,
                D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT,
                D3D12_SHADER_BYTECODE, D3D12_TEXTURE_LAYOUT_ROW_MAJOR, D3D12_VERTEX_BUFFER_VIEW,
                D3D12_VIEWPORT, D3D_ROOT_SIGNATURE_VERSION_1,
            },
            Dxgi::{
                Common::{
                    DXGI_FORMAT, DXGI_FORMAT_R32G32B32A32_FLOAT, DXGI_FORMAT_R32G32B32_FLOAT,
                    DXGI_FORMAT_R8G8B8A8_UNORM, DXGI_SAMPLE_DESC,
                },
                CreateDXGIFactory2, IDXGIAdapter2, IDXGIFactory2, IDXGISwapChain3,
                DXGI_ADAPTER_DESC1, DXGI_CREATE_FACTORY_DEBUG, DXGI_MWA_NO_ALT_ENTER,
                DXGI_SWAP_CHAIN_DESC1, DXGI_SWAP_EFFECT_FLIP_DISCARD,
                DXGI_USAGE_RENDER_TARGET_OUTPUT,
            },
        },
        System::{
            Threading::{CreateEventW, WaitForSingleObject},
            WindowsProgramming::INFINITE,
        },
    },
};

const FRAME_COUNT: usize = 2;

pub struct Renderer {
    debug: Option<ID3D12Debug1>,
    factory: IDXGIFactory2,
    adapter: IDXGIAdapter2,
    device: ID3D12Device2,
    command_queue: ID3D12CommandQueue,
    swap_chain: IDXGISwapChain3,
    rtv_heap: ID3D12DescriptorHeap,
    rtv_descriptor_size: u32,
    rt_views: [ID3D12Resource2; FRAME_COUNT],
    viewport: D3D12_VIEWPORT,
    scissor_rect: RECT,
    command_allocator: ID3D12CommandAllocator,
    root_signature: ID3D12RootSignature,
    pipeline_state: ID3D12PipelineState,
    command_list: ID3D12GraphicsCommandList,
    vertex_buffer: ID3D12Resource2,
    vertex_buffer_view: D3D12_VERTEX_BUFFER_VIEW,
    fence: ID3D12Fence,
    fence_value: u64,
    fence_event: HANDLE,
    frame_index: u32,
}

impl Renderer {
    pub fn create(hwnd: HWND, window_rect: RECT) -> Result<Self> {
        let width = window_rect.right - window_rect.left;
        let height = window_rect.bottom - window_rect.top;

        let debug = if cfg!(debug_assertions) {
            let mut debug: Option<ID3D12Debug1> = None;
            unsafe {
                D3D12GetDebugInterface(&mut debug)?;

                let some_debug = debug.as_ref().unwrap();
                some_debug.EnableDebugLayer();
                some_debug.SetEnableGPUBasedValidation(true);
            }

            debug
        } else {
            None
        };

        let factory = unsafe {
            CreateDXGIFactory2::<IDXGIFactory2>(if cfg!(debug_assertions) {
                DXGI_CREATE_FACTORY_DEBUG
            } else {
                0
            })?
        };

        let (adapter, device) = {
            let mut adapter_index = 0u32;
            loop {
                unsafe {
                    let adapter = factory
                        .EnumAdapters1(adapter_index)?
                        .cast::<IDXGIAdapter2>()?;
                    adapter_index += 1;

                    let mut adapter_desc = MaybeUninit::<DXGI_ADAPTER_DESC1>::uninit();
                    adapter.GetDesc1(adapter_desc.as_mut_ptr())?;

                    let adapter_desc = adapter_desc.assume_init();
                    // TODO: determine if adapter is suitable
                    _ = adapter_desc;

                    let mut device: Option<ID3D12Device2> = None;
                    if D3D12CreateDevice(&adapter, D3D_FEATURE_LEVEL_12_0, &mut device).is_err() {
                        continue;
                    }

                    break (adapter, device.unwrap());
                }
            }
        };

        let command_queue = unsafe {
            device.CreateCommandQueue::<ID3D12CommandQueue>(&D3D12_COMMAND_QUEUE_DESC {
                Type: D3D12_COMMAND_LIST_TYPE_DIRECT,
                ..Default::default()
            })?
        };

        let swap_chain = unsafe {
            let swap_chain = factory.CreateSwapChainForHwnd(
                &command_queue,
                hwnd,
                &DXGI_SWAP_CHAIN_DESC1 {
                    Width: width as u32,
                    Height: height as u32,
                    Format: DXGI_FORMAT_R8G8B8A8_UNORM,
                    SampleDesc: DXGI_SAMPLE_DESC {
                        Count: 1,
                        ..Default::default()
                    },
                    BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT,
                    BufferCount: FRAME_COUNT as u32,
                    SwapEffect: DXGI_SWAP_EFFECT_FLIP_DISCARD,
                    ..Default::default()
                },
                None,
                None,
            )?;
            swap_chain.cast::<IDXGISwapChain3>()?
        };

        unsafe { factory.MakeWindowAssociation(hwnd, DXGI_MWA_NO_ALT_ENTER)? };

        let rtv_heap = unsafe {
            device.CreateDescriptorHeap::<ID3D12DescriptorHeap>(&D3D12_DESCRIPTOR_HEAP_DESC {
                Type: D3D12_DESCRIPTOR_HEAP_TYPE_RTV,
                NumDescriptors: FRAME_COUNT as u32,
                ..Default::default()
            })?
        };

        let rtv_descriptor_size =
            unsafe { device.GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV) };

        let rt_views = unsafe {
            let rtv_handle = rtv_heap.GetCPUDescriptorHandleForHeapStart();

            let mut rt_views: [MaybeUninit<ID3D12Resource2>; FRAME_COUNT] =
                MaybeUninit::uninit().assume_init();

            for i in 0..FRAME_COUNT {
                // TODO: Is early returning from an error safe? i.e. will a drop of uninitialized
                // `rt_views` occur here
                let resource = swap_chain.GetBuffer::<ID3D12Resource2>(i as u32)?;

                device.CreateRenderTargetView(
                    &resource,
                    None,
                    D3D12_CPU_DESCRIPTOR_HANDLE {
                        ptr: rtv_handle.ptr + (i * (rtv_descriptor_size as usize)),
                    },
                );

                rt_views[i].write(resource);
            }

            mem::transmute::<_, [ID3D12Resource2; FRAME_COUNT as usize]>(rt_views)
        };

        let viewport = D3D12_VIEWPORT {
            TopLeftX: 0.0,
            TopLeftY: 0.0,
            Width: width as f32,
            Height: height as f32,
            MinDepth: D3D12_MIN_DEPTH,
            MaxDepth: D3D12_MAX_DEPTH,
        };

        let command_allocator = unsafe {
            device
                .CreateCommandAllocator::<ID3D12CommandAllocator>(D3D12_COMMAND_LIST_TYPE_DIRECT)?
        };

        let root_signature = unsafe {
            let blob = {
                let mut blob: Option<ID3DBlob> = None;
                D3D12SerializeRootSignature(
                    &D3D12_ROOT_SIGNATURE_DESC {
                        Flags: D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT,
                        ..Default::default()
                    },
                    D3D_ROOT_SIGNATURE_VERSION_1,
                    &mut blob,
                    None,
                )?;
                blob.unwrap()
            };

            device.CreateRootSignature::<ID3D12RootSignature>(
                0,
                slice::from_raw_parts(blob.GetBufferPointer().cast(), blob.GetBufferSize()),
            )?
        };

        let pipeline_state = {
            let (vertex_shader, pixel_shader) = {
                let shader_code = include_bytes!("main.hlsl");

                let make_shader = |entry_point, target| unsafe {
                    let mut shader: Option<ID3DBlob> = None;

                    D3DCompile(
                        shader_code.as_ptr().cast(),
                        shader_code.len(),
                        s!("render.hlsl"),
                        None,
                        None,
                        entry_point,
                        target,
                        0,
                        0,
                        &mut shader,
                        None,
                    )?;

                    Result::Ok(shader.unwrap())
                };

                (
                    make_shader(s!("vs_main"), s!("vs_5_0"))?,
                    make_shader(s!("ps_main"), s!("ps_5_0"))?,
                )
            };

            let (vertex_shader_desc, pixel_shader_desc) = unsafe {
                (
                    D3D12_SHADER_BYTECODE {
                        pShaderBytecode: vertex_shader.GetBufferPointer(),
                        BytecodeLength: vertex_shader.GetBufferSize(),
                    },
                    D3D12_SHADER_BYTECODE {
                        pShaderBytecode: pixel_shader.GetBufferPointer(),
                        BytecodeLength: pixel_shader.GetBufferSize(),
                    },
                )
            };

            let mut input_element_descs = [
                D3D12_INPUT_ELEMENT_DESC {
                    SemanticName: s!("POSITION"),
                    SemanticIndex: 0,
                    Format: DXGI_FORMAT_R32G32B32_FLOAT,
                    InputSlot: 0,
                    AlignedByteOffset: 0,
                    InputSlotClass: D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,
                    InstanceDataStepRate: 0,
                },
                D3D12_INPUT_ELEMENT_DESC {
                    SemanticName: s!("COLOR"),
                    SemanticIndex: 0,
                    Format: DXGI_FORMAT_R32G32B32A32_FLOAT,
                    InputSlot: 0,
                    AlignedByteOffset: 12,
                    InputSlotClass: D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,
                    InstanceDataStepRate: 0,
                },
            ];

            let desc = D3D12_GRAPHICS_PIPELINE_STATE_DESC {
                InputLayout: D3D12_INPUT_LAYOUT_DESC {
                    pInputElementDescs: input_element_descs.as_mut_ptr(),
                    NumElements: input_element_descs.len() as u32,
                },
                pRootSignature: ManuallyDrop::new(&root_signature),
                VS: vertex_shader_desc,
                PS: pixel_shader_desc,
                RasterizerState: D3D12_RASTERIZER_DESC {
                    FillMode: D3D12_FILL_MODE_SOLID,
                    CullMode: D3D12_CULL_MODE_NONE,
                    ..Default::default()
                },
                BlendState: D3D12_BLEND_DESC {
                    AlphaToCoverageEnable: false.into(),
                    IndependentBlendEnable: false.into(),
                    RenderTarget: [
                        D3D12_RENDER_TARGET_BLEND_DESC {
                            BlendEnable: false.into(),
                            LogicOpEnable: false.into(),
                            SrcBlend: D3D12_BLEND_ONE,
                            DestBlend: D3D12_BLEND_ZERO,
                            BlendOp: D3D12_BLEND_OP_ADD,
                            SrcBlendAlpha: D3D12_BLEND_ONE,
                            DestBlendAlpha: D3D12_BLEND_ONE,
                            BlendOpAlpha: D3D12_BLEND_OP_ADD,
                            LogicOp: D3D12_LOGIC_OP_NOOP,
                            RenderTargetWriteMask: D3D12_COLOR_WRITE_ENABLE_ALL.0 as u8,
                        },
                        D3D12_RENDER_TARGET_BLEND_DESC::default(),
                        D3D12_RENDER_TARGET_BLEND_DESC::default(),
                        D3D12_RENDER_TARGET_BLEND_DESC::default(),
                        D3D12_RENDER_TARGET_BLEND_DESC::default(),
                        D3D12_RENDER_TARGET_BLEND_DESC::default(),
                        D3D12_RENDER_TARGET_BLEND_DESC::default(),
                        D3D12_RENDER_TARGET_BLEND_DESC::default(),
                    ],
                },
                DepthStencilState: D3D12_DEPTH_STENCIL_DESC::default(),
                SampleMask: u32::max_value(),
                PrimitiveTopologyType: D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE,
                NumRenderTargets: 1,
                SampleDesc: DXGI_SAMPLE_DESC {
                    Count: 1,
                    ..Default::default()
                },
                RTVFormats: [
                    DXGI_FORMAT_R8G8B8A8_UNORM,
                    DXGI_FORMAT::default(),
                    DXGI_FORMAT::default(),
                    DXGI_FORMAT::default(),
                    DXGI_FORMAT::default(),
                    DXGI_FORMAT::default(),
                    DXGI_FORMAT::default(),
                    DXGI_FORMAT::default(),
                ],
                ..Default::default()
            };

            unsafe { device.CreateGraphicsPipelineState::<ID3D12PipelineState>(&desc)? }
        };

        let command_list = unsafe {
            let command_list = device.CreateCommandList::<_, _, ID3D12GraphicsCommandList>(
                0,
                D3D12_COMMAND_LIST_TYPE_DIRECT,
                &command_allocator,
                &pipeline_state,
            )?;
            command_list.Close()?;
            command_list
        };

        let aspect_ratio = (width as f32) / (height as f32);

        let (vertex_buffer, vertex_buffer_view) = {
            #[repr(C)]
            struct Vertex {
                position: [f32; 3],
                color: [f32; 4],
            }

            let vertices = [
                Vertex {
                    position: [0.0, 0.25 * aspect_ratio, 0.0],
                    color: [1.0, 0.0, 0.0, 1.0],
                },
                Vertex {
                    position: [0.25, -0.25 * aspect_ratio, 0.0],
                    color: [0.0, 1.0, 0.0, 1.0],
                },
                Vertex {
                    position: [-0.25, -0.25 * aspect_ratio, 0.0],
                    color: [0.0, 0.0, 1.0, 1.0],
                },
            ];

            let vertex_buffer = unsafe {
                let mut vertex_buffer: Option<ID3D12Resource2> = None;
                device.CreateCommittedResource(
                    &D3D12_HEAP_PROPERTIES {
                        Type: D3D12_HEAP_TYPE_UPLOAD,
                        ..Default::default()
                    },
                    D3D12_HEAP_FLAG_NONE,
                    &D3D12_RESOURCE_DESC {
                        Dimension: D3D12_RESOURCE_DIMENSION_BUFFER,
                        Width: mem::size_of_val(&vertices) as u64,
                        Height: 1,
                        DepthOrArraySize: 1,
                        MipLevels: 1,
                        SampleDesc: DXGI_SAMPLE_DESC {
                            Count: 1,
                            Quality: 0,
                        },
                        Layout: D3D12_TEXTURE_LAYOUT_ROW_MAJOR,
                        ..Default::default()
                    },
                    D3D12_RESOURCE_STATE_GENERIC_READ,
                    None,
                    &mut vertex_buffer,
                )?;
                vertex_buffer.unwrap()
            };

            unsafe {
                let mut data = ptr::null_mut::<c_void>();
                vertex_buffer.Map(0, None, Some(&mut data))?;
                ptr::copy_nonoverlapping(
                    vertices.as_ptr(),
                    data.cast(),
                    mem::size_of_val(&vertices),
                );
            }

            let vertex_buffer_view = D3D12_VERTEX_BUFFER_VIEW {
                BufferLocation: unsafe { vertex_buffer.GetGPUVirtualAddress() },
                StrideInBytes: mem::size_of::<Vertex>() as u32,
                SizeInBytes: mem::size_of_val(&vertices) as u32,
            };

            (vertex_buffer, vertex_buffer_view)
        };

        let (fence, fence_value, fence_event) = unsafe {
            (
                device.CreateFence::<ID3D12Fence>(0, D3D12_FENCE_FLAG_NONE)?,
                1u64,
                CreateEventW(None, false, false, None)?,
            )
        };

        let frame_index = unsafe { swap_chain.GetCurrentBackBufferIndex() };

        Ok(Self {
            debug,
            factory,
            adapter,
            device,
            command_queue,
            swap_chain,
            rtv_heap,
            rtv_descriptor_size,
            rt_views,
            viewport,
            scissor_rect: window_rect,
            command_allocator,
            root_signature,
            pipeline_state,
            command_list,
            vertex_buffer,
            vertex_buffer_view,
            fence,
            fence_value,
            fence_event,
            frame_index,
        })
    }

    pub fn render(&mut self) -> Result<()> {
        unsafe {
            self.command_allocator.Reset()?;

            self.command_list
                .Reset(&self.command_allocator, &self.pipeline_state)?;
            self.command_list
                .SetGraphicsRootSignature(&self.root_signature);
            self.command_list.RSSetViewports(&[self.viewport]);
            self.command_list.RSSetScissorRects(&[self.scissor_rect]);
            self.command_list.ResourceBarrier(&[D3D12_RESOURCE_BARRIER {
                Type: D3D12_RESOURCE_BARRIER_TYPE_TRANSITION,
                Flags: D3D12_RESOURCE_BARRIER_FLAG_NONE,
                Anonymous: D3D12_RESOURCE_BARRIER_0 {
                    Transition: mem::ManuallyDrop::new(D3D12_RESOURCE_TRANSITION_BARRIER {
                        pResource: ManuallyDrop::new(
                            &self.rt_views[self.frame_index as usize].cast()?,
                        ),
                        StateBefore: D3D12_RESOURCE_STATE_PRESENT,
                        StateAfter: D3D12_RESOURCE_STATE_RENDER_TARGET,
                        Subresource: D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
                    }),
                },
            }]);

            let rtv_handle = D3D12_CPU_DESCRIPTOR_HANDLE {
                ptr: self.rtv_heap.GetCPUDescriptorHandleForHeapStart().ptr
                    + ((self.frame_index * self.rtv_descriptor_size) as usize),
            };

            self.command_list
                .OMSetRenderTargets(1, Some(&rtv_handle), false, None);
            self.command_list
                .ClearRenderTargetView(rtv_handle, [0.0, 0.2, 0.4, 1.0].as_ptr(), &[]);
            self.command_list
                .IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            self.command_list
                .IASetVertexBuffers(0, Some(&[self.vertex_buffer_view]));
            self.command_list.DrawInstanced(3, 1, 0, 0);
            self.command_list.ResourceBarrier(&[D3D12_RESOURCE_BARRIER {
                Type: D3D12_RESOURCE_BARRIER_TYPE_TRANSITION,
                Flags: D3D12_RESOURCE_BARRIER_FLAG_NONE,
                Anonymous: D3D12_RESOURCE_BARRIER_0 {
                    Transition: mem::ManuallyDrop::new(D3D12_RESOURCE_TRANSITION_BARRIER {
                        pResource: ManuallyDrop::new(
                            &self.rt_views[self.frame_index as usize].cast()?,
                        ),
                        StateBefore: D3D12_RESOURCE_STATE_RENDER_TARGET,
                        StateAfter: D3D12_RESOURCE_STATE_PRESENT,
                        Subresource: D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
                    }),
                },
            }]);
            self.command_list.Close()?;

            self.command_queue
                .ExecuteCommandLists(&[self.command_list.cast()?]);

            self.swap_chain.Present(1, 0).ok()?;

            let fence_value = self.fence_value;
            self.command_queue.Signal(&self.fence, fence_value)?;

            self.fence_value += 1;

            if self.fence.GetCompletedValue() < fence_value {
                self.fence
                    .SetEventOnCompletion(fence_value, self.fence_event)?;

                WaitForSingleObject(self.fence_event, INFINITE);
            }

            self.frame_index = self.swap_chain.GetCurrentBackBufferIndex();
        }

        Ok(())
    }
}
