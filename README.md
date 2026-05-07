# zecli

`ZeCli` is a self-contained Zig library for CLI argument parsing and shell completion generation. Use it as a Zig package dependency and import its public `cli` and `completion` modules.

The implementation is based on the CLI parsing code from [agent-specs](https://github.com/vrypan/agent-specs).

## Files

- **`src/cli.zig`** — flag/argument parsing, help formatting
- **`src/completion.zig`** — generates bash, zsh, and fish completion scripts

## Usage

Add the package to your project:

```sh
zig fetch --save=zecli git+https://github.com/vrypan/zecli.git
```

Import the modules from your `build.zig`:

```zig
// build.zig
const zecli = b.dependency("zecli", .{});

exe.root_module.addImport("cli", zecli.module("cli"));
exe.root_module.addImport("completion", zecli.module("completion"));
```

Define command specs and parse arguments:

```zig
const std = @import("std");
const cli = @import("cli");

const flags = [_]cli.FlagSpec{
    .{ .name = "name", .short = 'n', .value = .string, .value_name = "TEXT", .default_value = "world" },
    .{ .name = "times", .short = 't', .value = .int, .value_name = "N", .default_value = "1" },
    .{ .name = "shout", .short = 's' },
};

const spec = cli.CommandSpec{
    .name = "greet",
    .description = "Print a greeting.",
    .usage = "mytool greet [options]",
    .flags = &flags,
};

pub fn run(allocator: std.mem.Allocator, stderr: anytype, args: []const [:0]const u8) !void {
    const parsed = try cli.parseCommand(allocator, stderr, args, spec);

    const name = parsed.last("name") orelse "world";
    const times = try std.fmt.parseInt(usize, parsed.last("times") orelse "1", 10);
    const shout = parsed.present("shout");

    _ = name;
    _ = times;
    _ = shout;
}
```

Generate shell completions from the same specs:

```zig
// your_completion_main.zig
const cli = @import("cli");
const completion = @import("completion");

const spec = completion.CompletionSpec{
    .command = "mytool",
    .commands = &commands,       // []const cli.CommandEntry
    .root = root_spec,           // cli.CommandSpec
    .subcommands = &subcommands, // []const cli.CommandSpec
};

try completion.generateBash(writer, spec);
try completion.generateZsh(writer, spec);
try completion.generateFish(writer, spec);
```
