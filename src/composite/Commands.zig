const std = @import("std");
const vk = @import("vulkan");
const Context = @import("Context.zig");

allocator: std.mem.Allocator,
pool: vk.CommandPool,
buffers: []const vk.CommandBuffer,
queue: vk.Queue,

const Self = @This();

pub fn init(
    allocator: std.mem.Allocator,
    context: *const Context,
    len: usize,
) !Self {
    const pool = try context.device_fns.createCommandPool(
        context.device,
        &vk.CommandPoolCreateInfo{ .queue_family_index = context.graphics_family_index },
        null,
    );

    const buffers = try allocator.alloc(vk.CommandBuffer, len);
    try context.device_fns.allocateCommandBuffers(
        context.device,
        &vk.CommandBufferAllocateInfo{
            .command_pool = pool,
            .level = .primary,
            .command_buffer_count = buffers.len,
        },
        buffers.ptr,
    );

    const queue = context.device_fns.getDeviceQueue(context.device, context.graphics_family_index, 0);

    return Self{
        .allocator = allocator,
        .pool = pool,
        .buffers = buffers,
        .queue = queue,
    };
}

pub fn deinit(self: Self, context: *const Context) void {
    context.device_fns.freeCommandBuffers(context.device, self.pool, self.buffers.len, self.buffers.ptr);
    self.allocator.free(self.buffers);
    context.device_fns.destroyCommandPool(context.device, self.pool, null);
}

pub fn begin(self: *const Self, context: *const Context, buffer_index: usize) !void {
    try context.device_fns.beginCommandBuffer(
        self.buffers[buffer_index],
        &vk.CommandBufferBeginInfo{
            .flags = vk.CommandBufferUsageFlags{
                .one_time_submit_bit = true,
            },
        },
    );
}

pub fn submit(
    self: *const Self,
    context: *const Context,
    buffer_index: usize,
    wait_semaphore: ?vk.Semaphore,
    wait_stage_mask: ?vk.PipelineStageFlags,
    signal_semaphore: ?vk.Semaphore,
    fence: vk.Fence,
) !void {
    try context.device_fns.endCommandBuffer(self.buffers[buffer_index]);
    try context.device_fns.queueSubmit(
        self.queue,
        1,
        &vk.SubmitInfo{
            .wait_semaphore_count = if (wait_semaphore != null) 1 else 0,
            .p_wait_semaphores = if (wait_semaphore) |ws| &ws else null,
            .pWaitDstStageMask = if (wait_stage_mask) |wsm| &wsm else null,
            .signal_semaphore_count = if (signal_semaphore != null) 1 else 0,
            .p_signal_semaphores = if (signal_semaphore) |ss| &ss else null,
            .command_buffer_count = 1,
            .p_command_buffers = &self.buffers[buffer_index],
        },
        fence,
    );
}

pub fn copyBuffer(
    self: *const Self,
    context: *const Context,
    buffer_index: usize,
    src: vk.Buffer,
    dst: vk.Buffer,
    region: vk.BufferCopy,
) void {
    context.device_fns.cmdCopyBuffer(
        self.buffers[buffer_index],
        src,
        dst,
        1,
        &region,
    );
}

pub fn beginRenderPass(
    self: *const Self,
    context: *const Context,
    buffer_index: usize,
    render_pass: vk.RenderPass,
    framebuffer: vk.Framebuffer,
    width: u32,
    height: u32,
) void {
    context.device_fns.cmdBeginRenderPass(
        self.buffers[buffer_index],
        &vk.RenderPassBeginInfo{
            .render_pass = render_pass,
            .framebuffer = framebuffer,
            .render_area = vk.Rect2D{
                .offset = vk.Offset2D{
                    .x = 0,
                    .y = 0,
                },
                .extent = vk.Extent2D{
                    .width = width,
                    .height = height,
                },
            },
            .clear_value_count = 1,
            .p_clear_values = &vk.ClearValue{
                .color = vk.ClearColorValue{
                    .float_32 = [_]f32{ 0.0, 0.0, 0.0, 0.0 },
                },
            },
        },
        .@"inline",
    );
}

pub fn endRenderPass(self: *const Self, context: *const Context, buffer_index: usize) void {
    context.device_fns.cmdEndRenderPass(self.buffers[buffer_index]);
}

pub fn setViewport(self: *const Self, context: *const Context, buffer_index: usize, width: f32, height: f32) void {
    context.device_fns.cmdSetViewport(
        self.buffers[buffer_index],
        0,
        1,
        &vk.Viewport{
            .x = 0.0,
            .y = 0.0,
            .width = width,
            .height = height,
            .min_depth = 1.0,
            .max_depth = 1.0,
        },
    );
}

pub fn setScissor(self: *const Self, context: *const Context, buffer_index: usize, width: u32, height: u32) void {
    context.device_fns.cmdSetScissor(
        self.buffers[buffer_index],
        0,
        1,
        &vk.Rect2D{
            .offset = vk.Offset2D{
                .x = 0,
                .y = 0,
            },
            .extent = vk.Extent2D{
                .width = width,
                .height = height,
            },
        },
    );
}

pub fn bindDescriptorSet(
    self: *const Self,
    context: *const Context,
    buffer_index: usize,
    layout: vk.PipelineLayout,
    descriptor_set: vk.DescriptorSet,
) void {
    context.device_fns.cmdBindDescriptorSets(
        self.buffers[buffer_index],
        .graphics,
        layout,
        0,
        1,
        &descriptor_set,
        0,
        null,
    );
}

pub fn bindGraphicsPipeline(self: *const Self, context: *const Context, buffer_index: usize, pipeline: vk.Pipeline) void {
    context.device_fns.cmdBindPipeline(
        self.buffers[buffer_index]
            .graphics,
        pipeline,
    );
}

pub fn bindVertexBuffer(self: *const Self, context: *const Context, buffer_index: usize, buffer: vk.Buffer) void {
    const offset: vk.DeviceSize = 0;
    context.device_fns.cmdBindVertexBuffers(
        self.buffers[buffer_index],
        0,
        1,
        &buffer,
        &offset,
    );
}

pub fn bindIndexBuffer(self: *const Self, context: *const Context, buffer_index: usize, buffer: vk.Buffer) void {
    context.device_fns.cmdBindIndexBuffer(
        self.buffers[buffer_index],
        buffer,
        0,
        .uint32,
    );
}

pub fn drawIndexed(self: *const Self, context: *const Context, buffer_index: usize, index_count: u32) void {
    context.device_fns.cmdDrawIndexed(
        self.buffers[buffer_index],
        index_count,
        1,
        0,
        0,
        0,
    );
}
