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

This is the default `.passthrough` behavior for `CommandSpec.double_dash`. Set
it to `.positionals` for a command where `--` should only mark the end of
options, not the start of a wrapped command's argv:

```zig
.{
    .name = "cat",
    .usage = "app cat [options] <REF>...",
    .arguments = &.{.{ .name = "REF", .required = true, .repeatable = true }},
    .double_dash = .positionals,
}
```

With `.positionals`, everything after `--` is combined, in order, with any
positionals given before it, so `app cat -- @42/out` and
`app cat @42/out -- @43/out` both satisfy a required `REF` argument.
`passthrough()` returns `null` and generated completions keep offering
positional candidates across the delimiter instead of stopping at it.

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
omitted. Repeatable options read comma-separated environment values, so
`MY_APP_TAG=fruit,asia` is equivalent to `--tag fruit --tag asia` when `--tag`
is omitted.

For raw access, checked conversions, repeatable values, and the parsed-result
layout, see [Value Resolution](docs/value-resolution.md).

## Help

Call `invocation.printHelpIfRequested(allocator, writer)` once after
initialization. It prints application help for root `--help` and command help
for `--help` after the selected command, including after root options. Help is
generated from the specification, including aliases, choices, defaults, and
repeatable markers.

Help uses uppercase section headings, indented rows, and aligned descriptions.
Long labels move their descriptions onto the following line when there is too
little room beside them. Wrapped help text defaults to at most
`cli.default_help_line_width` (80 columns), or the terminal width if narrower.
Terminal width detection supports Linux and macOS, with an 80-column fallback
for redirected output, unavailable dimensions, and other platforms. No additional
dependencies are required.

To enable automatic terminal styling, wrap your output writer once using the
actual destination file and your process's I/O and environment:

```zig
const help_output = cli.helpWriter(
    writer,
    cli.HelpStyle.auto.detect(init.io, .stdout(), init.environ_map),
);
if (try invocation.printHelpIfRequested(allocator, help_output)) return;
```

Use `.stderr()` instead if that is where the writer sends help. Automatic mode
requires a terminal with ANSI support and a nonempty `TERM` other than `dumb`.
Pipes, files, unknown capabilities, and a nonempty `NO_COLOR` produce plain
text without escape sequences. `HelpStyle.always` and `.never` explicitly
override automatic detection, including `NO_COLOR`. Zecli does not add a color
command-line flag; applications can map their own preference to this policy.

Headings use bold terminal cyan, labels use bold default foreground, and
the opening description and annotations use dim default foreground. A blank line
precedes the description. No RGB values, indexed extended colors,
or background colors are used. Plain output preserves the same layout.
Unwrapped writers default to plain; custom writers may implement
`pub fn helpStyle(self: ...) bool` to supply a resolved styling decision.

Writers exposing a `file: std.Io.File` field use that file's terminal width;
other writers assume stdout for width only. A custom writer can define
`pub fn helpWidth(self: ...) usize` to supply the available width (zero selects
the fallback),
or call `cli.terminalWidth(file)` to query a different output file. The
`helpWriter` adapter preserves this behavior. In-memory writers can return a
fixed width and use `cli.helpWriter(&buffer, true)` for styled snapshots.

To use the full terminal width while keeping word wrapping, set the adapter's
`max_width` to zero. A positive value sets a different cap:

```zig
var help_output = cli.helpWriter(writer, styled);
help_output.max_width = 0;
try cli.printApplicationHelp(allocator, help_output, application);
```

Custom writers can instead implement `pub fn helpMaxWidth(self: ...) usize`;
zero means full available width, and the default cap is 80. When no terminal
width is available, full-width mode still wraps at the 80-column fallback.

Both application and command specifications support structured examples and
custom sections:

```zig
.examples = &.{ "app respond 'Hello'", "app chat" },
.help_sections = &.{.{
    .title = "Models",
    .entries = &.{.{
        .name = "system",
        .description = "On-device model (default)",
    }},
}},
```

Custom sections follow the built-in lists, then examples, then `extra_help`.
Empty sections are omitted. `extra_help` is prose, indented two spaces and
wrapped to the help width, preserving explicit line breaks and blank paragraphs.
It has no automatic heading; use a custom section when a title is useful.
Usage lines, labels, and examples retain their original text and are not wrapped;
caller-authored text should
contain no ANSI escapes if plain output is required. Styling is added separately
from text measurement, so it does not change wrapping or alignment.

## Shell completion

The same `ApplicationSpec` generates all three scripts:

```zig
try completion.generateBash(writer, application);
try completion.generateZsh(writer, application);
try completion.generateFish(writer, application);
```

Generated scripts handle commands, options, aliases, choices, files,
directories, and external completers declared in the specification.

## Release Notes

Generate Markdown release notes from commit subjects:

```sh
scripts/release-notes
scripts/release-notes v0.3.1
scripts/release-notes --range v0.3.0..v0.3.1
```

The `Release` GitHub Actions workflow runs on pushed `v*` tags and creates a
GitHub Release whose notes come from the same script:

```sh
git tag v0.3.1
git push origin v0.3.1
```

You can also run the workflow manually with an existing tag. The workflow uses
the previous reachable tag as the start of the release range. Release creation
fails if `build.zig.zon` does not contain the same version as the tag, without
the leading `v`.
