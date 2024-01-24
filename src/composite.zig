const vk = @import("composite/vulkan.zig");

//pub fn import(
//    device_fns: fns.DeviceFns,
//    device: vk.Device,
//    memory_type_index: u32,
//    format: vk.Format,
//    queue_family_index: u32,
//    width: u32,
//    height: u32,
//    handle: win.HANDLE,
//) !Self {
//    const iv = try createImageAndView(
//        device_fns,
//        device,
//        format,
//        queue_family_index,
//        width,
//        height,
//        vk.ImageUsageFlags{ .color_attachment_bit = true },
//    );
//
//    const memory = try device_fns.allocateMemory(
//        device,
//        &vk.MemoryAllocateInfo{
//            .p_next = &vk.ImportMemoryWin32HandleInfoKHR{
//                .handle_type = vk.ExternalMemoryHandleTypeFlags{ .opaque_win32_bit = true },
//                .handle = handle,
//                .name = null,
//            },
//            .allocation_size = iv.reqs.size,
//            .memory_type_index = memory_type_index,
//        },
//        null,
//    );
//
//    return Self{
//        .memory = memory,
//        .image = iv.image,
//        .view = iv.view,
//    };
//}
