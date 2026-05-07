# zecli

A self-contained Zig library for CLI argument parsing and shell completion generation. Use it as a Zig package dependency and import its public `cli` and `completion` modules.

## Files

- **`src/cli.zig`** — flag/argument parsing, help formatting
- **`src/completion.zig`** — generates bash, zsh, and fish completion scripts

## Usage

```zig
// build.zig
const zecli = b.dependency("zecli", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("cli", zecli.module("cli"));
exe.root_module.addImport("completion", zecli.module("completion"));
```

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
