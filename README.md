# zecli

`zecli` is a small, self-contained Zig library for command-line argument
parsing, help formatting, and shell completion generation. You describe your
program once as an `ApplicationSpec`, and that single value drives parsing,
canonical command and option lookup, `--help` output, and generated bash, zsh,
and fish completions.

Requires Zig `0.16.0`.

## Installation

```sh
zig fetch --save=zecli git+https://github.com/vrypan/zecli.git
```

```zig
// build.zig
const zecli = b.dependency("zecli", .{});

exe.root_module.addImport("cli", zecli.module("cli"));
exe.root_module.addImport("completion", zecli.module("completion"));
```

## Define a CLI

Describe your program with `ApplicationSpec`. It supports one level of
subcommands.

```zig
const greet_flags = [_]cli.FlagSpec{
    .{ .name = "name", .short = 'n', .value = .string, .value_name = "TEXT",
       .description = "Name to greet", .default_value = "world" },
    .{ .name = "color", .aliases = &.{"colour"}, .value = .string, .value_name = "WHEN",
       .description = "Colorize the greeting", .default_value = "auto",
       .choices = &.{ "auto", "always", "never" } },
};

const application = cli.ApplicationSpec{
    .name = "zecli-example",
    .description = "Small example program using zecli.",
    .usage = "zecli-example [options] <command>",
    .flags = &root_flags,
    .commands = &commands,
};
```

Use `comptimeValidated` to turn specification mistakes into build errors:

```zig
const application = cli.comptimeValidated(.{
    .name = "demo",
    .description = "A demo",
    .usage = "demo [options] <command>",
    .commands = &commands,
});
```

The full example is in [`example/src/main.zig`](example/src/main.zig).

## Parsing

```zig
fn run(allocator: std.mem.Allocator, stdout: anytype, stderr: anytype,
       args: []const [:0]const u8) !u8 {
    if (args.len <= 1 or cli.helpRequested(args[1..2])) {
        try cli.printApplicationHelp(allocator, stdout, application);
        return 0;
    }

    // Canonical lookup resolves aliases; dispatch stays your job.
    const command = cli.findCommand(application, args[1]) orelse {
        try stderr.print("error: unknown command '{s}'\n", .{args[1]});
        return 1;
    };

    const rest = args[2..];
    if (cli.helpRequested(rest)) {
        try cli.printCommandHelp(allocator, stdout, command);
        return 0;
    }

    const parsed = try cli.parseCommand(allocator, stderr, rest, command);
    const name = parsed.getValue([]const u8, "name").?; // "world" when --name was omitted
    ...
}
```

`parseCommand` prints a diagnostic and returns `error.ReportedCliError` when the
command line is invalid, so a caller only has to map that error to a non-zero
exit status. The lower-level `parse` reports `error.InvalidArgument` without
printing anything.

### Reading results

```zig
const name = parsed.getValue([]const u8, "name").?;
const times = parsed.getValue(usize, "times").?;
const color = parsed.getValue([]const u8, "color").?;
```

Defaults are resolved automatically when an option is omitted.

For raw access, checked conversions, repeatable values, and the parsed-result
layout, see [Value Resolution](docs/value-resolution.md).

## Help

`printApplicationHelp` and `printCommandHelp` are generated entirely from the
specification, including aliases, choices, defaults, and repeatable markers.

## Shell completion

The same `ApplicationSpec` generates all three scripts:

```zig
try completion.generateBash(writer, application);
try completion.generateZsh(writer, application);
try completion.generateFish(writer, application);
```

Generated scripts handle commands, options, aliases, choices, files,
directories, and external completers declared in the specification.
