# zecli

`zecli` is a small, self-contained Zig library for command-line argument
parsing, help formatting, and shell completion generation. You describe your
program once as an `ApplicationSpec`, and that single value drives parsing,
canonical command and option lookup, `--help` output, and generated bash, zsh,
and fish completions.

The implementation is based on the CLI parsing code from
[agent-specs](https://github.com/vrypan/agent-specs).

- **`src/cli.zig`** — specifications, validation, parsing, help formatting
- **`src/completion.zig`** — bash, zsh, and fish completion generators

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

## The application specification

One value describes the whole program. `zecli` supports exactly one level of
subcommands.

```zig
pub const ApplicationSpec = struct {
    name: []const u8,
    description: []const u8,
    usage: []const u8,
    flags: []const FlagSpec = &.{},
    commands: []const CommandSpec = &.{},
    extra_help: ?[]const u8 = null,
};

pub const CommandSpec = struct {
    name: []const u8,
    aliases: []const []const u8 = &.{},
    description: []const u8,
    usage: []const u8,
    flags: []const FlagSpec = &.{},
    arguments: []const ArgumentSpec = &.{},
    extra_help: ?[]const u8 = null,
};

pub const FlagSpec = struct {
    name: []const u8,
    aliases: []const []const u8 = &.{},
    short: ?u8 = null,
    value: ValueKind = .none,          // .none, .string, .int, .bool_required, .bool_optional
    value_name: ?[]const u8 = null,
    description: []const u8 = "",
    default_value: ?[]const u8 = null,
    repeatable: bool = false,
    attached_short_value: bool = false,
    choices: []const []const u8 = &.{},
    completion: CompletionKind = .none,
};

pub const ArgumentSpec = struct {
    name: []const u8,
    description: []const u8 = "",
    required: bool = false,
    repeatable: bool = false,
    completion: CompletionKind = .none,
};
```

A worked example lives in [`example/src/main.zig`](example/src/main.zig); the
snippets below are taken from it.

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

### Validating a specification

`validateApplicationSpec` and `validateCommandSpec` reject malformed
specifications: invalid or duplicate names, aliases equal to their canonical
name, duplicate short options, a required positional after an optional one, a
repeatable positional that is not last, choices on an option that takes no
value, a default value outside the declared choices, and choices combined with
an explicit completion kind.

Command and long-option names must start with an ASCII alphanumeric and may
then contain ASCII alphanumerics or `-`; short options are a single ASCII
alphanumeric. This grammar is what makes generated completions safe in all
three shells. Descriptions, usage text, value names, and completion values are
arbitrary UTF-8 and are quoted by the generators.

`comptimeValidated` runs that check at compile time and returns the
specification unchanged, so a mistake is a build error and the validation code
never reaches the binary:

```zig
const application = cli.comptimeValidated(.{
    .name = "demo",
    .description = "A demo",
    .usage = "demo [options] <command>",
    .commands = &commands,
});
```

A duplicate command name then fails the build with
`invalid ApplicationSpec 'demo': DuplicateName`, pointing at the declaration.
Every field must be comptime-known; a specification assembled at runtime calls
`validateApplicationSpec` directly instead.

Validation compares every pair of names in a scope, so it can exceed Zig's
default limit of 1000 backwards branches. `comptimeValidated` raises the limit
to a bound computed from the specification, so no call site needs
`@setEvalBranchQuota`. Because `@setEvalBranchQuota` only ever raises the
limit, a caller that has already asked for more keeps it.

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
    const name = parsed.last("name").?; // "world" when --name was omitted
    ...
}
```

`parseCommand` prints a diagnostic and returns `error.ReportedCliError` when the
command line is invalid, so a caller only has to map that error to a non-zero
exit status. The lower-level `parse` reports `error.InvalidArgument` without
printing anything.

### Rules

- **Aliases.** `findCommand` and `findFlag` accept a canonical name or an alias
  and return the canonical specification. A value typed as `--colour never` is
  always recorded under the canonical name `color`.
- **Required values.** An option declaring a value accepts both
  `--color always` and `--color=always`. A bare `--color` at the end of the
  command line is a missing-value error.
- **Choices.** When `choices` is set, any other value is rejected with a
  diagnostic naming the option, the invalid value, and the allowed values. The
  same list drives help output and shell value completion.
- **Short options.** A short option takes its value as the next word. An
  attached value such as `-t42` is only accepted when the option opts in with
  `attached_short_value`. Short option clusters are not supported.
- **Repetition.** A `repeatable` option keeps every occurrence in
  `parsed.flags`; `parsed.last(name)` returns the final one. A non-repeatable
  option keeps only the last value.
- **`--`.** Every token after the first `--` is positional, including tokens
  beginning with `-` and the literal `--help`.
- **Help.** `helpRequested` stops scanning at `--`, so `mytool run -- cmd --help`
  asks the wrapped command for help, not yours. Pass it the argument slice you
  consider your own syntax; a pass-through command can pass a shorter slice or
  skip the check entirely.

### Reading results

```zig
parsed.present("shout")     // bool: was the option given?
parsed.last("color")        // ?[]const u8: the final value, if any
parsed.flags.items          // explicit occurrences plus defaults, under canonical names
parsed.positionals.items    // positional arguments
```

When an option is omitted and its specification has a `default_value`, the
default is added to the parsed result. `last` therefore returns the effective
value. `present` remains false for a defaulted option because it reports
whether the option appeared on the command line. Each `FlagValue.source`
distinguishes `.command_line` from `.default`.

Parsed strings borrow from `argv` and from the specification, so nothing is
copied. If you are not using an arena, release the two buffers explicitly:

```zig
var parsed = try cli.parseCommand(allocator, stderr, args, command);
defer parsed.deinit(allocator);
```

## Help

`printApplicationHelp` and `printCommandHelp` are generated entirely from the
specification, including aliases, choices, defaults, and repeatable markers.

```
$ zecli-example --help
Small example program using zecli.

Usage: zecli-example [options] <command>

Commands:
  greet, hi   Print a configurable greeting
  cat, show   Print one or more files
  complete    Print completion candidates for a prefix
  completion  Generate a shell completion script

Options:
      --home <DIR>  Directory to work in
  -V, --version     Print version
  -h, --help        Print help
```

```
$ zecli-example greet --help
Print a configurable greeting

Usage: zecli-example greet [options]

Options:
  -n, --name <TEXT>             Name to greet [default: world]
  -t, --times <N>               Number of greetings to print [default: 1]
  -s, --shout                   Uppercase the greeting
      --color, --colour <WHEN>  Colorize the greeting [choices: auto, always, never] [default: auto]
  -h, --help                    Print help
```

## Shell completion

The same `ApplicationSpec` generates all three scripts:

```zig
try completion.generateBash(writer, application);
try completion.generateZsh(writer, application);
try completion.generateFish(writer, application);
```

Generated completions offer commands and their aliases, root options before the
command and command options after it, canonical and aliased long options, short
options, and declared choices. They find the command even when root options and
their values precede it (`mytool --home /tmp hist`, `mytool --home=/tmp hist`),
do not mistake an option value for a command name, and stop offering options
after `--`.

Descriptions are shown wherever the shell supports them, which means zsh and
fish; bash has no native mechanism for per-candidate descriptions.

### Installing

```sh
# bash
mytool completion bash > ~/.local/share/bash-completion/completions/mytool

# zsh (a directory on your $fpath)
mytool completion zsh > ~/.zfunc/_mytool

# fish
mytool completion fish > ~/.config/fish/completions/mytool.fish
```

### Completion metadata

What a value or positional completes to is explicit metadata, never inferred
from a name:

```zig
pub const CompletionKind = union(enum) {
    none,
    files,
    directories,
    commands,                       // executable names
    values: []const []const u8,
    external: ExternalCompleter,
};

pub const ExternalCompleter = struct {
    executable: []const u8,
    arguments: []const []const u8 = &.{},
};
```

```zig
.{ .name = "home", .value = .string, .value_name = "DIR", .completion = .directories },
.{ .name = "FILE", .required = true, .repeatable = true, .completion = .files },
```

An option with `choices` completes those choices unless an explicit
`completion` kind is given; declaring both is a validation error rather than a
silent choice between them.

### External completers

For candidates only your program can compute, declare an external completer:

```zig
.{
    .name = "ref",
    .value = .string,
    .value_name = "REF",
    .completion = .{ .external = .{
        .executable = "mytool",
        .arguments = &.{"complete"},
    } },
}
```

Every generated shell then runs `mytool complete <current-prefix>` and reads
candidates from its stdout. The contract is:

1. the executable is invoked **directly, never through `eval`**;
2. the configured arguments are passed first, then the current word prefix as a
   single argument;
3. stdout is read as **one candidate per line**;
4. a nonzero exit status or empty output means no candidates;
5. a candidate containing spaces stays a single candidate;
6. stderr is discarded and never becomes a candidate.

Your side of the contract is a few lines:

```zig
for (candidates) |candidate| {
    if (std.mem.startsWith(u8, candidate, prefix)) {
        try stdout.print("{s}\n", .{candidate});
    }
}
```

Specifications never carry raw shell fragments. Everything a caller supplies —
names, descriptions, usage text, choices, executables, and completer arguments
— is quoted for the target shell, so a description containing `$(...)`, quotes,
or a backslash cannot become executable code in a generated script. This is a
deliberate security boundary: there is no API for injecting shell source, and
`eval` is not used.

## Scope

`zecli` is intentionally narrow. It parses, formats help, and generates
completion, and it leaves everything else to you.

Supported: one level of subcommands, command and long-option aliases, required
and optional values, choices, repeatable options and positionals, `--`,
generated help, and bash/zsh/fish completion.

Out of scope: nested subcommands, action callbacks, middleware, dependency
injection, prompts or terminal UI, configuration-file support, Windows shell
completion, and delegating completion to a wrapped command after `--`.

## Migrating from 0.2.1

`0.2.2` changes one signature. `printCommandList` no longer takes an
allocator, because it now measures and writes labels without building them:

| 0.2.1 | 0.2.2 |
|---|---|
| `cli.printCommandList(allocator, writer, commands)` | `cli.printCommandList(writer, commands)` |

`printApplicationHelp`, `printCommandHelp`, and `printOptions` keep their
signatures. Help printing no longer allocates for anything but an unusually
long `[choices: ...]` or `[default: ...]` suffix, which still needs the
allocator those three take.

`cli.comptimeValidated` is new and additive; the hand-written `comptime`
block it replaces keeps working.

## Migrating from 0.1.x

`0.2.0` is a breaking release.

| 0.1.x | 0.2.0 |
|---|---|
| `cli.CommandEntry` and a separate `commands` array | `CommandSpec` entries inside `ApplicationSpec.commands` |
| `completion.CompletionSpec` with `command`, `commands`, `root`, `subcommands` | the single `cli.ApplicationSpec` |
| `generateBash(writer, completion_spec)` | `generateBash(writer, application)` |
| manual root help printing | `cli.printApplicationHelp(allocator, writer, application)` |
| `cli.printCommandList(writer, entries)` | `cli.printCommandList(allocator, writer, commands)` |
| an argument literally named `FILE` completed files | `.completion = .files` on the `ArgumentSpec` |
| `helpRequested` scanned the whole slice | it now stops at `--` |

`ValueKind`, `value_name`, `default_value`, `repeatable`, and
`attached_short_value` are unchanged. `FlagSpec` gains `aliases`, `choices`, and
`completion`; `CommandSpec` gains `aliases`; `ArgumentSpec` gains `completion`.
`Parsed` gains `deinit`.

To migrate: replace the `CommandEntry` list and `CompletionSpec` with one
`ApplicationSpec`, add `.completion` metadata wherever you relied on the `FILE`
naming convention, and call `printApplicationHelp` instead of assembling root
help by hand.
