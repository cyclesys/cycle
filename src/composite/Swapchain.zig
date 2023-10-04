const std = @import("std");
const vk = @import("vulkan");
const Commands = @import("Commands.zig");
const Context = @import("Context.zig");

allocator: std.mem.Allocator,
present_queue: vk.Queue,
surface_format: vk.SurfaceFormatKHR,
image_count: u32,
present_mode: vk.PresentModeKHR,
swapchain: vk.SwapchainKHR,
targets: []Target,
wait_semaphore: vk.Semaphore,
image_index: u32,

const timeout = 100000000000;

const Target = struct {
    image: vk.Image,
    image_view: vk.ImageView,
    wait_semaphore: vk.Semaphore,
    signal_semaphore: vk.Semaphore,
    fence: vk.Fence,

    fn init(context: *const Context, image: vk.Image, format: vk.Format) !Target {
        return Target{
            .image = image,
            .image_view = try context.device_fns.createImageView(
                context.device,
                &vk.ImageViewCreateInfo{
                    .image = image,
                    .view_type = .@"2d",
                    .format = format,
                    .components = vk.ComponentMapping{
                        .r = .identity,
                        .g = .identity,
                        .b = .identity,
                        .a = .identity,
                    },
                    .subresource_range = vk.ImageSubresourceRange{
                        .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                        .base_mip_level = 0,
                        .level_count = 1,
                        .base_array_layer = 0,
                        .layer_count = 1,
                    },
                },
                null,
            ),
            .wait_semaphore = try context.device_fns.createSemaphore(context.device, &vk.SemaphoreCreateInfo{}, null),
            .signal_semaphore = try context.device_fns.createSemaphore(context.device, &vk.SemaphoreCreateInfo{}, null),
            .fence = try context.device_fns.createFence(
                context.device,
                &vk.FenceCreateInfo{ .signaled_bit = true },
                null,
            ),
        };
    }

    fn deinit(self: Target, context: *const Context) !void {
        try self.wait(context);
        context.device_fns.destroyFence(context.device, self.fence, null);
        context.device_fns.destroySemaphore(context.device, self.signal_semaphore, null);
        context.device_fns.destroySemaphore(context.device, self.wait_sempahore, null);
        context.device_fns.destroyImageView(context.device, self.image_view, null);
    }

    fn wait(self: Target, context: *const Context) void {
        if (try context.device_fns.waitForFences(
            context.device,
            1,
            &self.fence,
            vk.TRUE,
            timeout,
        ) == .timeout) {
            return error.VkFenceWaitTimedOut;
        }
    }
};
const Self = @This();

pub fn init(allocator: std.mem.Allocator, context: *const Context, fallback_extent: vk.Extent2D) !Self {
    const present_queue = context.device_fns.getDeviceQueue(context.device, context.present_family_index, 0);
    const surface_format = try selectSurfaceFormat(allocator, context);
    const present_mode = try selectPresentMode(allocator, context);
    const swapchain = try createSwapchain(
        context,
        fallback_extent,
        surface_format,
        present_mode,
        .null_handle,
    );
    const targets, const wait_semaphore, const image_index = try createTargetsAndSemaphore(allocator, context, surface_format, swapchain);
    return Self{
        .allocator = allocator,
        .present_queue = present_queue,
        .surface_format = surface_format,
        .present_mode = present_mode,
        .swapchain = swapchain,
        .targets = targets,
        .wait_semaphore = wait_semaphore,
        .image_index = image_index,
    };
}

pub fn deinit(self: *Self, context: *const Context) void {
    self.deinitTargetsAndSemaphore(context) catch |e| {
        std.log.err("{}", .{e});
    };
}

fn deinitTargetsAndSemaphore(self: *Self, context: *const Context) !void {
    for (self.targets) |target| {
        try target.deinit(context);
    }
    self.allocator.free(self.targets);
    context.device_fns.destroySemaphore(context.device, self.wait_semaphore, null);
}

pub fn recreate(self: *Self, context: *const Context, fallback_extent: vk.Extent2D) !void {
    try self.deinitTargetsAndSemaphore(context);
    const swapchain = try createSwapchain(
        context,
        fallback_extent,
        self.surface_format,
        self.present_mode,
        self.swapchain,
    );
    self.swapchain = swapchain;

    const targets, const wait_semaphore, const image_index = try createTargetsAndSemaphore(
        self.alloctor,
        context,
        self.surface_format,
        swapchain,
    );
    self.targets = targets;
    self.wait_semaphore = wait_semaphore;
    self.image_index = image_index;
}

pub fn present(self: *const Self, context: *const Context, commands: *const Commands) !bool {
    const target = &self.targets[self.image_index];
    try target.wait(context);
    try context.device_fns.resetFences(context.device, 1, &target.fence);

    try commands.submit(
        context,
        self.image_index,
        target.wait_semaphore,
        vk.PipelineStageFlags{ .top_of_pipe_bit = true },
        target.signal_semaphore,
        target.fence,
    );

    try context.device_fns.queuePresentKHR(
        self.present_queue,
        &vk.PresentInfoKHR{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = &target.signal_semaphore,
            .swapchain_count = 1,
            .p_swapchains = &self.swapchain,
            .p_image_indices = &self.image_index,
        },
    );

    const result = try context.device_fns.acquireNextImageKHR(
        context.device,
        self.swapchain,
        timeout,
        self.acquire_next_semaphore,
        .null_handle,
    );

    std.mem.swap(vk.Semaphore, &self.targets[result.image_index].wait_semaphore, &self.wait_semaphore);
    self.image_index = result.image_index;

    return switch (result.result) {
        .success, .not_ready => true,
        .suboptimal_khr => false,
        .timeout => error.VkAcquireNextImageTimedOut,
        else => unreachable,
    };
}

fn createSwapchain(
    context: *const Context,
    fallback_extent: vk.Extent2D,
    surface_format: vk.SurfaceFormatKHR,
    present_mode: vk.PresentModeKHR,
    old_swapchain: vk.SwapchainKHR,
) !vk.SwapchainKHR {
    const surface_capabilities = context.instance_fns.getPhysicalDeviceSurfaceCapabilitiesKHR(
        context.physical_device,
        context.surface,
    );
    const min_image_count = if (surface_capabilities.max_image_count > surface_capabilities.min_image_count)
        surface_capabilities.min_image_count + 1
    else
        surface_capabilities.min_image_count;
    const image_extent = if (surface_capabilities.current_extent.width == 0xFFFFFFFF)
        vk.Extent2D{
            .width = std.math.clamp(
                fallback_extent.width,
                surface_capabilities.min_image_extent.width,
                surface_capabilities.max_image_extent.width,
            ),
            .height = std.math.clamp(
                fallback_extent.height,
                surface_capabilities.min_image_extent.height,
                surface_capabilities.max_image_extent.height,
            ),
        }
    else
        fallback_extent;
    const image_sharing_mode = if (context.graphics_family_index != context.present_family_index)
        .concurrent
    else
        .exclusive;
    const queue_family_indices = [_]u32{
        context.graphics_family_index,
        context.present_family_index,
    };
    const swapchain = try context.device_fns.createSwapchainKHR(
        context.device,
        &vk.SwapchainCreateInfoKHR{
            .surface = context.surface,
            .min_image_count = min_image_count,
            .image_format = surface_format.format,
            .image_color_space = surface_format.color_space,
            .image_extent = image_extent,
            .image_array_layers = 1,
            .image_usage = vk.ImageUsageFlags{
                .color_attachment_bit = true,
                .transfer_dst_bit = true,
            },
            .image_sharing_mode = image_sharing_mode,
            .queue_family_index_count = queue_family_indices.len,
            .p_queue_family_indices = queue_family_indices.ptr,
            .pre_transform = surface_capabilities.current_transform,
            .composite_alpha = vk.CompositeAlphaFlagsKHR{
                .opaque_bit_khr = true,
            },
            .present_mode = present_mode,
            .clipped = vk.TRUE,
            .old_swapchain = old_swapchain,
        },
        null,
    );

    if (old_swapchain != .null_handle) {
        context.device_fns.destroySwapchainKHR(
            context.device,
            old_swapchain,
            null,
        );
    }

    return swapchain;
}

fn createTargetsAndSemaphore(
    allocator: std.mem.Allocator,
    context: *const Context,
    surface_format: vk.SurfaceFormatKHR,
    swapchain: vk.SwapchainKHR,
) !struct {
    []Target,
    vk.Semaphore,
    u32,
} {
    var swapchain_image_count: u32 = undefined;
    _ = try context.device_fns.getSwapchainImagesKHR(context.device, swapchain, &swapchain_image_count, null);

    const swapchain_images = try allocator.alloc(vk.Image, swapchain_image_count);
    defer allocator.free(swapchain_images);

    _ = try context.device_fns.getSwapchainImagesKHR(
        context.device,
        swapchain,
        &swapchain_image_count,
        swapchain_images.ptr,
    );

    const targets = try allocator.alloc(Target, swapchain_image_count);

    for (swapchain_images, 0..) |image, i| {
        targets[i] = try Target.init(context, image, surface_format.format);
    }

    var wait_semaphore = try context.device_fns.createSemaphore(context.device, &vk.SemaphoreCreateInfo{}, null);
    const result = try context.device_fns.acquireNextImageKHR(
        context.device,
        swapchain,
        timeout,
        wait_semaphore,
        .null_handle,
    );
    std.mem.swap(vk.Semaphore, &targets[result.image_index].wait_semaphore, &wait_semaphore);

    return .{
        targets,
        wait_semaphore,
        result.image_index,
    };
}

fn selectSurfaceFormat(allocator: std.mem.Allocator, context: *const Context) !vk.SurfaceFormatKHR {
    var surface_format_count: u32 = undefined;
    _ = try context.instance_fns.getPhysicalDeviceSurfaceFormatsKHR(
        context.device,
        context.surface,
        &surface_format_count,
        null,
    );

    const surface_formats = allocator.alloc(vk.SurfaceFormatKHR, surface_format_count);
    defer allocator.free(surface_formats);

    _ = try context.instance_fns.getPhysicalDeviceSurfaceFormatsKHR(
        context.device,
        context.surface,
        &surface_format_count,
        surface_formats.ptr,
    );

    for (surface_formats) |face_format| {
        if (face_format.format == .r32g32b32a32_sfloat) {
            return face_format;
        }
    }

    return surface_formats[0];
}

fn selectPresentMode(allocator: std.mem.Allocator, context: *const Context) !vk.PresentModeKHR {
    var present_mode_count: u32 = undefined;
    _ = try context.instance_fns.getPhysicalDeviceSurfacePresentModesKHR(
        context.physical_device,
        context.surface,
        &present_mode_count,
        null,
    );

    const present_modes = try allocator.alloc(vk.PresentModeKHR, present_mode_count);
    defer allocator.free(present_modes);

    _ = try context.instance_fns.getPhysicalDeviceSurfacePresentModesKHR(
        context.physical_device,
        context.surface,
        &present_mode_count,
        present_modes.ptr,
    );

    const preferred = [_]vk.PresentModeKHR{
        .mailbox_khr,
        .immediate_khr,
    };
    for (preferred) |pref| {
        for (present_modes) |mode| {
            if (mode == pref) {
                return mode;
            }
        }
    }

    return .fifo_khr;
}
