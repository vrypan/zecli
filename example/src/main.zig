const std = @import("std");
const cli = @import("cli");
const completion = @import("completion");

var process_io: std.Io = undefined;

const FileWriter = struct {
    file: std.Io.File,

    pub fn writeAll(self: FileWriter, data: []const u8) !void {
        try self.file.writeStreamingAll(process_io, data);
    }

    pub fn writeByte(self: FileWriter, byte: u8) !void {
        try self.writeAll(&.{byte});
    }

    pub fn print(self: FileWriter, comptime fmt: []const u8, args: anytype) !void {
        var sfb = std.heap.stackFallback(4096, std.heap.page_allocator);
        const allocator = sfb.get();
        const data = try std.fmt.allocPrint(allocator, fmt, args);
        defer allocator.free(data);
        try self.writeAll(data);
    }
};

const root_flags = [_]cli.FlagSpec{
    .{ .name = "version", .short = 'V', .description = "Print version" },
};

const greet_flags = [_]cli.FlagSpec{
    .{ .name = "name", .short = 'n', .value = .string, .value_name = "TEXT", .description = "Name to greet", .default_value = "world" },
    .{ .name = "times", .short = 't', .value = .int, .value_name = "N", .description = "Number of greetings to print", .default_value = "1", .attached_short_value = true },
    .{ .name = "shout", .short = 's', .description = "Uppercase the greeting" },
};

const completion_arguments = [_]cli.ArgumentSpec{
    .{ .name = "SHELL", .description = "Shell to generate completions for: bash, zsh, or fish", .required = true },
};

const commands = [_]cli.CommandEntry{
    .{ .name = "completion", .description = "Generate shell completions" },
    .{ .name = "greet", .description = "Print a configurable greeting" },
};

const root_spec = cli.CommandSpec{
    .name = "zecli-example",
    .description = "Small example program using zecli.",
    .usage = "zecli-example [options] <command>",
    .flags = &root_flags,
};

const greet_spec = cli.CommandSpec{
    .name = "greet",
    .description = "Print a greeting.",
    .usage = "zecli-example greet [options]",
    .flags = &greet_flags,
};

const completion_spec = cli.CommandSpec{
    .name = "completion",
    .description = "Generate a completion script.",
    .usage = "zecli-example completion SHELL",
    .arguments = &completion_arguments,
};

const completion_generation_spec = completion.CompletionSpec{
    .command = "zecli-example",
    .commands = &commands,
    .root = root_spec,
    .subcommands = &.{ greet_spec, completion_spec },
};

pub fn main(init: std.process.Init) !void {
    process_io = init.io;
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    const stdout = FileWriter{ .file = .stdout() };
    const stderr = FileWriter{ .file = .stderr() };

    const exit_code = run(allocator, stdout, stderr, args) catch |err| {
        if (err == error.ReportedCliError) return std.process.exit(1);
        try stderr.print("error: {s}\n", .{@errorName(err)});
        return std.process.exit(1);
    };
    if (exit_code != 0) std.process.exit(exit_code);
}

fn run(allocator: std.mem.Allocator, stdout: anytype, stderr: anytype, args: []const [:0]const u8) !u8 {
    if (args.len <= 1 or isHelp(args[1])) {
        try printRootHelp(allocator, stdout);
        return 0;
    }
    if (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-V")) {
        try stdout.writeAll("zecli-example 0.1.0\n");
        return 0;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "greet")) {
        if (args.len > 2 and isHelp(args[2])) {
            try cli.printCommandHelp(allocator, stdout, greet_spec);
            return 0;
        }
        return try runGreet(allocator, stdout, stderr, args[2..]);
    }
    if (std.mem.eql(u8, command, "completion")) {
        if (args.len > 2 and isHelp(args[2])) {
            try cli.printCommandHelp(allocator, stdout, completion_spec);
            return 0;
        }
        return try runCompletion(allocator, stdout, stderr, args[2..]);
    }

    try stderr.print("error: unknown command '{s}'\n\n", .{command});
    try printRootHelp(allocator, stderr);
    return 1;
}

fn runGreet(allocator: std.mem.Allocator, stdout: anytype, stderr: anytype, raw_args: []const [:0]const u8) !u8 {
    const parsed = try cli.parseCommand(allocator, stderr, raw_args, greet_spec);

    const name = parsed.last("name") orelse "world";
    const times_text = parsed.last("times") orelse "1";
    const times = try std.fmt.parseInt(usize, times_text, 10);

    var i: usize = 0;
    while (i < times) : (i += 1) {
        if (parsed.present("shout")) {
            try stdout.writeAll("HELLO, ");
            try writeUpper(stdout, name);
            try stdout.writeAll("!\n");
        } else {
            try stdout.print("Hello, {s}!\n", .{name});
        }
    }
    return 0;
}

fn runCompletion(allocator: std.mem.Allocator, stdout: anytype, stderr: anytype, raw_args: []const [:0]const u8) !u8 {
    const parsed = try cli.parseCommand(allocator, stderr, raw_args, completion_spec);
    const shell = parsed.positionals.items[0];

    if (std.mem.eql(u8, shell, "bash")) {
        try completion.generateBash(stdout, completion_generation_spec);
    } else if (std.mem.eql(u8, shell, "zsh")) {
        try completion.generateZsh(stdout, completion_generation_spec);
    } else if (std.mem.eql(u8, shell, "fish")) {
        try completion.generateFish(stdout, completion_generation_spec);
    } else {
        try stderr.print("error: unsupported shell '{s}'; expected bash, zsh, or fish\n", .{shell});
        return 1;
    }
    return 0;
}

fn printRootHelp(allocator: std.mem.Allocator, writer: anytype) !void {
    try writer.print("{s}\n\nUsage: {s}\n", .{ root_spec.description, root_spec.usage });
    try cli.printCommandList(writer, &commands);
    try cli.printOptions(allocator, writer, root_spec.flags, true);
}

fn isHelp(value: []const u8) bool {
    return std.mem.eql(u8, value, "--help") or std.mem.eql(u8, value, "-h");
}

fn writeUpper(writer: anytype, value: []const u8) !void {
    for (value) |char| try writer.writeByte(std.ascii.toUpper(char));
}
