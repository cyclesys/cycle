const std = @import("std");
const vkz = @import("vulkan_zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "cycle",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const lib_dep = b.dependency("cycle", .{});
    exe.addModule("cycle", lib_dep.module("cycle"));
    @import("cycle").link(lib_dep.builder, exe);

    const glfw_dep = b.dependency("mach_glfw", .{});
    exe.addModule("glfw", glfw_dep.module("mach-glfw"));
    @import("mach_glfw").link(glfw_dep.builder, exe);

    exe.addModule("vulkan", try vulkanModule(b));
    exe.addModule("shaders", shadersModule(b));

    const known_folders_dep = b.dependency("known_folders", .{});
    exe.addModule("known_folders", known_folders_dep.module("known-folders"));

    exe.linkLibC();
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    main_tests.addModule("cycle", lib_dep.module("cycle"));

    const run_main_tests = b.addRunArtifact(main_tests);
    const main_tests_step = b.step("test", "Run main tests");
    main_tests_step.dependOn(&run_main_tests.step);
}

fn vulkanModule(b: *std.Build) !*std.Build.Module {
    const vk_hash = "3dae5d7fbf332970ae0a97d5ab05ae5db93e62f0";
    const vk_file_name = vk_hash ++ "-vk.xml";
    const vk_file_url = "https://raw.githubusercontent.com/KhronosGroup/Vulkan-Docs/" ++
        vk_hash ++ "/xml/vk.xml";

    const vk_file_path = try ensureCachedFile(b.allocator, b.cache_root.path.?, vk_file_name, vk_file_url);

    const vkzig_dep = b.dependency("vulkan_zig", .{
        .registry = vk_file_path,
    });
    return vkzig_dep.module("vulkan-zig");
}

fn shadersModule(b: *std.Build) *std.Build.Module {
    const shader_comp = vkz.ShaderCompileStep.create(
        b,
        &[_][]const u8{"glslc"},
        "-o",
    );
    shader_comp.add("vertex", "src/composite/shaders/vert.glsl", .{
        .args = &[_][]const u8{"-fshader-stage=vertex"},
    });
    shader_comp.add("fragment", "src/composite/shaders/frag.glsl", .{
        .args = &[_][]const u8{"-fshader-stage=fragment"},
    });

    return shader_comp.getModule();
}

fn ensureCachedFile(allocator: std.mem.Allocator, cache_root: []const u8, name: []const u8, url: []const u8) ![]const u8 {
    const path = try std.fs.path.join(allocator, &.{ cache_root, name });
    const file = std.fs.openFileAbsolute(path, .{}) catch |e| {
        switch (e) {
            error.FileNotFound => {
                const result = try std.ChildProcess.exec(.{
                    .allocator = allocator,
                    .argv = &.{ "curl", url, "-o", path },
                });
                allocator.free(result.stdout);
                allocator.free(result.stderr);

                switch (result.term) {
                    .Exited => |code| {
                        if (code != 0) {
                            return error.ExitCodeFailure;
                        }
                    },
                    .Signal, .Stopped, .Unknown => {
                        return error.ProcessTerminated;
                    },
                }

                return path;
            },
            else => {
                return e;
            },
        }
    };
    file.close();
    return path;
}
