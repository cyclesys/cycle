const std = @import("std");
const vk = @import("vulkan");
const shaders = @import("shaders");
const Context = @import("Context.zig");

descriptor_ppol: vk.DescriptorPool,
descriptor_set_layout: vk.DescriptorSetLayout,
descriptor_set: vk.DescriptorSet,

render_pass: vk.RenderPass,

pipeline_layout: vk.PipelineLayout,
pipeline: vk.Pipeline,

pub const Vertex = extern struct {
    pos: Pos,
    idx: u32,

    pub const Pos = [2]u32;
};
const Self = @This();

pub fn init(context: *const Context, format: vk.Format) !Self {
    const descriptor_pool, const descriptor_set_layout, const descriptor_set = try createDescriptorSet(context);
    const render_pass = try createRenderPass(context, format);
    const pipeline_layout, const pipeline = try createPipeline(context, descriptor_set_layout, render_pass);
    return Self{
        .descriptor_pool = descriptor_pool,
        .descriptor_set_layout = descriptor_set_layout,
        .descriptor_set = descriptor_set,
        .render_pass = render_pass,
        .pipeline_layout = pipeline_layout,
        .pipeline = pipeline,
    };
}

pub fn deinit(self: *Self, context: *const Context) void {
    context.device_fns.destroyPipeline(context.device, self.pipeline, null);
    context.device_fns.destroyPipelineLayout(context.device, self.pipeline_layout, null);
    context.device_fns.destroyRenderPass(context.device, self.render_pass, null);
    context.device_fns.freeDescriptorSets(context.device, self.descriptor_pool, 1, &self.descriptor_set);
    context.device_fns.destroyDescriptorSetLayout(context.device, self.descriptor_set_layout, null);
    context.device_fns.destroyDescriptorPool(context.device, self.descriptor_pool, null);
}

fn createDescriptorSet(context: *const Context) !struct {
    vk.DescriptorPool,
    vk.DescriptorSetLayout,
    vk.DescriptorSet,
} {
    const max_descriptor_count = std.math.maxInt(u16);

    const pool_size = vk.DescriptorPoolSize{
        .type = .combined_image_sampler,
        .descriptor_count = max_descriptor_count,
    };
    const pool = try context.device_fns.createDescriptorPool(
        context.device,
        &vk.DescriptorPoolCreateInfo{
            .flags = vk.DescriptorPoolCreateFlags{
                .update_after_bind_bit = true,
            },
            .max_sets = 1,
            .pool_size_count = 1,
            .p_pool_sizes = &pool_size,
        },
        null,
    );

    const binding = vk.DescriptorSetLayoutBinding{
        .binding = 0,
        .descriptor_type = .combined_image_sampler,
        .descriptor_count = max_descriptor_count,
        .stage_flags = .fragment_bit,
    };

    const binding_flags = vk.DescriptorSetLayoutBindingFlagsCreateInfo{
        .binding_count = 1,
        .p_binding_flags = &vk.DescriptorBindingFlags{
            .update_after_bind_bit = true,
            .partially_bound_bit = true,
        },
    };
    const layout = try context.device_fns.createDescriptorSetLayout(
        context.device,
        &vk.DescriptorSetLayoutCreateInfo{
            .p_next = &binding_flags,
            .flags = vk.DescriptorSetLayoutCreateFlags{
                .update_after_bind_pool_bit = true,
            },
            .binding_count = 1,
            .p_bindings = &binding,
        },
        null,
    );

    var set: vk.DescriptorSet = undefined;
    try context.device_fns.allocateDescriptorSets(
        context.device,
        &vk.DescriptorSetAllocateInfo{
            .descriptor_pool = pool,
            .descriptor_set_count = 1,
            .p_set_layouts = &layout,
        },
        &set,
    );

    return .{
        pool,
        layout,
        set,
    };
}

fn createRenderPass(context: *const Context, format: vk.Format) !vk.RenderPass {
    const attachment_desc = vk.AttachmentDescription{
        .format = format,
        .samples = .@"1_bit",
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .read_only_optimal,
    };
    const attachment_ref = vk.AttachmentReference{
        .attachment = 0,
        .layout = .color_attachment_optimal,
    };
    const subpass_desc = vk.SubpassDescription{
        .pipeline_bind_point = .graphics,
        .color_attachment_count = 1,
        .p_color_attachments = &attachment_ref,
    };
    const subpass_dep = vk.SubpassDependency{
        .src_subpass = vk.SUBPASS_EXTERNAL,
        .dst_subpass = 0,
        .src_stage_mask = vk.PipelineStageFlags{
            .early_fragment_tests_bit = true,
            .late_fragmnet_tests_bit = true,
        },
        .dst_stage_mask = vk.PipelineStageFlags{
            .early_fragment_tests_bit = true,
            .late_fragment_tests_bit = true,
        },
        .dst_access_mask = vk.AccessFlags{
            .color_attachment_write_bit = true,
            .color_attachment_read_bit = true,
        },
    };
    return try context.device_fns.createRenderPass(
        context.device,
        &vk.RenderPassCreateInfo{
            .attachment_count = 1,
            .p_attachments = &attachment_desc,
            .subpass_count = 1,
            .p_subpasses = &subpass_desc,
            .dependency_count = 1,
            .p_dependencies = &subpass_dep,
        },
        null,
    );
}

fn createPipeline(context: *const Context, descriptor_set_layout: vk.DescriptorSetLayout, render_pass: vk.RenderPass) !struct {
    vk.PipelineLayout,
    vk.Pipeline,
} {
    const vertex_module = try context.device_fns.createShaderModule(
        context.device,
        &vk.ShaderModuleCreateInfo{
            .code_size = shaders.vertex.len,
            .p_code = @ptrCast(shaders.vertex.ptr),
        },
        null,
    );
    defer context.device_fns.destroyShaderModule(context.device, vertex_module, null);

    const fragment_module = try context.device_fns.createShaderModule(
        context.device,
        &vk.ShaderModuleCreateInfo{
            .code_size = shaders.fragment.len,
            .p_code = @ptrCast(shaders.fragment.ptr),
        },
        null,
    );
    defer context.device_fns.destroyShaderModule(context.device, fragment_module, null);

    const stages = [_]vk.PipelineShaderStageCreateInfo{
        vk.PipelineShaderStageCreateInfo{
            .stage = vk.ShaderStageFlags{ .vertex_bit = true },
            .module = vertex_module,
            .p_name = "main",
        },
        vk.PipelineShaderStageCreateInfo{
            .stage = vk.ShaderStageFlags{ .fragment_bit = true },
            .module = fragment_module,
            .p_name = "main",
        },
    };

    const vertex_binding = vk.VertexInputBindingDescription{
        .binidng = 0,
        .stride = @sizeOf(Vertex),
        .input_rate = .vertex,
    };

    const vertex_attributes = [_]vk.VertexInputAttributeDescription{
        vk.VertexInputAttributeDescription{
            .binding = 0,
            .location = 0,
            .format = .r32g32_uint,
            .offset = @offsetOf(Vertex, "pos"),
        },
        vk.VertexInputAttributeDescription{
            .binding = 0,
            .location = 1,
            .format = .r32_uint,
            .offset = @offsetOf(Vertex, "idx"),
        },
    };

    const dynamic_states = [_]vk.DynamicState{
        .viewport,
        .scissor,
    };

    const stencil_state = vk.StencilOpState{
        .fail_op = .zero,
        .pass_op = .zero,
        .depth_fail_op = .zero,
        .compare_op = .never,
        .compare_mask = 0,
        .write_mask = 0,
        .reference = 0,
    };

    const layout = try context.device_fns.createPipelineLayout(
        context.device,
        &vk.PipelineLayoutCreateInfo{
            .set_layout_count = 1,
            .p_set_layouts = &descriptor_set_layout,
        },
        null,
    );

    const create_info = vk.GraphicsPipelineCreateInfo{
        .stage_count = stages.len,
        .p_stages = &stages,
        .p_vertex_input_state = &vk.PipelineVertexInputStateCreateInfo{
            .vertex_binding_description_count = 1,
            .p_vertex_binding_descriptions = &vertex_binding,
            .vertex_attribute_description_count = vertex_attributes.len,
            .p_vertex_attribute_descriptions = &vertex_attributes,
        },
        .p_input_assembly_state = &vk.PipelineInputAssemblyStateCreateInfo{
            .topology = .triangle_list,
            .primitive_restart_enable = vk.FALSE,
        },
        .p_viewport_state = &vk.PipelineViewportStateCreateInfo{
            .viewport_count = 1,
            .scissor_count = 1,
        },
        .p_rasterization_state = &vk.PipelineRasterizationStateCreateInfo{
            .depth_clamp_enable = vk.FALSE,
            .rasterizer_discard_enable = vk.FALSE,
            .polygon_mode = .fill,
            .front_face = .clockwise,
            .depth_bias_enable = vk.FALSE,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = vk.FALSE,
            .depth_bias_slope_factor = 0,
            .line_width = 1.0,
        },
        .p_multisample_state = &vk.PipelineMultisampleStateCreateInfo{
            .rasterization_samples = .@"1_bit",
            .sample_shading_enable = vk.FALSE,
            .min_sample_shading = 0,
            .alpha_to_coverage_enable = vk.FALSE,
            .alpha_to_one_enable = 0,
        },
        .p_depth_stencil_state = &vk.PipelineDepthStencilStateCreateInfo{
            .depth_test_enable = vk.FALSE,
            .depth_write_enable = vk.FALSE,
            .depth_compare_op = .never,
            .depth_bounds_test_enable = vk.FALSE,
            .stencil_test_enable = vk.FALSE,
            .front = stencil_state,
            .back = stencil_state,
            .min_depth_bounds = 1.0,
            .max_depth_bounds = 1.0,
        },
        .p_color_blend_state = &vk.PipelineColorBlendStateCreateInfo{
            .logic_op_enable = vk.TRUE,
            .logic_op = .clear,
            .blend_constants = [_]f32{ 0.0, 0.0, 0.0, 0.0 },
        },
        .p_dynamic_state = &vk.PipelineDynamicStateCreateInfo{
            .dynamic_state_count = dynamic_states.len,
            .p_dynamic_states = &dynamic_states,
        },
        .layout = layout,
        .render_pass = render_pass,
        .subpass = 0,
    };

    var pipeline: vk.Pipeline = undefined;
    try context.device_fns.createGraphicsPipelines(context.device, .null_handle, 1, &create_info, null, &pipeline);
    return .{
        layout,
        pipeline,
    };
}
