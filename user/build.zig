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

    const hello_elf = b.addExecutable(.{
        .name = "hello",
        .root_source_file = b.path("src/hello.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .code_model = .small,
        .link_libc = false,
        .omit_frame_pointer = false,
    });
    hello_elf.setLinkerScript(.{ .src_path = .{ .owner = b, .sub_path = "user.ld" } });
    b.installArtifact(hello_elf);

    const sh_elf = b.addExecutable(.{
        .name = "sh",
        .root_source_file = b.path("src/sh.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .code_model = .small,
        .link_libc = false,
        .omit_frame_pointer = false,
    });
    sh_elf.setLinkerScript(.{ .src_path = .{ .owner = b, .sub_path = "user.ld" } });
    b.installArtifact(sh_elf);

    const ls_elf = b.addExecutable(.{
        .name = "ls",
        .root_source_file = b.path("src/ls.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .code_model = .small,
        .link_libc = false,
        .omit_frame_pointer = false,
    });
    ls_elf.setLinkerScript(.{ .src_path = .{ .owner = b, .sub_path = "user.ld" } });
    b.installArtifact(ls_elf);
}
