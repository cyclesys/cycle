const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "cycle",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addIncludePath(.{ .path = "src/ui/render" });
    exe.addCSourceFiles(.{
        .files = &.{
            "src/ui/render/context.cc",
            "src/ui/render/internal.cc",
            "src/ui/render/object.cc",
            "src/ui/render/text.cc",
            "src/ui/render/window.cc",
        },
        .flags = &.{
            "-std=c++17",
            "-O3",
            "-Wall",
            "-Wextra",
        },
    });
    exe.linkLibC();
    exe.linkLibCpp();
    exe.linkSystemLibrary("d2d1");
    exe.linkSystemLibrary("dwrite");

    exe.root_module.addImport("glfw", b.dependency("mach_glfw", .{
        .target = target,
        .optimize = optimize,
    }).module("mach-glfw"));

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

    const run_main_tests = b.addRunArtifact(main_tests);
    const main_tests_step = b.step("test", "Run main tests");
    main_tests_step.dependOn(&run_main_tests.step);
}
