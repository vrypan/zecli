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

// ── The application specification ────────────────────────────────────────────
//
// One value describes the whole CLI. Help, canonical lookup, parsing, and all
// three completion generators read from it.

const root_flags = [_]cli.FlagSpec{
    .{
        .name = "home",
        .value = .string,
        .value_name = "DIR",
        .description = "Directory to work in",
        .completion = .directories,
    },
    .{ .name = "version", .short = 'V', .description = "Print version" },
};

const greet_flags = [_]cli.FlagSpec{
    .{
        .name = "name",
        .short = 'n',
        .value = .string,
        .value_name = "TEXT",
        .description = "Name to greet",
        .default_value = "world",
    },
    .{
        .name = "times",
        .short = 't',
        .value = .int,
        .value_name = "N",
        .description = "Number of greetings to print",
        .default_value = "1",
        .attached_short_value = true,
    },
    .{ .name = "shout", .short = 's', .description = "Uppercase the greeting" },
    .{
        // A required value with a fixed set of choices, reachable through a
        // long alias: --color, --colour, --color=always, --colour never.
        .name = "color",
        .aliases = &.{"colour"},
        .value = .string,
        .value_name = "WHEN",
        .description = "Colorize the greeting",
        .default_value = "auto",
        .choices = &.{ "auto", "always", "never" },
    },
};

const cat_flags = [_]cli.FlagSpec{
    .{
        // Candidates come from `zecli-example complete <prefix>`: zecli invokes
        // the program directly and reads one candidate per line.
        .name = "ref",
        .value = .string,
        .value_name = "REF",
        .description = "Reference to resolve",
        .completion = .{ .external = .{
            .executable = "zecli-example",
            .arguments = &.{"complete"},
        } },
    },
};

const cat_arguments = [_]cli.ArgumentSpec{
    .{
        .name = "FILE",
        .description = "File to print",
        .required = true,
        .repeatable = true,
        .completion = .files,
    },
};

const complete_arguments = [_]cli.ArgumentSpec{
    .{ .name = "PREFIX", .description = "Prefix to complete" },
};

const completion_arguments = [_]cli.ArgumentSpec{
    .{
        .name = "SHELL",
        .description = "Shell to generate completions for",
        .required = true,
        .completion = .{ .values = &.{ "bash", "zsh", "fish" } },
    },
};

const commands = [_]cli.CommandSpec{
    .{
        .name = "greet",
        .aliases = &.{"hi"},
        .description = "Print a configurable greeting",
        .usage = "zecli-example greet [options]",
        .flags = &greet_flags,
    },
    .{
        .name = "cat",
        .aliases = &.{"show"},
        .description = "Print one or more files",
        .usage = "zecli-example cat [options] <FILE>...",
        .flags = &cat_flags,
        .arguments = &cat_arguments,
    },
    .{
        .name = "complete",
        .description = "Print completion candidates for a prefix",
        .usage = "zecli-example complete [PREFIX]",
        .arguments = &complete_arguments,
    },
    .{
        .name = "completion",
        .description = "Generate a shell completion script",
        .usage = "zecli-example completion <SHELL>",
        .arguments = &completion_arguments,
    },
};

// Specification mistakes are build errors rather than runtime surprises, and
// the validation never reaches the binary.
const application = cli.comptimeValidated(.{
    .name = "zecli-example",
    .description = "Small example program using zecli.",
    .usage = "zecli-example [options] <command>",
    .flags = &root_flags,
    .commands = &commands,
});

// Candidates the external completer offers, including one containing a space
// to show that a candidate is never split.
const demo_references = [_][]const u8{ "@1/out", "@2/out", "@42/out", "note with space" };

pub fn main(init: std.process.Init) !void {
    process_io = init.io;
    // Everything parsed borrows from argv and from the specification, and the
    // arena is released when the process exits. `parsed.deinit(allocator)` is
    // only needed by callers that reuse a general-purpose allocator; runCat
    // below shows that form.
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

fn run(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    args: []const [:0]const u8,
) !u8 {
    if (args.len <= 1 or cli.helpRequested(args[1..2])) {
        try cli.printApplicationHelp(allocator, stdout, application);
        return 0;
    }
    if (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-V")) {
        try stdout.writeAll("zecli-example 0.2.0\n");
        return 0;
    }

    // Canonical lookup resolves aliases; dispatch stays the caller's job.
    const command = cli.findCommand(application, args[1]) orelse {
        try stderr.print("error: unknown command '{s}'\n\n", .{args[1]});
        try cli.printApplicationHelp(allocator, stderr, application);
        return 1;
    };

    const rest = args[2..];
    if (cli.helpRequested(rest)) {
        try cli.printCommandHelp(allocator, stdout, command);
        return 0;
    }

    if (std.mem.eql(u8, command.name, "greet")) return runGreet(allocator, stdout, stderr, command, rest);
    if (std.mem.eql(u8, command.name, "cat")) return runCat(allocator, stdout, stderr, command, rest);
    if (std.mem.eql(u8, command.name, "complete")) return runComplete(allocator, stdout, stderr, command, rest);
    return runCompletion(allocator, stdout, stderr, command, rest);
}

fn runGreet(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    spec: cli.CommandSpec,
    args: []const [:0]const u8,
) !u8 {
    const parsed = try cli.parseCommand(allocator, stderr, args, spec);

    // --colour always is recorded under the canonical name "color".
    const color = parsed.last("color").?;
    const shout = parsed.present("shout") or std.mem.eql(u8, color, "always");

    const name = parsed.last("name").?;
    const times = try std.fmt.parseInt(usize, parsed.last("times").?, 10);

    var i: usize = 0;
    while (i < times) : (i += 1) {
        if (shout) {
            try stdout.writeAll("HELLO, ");
            for (name) |char| try stdout.writeByte(std.ascii.toUpper(char));
            try stdout.writeAll("!\n");
        } else {
            try stdout.print("Hello, {s}!\n", .{name});
        }
    }
    return 0;
}

fn runCat(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    spec: cli.CommandSpec,
    args: []const [:0]const u8,
) !u8 {
    var parsed = try cli.parseCommand(allocator, stderr, args, spec);
    // Not required here, since main uses an arena, but this is the form a
    // caller with a general-purpose allocator would use.
    defer parsed.deinit(allocator);

    if (parsed.last("ref")) |ref| try stdout.print("ref: {s}\n", .{ref});
    for (parsed.positionals.items) |path| try stdout.print("file: {s}\n", .{path});
    return 0;
}

fn runComplete(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    spec: cli.CommandSpec,
    args: []const [:0]const u8,
) !u8 {
    const parsed = try cli.parseCommand(allocator, stderr, args, spec);
    const prefix = if (parsed.positionals.items.len > 0) parsed.positionals.items[0] else "";

    // One candidate per line on stdout is the whole external-completer contract.
    for (demo_references) |reference| {
        if (std.mem.startsWith(u8, reference, prefix)) {
            try stdout.print("{s}\n", .{reference});
        }
    }
    return 0;
}

fn runCompletion(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    spec: cli.CommandSpec,
    args: []const [:0]const u8,
) !u8 {
    const parsed = try cli.parseCommand(allocator, stderr, args, spec);
    const shell = parsed.positionals.items[0];

    if (std.mem.eql(u8, shell, "bash")) {
        try completion.generateBash(stdout, application);
    } else if (std.mem.eql(u8, shell, "zsh")) {
        try completion.generateZsh(stdout, application);
    } else if (std.mem.eql(u8, shell, "fish")) {
        try completion.generateFish(stdout, application);
    } else {
        try stderr.print("error: unsupported shell '{s}'; expected bash, zsh, or fish\n", .{shell});
        return 1;
    }
    return 0;
}
