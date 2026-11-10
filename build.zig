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

    // zlib is the reference implementation for differential tests and the
    // baseline for benchmarks. only those steps fetch and compile it.
    const differential_step = b.step("differential", "round-trip against zlib in both directions");
    if (b.lazyDependency("zlib", .{})) |zlib_src| {
        const zlib = zlibModule(b, zlib_src, target, optimize);
        const differential = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("test/differential.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pmdeflate", .module = pmdeflate },
                .{ .name = "zlib", .module = zlib },
                .{ .name = "corpus", .module = b.createModule(.{ .root_source_file = b.path("test/corpus.zig") }) },
            },
        }) });
        differential_step.dependOn(&b.addRunArtifact(differential).step);
    }
}

fn zlibModule(b: *std.Build, src: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const c = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    c.addIncludePath(src.path("."));
    c.addCSourceFiles(.{
        .root = src.path("."),
        .files = &.{ "adler32.c", "crc32.c", "deflate.c", "inffast.c", "inflate.c", "inftrees.c", "trees.c", "zutil.c" },
    });
    const module = b.createModule(.{
        .root_source_file = b.path("test/zlib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.linkLibrary(b.addLibrary(.{ .name = "z", .root_module = c }));
    return module;
}
