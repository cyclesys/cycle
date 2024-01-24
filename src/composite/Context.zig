const std = @import("std");
const builtin = @import("builtin");
const lib = @import("lib");
const vk = @import("vulkan");
const win = @import("../windows.zig");

base_fns: BaseFns,
instance: vk.Instance,
instance_fns: InstanceFns,

surface: vk.SurfaceKHR,

physical_device: vk.PhysicalDevice,
physical_device_properties: vk.PhysicalDeviceProperties,
graphics_family_index: u32,
present_family_index: u32,
host_visible_memory_index: u32,

device: vk.Device,
device_fns: DeviceFns,

pub const max_concurrent_frames = 2;
const Self = @This();

pub fn init(allocator: std.mem.Allocator, hwnd: win.HWND) !Self {
    const loader = try lib.ui.render.vulkanLoader();
    const base_fns = try BaseFns.load(loader);

    const instance = try createInstance(allocator, base_fns);
    const instance_fns = try InstanceFns.load(instance, loader);

    const surface = instance_fns.createWin32SurfaceKHR(
        instance,
        &vk.Win32SurfaceCreateInfoKHR{
            .hinstance = win.GetModuleHandleW(null).?,
            .hwnd = hwnd,
        },
        null,
    );

    const physical_device, const physical_device_properties, const physical_device_memory_properties, const graphics_family_index, const present_family_index, const surface_format = try selectPhysicalDevice(
        allocator,
        instance_fns,
        instance,
        surface,
    );

    const host_visible_memory_index = for (0..physical_device_memory_properties.memory_type_count) |i| {
        const memory_type = physical_device_memory_properties.memory_types[i];
        if (memory_type.property_flags.host_visible_bit) {
            break i;
        }
    } else {
        return error.RequiredMemoryTypeNotAvailable;
    };

    const device = try createDevice(instance_fns, physical_device, graphics_family_index, present_family_index);
    const device_fns = try DeviceFns.load(device, instance_fns.dispatch.vkGetDeviceProcAddr);

    return Self{
        .base_fns = base_fns,
        .instance = instance,
        .instance_fns = instance_fns,
        .surface = surface,
        .surface_format = surface_format,
        .physical_device = physical_device,
        .physical_device_properties = physical_device_properties,
        .graphics_family_index = graphics_family_index,
        .present_family_index = present_family_index,
        .host_visible_memory_index = host_visible_memory_index,
        .device = device,
        .device_fns = device_fns,
    };
}

pub fn deinit(self: Self) void {
    self.device_fns.destroyDevice(self.device, null);
    self.instance_fns.destroySurfaceKHR(self.instance, self.surface, null);
    self.instance_fns.destroyInstance(self.instance, null);
}

fn createInstance(allocator: std.mem.Allocator, base_fns: BaseFns) !vk.Instance {
    var extension_count: u32 = 0;
    _ = try base_fns.enumerateInstanceExtensionProperties(null, &extension_count, null);

    const extensions = try allocator.alloc(vk.ExtensionProperties, extension_count);
    defer allocator.free(extensions);

    _ = try base_fns.enumerateInstanceExtensionProperties(null, &extension_count, extensions.ptr);

    if (!required_extensions.contains(extensions))
        return error.VulkanExtensionsNotSupported;

    const instance = try base_fns.createInstance(&.{
        .p_application_info = &vk.ApplicationInfo{
            .p_application_name = @as([*:0]const u8, "Cycle"),
            .application_version = vk.makeApiVersion(0, 0, 1, 0),
            .p_engine_name = @as([*:0]const u8, "cycle.Compositor"),
            .engine_version = vk.makeApiVersion(0, 0, 1, 0),
            .api_version = vk.API_VERSION_1_3,
        },
        .enabled_extension_count = required_extensions.names.len,
        .pp_enabled_extension_names = &required_extensions.names,
    });

    return instance;
}

fn selectPhysicalDevice(
    allocator: std.mem.Allocator,
    instance_fns: InstanceFns,
    instance: vk.Instance,
    surface: vk.SurfaceKHR,
) !struct {
    vk.PhysicalDevice,
    vk.PhysicalDeviceProperties,
    vk.PhysicalDeviceMemoryProperties,
    u32,
    u32,
    vk.Format,
} {
    var device_count: u32 = 0;
    _ = try instance_fns.enumeratePhysicalDevices(instance, &device_count, null);

    const devices = try allocator.alloc(vk.PhysicalDevice, device_count);
    defer allocator.free(devices);

    _ = try instance_fns.enumeratePhysicalDevices(instance, &device_count, devices.ptr);

    for (devices) |device| {
        const properties = instance_fns.getPhysicalDeviceProperties(device);
        if (properties.device_type != .integrated_gpu and
            properties.device_type != .discrete_gpu)
        {
            continue;
        }

        {
            var surface_format_count: u32 = 0;
            _ = try instance_fns.getPhysicalDeviceSurfaceFormatsKHR(
                device,
                surface,
                &surface_format_count,
                null,
            );
            if (surface_format_count == 0)
                continue;
        }

        {
            var present_mode_count: u32 = 0;
            _ = try instance_fns.getPhysicalDeviceSurfacePresentModesKHR(
                device,
                surface,
                &present_mode_count,
                null,
            );
            if (present_mode_count == 0)
                continue;
        }

        {
            var extension_count: u32 = 0;
            _ = try instance_fns.enumerateDeviceExtensionProperties(device, null, &extension_count, null);

            const extensions = try allocator.alloc(vk.ExtensionProperties, extension_count);
            defer allocator.free(extensions);

            _ = try instance_fns.enumerateDeviceExtensionProperties(device, null, &extension_count, extensions.ptr);
            if (!required_extensions.contains(extensions))
                continue;
        }

        {
            var indexing_features = vk.PhysicalDeviceDescriptorIndexingFeatures{};
            var device_features = vk.PhysicalDeviceFeatures2{
                .p_next = @ptrCast(&indexing_features),
                .features = vk.PhysicalDeviceFeatures{},
            };
            instance_fns.getPhysicalDeviceFeatures2(device, &device_features);
            if (indexing_features.shader_sampled_image_array_non_uniform_indexing == vk.FALSE or
                indexing_features.descriptor_binding_sampled_image_update_after_bind == vk.FALSE)
            {
                continue;
            }
        }

        var queue_family_count: u32 = 0;
        _ = try instance_fns.getPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, null);

        const queue_families = try allocator.alloc(vk.QueueFamilyProperties, queue_family_count);
        defer allocator.free(queue_families);

        _ = try instance_fns.getPhysicalDeviceQueueFamilyProperties(
            device,
            &queue_family_count,
            queue_families.ptr,
        );

        var graphics_family_index: ?u32 = null;
        var present_family_index: ?u32 = null;
        for (queue_families, 0..) |family, ii| {
            if (graphics_family_index == null and family.queue_flags.graphics_bit) {
                graphics_family_index = ii;
                if (present_family_index == null) continue else break;
            }

            if (present_family_index == null and
                try instance_fns.getPhysicalDeviceSurfaceSupportKHR(device, ii, surface) == vk.TRUE)
            {
                present_family_index = ii;
                if (graphics_family_index == null) continue else break;
            }
        }

        if (graphics_family_index != null) {
            if (present_family_index == null) {
                const surface_support = try instance_fns.getPhysicalDeviceSurfaceSupportKHR(device, graphics_family_index.?, surface);
                if (surface_support != vk.TRUE)
                    continue;

                present_family_index = graphics_family_index;
            }

            const memory_properties = instance_fns.getPhysicalDeviceMemoryProperties(device);
            return .{
                device,
                properties,
                memory_properties,
                graphics_family_index.?,
                present_family_index.?,
            };
        }
    }

    return error.NoSuitableDeviceFound;
}

fn createDevice(
    instance_fns: InstanceFns,
    physical_device: vk.PhysicalDevice,
    graphics_family_index: u32,
    present_family_index: u32,
) !vk.Device {
    const priorities = [_]f32{1.0};
    const queue_create_infos = [_]vk.DeviceQueueCreateInfo{
        vk.DeviceQueueCreateInfo{
            .queue_family_index = graphics_family_index,
            .queue_count = 1,
            .p_queue_priorites = &priorities,
        },
        vk.DeviceQueueCreateInfo{
            .queue_family_index = present_family_index,
            .queue_count = 1,
            .p_queue_priorites = &priorities,
        },
    };
    var indexing_features = vk.PhysicalDeviceDescriptorIndexingFeatures{};
    var device_features = vk.PhysicalDeviceFeatures2{
        .p_next = @ptrCast(&indexing_features),
        .features = vk.PhysicalDeviceFeatures{},
    };
    return try instance_fns.createDevice(
        physical_device,
        &vk.DeviceCreateInfo{
            .p_next = @ptrCast(&device_features),
            .queue_create_info_count = queue_create_infos.len,
            .p_queue_create_infos = &queue_create_infos,
        },
        null,
    );
}

const BaseFns = vk.BaseWrapper(.{
    .createInstance = true,
    .enumerateInstanceExtensionProperties = true,
});

const InstanceFns = vk.InstanceWrapper(.{
    .destroyInstance = true,

    .enumeratePhysicalDevices = true,
    .getPhysicalDeviceProperties = true,
    .getPhysicalDeviceQueueFamilyProperties = true,
    .getPhysicalDeviceMemoryProperties = true,
    .getPhysicalDeviceSurfaceSupportKHR = true,
    .getPhysicalDeviceSurfaceFormatsKHR = true,
    .getPhysicalDeviceSurfacePresentModesKHR = true,

    .createDevice = true,
    .createWin32SurfaceKHR = true,
    .createDebugUtilsMessengerEXT = true,
    .destroySurfaceKHR = true,
});

const DeviceFns = vk.DeviceWrapper(.{
    .destroyDevice = true,
});

const required_extensions = struct {
    const names: []const [:0]const u8 = &.{
        vk.extension_info.khr_surface,
        vk.extension_info.khr_swapchain,
        vk.extension_info.khr_external_memory,
    } ++ switch (builtin.target.os.tag) {
        .windows => &.{
            vk.extension_info.khr_win_32_surface,
            vk.khr_external_memory_win_32,
        },
        else => @compileError("unsupported target"),
    };

    fn contains(extensions: []const vk.ExtensionProperties) bool {
        outer: for (names) |req| {
            for (extensions) |ext| {
                const extension_name = std.mem.sliceTo(&ext.extension_name, 0);
                if (std.mem.eql(u8, extension_name, req.?)) {
                    continue :outer;
                }
            } else {
                return false;
            }
        }

        return true;
    }
};
