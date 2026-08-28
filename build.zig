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

    const test_step = b.step("test", "Run library tests");

    const roots = [_][]const u8{ "src/test.zig", "src/completion_test.zig" };
    for (roots) |root| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
        });
        test_mod.addImport("cli", cli_mod);
        test_mod.addImport("completion", completion_mod);

        const tests = b.addTest(.{ .root_module = test_mod });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
