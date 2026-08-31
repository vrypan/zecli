# Value Resolution

`Parsed.getValue` is the normal way to read an option value. It returns the
final effective value in the type declared by `FlagSpec.value`.

```zig
const name = parsed.getValue([]const u8, "name").?;
const times = parsed.getValue(usize, "times").?;
const offset = parsed.getValue(i64, "offset").?;
const ratio = parsed.getValue(f64, "ratio").?;
const enabled = parsed.getValue(bool, "enabled").?;
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
| `.none` | no value | none; use `present` |

## Sources and precedence

Explicit command-line values override defaults. When an option with a
`default_value` is omitted, zecli adds that default to `Parsed.flags`.

```text
--times 5                 -> 5
default_value = "10"      -> 10 when --times is omitted
```

`parsed.present("times")` is true only when `--times` was passed on the
command line. `FlagValue.source` distinguishes `.command_line` from
`.default`.

Defaults are parsed and validated in the same representation as command-line
values. For example, an `.int` default must be a valid `usize`, and a `.float`
default must be a valid `f64`.

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
and has a default, the iterator yields that default once. Explicit values always
take precedence over the default.

## Raw result access

`Parsed.last(name)` returns the final raw string value, regardless of declared
value type. It is useful for pass-through commands and consumers that require
the original spelling.

`Parsed.flags.items` contains every explicit occurrence for repeatable flags,
plus one default entry for each omitted option with a default. Each entry is a
`FlagValue` with its canonical name, raw value, parsed value, and source.

All strings borrow from `argv` or the static specification; `Parsed.deinit`
only releases its internal arrays.
