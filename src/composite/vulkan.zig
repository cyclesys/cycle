const std = @import("std");
const vk = @import("vulkan");
const lib_vk = @import("lib").render.vk;

const win32 = struct {
    const mod = @import("win32");
    usingnamespace mod.foundation;
    usingnamespace mod.system.library_loader;
};

const BaseDispatch = vk.BaseWrapper(.{
    .createInstance = true,
});

const InstanceDispatch = vk.InstanceWrapper(.{
    .createDevice = true,
    .createWin32SurfaceKHR = true,
    .createDebugUtilsMessengerEXT = true,
    .destroyInstance = true,
    .destroySurfaceKHR = true,
});

const DeviceDispatch = vk.DeviceWrapper(.{
    .destroyDevice = true,
});

const required_extensions = struct {
    const names = .{
        @as([:0]const u8, "VK_KHR_surface"),
        @as([:0]const u8, "VK_KHR_win32_surface"),
        @as([:0]const u8, "VK_KHR_external_memory_win32"),
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

pub const Compositor = struct {
    allocator: std.mem.Allocator,
    dis: struct {
        base: BaseDispatch,
        ins: InstanceDispatch,
        dev: DeviceDispatch,
    },
    instance: vk.Instance,
    surface: vk.SurfaceKHR,
    phy: struct {
        dev: vk.PhysicalDevice,
        props: vk.PhysicalDeviceProperties,
        mem_props: vk.PhysicalDeviceMemoryProperties,
    },
    dev: vk.Device,
    q: struct {
        gfx_idx: u32,
        gfx: vk.Queue,
        present_idx: u32,
        present: vk.Queue,
    },

    pub fn init(allocator: std.mem.Allocator, hwnd: win32.HWND) !Compositor {
        const loader = try lib_vk.vulkanLoader();
        var base_dis = try BaseDispatch.load(loader);

        const instance = try createInstance(base_dis);
        var ins_dis = try InstanceDispatch.load(instance, loader);

        const surface = try ins_dis.createWin32SurfaceKHR(
            instance,
            &vk.Win32SurfaceCreateInfoKHR{
                .hinstance = win32.GetModuleHandleA(null).?,
                .hwnd = hwnd,
            },
            null,
        );

        const phy = selectPhysicalDevice(allocator, instance, ins_dis, surface);
        const dev = try createDevice(ins_dis, phy.dev, phy.graphics, phy.present);
        const dev_dis = try DeviceDispatch.load(dev, ins_dis.dispatch.vkGetDeviceProcAddr);

        const gfx_q = dev_dis.getDeviceQueue(dev, phy.gfx, 0);
        const present_q = dev_dis.getDeviceQueue(dev, phy.present, 0);

        return Compositor{
            .allocator = allocator,
            .dis = .{
                .base = base_dis,
                .ins = ins_dis,
                .dev = dev_dis,
            },
            .instance = instance,
            .surface = surface,
            .phy = .{
                .dev = phy.dev,
                .props = phy.props,
                .mem_props = phy.mem_props,
            },
            .dev = dev,
            .q = .{
                .gfx_idx = phy.gfx,
                .gfx = gfx_q,
                .present_idx = phy.present,
                .present = present_q,
            },
        };
    }
};

fn createInstance(allocator: std.mem.Allocator, dis: BaseDispatch) !vk.Instance {
    var extension_count: u32 = 0;
    _ = try dis.enumerateInstanceExtensionProperties(null, &extension_count, null);

    const extensions = try allocator.alloc(vk.ExtensionProperties, extension_count);
    defer allocator.free(extensions);

    _ = try dis.enumerateInstanceExtensionProperties(null, &extension_count, extensions.ptr);

    if (!required_extensions.contains(extensions))
        return error.VulkanExtensionsNotSupported;

    const instance = try dis.createInstance(&.{
        .p_application_info = &vk.ApplicationInfo{
            .p_application_name = "cycle",
            .application_version = vk.makeApiVersion(0, 0, 1, 0),
            .p_engine_name = "cycle.Compositor",
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
    instance: vk.Instance,
    dis: InstanceDispatch,
    surface: vk.SurfaceKHR,
) !struct {
    dev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    mem_props: vk.PhysicalDeviceMemoryProperties,
    gfx: u32,
    present: u32,
    format: vk.Format,
} {
    var dev_count: u32 = 0;
    _ = try dis.enumeratePhysicalDevices(instance, &dev_count, null);

    const devs = try allocator.alloc(vk.PhysicalDevice, dev_count);
    defer allocator.free(devs);

    _ = try dis.enumeratePhysicalDevices(instance, &dev_count, devs.ptr);

    for (0..dev_count) |i| {
        const dev = devs[i];

        const props = dis.getPhysicalDeviceProperties(dev);
        if (props.device_type != .integrated_gpu and
            props.device_type != .discrete_gpu)
        {
            continue;
        }

        {
            var surface_format_count: u32 = 0;
            _ = try dis.getPhysicalDeviceSurfaceFormatsKHR(
                dev,
                surface,
                &surface_format_count,
                null,
            );
            if (surface_format_count == 0)
                continue;
        }

        {
            var present_mode_count: u32 = 0;
            _ = try dis.getPhysicalDeviceSurfacePresentModesKHR(
                dev,
                surface,
                &present_mode_count,
                null,
            );
            if (present_mode_count == 0)
                continue;
        }

        {
            var extension_count: u32 = 0;
            _ = try dis.enumerateDeviceExtensionProperties(dev, null, &extension_count, null);

            const extensions = try allocator.alloc(vk.ExtensionProperties, extension_count);
            defer allocator.free(extensions);

            _ = try dis.enumerateDeviceExtensionProperties(dev, null, &extension_count, extensions.ptr);
            if (!required_extensions.contains(extensions))
                continue;
        }

        var queue_family_count: u32 = 0;
        _ = try dis.getPhysicalDeviceQueueFamilyProperties(dev, &queue_family_count, null);

        const queue_families = try allocator.alloc(vk.QueueFamilyProperties, queue_family_count);
        defer allocator.free(queue_families);

        _ = try dis.getPhysicalDeviceQueueFamilyProperties(
            dev,
            &queue_family_count,
            queue_families.ptr,
        );

        var gfx: ?u32 = null;
        var present: ?u32 = null;
        for (queue_families, 0..) |family, ii| {
            if (gfx == null and family.queue_flags.graphics_bit) {
                gfx = ii;
                if (present == null) continue else break;
            }

            if (present == null and
                try dis.getPhysicalDeviceSurfaceSupportKHR(dev, ii, surface) == vk.TRUE)
            {
                present = ii;
                if (gfx == null) continue else break;
            }
        }

        if (gfx != null) {
            if (present == null) {
                const surface_support = try dis.getPhysicalDeviceSurfaceSupportKHR(dev, gfx.?, surface);
                if (surface_support != vk.TRUE)
                    continue;

                present = gfx.?;
            }

            var surface_format_count: u32 = 0;
            _ = try dis.getPhysicalDeviceSurfaceFormatsKHR(dev, surface, &surface_format_count, null);

            const surface_formats = allocator.alloc(vk.SurfaceFormatKHR, surface_format_count);
            defer allocator.free(surface_formats);

            _ = try dis.getPhysicalDeviceSurfaceFormatsKHR(dev, surface, &surface_format_count, surface_formats.ptr);

            const mem_props = dis.getPhysicalDeviceMemoryProperties(dev);
            return .{
                .dev = dev,
                .props = props,
                .mem_props = mem_props,
                .gfx = gfx.?,
                .present = present.?,
                .format = surface_formats[0].format,
            };
        }
    }

    return error.VulkanDeviceNotFound;
}

fn createDevice(
    dis: InstanceDispatch,
    phy_dev: vk.PhysicalDevice,
    graphics: u32,
    present: u32,
) !vk.Device {
    const prio = [_]f32{1.0};
    const queue_create_infos = .{
        .{
            .queue_family_index = graphics,
            .queue_count = 1,
            .p_queue_priorities = &prio,
        },
        .{
            .queue_family_index = present,
            .queue_count = 1,
            .p_queue_priorities = &prio,
        },
    };

    const device = dis.createDevice(
        phy_dev,
        &vk.DeviceCreateInfo{
            .queue_create_info_count = if (present == graphics) 1 else 2,
            .p_queue_create_infos = &queue_create_infos,
            .enabled_extension_count = required_extensions.names.len,
            .pp_enabled_extension_names = &required_extensions.names,
        },
        null,
    );

    return device;
}
