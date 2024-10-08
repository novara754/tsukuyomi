const std = @import("std");

pub fn build(b: *std.Build) void {
    var cpu_features_sub = std.Target.Cpu.Feature.Set.empty;
    cpu_features_sub.addFeature(@intFromEnum(std.Target.x86.Feature.mmx));
    cpu_features_sub.addFeature(@intFromEnum(std.Target.x86.Feature.sse));
    cpu_features_sub.addFeature(@intFromEnum(std.Target.x86.Feature.sse2));
    cpu_features_sub.addFeature(@intFromEnum(std.Target.x86.Feature.sse3));
    cpu_features_sub.addFeature(@intFromEnum(std.Target.x86.Feature.ssse3));
    cpu_features_sub.addFeature(@intFromEnum(std.Target.x86.Feature.sse4_1));
    cpu_features_sub.addFeature(@intFromEnum(std.Target.x86.Feature.sse4_2));
    cpu_features_sub.addFeature(@intFromEnum(std.Target.x86.Feature.avx));
    cpu_features_sub.addFeature(@intFromEnum(std.Target.x86.Feature.avx2));

    var cpu_features_add = std.Target.Cpu.Feature.Set.empty;
    cpu_features_add.addFeature(@intFromEnum(std.Target.x86.Feature.soft_float));

    const target = b.standardTargetOptions(.{ .default_target = .{
        .abi = .none,
        .cpu_arch = .x86_64,
        .cpu_features_add = cpu_features_add,
        .cpu_features_sub = cpu_features_sub,
        .ofmt = .elf,
        .os_tag = .freestanding,
    } });

    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .Debug });

    // const kernel_lib = b.addStaticLibrary(.{
    //     .name = "tsukuyomi-lib",
    //     .root_source_file = b.path("src/lib.zig"),
    //     .target = target,
    //     .optimize = optimize,
    //     .code_model = .kernel,
    //     .link_libc = false,
    // });
    // kernel_lib.setLinkerScript(.{ .src_path = .{ .owner = b, .sub_path = "kernel_lib.ld" } });
    // kernel_lib.addAssemblyFile(.{ .src_path = .{ .owner = b, .sub_path = "src/load_gdt.s" } });
    // kernel_lib.addAssemblyFile(.{ .src_path = .{ .owner = b, .sub_path = "src/interrupts/traps.s" } });
    // kernel_lib.addAssemblyFile(.{ .src_path = .{ .owner = b, .sub_path = "src/interrupts/handle_trap.s" } });
    // kernel_lib.addAssemblyFile(.{ .src_path = .{ .owner = b, .sub_path = "src/switch_context.s" } });
    // b.installArtifact(kernel_lib);

    const kernel = b.addExecutable(.{
        .name = "tsukuyomi",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .kernel,
        .link_libc = false,
    });
    kernel.setLinkerScript(.{ .src_path = .{ .owner = b, .sub_path = "kernel.ld" } });
    kernel.addAssemblyFile(.{ .src_path = .{ .owner = b, .sub_path = "src/load_gdt.s" } });
    kernel.addAssemblyFile(.{ .src_path = .{ .owner = b, .sub_path = "src/interrupts/traps.s" } });
    kernel.addAssemblyFile(.{ .src_path = .{ .owner = b, .sub_path = "src/interrupts/handle_trap.s" } });
    kernel.addAssemblyFile(.{ .src_path = .{ .owner = b, .sub_path = "src/switch_context.s" } });
    b.installArtifact(kernel);

    const kernel_lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_kernel_lib_unit_tests = b.addRunArtifact(kernel_lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_kernel_lib_unit_tests.step);
}
