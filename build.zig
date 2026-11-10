const std = @import("std");

/// targets the library must build for; `zig build targets` checks each
const portable_targets = [_][]const u8{
    "x86_64-linux-none",
    "aarch64-linux-none",
    "arm-linux-none",
    "riscv64-linux-none",
    "s390x-linux-none",
    "x86_64-windows-none",
    "aarch64-windows-none",
    "aarch64-macos-none",
    "x86_64-macos-none",
    "x86_64-freebsd-none",
    "wasm32-freestanding-none",
    "wasm32-wasi-none",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pmdeflate = b.addModule("pmdeflate", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit = b.addTest(.{ .root_module = pmdeflate });
    const test_step = b.step("test", "RFC 7692 vectors and unit tests");
    test_step.dependOn(&b.addRunArtifact(unit).step);

    const targets_step = b.step("targets", "build the library for every portable target, wasm included");
    for (portable_targets) |triple| {
        const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch unreachable;
        const lib = b.addLibrary(.{
            .name = "pmdeflate",
            .linkage = .static,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/exports.zig"),
                .target = b.resolveTargetQuery(query),
                .optimize = .ReleaseSmall,
                .imports = &.{.{ .name = "pmdeflate", .module = b.createModule(.{ .root_source_file = b.path("src/root.zig") }) }},
            }),
        });
        targets_step.dependOn(&lib.step);
    }
}
