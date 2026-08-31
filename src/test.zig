const std = @import("std");
const cli = @import("cli");
const testing = std.testing;

// Minimal duck-typed writer that discards all output, matching the
// interface expected by parseCommand / printCommandHelp.
const NullWriter = struct {
    pub fn writeAll(_: NullWriter, _: []const u8) !void {}
    pub fn writeByte(_: NullWriter, _: u8) !void {}
    pub fn print(_: NullWriter, comptime _: []const u8, _: anytype) !void {}
};

const nw = NullWriter{};
var empty_environ = std.process.Environ.Map.init(std.heap.page_allocator);

// ── parseBool ────────────────────────────────────────────────────────────────

test "parseBool: true strings" {
    try testing.expect(try cli.parseBool("true"));
    try testing.expect(try cli.parseBool("True"));
    try testing.expect(try cli.parseBool("TRUE"));
    try testing.expect(try cli.parseBool("yes"));
    try testing.expect(try cli.parseBool("Yes"));
    try testing.expect(try cli.parseBool("YES"));
    try testing.expect(try cli.parseBool("1"));
}

test "parseBool: false strings" {
    try testing.expect(!try cli.parseBool("false"));
    try testing.expect(!try cli.parseBool("False"));
    try testing.expect(!try cli.parseBool("FALSE"));
    try testing.expect(!try cli.parseBool("no"));
    try testing.expect(!try cli.parseBool("No"));
    try testing.expect(!try cli.parseBool("NO"));
    try testing.expect(!try cli.parseBool("0"));
}

test "parseBool: invalid strings return error" {
    try testing.expectError(error.InvalidArgument, cli.parseBool(""));
    try testing.expectError(error.InvalidArgument, cli.parseBool("maybe"));
    try testing.expectError(error.InvalidArgument, cli.parseBool("2"));
    try testing.expectError(error.InvalidArgument, cli.parseBool("yep"));
    try testing.expectError(error.InvalidArgument, cli.parseBool("truee"));
    try testing.expectError(error.InvalidArgument, cli.parseBool("nope"));
}

// ── helpRequested ────────────────────────────────────────────────────────────

test "helpRequested: detects --help" {
    const args = [_][:0]const u8{"--help"};
    try testing.expect(cli.helpRequested(&args));
}

test "helpRequested: detects -h" {
    const args = [_][:0]const u8{"-h"};
    try testing.expect(cli.helpRequested(&args));
}

test "helpRequested: detects --help anywhere before the separator" {
    const args = [_][:0]const u8{ "--verbose", "--help", "foo" };
    try testing.expect(cli.helpRequested(&args));
}

test "helpRequested: returns false when absent" {
    const args = [_][:0]const u8{ "--verbose", "foo" };
    try testing.expect(!cli.helpRequested(&args));
}

test "helpRequested: returns false for empty slice" {
    try testing.expect(!cli.helpRequested(&.{}));
}

test "helpRequested: --help after the separator is literal" {
    const args = [_][:0]const u8{ "--", "--help" };
    try testing.expect(!cli.helpRequested(&args));
}

test "helpRequested: -h after the separator is literal" {
    const args = [_][:0]const u8{ "grep", "--", "-h" };
    try testing.expect(!cli.helpRequested(&args));
}

test "helpRequested: a pass-through command's own arguments are not scanned" {
    const args = [_][:0]const u8{ "--", "command", "--help" };
    try testing.expect(!cli.helpRequested(&args));
}

test "helpRequested: help before the separator still requests help" {
    const args = [_][:0]const u8{ "--help", "--", "--help" };
    try testing.expect(cli.helpRequested(&args));
}

// ── parse: positionals ───────────────────────────────────────────────────────

test "parse: bare strings are positionals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = [_][:0]const u8{ "foo", "bar", "baz" };
    const result = try cli.parse(alloc, &args, &.{});

    try testing.expectEqual(@as(usize, 3), result.positionals.items.len);
    try testing.expectEqualStrings("foo", result.positionals.items[0]);
    try testing.expectEqualStrings("bar", result.positionals.items[1]);
    try testing.expectEqualStrings("baz", result.positionals.items[2]);
}

test "parse: bare dash is a positional" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const args = [_][:0]const u8{"-"};
    const result = try cli.parse(arena.allocator(), &args, &.{});

    try testing.expectEqual(@as(usize, 1), result.positionals.items.len);
    try testing.expectEqualStrings("-", result.positionals.items[0]);
}

test "parse: -- separator preserves a passthrough argument list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const specs = [_]cli.FlagSpec{.{ .name = "verbose" }};
    const args = [_][:0]const u8{ "--verbose", "--", "--not-a-flag", "also-pos" };
    const result = try cli.parse(alloc, &args, &specs);

    try testing.expect(result.present("verbose"));
    try testing.expectEqual(@as(usize, 0), result.positionals.items.len);
    try testing.expect(result.has_passthrough);
    try testing.expectEqual(@as(usize, 2), result.passthrough.items.len);
    try testing.expectEqualStrings("--not-a-flag", result.passthrough.items[0]);
    try testing.expectEqualStrings("also-pos", result.passthrough.items[1]);
}

// ── parse: long flags ────────────────────────────────────────────────────────

test "parse: long flag without value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const specs = [_]cli.FlagSpec{.{ .name = "verbose" }};
    const args = [_][:0]const u8{"--verbose"};
    const result = try cli.parse(arena.allocator(), &args, &specs);

    try testing.expect(result.present("verbose"));
    try testing.expect(!result.present("other"));
}

test "parse: long flag with string value as next arg" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const specs = [_]cli.FlagSpec{.{ .name = "name", .value = .string }};
    const args = [_][:0]const u8{ "--name", "alice" };
    const result = try cli.parse(arena.allocator(), &args, &specs);

    try testing.expectEqualStrings("alice", result.last("name").?);
}

test "parse: long flag with inline =value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const specs = [_]cli.FlagSpec{.{ .name = "name", .value = .string }};
    const args = [_][:0]const u8{"--name=alice"};
    const result = try cli.parse(arena.allocator(), &args, &specs);

    try testing.expectEqualStrings("alice", result.last("name").?);
}

test "parse: long flag with int value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const specs = [_]cli.FlagSpec{.{ .name = "count", .value = .int }};
    const args = [_][:0]const u8{ "--count", "42" };
    const result = try cli.parse(arena.allocator(), &args, &specs);

    try testing.expectEqualStrings("42", result.last("count").?);
}

test "parse: long flag with invalid int returns error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const specs = [_]cli.FlagSpec{.{ .name = "count", .value = .int }};
    const args = [_][:0]const u8{ "--count", "abc" };
    try testing.expectError(error.InvalidArgument, cli.parse(arena.allocator(), &args, &specs));
}

test "parse: unknown long flag returns error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const args = [_][:0]const u8{"--unknown"};
    try testing.expectError(error.InvalidArgument, cli.parse(arena.allocator(), &args, &.{}));
}

test "parse: long .none flag rejects inline value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const specs = [_]cli.FlagSpec{.{ .name = "verbose" }};
    const args = [_][:0]const u8{"--verbose=yes"};
    try testing.expectError(error.InvalidArgument, cli.parse(arena.allocator(), &args, &specs));
}

test "parse: long flag missing value returns error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const specs = [_]cli.FlagSpec{.{ .name = "name", .value = .string }};
    const args = [_][:0]const u8{"--name"};
    try testing.expectError(error.InvalidArgument, cli.parse(arena.allocator(), &args, &specs));
}

// ── parse: short flags ───────────────────────────────────────────────────────

test "parse: short flag without value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const specs = [_]cli.FlagSpec{.{ .name = "verbose", .short = 'v' }};
    const args = [_][:0]const u8{"-v"};
    const result = try cli.parse(arena.allocator(), &args, &specs);

    try testing.expect(result.present("verbose"));
}

test "parse: short flag with value as next arg" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const specs = [_]cli.FlagSpec{.{ .name = "name", .short = 'n', .value = .string }};
    const args = [_][:0]const u8{ "-n", "alice" };
    const result = try cli.parse(arena.allocator(), &args, &specs);

    try testing.expectEqualStrings("alice", result.last("name").?);
}

test "parse: short flag with attached value when allowed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const specs = [_]cli.FlagSpec{.{ .name = "times", .short = 't', .value = .int, .attached_short_value = true }};
    const args = [_][:0]const u8{"-t42"};
    const result = try cli.parse(arena.allocator(), &args, &specs);

    try testing.expectEqualStrings("42", result.last("times").?);
}

test "parse: short flag attached value rejected when not configured" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const specs = [_]cli.FlagSpec{.{ .name = "name", .short = 'n', .value = .string }};
    const args = [_][:0]const u8{"-nalice"};
    try testing.expectError(error.InvalidArgument, cli.parse(arena.allocator(), &args, &specs));
}

test "parse: short cluster on .none flag returns error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const specs = [_]cli.FlagSpec{.{ .name = "verbose", .short = 'v' }};
    const args = [_][:0]const u8{"-vx"};
    try testing.expectError(error.InvalidArgument, cli.parse(arena.allocator(), &args, &specs));
}

// ── parse: flag repetition ───────────────────────────────────────────────────

test "parse: non-repeatable flag keeps last value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const specs = [_]cli.FlagSpec{.{ .name = "name", .value = .string }};
    const args = [_][:0]const u8{ "--name", "alice", "--name", "bob" };
    const result = try cli.parse(arena.allocator(), &args, &specs);

    try testing.expectEqualStrings("bob", result.last("name").?);
    try testing.expectEqual(@as(usize, 1), result.flags.items.len);
}

test "parse: repeatable flag accumulates all values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const specs = [_]cli.FlagSpec{.{ .name = "tag", .value = .string, .repeatable = true }};
    const args = [_][:0]const u8{ "--tag", "a", "--tag", "b", "--tag", "c" };
    const result = try cli.parse(arena.allocator(), &args, &specs);

    try testing.expectEqual(@as(usize, 3), result.flags.items.len);
    try testing.expectEqualStrings("a", result.flags.items[0].value.?);
    try testing.expectEqualStrings("b", result.flags.items[1].value.?);
    try testing.expectEqualStrings("c", result.flags.items[2].value.?);
}

// ── parse: bool flags ────────────────────────────────────────────────────────

test "parse: bool_required flag accepts true/false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const specs = [_]cli.FlagSpec{.{ .name = "enabled", .value = .bool_required }};

    const args_t = [_][:0]const u8{ "--enabled", "true" };
    const r1 = try cli.parse(alloc, &args_t, &specs);
    try testing.expectEqualStrings("true", r1.last("enabled").?);

    const args_f = [_][:0]const u8{ "--enabled", "false" };
    const r2 = try cli.parse(alloc, &args_f, &specs);
    try testing.expectEqualStrings("false", r2.last("enabled").?);
}

test "parse: bool_required flag rejects invalid value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const specs = [_]cli.FlagSpec{.{ .name = "enabled", .value = .bool_required }};
    const args = [_][:0]const u8{ "--enabled", "maybe" };
    try testing.expectError(error.InvalidArgument, cli.parse(arena.allocator(), &args, &specs));
}

test "parse: bool_optional flag defaults to true when no value follows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const specs = [_]cli.FlagSpec{.{ .name = "verbose", .value = .bool_optional }};
    const args = [_][:0]const u8{"--verbose"};
    const result = try cli.parse(arena.allocator(), &args, &specs);

    try testing.expectEqualStrings("true", result.last("verbose").?);
}

test "parse: bool_optional flag consumes explicit value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const specs = [_]cli.FlagSpec{.{ .name = "verbose", .value = .bool_optional }};
    const args = [_][:0]const u8{ "--verbose", "false" };
    const result = try cli.parse(arena.allocator(), &args, &specs);

    try testing.expectEqualStrings("false", result.last("verbose").?);
}

test "parse: bool_optional flag does not consume following flag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const specs = [_]cli.FlagSpec{
        .{ .name = "verbose", .value = .bool_optional },
        .{ .name = "quiet" },
    };
    const args = [_][:0]const u8{ "--verbose", "--quiet" };
    const result = try cli.parse(arena.allocator(), &args, &specs);

    try testing.expectEqualStrings("true", result.last("verbose").?);
    try testing.expect(result.present("quiet"));
}

// ── Parsed helpers ───────────────────────────────────────────────────────────

test "Parsed.present: returns false for absent flag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = try cli.parse(arena.allocator(), &.{}, &.{});
    try testing.expect(!result.present("missing"));
}

test "Parsed.last: returns null for absent flag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = try cli.parse(arena.allocator(), &.{}, &.{});
    try testing.expect(result.last("missing") == null);
}

test "Parsed.last: returns the declared default for an omitted flag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const specs = [_]cli.FlagSpec{.{
        .name = "name",
        .value = .string,
        .default_value = "world",
    }};
    const result = try cli.parse(arena.allocator(), &.{}, &specs);

    try testing.expectEqualStrings("world", result.last("name").?);
    try testing.expect(!result.present("name"));
    try testing.expectEqual(cli.ValueSource.default, result.flags.items[0].source);
}

test "Parsed.last: an explicit value overrides the declared default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const specs = [_]cli.FlagSpec{.{
        .name = "name",
        .value = .string,
        .default_value = "world",
    }};
    const args = [_][:0]const u8{ "--name", "Zig" };
    const result = try cli.parse(arena.allocator(), &args, &specs);

    try testing.expectEqualStrings("Zig", result.last("name").?);
    try testing.expect(result.present("name"));
    try testing.expectEqual(@as(usize, 1), result.flags.items.len);
    try testing.expectEqual(cli.ValueSource.command_line, result.flags.items[0].source);
}

test "Parsed.getValue: returns typed effective values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const specs = [_]cli.FlagSpec{
        .{ .name = "name", .value = .string, .default_value = "world" },
        .{ .name = "times", .value = .int, .default_value = "10" },
        .{ .name = "offset", .value = .signed_int, .default_value = "-2" },
        .{ .name = "ratio", .value = .float, .default_value = "0.75" },
        .{ .name = "enabled", .value = .bool_required, .default_value = "yes" },
    };
    const result = try cli.parse(arena.allocator(), &.{}, &specs);

    try testing.expectEqualStrings("world", result.getValue([]const u8, "name").?);
    try testing.expectEqual(@as(usize, 10), result.getValue(usize, "times").?);
    try testing.expectEqual(@as(i64, -2), result.getValue(i64, "offset").?);
    try testing.expectApproxEqAbs(@as(f64, 0.75), result.getValue(f64, "ratio").?, 0.000001);
    try testing.expect(result.getValue(bool, "enabled").?);
}

test "Parsed.getValue: converts integers with overflow checks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const specs = [_]cli.FlagSpec{.{ .name = "times", .value = .int }};
    const args = [_][:0]const u8{ "--times", "300" };
    const result = try cli.parse(arena.allocator(), &args, &specs);

    try testing.expect(result.getValue(u64, "times") == null);
    try testing.expectEqual(@as(u64, 300), (try result.getValueAs(u64, "times")).?);
    try testing.expectError(error.IntegerOverflow, result.getValueAs(u8, "times"));
    try testing.expectError(error.IncompatibleValueType, result.getValueAs(bool, "times"));
}

test "parse: accepts signed integer and float values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const specs = [_]cli.FlagSpec{
        .{ .name = "offset", .value = .signed_int },
        .{ .name = "ratio", .value = .float },
    };
    const args = [_][:0]const u8{ "--offset", "-42", "--ratio", "1.5" };
    const result = try cli.parse(arena.allocator(), &args, &specs);

    try testing.expectEqual(@as(i64, -42), result.getValue(i64, "offset").?);
    try testing.expect(result.getValue(usize, "offset") == null);
    try testing.expectApproxEqAbs(@as(f32, 1.5), (try result.getValueAs(f32, "ratio")).?, 0.000001);
}

test "Parsed.getValues: returns repeated values in command line order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const specs = [_]cli.FlagSpec{.{
        .name = "item",
        .value = .string,
        .repeatable = true,
        .default_value = "default-item",
    }};
    const args = [_][:0]const u8{ "--item", "apple", "--item", "orange" };
    const result = try cli.parse(arena.allocator(), &args, &specs);
    var items = result.getValues([]const u8, "item");

    try testing.expectEqualStrings("apple", items.next().?);
    try testing.expectEqualStrings("orange", items.next().?);
    try testing.expect(items.next() == null);
}

test "Parsed.getValues: returns an omitted option's default once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const specs = [_]cli.FlagSpec{.{
        .name = "item",
        .value = .string,
        .repeatable = true,
        .default_value = "default-item",
    }};
    const result = try cli.parse(arena.allocator(), &.{}, &specs);
    var items = result.getValues([]const u8, "item");

    try testing.expectEqualStrings("default-item", items.next().?);
    try testing.expect(items.next() == null);
}

test "Parsed.last: returns last occurrence for repeatable flag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const specs = [_]cli.FlagSpec{.{ .name = "tag", .value = .string, .repeatable = true }};
    const args = [_][:0]const u8{ "--tag", "first", "--tag", "last" };
    const result = try cli.parse(arena.allocator(), &args, &specs);

    try testing.expectEqualStrings("last", result.last("tag").?);
}

// ── parseCommand: argument count validation ──────────────────────────────────

test "parseCommand: rejects too few required arguments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const spec = cli.CommandSpec{
        .name = "test",
        .description = "test",
        .usage = "test <FILE>",
        .arguments = &.{.{ .name = "FILE", .required = true }},
    };
    try testing.expectError(error.ReportedCliError, cli.parseCommand(arena.allocator(), nw, &.{}, spec));
}

test "parseCommand: rejects too many arguments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const spec = cli.CommandSpec{
        .name = "test",
        .description = "test",
        .usage = "test [FILE]",
        .arguments = &.{.{ .name = "FILE" }},
    };
    const args = [_][:0]const u8{ "a.txt", "b.txt" };
    try testing.expectError(error.ReportedCliError, cli.parseCommand(arena.allocator(), nw, &args, spec));
}

test "parseCommand: accepts exact required argument count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const spec = cli.CommandSpec{
        .name = "test",
        .description = "test",
        .usage = "test <FILE>",
        .arguments = &.{.{ .name = "FILE", .required = true }},
    };
    const args = [_][:0]const u8{"myfile.txt"};
    const result = try cli.parseCommand(arena.allocator(), nw, &args, spec);

    try testing.expectEqualStrings("myfile.txt", result.positionals.items[0]);
}

test "parseCommand: accepts zero args when none specified" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const spec = cli.CommandSpec{
        .name = "test",
        .description = "test",
        .usage = "test",
    };
    const result = try cli.parseCommand(arena.allocator(), nw, &.{}, spec);
    try testing.expectEqual(@as(usize, 0), result.positionals.items.len);
}

test "parseCommand: repeatable argument accepts multiple values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const spec = cli.CommandSpec{
        .name = "test",
        .description = "test",
        .usage = "test <FILE>...",
        .arguments = &.{.{ .name = "FILE", .required = true, .repeatable = true }},
    };
    const args = [_][:0]const u8{ "a.txt", "b.txt", "c.txt" };
    const result = try cli.parseCommand(arena.allocator(), nw, &args, spec);

    try testing.expectEqual(@as(usize, 3), result.positionals.items.len);
}

test "parseCommand: unknown flag returns ReportedCliError" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const spec = cli.CommandSpec{
        .name = "test",
        .description = "test",
        .usage = "test [options]",
    };
    const args = [_][:0]const u8{"--unknown"};
    try testing.expectError(error.ReportedCliError, cli.parseCommand(arena.allocator(), nw, &args, spec));
}

test "parseCommand: flags and positionals coexist" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const spec = cli.CommandSpec{
        .name = "test",
        .description = "test",
        .usage = "test [options] <FILE>",
        .flags = &.{.{ .name = "output", .short = 'o', .value = .string }},
        .arguments = &.{.{ .name = "FILE", .required = true }},
    };
    const args = [_][:0]const u8{ "--output", "out.txt", "in.txt" };
    const result = try cli.parseCommand(arena.allocator(), nw, &args, spec);

    try testing.expectEqualStrings("out.txt", result.last("output").?);
    try testing.expectEqualStrings("in.txt", result.positionals.items[0]);
}

test "Invocation: resolves root and command values through the public API" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("MY_APP_NAME", "Ada");
    try environ.put("MY_APP_TIMES", "3");

    const application = comptime cli.comptimeValidated(.{
        .name = "demo",
        .prefix = "MY_APP",
        .description = "d",
        .usage = "u",
        .flags = &.{.{ .name = "name", .value = .string, .default_value = "world" }},
        .commands = &.{.{
            .name = "greet",
            .description = "d",
            .usage = "u",
            .flags = &.{
                .{ .name = "times", .value = .int, .default_value = "1" },
            },
        }},
    });
    const CommandName = cli.CommandEnum(application);
    var invocation = try cli.Invocation.init(allocator, nw, application, &.{"greet"}, &environ);
    defer invocation.deinit(allocator);

    try testing.expectEqualStrings("Ada", invocation.getValue([]const u8, "name").?);
    const command = invocation.getCommand().?;
    try testing.expectEqualStrings("greet", command.name);
    try testing.expectEqual(CommandName.greet, try command.as(CommandName));
    try testing.expectEqual(@as(usize, 3), command.getValue(usize, "times").?);
    try testing.expect(!invocation.present("name"));
}

test "Invocation: command line values override environment values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("MY_APP_NAME", "Jane");

    const application = cli.ApplicationSpec{
        .name = "demo",
        .prefix = "MY_APP",
        .description = "d",
        .usage = "u",
        .commands = &.{.{
            .name = "greet",
            .description = "d",
            .usage = "u",
            .flags = &.{.{ .name = "name", .value = .string, .default_value = "world" }},
        }},
    };
    const args = [_][:0]const u8{ "greet", "--name", "John" };
    var invocation = try cli.Invocation.init(allocator, nw, application, &args, &environ);
    defer invocation.deinit(allocator);
    const command = invocation.getCommand().?;

    try testing.expectEqualStrings("John", command.getValue([]const u8, "name").?);
    try testing.expect(command.present("name"));
}

test "Invocation: ignores environment values without an application prefix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("MY_APP_NAME", "Jane");

    const application = cli.ApplicationSpec{
        .name = "demo",
        .description = "d",
        .usage = "u",
        .commands = &.{.{
            .name = "greet",
            .description = "d",
            .usage = "u",
            .flags = &.{.{ .name = "name", .value = .string, .default_value = "world" }},
        }},
    };
    var invocation = try cli.Invocation.init(allocator, nw, application, &.{"greet"}, &environ);
    defer invocation.deinit(allocator);

    try testing.expectEqualStrings("world", invocation.getCommand().?.getValue([]const u8, "name").?);
}

test "Invocation: reports an invalid environment value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("MY_APP_TIMES", "many");

    const application = cli.ApplicationSpec{
        .name = "demo",
        .prefix = "MY_APP",
        .description = "d",
        .usage = "u",
        .commands = &.{.{
            .name = "greet",
            .description = "d",
            .usage = "u",
            .flags = &.{.{ .name = "times", .value = .int }},
        }},
    };
    var buffer = Buffer.init(allocator);
    defer buffer.deinit();

    try testing.expectError(error.ReportedCliError, cli.Invocation.init(allocator, &buffer, application, &.{"greet"}, &environ));
    try testing.expect(std.mem.indexOf(u8, buffer.bytes.items, "invalid environment value for '--times'") != null);
}

test "Invocation: parses root and command scopes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const application = cli.ApplicationSpec{
        .name = "say",
        .prefix = "SAY",
        .description = "d",
        .usage = "say [options] <command> [options]",
        .flags = &.{.{ .name = "name", .value = .string, .default_value = "world" }},
        .commands = &.{.{
            .name = "gm",
            .description = "d",
            .usage = "say [options] gm [options]",
            .flags = &.{.{ .name = "day-conditions", .value = .string, .default_value = "clear" }},
        }},
    };
    const args = [_][:0]const u8{ "--name=John", "gm", "--day-conditions=clear" };
    var invocation = try cli.Invocation.init(allocator, nw, application, &args, &empty_environ);
    defer invocation.deinit(allocator);

    const command = invocation.getCommand().?;
    try testing.expectEqualStrings("John", invocation.getValue([]const u8, "name").?);
    try testing.expectEqualStrings("gm", command.name);
    try testing.expectEqualStrings("clear", command.getValue([]const u8, "day-conditions").?);
}

test "Invocation: resolves root environment values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("SAY_NAME", "Ada");

    const application = cli.ApplicationSpec{
        .name = "say",
        .prefix = "SAY",
        .description = "d",
        .usage = "say [options] <command>",
        .flags = &.{.{ .name = "name", .value = .string, .default_value = "world" }},
        .commands = &.{.{ .name = "gm", .description = "d", .usage = "u" }},
    };
    var invocation = try cli.Invocation.init(allocator, nw, application, &.{"gm"}, &environ);
    defer invocation.deinit(allocator);

    try testing.expectEqualStrings("Ada", invocation.getValue([]const u8, "name").?);
}

test "Invocation: returns null when no command is present" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const application = cli.ApplicationSpec{
        .name = "say",
        .description = "d",
        .usage = "say [options] [command]",
        .flags = &.{.{ .name = "name", .value = .string }},
        .commands = &.{.{ .name = "gm", .description = "d", .usage = "u" }},
    };
    var invocation = try cli.Invocation.init(arena.allocator(), nw, application, &.{ "--name", "Ada" }, &empty_environ);
    defer invocation.deinit(arena.allocator());

    try testing.expectEqualStrings("Ada", invocation.getValue([]const u8, "name").?);
    try testing.expect(invocation.getCommand() == null);
}

test "Invocation: rejects an unknown command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buffer = Buffer.init(arena.allocator());
    defer buffer.deinit();

    const application = cli.ApplicationSpec{
        .name = "say",
        .description = "d",
        .usage = "say <command>",
        .commands = &.{.{ .name = "gm", .description = "d", .usage = "u" }},
    };
    try testing.expectError(error.ReportedCliError, cli.Invocation.init(arena.allocator(), &buffer, application, &.{"nope"}, &empty_environ));
    try testing.expect(std.mem.indexOf(u8, buffer.items(), "unknown command 'nope'") != null);
}

test "Invocation: rejects a root option after the command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const application = cli.ApplicationSpec{
        .name = "say",
        .description = "d",
        .usage = "say [options] <command> [options]",
        .flags = &.{.{ .name = "name", .value = .string }},
        .commands = &.{.{ .name = "gm", .description = "d", .usage = "u" }},
    };
    const args = [_][:0]const u8{ "gm", "--name=John" };
    try testing.expectError(
        error.ReportedCliError,
        cli.Invocation.init(arena.allocator(), nw, application, &args, &empty_environ),
    );
}

test "Invocation: prints application help once when requested in the root scope" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buffer = Buffer.init(arena.allocator());
    defer buffer.deinit();

    const application = cli.ApplicationSpec{
        .name = "say",
        .description = "d",
        .usage = "say [options] <command>",
        .flags = &.{.{ .name = "name", .value = .string }},
        .commands = &.{.{ .name = "gm", .description = "d", .usage = "say gm" }},
    };
    var invocation = try cli.Invocation.init(arena.allocator(), &buffer, application, &.{ "--name", "Ada", "--help", "gm" }, &empty_environ);
    defer invocation.deinit(arena.allocator());

    try testing.expect(try invocation.printHelpIfRequested(arena.allocator(), &buffer));
    try testing.expect(invocation.getCommand() == null);
    try testing.expect(std.mem.indexOf(u8, buffer.items(), "Usage: say [options] <command>") != null);
}

test "Invocation: prints command help after root flags and bypasses required arguments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buffer = Buffer.init(arena.allocator());
    defer buffer.deinit();

    const application = cli.ApplicationSpec{
        .name = "say",
        .description = "d",
        .usage = "say [options] <command>",
        .flags = &.{.{ .name = "home", .value = .string }},
        .commands = &.{.{
            .name = "gm",
            .description = "d",
            .usage = "say gm <MESSAGE>",
            .arguments = &.{.{ .name = "MESSAGE", .required = true }},
        }},
    };
    var invocation = try cli.Invocation.init(arena.allocator(), &buffer, application, &.{ "--home", "/tmp", "gm", "--help" }, &empty_environ);
    defer invocation.deinit(arena.allocator());

    try testing.expect(invocation.getCommand() != null);
    try testing.expect(try invocation.printHelpIfRequested(arena.allocator(), &buffer));
    try testing.expect(std.mem.indexOf(u8, buffer.items(), "Usage: say gm <MESSAGE>") != null);
}

test "Invocation: help after the separator remains a passthrough argument" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const application = cli.ApplicationSpec{
        .name = "say",
        .description = "d",
        .usage = "say <command>",
        .commands = &.{.{
            .name = "gm",
            .description = "d",
            .usage = "say gm <MESSAGE>",
            .arguments = &.{.{ .name = "MESSAGE", .required = true }},
        }},
    };
    var invocation = try cli.Invocation.init(arena.allocator(), nw, application, &.{ "gm", "message", "--", "--help" }, &empty_environ);
    defer invocation.deinit(arena.allocator());

    try testing.expect(!try invocation.printHelpIfRequested(arena.allocator(), nw));
    try testing.expectEqualStrings("--help", invocation.getCommand().?.passthrough().?[0]);
}

test "Invocation: passthrough keeps child argv separate from fixed positionals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const application = cli.ApplicationSpec{
        .name = "tjctl",
        .description = "d",
        .usage = "tjctl new <JOURNAL> [-- <PROGRAM>...]",
        .commands = &.{.{
            .name = "new",
            .description = "d",
            .usage = "tjctl new <JOURNAL> [-- <PROGRAM>...]",
            .arguments = &.{.{ .name = "JOURNAL", .required = true }},
        }},
    };
    var invocation = try cli.Invocation.init(
        arena.allocator(),
        nw,
        application,
        &.{ "new", "journal", "--", "program", "--its-option", "value" },
        &empty_environ,
    );
    defer invocation.deinit(arena.allocator());

    const command = invocation.getCommand().?;
    try testing.expectEqualStrings("journal", command.positionals()[0]);
    const child_argv = command.passthrough().?;
    try testing.expectEqual(@as(usize, 3), child_argv.len);
    try testing.expectEqualStrings("program", child_argv[0]);
    try testing.expectEqualStrings("--its-option", child_argv[1]);
    try testing.expectEqualStrings("value", child_argv[2]);
}

test "Invocation: passthrough distinguishes no separator from a trailing separator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const application = cli.ApplicationSpec{
        .name = "tj",
        .description = "d",
        .usage = "tj noout [-- <PROGRAM>...]",
        .commands = &.{.{ .name = "noout", .description = "d", .usage = "tj noout [-- <PROGRAM>...]" }},
    };
    var without_separator = try cli.Invocation.init(arena.allocator(), nw, application, &.{"noout"}, &empty_environ);
    defer without_separator.deinit(arena.allocator());
    try testing.expect(without_separator.getCommand().?.passthrough() == null);

    var trailing_separator = try cli.Invocation.init(arena.allocator(), nw, application, &.{ "noout", "--" }, &empty_environ);
    defer trailing_separator.deinit(arena.allocator());
    try testing.expectEqual(@as(usize, 0), trailing_separator.getCommand().?.passthrough().?.len);
}

test "Invocation: generated command enums use canonical names and quoted tags" {
    const application = comptime cli.comptimeValidated(.{
        .name = "say",
        .description = "d",
        .usage = "say <command>",
        .commands = &.{.{
            .name = "good-morning",
            .aliases = &.{"gm"},
            .description = "d",
            .usage = "say good-morning",
        }},
    });
    const CommandName = cli.CommandEnum(application);

    var invocation = try cli.Invocation.init(testing.allocator, nw, application, &.{"gm"}, &empty_environ);
    defer invocation.deinit(testing.allocator);

    const command = invocation.getCommand().?;
    try testing.expectEqualStrings("good-morning", command.name);
    try testing.expectEqual(CommandName.@"good-morning", try command.as(CommandName));
}

test "Invocation: Command.getValues returns repeated values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const application = cli.ApplicationSpec{
        .name = "say",
        .description = "d",
        .usage = "say <command>",
        .commands = &.{.{
            .name = "gm",
            .description = "d",
            .usage = "say gm [options]",
            .flags = &.{.{ .name = "item", .value = .string, .repeatable = true }},
        }},
    };
    var invocation = try cli.Invocation.init(arena.allocator(), nw, application, &.{ "gm", "--item", "apple", "--item", "orange" }, &empty_environ);
    defer invocation.deinit(arena.allocator());

    var items = invocation.getCommand().?.getValues([]const u8, "item");
    try testing.expectEqualStrings("apple", items.next().?);
    try testing.expectEqualStrings("orange", items.next().?);
    try testing.expect(items.next() == null);
}

// ── A representative application ─────────────────────────────────────────────
//
// The color option is the generic form of the grammar a consumer needs: a
// required string value, reachable through a long alias, restricted to a fixed
// set of choices.

const color_flag = cli.FlagSpec{
    .name = "color",
    .aliases = &.{"colour"},
    .value = .string,
    .value_name = "WHEN",
    .description = "Colorize output",
    .default_value = "auto",
    .choices = &.{ "auto", "always", "never" },
};

const grep_spec = cli.CommandSpec{
    .name = "grep",
    .description = "Search entries",
    .usage = "demo grep [options] <PATTERN>",
    .flags = &.{color_flag},
    .arguments = &.{.{ .name = "PATTERN", .required = true }},
};

const hist_spec = cli.CommandSpec{
    .name = "hist",
    .aliases = &.{"history"},
    .description = "Show past entries",
    .usage = "demo hist [options]",
    .flags = &.{
        .{ .name = "tag", .value = .string, .description = "Filter by tag", .repeatable = true },
    },
};

const demo_app = cli.ApplicationSpec{
    .name = "demo",
    .description = "Demo application.",
    .usage = "demo [options] <command>",
    .flags = &.{
        .{ .name = "home", .value = .string, .value_name = "DIR", .description = "Home directory" },
    },
    .commands = &.{ grep_spec, hist_spec },
};

// A writer that keeps output in memory, matching the interface the help
// printers expect.
const Buffer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    fn init(allocator: std.mem.Allocator) Buffer {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Buffer) void {
        self.bytes.deinit(self.allocator);
    }

    fn items(self: *const Buffer) []const u8 {
        return self.bytes.items;
    }

    pub fn writeAll(self: *Buffer, data: []const u8) !void {
        try self.bytes.appendSlice(self.allocator, data);
    }

    pub fn writeByte(self: *Buffer, byte: u8) !void {
        try self.bytes.append(self.allocator, byte);
    }

    pub fn print(self: *Buffer, comptime fmt: []const u8, args: anytype) !void {
        const data = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(data);
        try self.writeAll(data);
    }
};

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |pos| {
        count += 1;
        rest = rest[pos + needle.len ..];
    }
    return count;
}

// ── Command and flag lookup ──────────────────────────────────────────────────

test "findCommand: resolves a canonical name" {
    const found = cli.findCommand(demo_app, "hist").?;
    try testing.expectEqualStrings("hist", found.name);
}

test "findCommand: resolves an alias to the canonical specification" {
    const found = cli.findCommand(demo_app, "history").?;
    try testing.expectEqualStrings("hist", found.name);
}

test "findCommand: returns null for an unknown command" {
    try testing.expect(cli.findCommand(demo_app, "nope") == null);
}

test "findFlag: resolves a canonical long option" {
    const found = cli.findFlag(grep_spec, "color").?;
    try testing.expectEqualStrings("color", found.name);
}

test "findFlag: resolves a long alias to the canonical specification" {
    const found = cli.findFlag(grep_spec, "colour").?;
    try testing.expectEqualStrings("color", found.name);
}

test "findFlag: returns null for an unknown option" {
    try testing.expect(cli.findFlag(grep_spec, "colored") == null);
}

test "findApplicationFlag: resolves a root option" {
    const found = cli.findApplicationFlag(demo_app, "home").?;
    try testing.expectEqualStrings("home", found.name);
}

// ── Aliases store values under canonical names ───────────────────────────────

test "parse: a long alias records the value under the canonical name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const args = [_][:0]const u8{ "--colour", "never" };
    const result = try cli.parse(arena.allocator(), &args, grep_spec.flags);

    try testing.expectEqualStrings("never", result.last("color").?);
    try testing.expect(!result.present("colour"));
    try testing.expectEqualStrings("color", result.flags.items[0].name);
}

test "parse: repeatable values through a mix of spellings all accumulate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const args = [_][:0]const u8{ "--tag", "bug", "--tag", "parser" };
    const result = try cli.parse(arena.allocator(), &args, hist_spec.flags);

    try testing.expectEqual(@as(usize, 2), result.flags.items.len);
    try testing.expectEqualStrings("bug", result.flags.items[0].value.?);
    try testing.expectEqualStrings("parser", result.flags.items[1].value.?);
}

// ── Choices ──────────────────────────────────────────────────────────────────

test "parse: accepts a declared choice given as the next word" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const args = [_][:0]const u8{ "--color", "always", "pattern" };
    const result = try cli.parse(arena.allocator(), &args, grep_spec.flags);

    try testing.expectEqualStrings("always", result.last("color").?);
    try testing.expectEqual(@as(usize, 1), result.positionals.items.len);
    try testing.expectEqualStrings("pattern", result.positionals.items[0]);
}

test "parse: accepts a declared choice given inline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const args = [_][:0]const u8{ "--color=always", "pattern" };
    const result = try cli.parse(arena.allocator(), &args, grep_spec.flags);

    try testing.expectEqualStrings("always", result.last("color").?);
    try testing.expectEqualStrings("pattern", result.positionals.items[0]);
}

test "parse: a required value is not optional" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const args = [_][:0]const u8{"--color"};
    try testing.expectError(
        error.InvalidArgument,
        cli.parse(arena.allocator(), &args, grep_spec.flags),
    );
}

test "parse: rejects a value outside the declared choices" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const args = [_][:0]const u8{ "--color", "sometimes" };
    try testing.expectError(
        error.InvalidArgument,
        cli.parse(arena.allocator(), &args, grep_spec.flags),
    );
}

test "parse: rejects an invalid choice given through an alias" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const args = [_][:0]const u8{"--colour=sometimes"};
    try testing.expectError(
        error.InvalidArgument,
        cli.parse(arena.allocator(), &args, grep_spec.flags),
    );
}

test "parse: accepts a valid choice through an alias" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const args = [_][:0]const u8{ "--colour=never", "--", "-pattern" };
    const result = try cli.parse(arena.allocator(), &args, grep_spec.flags);

    try testing.expectEqualStrings("never", result.last("color").?);
    try testing.expectEqualStrings("-pattern", result.passthrough.items[0]);
}

test "parseCommand: an invalid choice names the option, value, and allowed values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var buffer = Buffer.init(testing.allocator);
    defer buffer.deinit();

    const args = [_][:0]const u8{ "--colour", "sometimes", "pattern" };
    try testing.expectError(
        error.ReportedCliError,
        cli.parseCommand(arena.allocator(), &buffer, &args, grep_spec),
    );

    try testing.expect(std.mem.indexOf(u8, buffer.items(), "--color") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items(), "sometimes") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items(), "'auto'") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items(), "'always'") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items(), "'never'") != null);
}

test "parseCommand: a missing required value is reported" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var buffer = Buffer.init(testing.allocator);
    defer buffer.deinit();

    const args = [_][:0]const u8{"--color"};
    try testing.expectError(
        error.ReportedCliError,
        cli.parseCommand(arena.allocator(), &buffer, &args, grep_spec),
    );
    try testing.expect(std.mem.indexOf(u8, buffer.items(), "requires <WHEN>") != null);
}

// ── Ownership ────────────────────────────────────────────────────────────────

test "Parsed.deinit: releases both buffers" {
    const args = [_][:0]const u8{ "--tag", "a", "--tag", "b", "one", "two" };
    var result = try cli.parse(testing.allocator, &args, hist_spec.flags);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.flags.items.len);
    try testing.expectEqual(@as(usize, 2), result.positionals.items.len);
}

test "Parsed.deinit: is safe to call twice" {
    const args = [_][:0]const u8{"one"};
    var result = try cli.parse(testing.allocator, &args, &.{});
    result.deinit(testing.allocator);
    result.deinit(testing.allocator);
}

test "parseCommand: releases the parse buffers when arguments are rejected" {
    const spec = cli.CommandSpec{
        .name = "test",
        .description = "test",
        .usage = "test <FILE>",
        .arguments = &.{.{ .name = "FILE", .required = true }},
    };
    try testing.expectError(
        error.ReportedCliError,
        cli.parseCommand(testing.allocator, nw, &.{}, spec),
    );
}

// ── Specification validation ─────────────────────────────────────────────────

test "validateApplicationSpec: accepts a well-formed application" {
    try cli.validateApplicationSpec(demo_app);
}

test "validateApplicationSpec: rejects an invalid application name" {
    const app = cli.ApplicationSpec{ .name = "-demo", .description = "d", .usage = "u" };
    try testing.expectError(error.InvalidName, cli.validateApplicationSpec(app));
}

test "validateCommandSpec: rejects an empty command name" {
    const spec = cli.CommandSpec{ .name = "", .description = "d", .usage = "u" };
    try testing.expectError(error.InvalidName, cli.validateCommandSpec(spec));
}

test "validateCommandSpec: rejects a name outside the shell-safe grammar" {
    const spec = cli.CommandSpec{ .name = "we ird", .description = "d", .usage = "u" };
    try testing.expectError(error.InvalidName, cli.validateCommandSpec(spec));
}

test "validateCommandSpec: rejects an invalid alias" {
    const spec = cli.CommandSpec{
        .name = "hist",
        .aliases = &.{"his tory"},
        .description = "d",
        .usage = "u",
    };
    try testing.expectError(error.InvalidName, cli.validateCommandSpec(spec));
}

test "validateCommandSpec: rejects an alias equal to the command name" {
    const spec = cli.CommandSpec{
        .name = "hist",
        .aliases = &.{"hist"},
        .description = "d",
        .usage = "u",
    };
    try testing.expectError(error.AliasEqualsName, cli.validateCommandSpec(spec));
}

test "validateCommandSpec: rejects duplicate aliases on one command" {
    const spec = cli.CommandSpec{
        .name = "hist",
        .aliases = &.{ "history", "history" },
        .description = "d",
        .usage = "u",
    };
    try testing.expectError(error.DuplicateName, cli.validateCommandSpec(spec));
}

test "validateApplicationSpec: rejects duplicate command names" {
    const app = cli.ApplicationSpec{
        .name = "demo",
        .description = "d",
        .usage = "u",
        .commands = &.{
            .{ .name = "hist", .description = "d", .usage = "u" },
            .{ .name = "hist", .description = "d", .usage = "u" },
        },
    };
    try testing.expectError(error.DuplicateName, cli.validateApplicationSpec(app));
}

test "validateApplicationSpec: rejects an alias colliding with another command" {
    const app = cli.ApplicationSpec{
        .name = "demo",
        .description = "d",
        .usage = "u",
        .commands = &.{
            .{ .name = "hist", .aliases = &.{"log"}, .description = "d", .usage = "u" },
            .{ .name = "log", .description = "d", .usage = "u" },
        },
    };
    try testing.expectError(error.DuplicateName, cli.validateApplicationSpec(app));
}

test "validateApplicationSpec: rejects two commands sharing an alias" {
    const app = cli.ApplicationSpec{
        .name = "demo",
        .description = "d",
        .usage = "u",
        .commands = &.{
            .{ .name = "hist", .aliases = &.{"h"}, .description = "d", .usage = "u" },
            .{ .name = "help", .aliases = &.{"h"}, .description = "d", .usage = "u" },
        },
    };
    try testing.expectError(error.DuplicateName, cli.validateApplicationSpec(app));
}

test "validateCommandSpec: rejects duplicate long option names" {
    const spec = cli.CommandSpec{
        .name = "c",
        .description = "d",
        .usage = "u",
        .flags = &.{ .{ .name = "tag" }, .{ .name = "tag" } },
    };
    try testing.expectError(error.DuplicateName, cli.validateCommandSpec(spec));
}

test "validateCommandSpec: rejects an option alias colliding with another option" {
    const spec = cli.CommandSpec{
        .name = "c",
        .description = "d",
        .usage = "u",
        .flags = &.{
            .{ .name = "color", .aliases = &.{"colour"}, .value = .string },
            .{ .name = "colour", .value = .string },
        },
    };
    try testing.expectError(error.DuplicateName, cli.validateCommandSpec(spec));
}

test "validateCommandSpec: rejects duplicate short options" {
    const spec = cli.CommandSpec{
        .name = "c",
        .description = "d",
        .usage = "u",
        .flags = &.{ .{ .name = "tag", .short = 't' }, .{ .name = "time", .short = 't' } },
    };
    try testing.expectError(error.DuplicateShortOption, cli.validateCommandSpec(spec));
}

test "validateCommandSpec: rejects an option alias equal to its own name" {
    const spec = cli.CommandSpec{
        .name = "c",
        .description = "d",
        .usage = "u",
        .flags = &.{.{ .name = "color", .aliases = &.{"color"}, .value = .string }},
    };
    try testing.expectError(error.AliasEqualsName, cli.validateCommandSpec(spec));
}

test "validateCommandSpec: rejects a required argument after an optional one" {
    const spec = cli.CommandSpec{
        .name = "c",
        .description = "d",
        .usage = "u",
        .arguments = &.{ .{ .name = "A" }, .{ .name = "B", .required = true } },
    };
    try testing.expectError(error.RequiredArgumentAfterOptional, cli.validateCommandSpec(spec));
}

test "validateCommandSpec: rejects a repeatable argument that is not last" {
    const spec = cli.CommandSpec{
        .name = "c",
        .description = "d",
        .usage = "u",
        .arguments = &.{
            .{ .name = "A", .required = true, .repeatable = true },
            .{ .name = "B", .required = true },
        },
    };
    try testing.expectError(error.RepeatableArgumentNotLast, cli.validateCommandSpec(spec));
}

test "validateCommandSpec: accepts a repeatable final argument" {
    const spec = cli.CommandSpec{
        .name = "c",
        .description = "d",
        .usage = "u",
        .arguments = &.{
            .{ .name = "A", .required = true },
            .{ .name = "B", .required = true, .repeatable = true },
        },
    };
    try cli.validateCommandSpec(spec);
}

test "validateCommandSpec: rejects choices on an option that takes no value" {
    const spec = cli.CommandSpec{
        .name = "c",
        .description = "d",
        .usage = "u",
        .flags = &.{.{ .name = "shout", .choices = &.{"a"} }},
    };
    try testing.expectError(error.ChoicesWithoutValue, cli.validateCommandSpec(spec));
}

test "validateCommandSpec: rejects completion metadata on an option that takes no value" {
    const spec = cli.CommandSpec{
        .name = "c",
        .description = "d",
        .usage = "u",
        .flags = &.{.{ .name = "shout", .completion = .files }},
    };
    try testing.expectError(error.CompletionWithoutValue, cli.validateCommandSpec(spec));
}

test "validateCommandSpec: rejects choices combined with an explicit completion kind" {
    const spec = cli.CommandSpec{
        .name = "c",
        .description = "d",
        .usage = "u",
        .flags = &.{.{
            .name = "color",
            .value = .string,
            .choices = &.{"auto"},
            .completion = .files,
        }},
    };
    try testing.expectError(error.ConflictingCompletion, cli.validateCommandSpec(spec));
}

test "validateCommandSpec: rejects a default value outside the choices" {
    const spec = cli.CommandSpec{
        .name = "c",
        .description = "d",
        .usage = "u",
        .flags = &.{.{
            .name = "color",
            .value = .string,
            .choices = &.{ "auto", "never" },
            .default_value = "always",
        }},
    };
    try testing.expectError(error.DefaultNotInChoices, cli.validateCommandSpec(spec));
}

test "validateCommandSpec: rejects an invalid typed default" {
    const spec = cli.CommandSpec{
        .name = "c",
        .description = "d",
        .usage = "u",
        .flags = &.{.{ .name = "ratio", .value = .float, .default_value = "many" }},
    };
    try testing.expectError(error.InvalidDefaultValue, cli.validateCommandSpec(spec));
}

// ── Help ─────────────────────────────────────────────────────────────────────

test "printApplicationHelp: lists commands, aliases, and root options" {
    var buffer = Buffer.init(testing.allocator);
    defer buffer.deinit();

    try cli.printApplicationHelp(testing.allocator, &buffer, demo_app);
    const text = buffer.items();

    try testing.expect(std.mem.indexOf(u8, text, "Demo application.") != null);
    try testing.expect(std.mem.indexOf(u8, text, "demo [options] <command>") != null);
    try testing.expect(std.mem.indexOf(u8, text, "grep") != null);
    try testing.expect(std.mem.indexOf(u8, text, "hist, history") != null);
    try testing.expect(std.mem.indexOf(u8, text, "--home <DIR>") != null);
    try testing.expect(std.mem.indexOf(u8, text, "-h, --help") != null);
}

test "printApplicationHelp: shows each alias exactly once" {
    var buffer = Buffer.init(testing.allocator);
    defer buffer.deinit();

    try cli.printApplicationHelp(testing.allocator, &buffer, demo_app);
    try testing.expectEqual(@as(usize, 1), countOccurrences(buffer.items(), "history"));
}

/// Counts every allocation made through it, so a test can assert that help
/// printing stays off the heap.
const CountingAllocator = struct {
    parent: std.mem.Allocator,
    count: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, n: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.parent.rawAlloc(n, a, ra);
    }

    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.parent.rawResize(m, a, n, ra);
    }

    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.parent.rawRemap(m, a, n, ra);
    }

    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(m, a, ra);
    }
};

test "help printing does not allocate" {
    var counting = CountingAllocator{ .parent = testing.allocator };
    const allocator = counting.allocator();

    try cli.printApplicationHelp(allocator, nw, demo_app);
    for (demo_app.commands) |command| {
        try cli.printCommandHelp(allocator, nw, command);
    }

    try testing.expectEqual(@as(usize, 0), counting.count);
}

test "comptimeValidated returns the specification unchanged" {
    const application = cli.comptimeValidated(.{
        .name = "demo",
        .description = "Demo application.",
        .usage = "demo [options] <command>",
        .flags = demo_app.flags,
        .commands = demo_app.commands,
    });
    try testing.expectEqualStrings("demo", application.name);
    try testing.expectEqual(demo_app.commands.len, application.commands.len);
}

/// A specification far larger than the demo one, built at compile time, to
/// keep `comptimeValidated` inside Zig's evaluation limits for a real
/// application. Validation compares every pair of names in a scope, so the
/// work grows with the square of this.
const large_app = blk: {
    // This quota is for building the fixture's names with comptimePrint, not
    // for validating it: comptimeValidated raises its own.
    @setEvalBranchQuota(500_000);

    const command_count = 24;
    const flags_per_command = 10;

    var commands: [command_count]cli.CommandSpec = undefined;
    for (&commands, 0..) |*command, i| {
        var flags: [flags_per_command]cli.FlagSpec = undefined;
        for (&flags, 0..) |*flag, j| {
            flag.* = .{
                .name = std.fmt.comptimePrint("option-{d}-{d}", .{ i, j }),
                .aliases = &.{std.fmt.comptimePrint("alias-{d}-{d}", .{ i, j })},
                .value = .string,
                .description = "An option",
            };
        }
        const frozen = flags;
        command.* = .{
            .name = std.fmt.comptimePrint("command-{d}", .{i}),
            .aliases = &.{std.fmt.comptimePrint("c{d}", .{i})},
            .description = "A command",
            .usage = std.fmt.comptimePrint("large command-{d}", .{i}),
            .flags = &frozen,
        };
    }
    const frozen_commands = commands;
    break :blk cli.comptimeValidated(.{
        .name = "large",
        .description = "A large application.",
        .usage = "large [options] <command>",
        .commands = &frozen_commands,
    });
};

test "comptimeValidated handles a specification with many commands and options" {
    // Reaching this at all means the compile-time validation stayed inside the
    // branch quota; the assertions just pin the shape.
    try testing.expectEqual(@as(usize, 24), large_app.commands.len);
    try testing.expectEqual(@as(usize, 10), large_app.commands[0].flags.len);
    try testing.expect(cli.findCommand(large_app, "c23") != null);
}

test "printCommandHelp: shows option aliases, choices, and defaults" {
    var buffer = Buffer.init(testing.allocator);
    defer buffer.deinit();

    try cli.printCommandHelp(testing.allocator, &buffer, grep_spec);
    const text = buffer.items();

    try testing.expect(std.mem.indexOf(u8, text, "--color, --colour <WHEN>") != null);
    try testing.expect(std.mem.indexOf(u8, text, "[choices: auto, always, never]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "[default: auto]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "<PATTERN>") != null);
}

test "printCommandHelp: marks a repeatable option" {
    var buffer = Buffer.init(testing.allocator);
    defer buffer.deinit();

    try cli.printCommandHelp(testing.allocator, &buffer, hist_spec);
    try testing.expect(std.mem.indexOf(u8, buffer.items(), "[repeatable]") != null);
}
