const std = @import("std");
const vkgen = @import("deps/vulkan-zig/generator/index.zig");
const ftgen = @import("deps/mach-freetype/build.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const windows = b.createModule(.{
        .source_file = .{ .path = "windows.zig" },
    });

    const vulkan_sdk_path = b.env_map.get("VULKAN_SDK");
    if (vulkan_sdk_path == null) {
        return error.VulkanSdkNotSet;
    }
    const vulkan_step = vkgen.VkGenerateStep.create(b, vulkan_sdk_path.?);
    const vulkan = vulkan_step.getModule();

    const freetype = ftgen.module(b);
    const harfbuzz = ftgen.harfbuzzModule(b);

    const known_folders = b.createModule(.{
        .source_file = .{ .path = "deps/known-folders/known-folders.zig" },
    });

    const lib = b.createModule(.{
        .source_file = .{ .path = "lib/src/lib.zig" },
        .dependencies = &.{
            .{
                .name = "windows",
                .module = windows,
            },
            .{
                .name = "vulkan",
                .module = vulkan,
            },
            .{
                .name = "freetype",
                .module = freetype,
            },
            .{
                .name = "harfbuzz",
                .module = harfbuzz,
            },
            .{
                .name = "known_folders",
                .module = known_folders,
            },
        },
    });

    const exe = b.addExecutable(.{
        .name = "cycle",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    ftgen.link(b, exe, .{ .harfbuzz = .{} });

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

    const lib_tests = b.addTest(.{
        .root_source_file = .{ .path = "lib/src/lib.zig" },
        .target = target,
        .optimize = optimize,
    });

    lib_tests.addModule("windows", windows);
    lib_tests.addModule("freetype", freetype);
    lib_tests.addModule("harfbuzz", harfbuzz);
    lib_tests.addModule("known_folders", known_folders);

    const run_lib_tests = b.addRunArtifact(lib_tests);
    const lib_test_step = b.step("test_lib", "Run lib tests");
    lib_test_step.dependOn(&run_lib_tests.step);
}
