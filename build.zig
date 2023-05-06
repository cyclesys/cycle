const std = @import("std");
const vkgen = @import("deps/vulkan-zig/generator/index.zig");
const ftgen = @import("deps/mach-freetype/build.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const win32 = b.createModule(.{
        .source_file = .{ .path = "deps/zigwin32/win32.zig" },
    });

    const vulkan_sdk_path = b.env_map.get("VULKAN_SDK");
    if (vulkan_sdk_path == null) {
        return error.VulkanSdkNotSet;
    }
    const vulkan_step = vkgen.VkGenerateStep.create(b, vulkan_sdk_path.?);
    const vulkan = vulkan_step.getModule();

    const freetype = ftgen.module(b);
    // TODO: currently broken
    //const harfbuzz = ftgen.harfbuzzModule(b);

    const lib = b.createModule(.{
        .source_file = .{ .path = "lib/src/lib.zig" },
        .dependencies = &.{
            .{
                .name = "win32",
                .module = win32,
            },
            .{
                .name = "vulkan",
                .module = vulkan,
            },
            .{
                .name = "freetype",
                .module = freetype,
            },
            //.{
            //    .name = "harfbuzz",
            //    .module = harfbuzz,
            //},
        },
    });

    const exe = b.addExecutable(.{
        .name = "cycle",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    ftgen.link(b, exe, .{}); // .{ .harfbuzz = .{} });

    exe.addModule("lib", lib);
    exe.addModule("vulkan", vulkan);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
