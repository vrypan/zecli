const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cli_mod = b.addModule("cli", .{
        .root_source_file = b.path("src/cli.zig"),
    });

    const completion_mod = b.addModule("completion", .{
        .root_source_file = b.path("src/completion.zig"),
    });
    completion_mod.addImport("cli", cli_mod);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("cli", cli_mod);

    const tests = b.addTest(.{ .root_module = test_mod });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);
}
