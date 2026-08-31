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
    .prefix = "MY_APP",
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
const CommandName = cli.CommandEnum(application);

fn run(allocator: std.mem.Allocator, stdout: anytype, stderr: anytype,
       args: []const [:0]const u8, environ: *const std.process.Environ.Map) !u8 {
    var invocation = try cli.Invocation.init(
        allocator,
        stderr,
        application,
        args[1..],
        environ,
    );
    defer invocation.deinit(allocator);

    if (try invocation.printHelpIfRequested(allocator, stdout)) {
        return 0;
    }

    const name = invocation.getValue([]const u8, "name").?;
    const command = invocation.getCommand() orelse return error.MissingCommand;

    switch (try command.as(CommandName)) {
        .greet => return runGreet(name, command),
        .cat => return runCat(command),
    }
}
```

`Invocation.init` prints a diagnostic and returns `error.ReportedCliError` for
an invalid invocation. Its v1 grammar is
`app [root options] <command> [command options]`; root options after the
command are rejected. `getCommand()` returns `null` when no command was given.

`CommandEnum` generates an enum from canonical command names. An alias resolves
to its canonical tag. A command name that is not a Zig identifier is a quoted
tag, such as `CommandName.@"good-morning"`.

Arguments after `--` are preserved separately for pass-through commands:

```zig
const journal = command.positionals()[0];
const child_argv = command.passthrough() orelse &.{};
```

`passthrough()` returns `null` when no separator was supplied. A trailing `--`
returns a non-null empty slice.

### Reading results

```zig
const name = invocation.getValue([]const u8, "name").?;
const times = command.getValue(usize, "times").?;
const color = command.getValue([]const u8, "color").?;
const shout = command.enabled("shout");
```

Defaults are resolved automatically when an option is omitted.

When `ApplicationSpec.prefix` is set, omitted value-taking options also read a
matching environment variable. For example, `--first-name` reads
`MY_APP_FIRST_NAME`. Command-line values take precedence over environment
values, which take precedence over defaults. No-value switches read boolean
environment values, so `MY_APP_SHOUT=true` enables `--shout` when the option is
omitted.

For raw access, checked conversions, repeatable values, and the parsed-result
layout, see [Value Resolution](docs/value-resolution.md).

## Help

Call `invocation.printHelpIfRequested(allocator, writer)` once after
initialization. It prints application help for root `--help` and command help
for `--help` after the selected command, including after root options. Help is
generated from the specification, including aliases, choices, defaults, and
repeatable markers.

## Shell completion

The same `ApplicationSpec` generates all three scripts:

```zig
try completion.generateBash(writer, application);
try completion.generateZsh(writer, application);
try completion.generateFish(writer, application);
```

Generated scripts handle commands, options, aliases, choices, files,
directories, and external completers declared in the specification.
