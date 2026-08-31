# Value Resolution

`Invocation.getValue` reads root option values and `Command.getValue` reads
selected-command option values. Both return the final effective value in the
type declared by `FlagSpec.value`. `Parsed.getValue` provides the same
low-level operation.

```zig
const name = invocation.getValue([]const u8, "name").?;
const times = command.getValue(usize, "times").?;
const offset = command.getValue(i64, "offset").?;
const ratio = command.getValue(f64, "ratio").?;
const enabled = command.getValue(bool, "enabled").?;
```

`getValue` returns `null` when the option has no effective value, or when the
requested type does not match the option's stored type.

| `FlagSpec.value` | Stored type | `getValue` type |
| --- | --- | --- |
| `.string` | string | `[]const u8` |
| `.int` | unsigned integer | `usize` |
| `.signed_int` | signed integer | `i64` |
| `.float` | floating-point number | `f64` |
| `.bool_required`, `.bool_optional` | boolean | `bool` |
| `.none` | no command-line value; environment values parse as booleans | use `present` for command-line presence or `enabled` for effective boolean state |

## Sources and precedence

Set `ApplicationSpec.prefix` to enable environment values. An option's variable
name is the prefix, an underscore, and its canonical long name in uppercase
with hyphens changed to underscores. For example, `.prefix = "MY_APP"` makes
`--first-name` read `MY_APP_FIRST_NAME`.

Explicit command-line values override environment values, which override
defaults. When an option with a `default_value` is omitted, zecli adds that
default to `Parsed.flags`.

```text
--times 5                 -> 5
MY_APP_TIMES=3            -> 3 when --times is omitted
default_value = "10"      -> 10 when --times is omitted
```

`parsed.present("times")` is true only when `--times` was passed on the
command line. For boolean options and no-value switches, use
`parsed.enabled("name")` to read the effective boolean state across command
line, environment, and default sources. `FlagValue.source` distinguishes
`.command_line`, `.environment`, and `.default`.

Defaults are parsed and validated in the same representation as command-line
values, and environment values follow that same validation. For example, an
`.int` value must be a valid `usize`, and a `.float` value must be a valid
`f64`.

No-value switches read environment variables as booleans:

```text
--shout                   -> enabled("shout") == true
MY_APP_SHOUT=true         -> enabled("shout") == true when --shout is omitted
MY_APP_SHOUT=false        -> enabled("shout") == false when --shout is omitted
```

`Invocation.init` applies this same resolution to application/root flags before
parsing the selected command. Its v1 grammar accepts root options only before
the command.

## Checked conversions

Use `getValueAs` when a consumer needs a numeric representation other than the
one declared by the option:

```zig
const limit = (try parsed.getValueAs(u64, "times")).?;
const compact_ratio = (try parsed.getValueAs(f32, "ratio")).?;
```

`getValueAs` returns `null` for an absent value. It returns
`error.IncompatibleValueType` for a nonnumeric value or an unsupported
conversion, and `error.IntegerOverflow` when an integer does not fit the
requested type. It also returns the raw string for `[]const u8` requests.

## Repeated values

Use `getValues` to iterate over a repeatable option without allocating:

```zig
var items = parsed.getValues([]const u8, "item");
while (items.next()) |item| {
    // "apple", then "orange"
}
```

Values are yielded in command-line order. When a repeatable option is omitted
and has an environment value, zecli splits that value on commas and yields each
item after trimming ASCII whitespace. A repeatable option's default is yielded
once. Explicit values take precedence over environment values and defaults.

```text
--tag fruit --tag asia    -> fruit, then asia
MY_APP_TAG=fruit,asia     -> fruit, then asia when --tag is omitted
MY_APP_TAG=fruit, asia    -> fruit, then asia when --tag is omitted
```

Comma escaping is not supported yet, and empty items are invalid. A
non-repeatable environment value is never split, even if it contains commas.

## Raw result access

`Command.positionals()` returns positional arguments before `--`.
`Command.passthrough()` returns an optional slice containing literal arguments
after the separator. The separator is absent when the result is `null`; a
trailing separator produces a non-null empty slice. Positional validation never
includes pass-through arguments.

`Parsed.last(name)` returns the final raw string value, regardless of declared
value type. It is useful for pass-through commands and consumers that require
the original spelling.

`Parsed.flags.items` contains every explicit occurrence for repeatable flags,
plus one default entry for each omitted option with a default. Each entry is a
`FlagValue` with its canonical name, raw value, parsed value, and source.
`Parsed.passthrough` and `Parsed.has_passthrough` expose the same separator
state at the lower level.

All strings borrow from `argv` or the static specification; `Parsed.deinit`
only releases its internal arrays.
