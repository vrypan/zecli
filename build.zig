const std = @import("std");

pub fn build(b: *std.Build) void {
    const cli_mod = b.addModule("cli", .{
        .root_source_file = b.path("src/cli.zig"),
    });

    const completion_mod = b.addModule("completion", .{
        .root_source_file = b.path("src/completion.zig"),
    });
    completion_mod.addImport("cli", cli_mod);
}
