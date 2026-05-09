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

test "helpRequested: detects --help anywhere in slice" {
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

test "parse: -- separator forces remaining args to positionals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const specs = [_]cli.FlagSpec{.{ .name = "verbose" }};
    const args = [_][:0]const u8{ "--verbose", "--", "--not-a-flag", "also-pos" };
    const result = try cli.parse(alloc, &args, &specs);

    try testing.expect(result.present("verbose"));
    try testing.expectEqual(@as(usize, 2), result.positionals.items.len);
    try testing.expectEqualStrings("--not-a-flag", result.positionals.items[0]);
    try testing.expectEqualStrings("also-pos", result.positionals.items[1]);
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
