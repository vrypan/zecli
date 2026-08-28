const std = @import("std");

const Allocator = std.mem.Allocator;

pub const ValueKind = enum {
    none,
    string,
    int,
    bool_required,
    bool_optional,
};

/// An external program consulted for completion candidates. Generated shell
/// scripts invoke `executable` directly with `arguments` followed by the word
/// being completed, and read one candidate per line from its stdout.
pub const ExternalCompleter = struct {
    executable: []const u8,
    arguments: []const []const u8 = &.{},
};

/// How a shell should complete a flag value or a positional argument.
pub const CompletionKind = union(enum) {
    none,
    files,
    directories,
    commands,
    values: []const []const u8,
    external: ExternalCompleter,
};

pub const FlagSpec = struct {
    name: []const u8,
    aliases: []const []const u8 = &.{},
    short: ?u8 = null,
    value: ValueKind = .none,
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

pub const CommandSpec = struct {
    name: []const u8,
    aliases: []const []const u8 = &.{},
    description: []const u8,
    usage: []const u8,
    flags: []const FlagSpec = &.{},
    arguments: []const ArgumentSpec = &.{},
    extra_help: ?[]const u8 = null,
};

pub const ApplicationSpec = struct {
    name: []const u8,
    description: []const u8,
    usage: []const u8,
    flags: []const FlagSpec = &.{},
    commands: []const CommandSpec = &.{},
    extra_help: ?[]const u8 = null,
};

/// The help flag every generated help listing and completion script offers.
pub const help_flag = FlagSpec{
    .name = "help",
    .short = 'h',
    .description = "Print help",
};

const help_line_width = 120;

pub const FlagValue = struct {
    name: []const u8,
    value: ?[]const u8 = null,
};

pub const Parsed = struct {
    flags: std.ArrayList(FlagValue) = .empty,
    positionals: std.ArrayList([]const u8) = .empty,

    /// Releases the two buffers. Flag names and values are borrowed from argv
    /// and from the specification, so they are not freed.
    pub fn deinit(self: *Parsed, allocator: Allocator) void {
        self.flags.deinit(allocator);
        self.positionals.deinit(allocator);
        self.* = .{};
    }

    pub fn present(self: *const Parsed, name: []const u8) bool {
        for (self.flags.items) |flag| {
            if (std.mem.eql(u8, flag.name, name)) return true;
        }
        return false;
    }

    pub fn last(self: *const Parsed, name: []const u8) ?[]const u8 {
        var i = self.flags.items.len;
        while (i > 0) {
            i -= 1;
            const flag = self.flags.items[i];
            if (std.mem.eql(u8, flag.name, name)) return flag.value;
        }
        return null;
    }
};

// ── Lookup ───────────────────────────────────────────────────────────────────

/// Resolves a command token, which may be a canonical name or an alias, to its
/// canonical specification.
pub fn findCommand(application: ApplicationSpec, token: []const u8) ?CommandSpec {
    for (application.commands) |command| {
        if (std.mem.eql(u8, command.name, token)) return command;
        for (command.aliases) |alias| {
            if (std.mem.eql(u8, alias, token)) return command;
        }
    }
    return null;
}

/// Resolves a long option name, which may be a canonical name or an alias, to
/// its canonical specification.
pub fn findFlag(command: CommandSpec, token: []const u8) ?FlagSpec {
    return findLong(command.flags, token);
}

/// Resolves a root long option name or alias to its canonical specification.
pub fn findApplicationFlag(application: ApplicationSpec, token: []const u8) ?FlagSpec {
    return findLong(application.flags, token);
}

fn findLong(specs: []const FlagSpec, name: []const u8) ?FlagSpec {
    for (specs) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
        for (spec.aliases) |alias| {
            if (std.mem.eql(u8, alias, name)) return spec;
        }
    }
    return null;
}

fn findShort(specs: []const FlagSpec, short: u8) ?FlagSpec {
    for (specs) |spec| {
        if (spec.short == short) return spec;
    }
    return null;
}

pub fn takesValue(flag: FlagSpec) bool {
    return flag.value != .none;
}

/// The completion a shell should offer for a flag value: the explicit kind if
/// one was declared, otherwise the declared choices.
pub fn flagCompletion(flag: FlagSpec) CompletionKind {
    if (flag.completion != .none) return flag.completion;
    if (flag.choices.len > 0) return .{ .values = flag.choices };
    return .none;
}

// ── Specification validation ─────────────────────────────────────────────────

pub const SpecError = error{
    InvalidName,
    DuplicateName,
    AliasEqualsName,
    DuplicateShortOption,
    RequiredArgumentAfterOptional,
    RepeatableArgumentNotLast,
    ChoicesWithoutValue,
    CompletionWithoutValue,
    ConflictingCompletion,
    DefaultNotInChoices,
};

/// Command and long-option names use a conservative grammar that is safe in
/// bash, zsh, and fish: an ASCII alphanumeric followed by ASCII alphanumerics
/// or '-'.
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphanumeric(name[0])) return false;
    for (name[1..]) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '-') return false;
    }
    return true;
}

fn validateFlags(flags: []const FlagSpec) SpecError!void {
    for (flags, 0..) |flag, i| {
        if (!isValidName(flag.name)) return error.InvalidName;
        if (flag.short) |short| {
            if (!std.ascii.isAlphanumeric(short)) return error.InvalidName;
        }

        for (flag.aliases) |alias| {
            if (!isValidName(alias)) return error.InvalidName;
            if (std.mem.eql(u8, alias, flag.name)) return error.AliasEqualsName;
        }

        if (!takesValue(flag)) {
            if (flag.choices.len > 0) return error.ChoicesWithoutValue;
            if (flag.completion != .none) return error.CompletionWithoutValue;
        }

        if (flag.choices.len > 0 and flag.completion != .none) {
            return error.ConflictingCompletion;
        }

        if (flag.choices.len > 0) {
            if (flag.default_value) |value| {
                if (!containsString(flag.choices, value)) return error.DefaultNotInChoices;
            }
        }

        // Duplicate long names, long aliases, and short options in this scope.
        for (flags[i + 1 ..]) |other| {
            if (namesOverlap(flag, other)) return error.DuplicateName;
            if (flag.short != null and flag.short == other.short) {
                return error.DuplicateShortOption;
            }
        }
        for (flag.aliases, 0..) |alias, j| {
            for (flag.aliases[j + 1 ..]) |other| {
                if (std.mem.eql(u8, alias, other)) return error.DuplicateName;
            }
        }
    }
}

fn namesOverlap(a: FlagSpec, b: FlagSpec) bool {
    if (std.mem.eql(u8, a.name, b.name)) return true;
    if (containsString(b.aliases, a.name)) return true;
    for (a.aliases) |alias| {
        if (std.mem.eql(u8, alias, b.name)) return true;
        if (containsString(b.aliases, alias)) return true;
    }
    return false;
}

fn validateArgumentShape(arguments: []const ArgumentSpec) SpecError!void {
    var seen_optional = false;
    for (arguments, 0..) |argument, i| {
        if (argument.required) {
            if (seen_optional) return error.RequiredArgumentAfterOptional;
        } else {
            seen_optional = true;
        }
        if (argument.repeatable and i != arguments.len - 1) {
            return error.RepeatableArgumentNotLast;
        }
    }
}

pub fn validateCommandSpec(spec: CommandSpec) SpecError!void {
    if (!isValidName(spec.name)) return error.InvalidName;
    for (spec.aliases, 0..) |alias, i| {
        if (!isValidName(alias)) return error.InvalidName;
        if (std.mem.eql(u8, alias, spec.name)) return error.AliasEqualsName;
        for (spec.aliases[i + 1 ..]) |other| {
            if (std.mem.eql(u8, alias, other)) return error.DuplicateName;
        }
    }
    try validateFlags(spec.flags);
    try validateArgumentShape(spec.arguments);
}

pub fn validateApplicationSpec(application: ApplicationSpec) SpecError!void {
    if (!isValidName(application.name)) return error.InvalidName;
    try validateFlags(application.flags);

    for (application.commands, 0..) |command, i| {
        try validateCommandSpec(command);
        for (application.commands[i + 1 ..]) |other| {
            if (commandNamesOverlap(command, other)) return error.DuplicateName;
        }
    }
}

fn commandNamesOverlap(a: CommandSpec, b: CommandSpec) bool {
    if (std.mem.eql(u8, a.name, b.name)) return true;
    if (containsString(b.aliases, a.name)) return true;
    for (a.aliases) |alias| {
        if (std.mem.eql(u8, alias, b.name)) return true;
        if (containsString(b.aliases, alias)) return true;
    }
    return false;
}

fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

// ── Parsing ──────────────────────────────────────────────────────────────────

const ParseIssue = enum {
    unknown_option,
    missing_value,
    invalid_int,
    invalid_bool,
    invalid_choice,
    unexpected_inline_value,
    unsupported_short_cluster,
    attached_short_value,
    too_few_arguments,
    too_many_arguments,
};

const ParseDiagnostic = struct {
    issue: ParseIssue = .unknown_option,
    token: []const u8 = "",
    flag_name: ?[]const u8 = null,
    value: ?[]const u8 = null,
    expected: ?[]const u8 = null,
    choices: []const []const u8 = &.{},
};

pub fn parseCommand(
    allocator: Allocator,
    writer: anytype,
    args: []const [:0]const u8,
    spec: CommandSpec,
) !Parsed {
    var diagnostic = ParseDiagnostic{};
    var parsed = parseInternal(allocator, args, spec.flags, &diagnostic) catch |err| {
        if (err != error.InvalidArgument) return err;
        try printParseError(writer, spec, diagnostic);
        return error.ReportedCliError;
    };
    errdefer parsed.deinit(allocator);
    validateArguments(parsed.positionals.items, spec.arguments, &diagnostic) catch |err| {
        if (err != error.InvalidArgument) return err;
        try printParseError(writer, spec, diagnostic);
        return error.ReportedCliError;
    };
    return parsed;
}

pub fn parse(allocator: Allocator, args: []const [:0]const u8, specs: []const FlagSpec) !Parsed {
    return parseInternal(allocator, args, specs, null);
}

/// Reports whether the caller should print help. Scanning stops at the first
/// `--`, so `-h` and `--help` after the separator stay literal arguments.
pub fn helpRequested(args: []const [:0]const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) return false;
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return true;
    }
    return false;
}

fn parseInternal(
    allocator: Allocator,
    args: []const [:0]const u8,
    specs: []const FlagSpec,
    diagnostic: ?*ParseDiagnostic,
) !Parsed {
    var parsed = Parsed{};
    errdefer parsed.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // Empty args, non-flags, and bare "-" are treated as positionals.
        if (arg.len == 0 or arg[0] != '-' or arg.len == 1) {
            try parsed.positionals.append(allocator, arg);
            continue;
        }

        if (arg[1] == '-') {
            if (arg.len == 2) {
                // "--" separator: everything after is positional.
                for (args[i + 1 ..]) |rest| {
                    try parsed.positionals.append(allocator, rest);
                }
                break;
            }
            try parseLong(allocator, args, &i, specs, &parsed, diagnostic);
        } else {
            try parseShort(allocator, args, &i, specs, &parsed, diagnostic);
        }
    }
    return parsed;
}

fn parseLong(
    allocator: Allocator,
    args: []const [:0]const u8,
    index: *usize,
    specs: []const FlagSpec,
    parsed: *Parsed,
    diagnostic: ?*ParseDiagnostic,
) !void {
    const arg = args[index.*];
    const raw = arg[2..];
    const eql_pos = std.mem.indexOfScalar(u8, raw, '=');
    const name = if (eql_pos) |pos| raw[0..pos] else raw;
    const inline_value = if (eql_pos) |pos| raw[pos + 1 ..] else null;

    const spec = findLong(specs, name) orelse {
        setDiagnostic(diagnostic, .{ .issue = .unknown_option, .token = arg });
        return error.InvalidArgument;
    };

    const value = try consumeValue(args, index, spec, inline_value, arg, diagnostic);
    try appendFlag(allocator, parsed, spec, value);
}

fn parseShort(
    allocator: Allocator,
    args: []const [:0]const u8,
    index: *usize,
    specs: []const FlagSpec,
    parsed: *Parsed,
    diagnostic: ?*ParseDiagnostic,
) !void {
    const arg = args[index.*];
    const body = arg[1..];
    if (body.len == 0) return error.InvalidArgument;

    const spec = findShort(specs, body[0]) orelse {
        setDiagnostic(diagnostic, .{ .issue = .unknown_option, .token = arg });
        return error.InvalidArgument;
    };

    const inline_value: ?[]const u8 = if (body.len > 1) blk: {
        if (spec.value == .none) {
            setDiagnostic(diagnostic, .{ .issue = .unsupported_short_cluster, .token = arg });
            return error.InvalidArgument;
        }
        if (!spec.attached_short_value) {
            setDiagnostic(diagnostic, .{
                .issue = .attached_short_value,
                .token = arg,
                .flag_name = spec.name,
            });
            return error.InvalidArgument;
        }
        break :blk body[1..];
    } else null;

    const value = try consumeValue(args, index, spec, inline_value, arg, diagnostic);
    try appendFlag(allocator, parsed, spec, value);
}

fn consumeValue(
    args: []const [:0]const u8,
    index: *usize,
    spec: FlagSpec,
    inline_value: ?[]const u8,
    token: []const u8,
    diagnostic: ?*ParseDiagnostic,
) !?[]const u8 {
    switch (spec.value) {
        .none => {
            if (inline_value != null) {
                setDiagnostic(diagnostic, .{
                    .issue = .unexpected_inline_value,
                    .token = token,
                    .flag_name = spec.name,
                });
                return error.InvalidArgument;
            }
            return null;
        },
        .string, .int, .bool_required => {
            const raw = inline_value orelse blk: {
                index.* += 1;
                if (index.* >= args.len) {
                    setDiagnostic(diagnostic, .{
                        .issue = .missing_value,
                        .token = token,
                        .flag_name = spec.name,
                        .expected = getValueName(spec),
                    });
                    return error.InvalidArgument;
                }
                break :blk args[index.*];
            };

            if (spec.value == .int) {
                _ = std.fmt.parseInt(usize, raw, 10) catch {
                    setDiagnostic(diagnostic, .{
                        .issue = .invalid_int,
                        .token = token,
                        .flag_name = spec.name,
                        .value = raw,
                        .expected = getValueName(spec),
                    });
                    return error.InvalidArgument;
                };
            }

            if (spec.value == .bool_required) {
                _ = parseBool(raw) catch {
                    setDiagnostic(diagnostic, .{
                        .issue = .invalid_bool,
                        .token = token,
                        .flag_name = spec.name,
                        .value = raw,
                        .expected = getValueName(spec),
                    });
                    return error.InvalidArgument;
                };
            }

            try checkChoices(spec, raw, token, diagnostic);
            return raw;
        },
        .bool_optional => {
            const raw = inline_value orelse blk: {
                if (index.* + 1 < args.len) {
                    const next = args[index.* + 1];
                    if (next.len == 0 or next[0] != '-') {
                        index.* += 1;
                        break :blk next;
                    }
                }
                return "true";
            };

            _ = parseBool(raw) catch {
                setDiagnostic(diagnostic, .{
                    .issue = .invalid_bool,
                    .token = token,
                    .flag_name = spec.name,
                    .value = raw,
                    .expected = getValueName(spec),
                });
                return error.InvalidArgument;
            };

            try checkChoices(spec, raw, token, diagnostic);
            return raw;
        },
    }
}

fn checkChoices(
    spec: FlagSpec,
    value: []const u8,
    token: []const u8,
    diagnostic: ?*ParseDiagnostic,
) !void {
    if (spec.choices.len == 0) return;
    if (containsString(spec.choices, value)) return;
    setDiagnostic(diagnostic, .{
        .issue = .invalid_choice,
        .token = token,
        .flag_name = spec.name,
        .value = value,
        .choices = spec.choices,
    });
    return error.InvalidArgument;
}

fn appendFlag(allocator: Allocator, parsed: *Parsed, spec: FlagSpec, value: ?[]const u8) !void {
    // Values are always recorded under the canonical name, never under the
    // alias the caller happened to type.
    if (!spec.repeatable) {
        for (parsed.flags.items) |*item| {
            if (std.mem.eql(u8, item.name, spec.name)) {
                item.value = value;
                return;
            }
        }
    }
    try parsed.flags.append(allocator, .{ .name = spec.name, .value = value });
}

fn validateArguments(
    positionals: []const []const u8,
    arguments: []const ArgumentSpec,
    diagnostic: *ParseDiagnostic,
) !void {
    var min: usize = 0;
    var max: usize = 0;
    var unlimited = false;

    for (arguments) |argument| {
        if (argument.required) min += 1;
        if (argument.repeatable) {
            unlimited = true;
        } else {
            max += 1;
        }
    }

    if (positionals.len < min) {
        diagnostic.* = .{
            .issue = .too_few_arguments,
            .expected = expectedArguments(arguments),
        };
        return error.InvalidArgument;
    }

    if (!unlimited and positionals.len > max) {
        diagnostic.* = .{
            .issue = .too_many_arguments,
            .value = positionals[positionals.len - 1],
            .expected = expectedArguments(arguments),
        };
        return error.InvalidArgument;
    }
}

fn expectedArguments(arguments: []const ArgumentSpec) []const u8 {
    for (arguments) |argument| {
        if (argument.required) return argument.name;
    }
    if (arguments.len > 0) return arguments[0].name;
    return "";
}

fn setDiagnostic(diagnostic: ?*ParseDiagnostic, value: ParseDiagnostic) void {
    if (diagnostic) |target| target.* = value;
}

pub fn parseBool(value: []const u8) !bool {
    if (value.len == 0) return error.InvalidArgument;
    switch (value[0]) {
        't', 'T' => if (std.ascii.eqlIgnoreCase(value, "true")) return true,
        'f', 'F' => if (std.ascii.eqlIgnoreCase(value, "false")) return false,
        'y', 'Y' => if (std.ascii.eqlIgnoreCase(value, "yes")) return true,
        'n', 'N' => if (std.ascii.eqlIgnoreCase(value, "no")) return false,
        '1' => if (value.len == 1) return true,
        '0' => if (value.len == 1) return false,
        else => {},
    }
    return error.InvalidArgument;
}

fn printParseError(writer: anytype, spec: CommandSpec, diagnostic: ParseDiagnostic) !void {
    const flag_name = diagnostic.flag_name orelse diagnostic.token;
    const label = commandLabel(spec);

    switch (diagnostic.issue) {
        .unknown_option => try writer.print(
            "error: unknown option '{s}'\n",
            .{diagnostic.token},
        ),
        .missing_value => try writer.print(
            "error: option '--{s}' requires <{s}>\n",
            .{ flag_name, diagnostic.expected orelse "VALUE" },
        ),
        .invalid_int => try writer.print(
            "error: invalid value for '--{s}': expected {s}, got '{s}'\n",
            .{ flag_name, diagnostic.expected orelse "N", diagnostic.value orelse "" },
        ),
        .invalid_bool => try writer.print(
            "error: invalid value for '--{s}': expected {s}, got '{s}'\n",
            .{ flag_name, diagnostic.expected orelse "BOOL", diagnostic.value orelse "" },
        ),
        .invalid_choice => {
            try writer.print(
                "error: invalid value for '--{s}': '{s}' is not one of ",
                .{ flag_name, diagnostic.value orelse "" },
            );
            for (diagnostic.choices, 0..) |choice, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("'{s}'", .{choice});
            }
            try writer.writeByte('\n');
        },
        .unexpected_inline_value => try writer.print(
            "error: option '--{s}' does not accept a value\n",
            .{diagnostic.flag_name orelse diagnostic.token},
        ),
        .unsupported_short_cluster => try writer.print(
            "error: unsupported short option cluster '{s}'\n",
            .{diagnostic.token},
        ),
        .attached_short_value => try writer.print(
            "error: option '-{c}' does not accept an attached value\n",
            .{shortName(spec.flags, diagnostic.flag_name)},
        ),
        .too_few_arguments => try writer.print(
            "error: missing required argument <{s}> for '{s}'\n",
            .{ diagnostic.expected orelse "ARG", label },
        ),
        .too_many_arguments => try writer.print(
            "error: too many arguments for '{s}'\n",
            .{label},
        ),
    }

    try writer.print(
        "\nUsage: {s}\n\nTry '{s} --help' for more information.\n",
        .{ spec.usage, label },
    );
}

fn shortName(flags: []const FlagSpec, name: ?[]const u8) u8 {
    const wanted = name orelse return '?';
    for (flags) |flag| {
        if (std.mem.eql(u8, flag.name, wanted)) return flag.short orelse '?';
    }
    return '?';
}

fn commandLabel(spec: CommandSpec) []const u8 {
    const marker = std.mem.indexOf(u8, spec.usage, " [") orelse spec.usage.len;
    return spec.usage[0..marker];
}

// ── Help ─────────────────────────────────────────────────────────────────────

pub fn printApplicationHelp(allocator: Allocator, writer: anytype, application: ApplicationSpec) !void {
    _ = try printWrapped(writer, application.description, 0, 0);
    try writer.print("\n\nUsage: {s}\n", .{application.usage});
    try printCommandList(allocator, writer, application.commands);
    try printOptions(allocator, writer, application.flags, true);
    if (application.extra_help) |extra| try writer.print("\n{s}", .{extra});
}

pub fn printCommandHelp(allocator: Allocator, writer: anytype, spec: CommandSpec) !void {
    _ = try printWrapped(writer, spec.description, 0, 0);
    try writer.print("\n\nUsage: {s}\n", .{spec.usage});
    try printArguments(writer, spec.arguments);
    try printOptions(allocator, writer, spec.flags, true);
    if (spec.extra_help) |extra| try writer.print("\n{s}", .{extra});
}

/// Renders "name" or "name, alias, alias" for the command list.
fn commandLabelAlloc(allocator: Allocator, spec: CommandSpec) ![]const u8 {
    if (spec.aliases.len == 0) return allocator.dupe(u8, spec.name);

    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);
    try buffer.appendSlice(allocator, spec.name);
    for (spec.aliases) |alias| {
        try buffer.appendSlice(allocator, ", ");
        try buffer.appendSlice(allocator, alias);
    }
    return buffer.toOwnedSlice(allocator);
}

pub fn printCommandList(allocator: Allocator, writer: anytype, commands: []const CommandSpec) !void {
    if (commands.len == 0) return;

    try writer.writeAll("\nCommands:\n");

    var max_label_len: usize = 0;
    for (commands) |command| {
        const label = try commandLabelAlloc(allocator, command);
        defer allocator.free(label);
        max_label_len = @max(max_label_len, label.len);
    }

    for (commands) |command| {
        const label = try commandLabelAlloc(allocator, command);
        defer allocator.free(label);

        try writer.print("  {s}", .{label});
        const description_col = max_label_len + 4;
        try writeSpaces(writer, max_label_len - label.len + 2);
        _ = try printWrapped(writer, command.description, description_col, description_col);
        try writer.writeByte('\n');
    }
}

pub fn printArguments(writer: anytype, arguments: []const ArgumentSpec) !void {
    if (arguments.len == 0) return;

    try writer.writeAll("\nArguments:\n");

    var max_label_len: usize = 0;
    for (arguments) |argument| {
        max_label_len = @max(max_label_len, argumentLabelLen(argument));
    }

    for (arguments) |argument| {
        try writeArgumentLabel(writer, argument);
        const description_col = max_label_len + 4;
        try writeSpaces(writer, max_label_len - argumentLabelLen(argument) + 2);
        _ = try printWrapped(writer, argument.description, description_col, description_col);
        try writer.writeByte('\n');
    }
}

pub fn printOptions(
    allocator: Allocator,
    writer: anytype,
    flags: []const FlagSpec,
    include_help: bool,
) !void {
    if (flags.len == 0 and !include_help) return;

    try writer.writeAll("\nOptions:\n");

    var max_label_len: usize = 0;
    for (flags) |flag| {
        const label = try flagLabel(allocator, flag);
        defer allocator.free(label);
        max_label_len = @max(max_label_len, label.len);
    }
    if (include_help) {
        max_label_len = @max(max_label_len, "  -h, --help".len);
    }

    for (flags) |flag| {
        const label = try flagLabel(allocator, flag);
        defer allocator.free(label);
        try printOption(allocator, writer, label, flag, max_label_len);
    }

    if (include_help) {
        try printOption(allocator, writer, "  -h, --help", help_flag, max_label_len);
    }
}

fn printOption(
    allocator: Allocator,
    writer: anytype,
    label: []const u8,
    flag: FlagSpec,
    max_label_len: usize,
) !void {
    try writer.print("{s}", .{label});
    const description_col = max_label_len + 2;
    try writeSpaces(writer, max_label_len - label.len + 2);

    var line_len = try printWrapped(writer, flag.description, description_col, description_col);

    if (flag.choices.len > 0) {
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(allocator);
        try buffer.appendSlice(allocator, "[choices: ");
        for (flag.choices, 0..) |choice, i| {
            if (i > 0) try buffer.appendSlice(allocator, ", ");
            try buffer.appendSlice(allocator, choice);
        }
        try buffer.append(allocator, ']');
        line_len = try printWrapped(writer, buffer.items, description_col, line_len);
    }

    if (flag.default_value) |value| {
        const suffix = try std.fmt.allocPrint(allocator, "[default: {s}]", .{value});
        defer allocator.free(suffix);
        line_len = try printWrapped(writer, suffix, description_col, line_len);
    }

    if (flag.repeatable) {
        _ = try printWrapped(writer, "[repeatable]", description_col, line_len);
    }

    try writer.writeByte('\n');
}

fn printWrapped(writer: anytype, text: []const u8, indent: usize, initial_line_len: usize) !usize {
    var line_len = initial_line_len;
    var pos: usize = 0;

    while (pos < text.len) {
        // Skip leading spaces.
        while (pos < text.len and text[pos] == ' ') pos += 1;
        if (pos >= text.len) break;

        // Extract the next word.
        const start = pos;
        while (pos < text.len and text[pos] != ' ') pos += 1;
        const word = text[start..pos];

        var remaining = word;
        while (remaining.len > 0) {
            const sep: usize = if (line_len == indent) 0 else 1;
            const available = if (help_line_width > line_len + sep)
                help_line_width - line_len - sep
            else
                0;

            if (remaining.len <= available) {
                if (sep == 1) {
                    try writer.writeByte(' ');
                    line_len += 1;
                }
                try writer.writeAll(remaining);
                line_len += remaining.len;
                break;
            }

            if (line_len > indent) {
                try writer.writeByte('\n');
                try writeSpaces(writer, indent);
                line_len = indent;
                continue;
            }

            const chunk_len = @min(
                remaining.len,
                if (help_line_width > indent) help_line_width - indent else 1,
            );
            try writer.writeAll(remaining[0..chunk_len]);
            line_len += chunk_len;
            remaining = remaining[chunk_len..];

            if (remaining.len > 0) {
                try writer.writeByte('\n');
                try writeSpaces(writer, indent);
                line_len = indent;
            }
        }
    }

    return line_len;
}

/// Renders "  -n, --name, --nom <TEXT>" for the option list.
fn flagLabel(allocator: Allocator, spec: FlagSpec) ![]const u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    if (spec.short) |short| {
        try buffer.appendSlice(allocator, "  -");
        try buffer.append(allocator, short);
        try buffer.appendSlice(allocator, ", ");
    } else {
        try buffer.appendSlice(allocator, "      ");
    }

    try buffer.appendSlice(allocator, "--");
    try buffer.appendSlice(allocator, spec.name);
    for (spec.aliases) |alias| {
        try buffer.appendSlice(allocator, ", --");
        try buffer.appendSlice(allocator, alias);
    }

    const value_name = getValueName(spec);
    switch (spec.value) {
        .none => {},
        .string, .int, .bool_required => {
            try buffer.appendSlice(allocator, " <");
            try buffer.appendSlice(allocator, value_name);
            try buffer.append(allocator, '>');
        },
        .bool_optional => {
            try buffer.appendSlice(allocator, "[=");
            try buffer.appendSlice(allocator, value_name);
            try buffer.append(allocator, ']');
        },
    }

    return buffer.toOwnedSlice(allocator);
}

pub fn getValueName(spec: FlagSpec) []const u8 {
    if (spec.value_name) |name| return name;
    return switch (spec.value) {
        .none => "",
        .string => "VALUE",
        .int => "N",
        .bool_required, .bool_optional => "BOOL",
    };
}

fn argumentLabelLen(argument: ArgumentSpec) usize {
    const brackets: usize = 2;
    const repeat: usize = if (argument.repeatable) 3 else 0;
    return argument.name.len + brackets + repeat;
}

fn writeArgumentLabel(writer: anytype, argument: ArgumentSpec) !void {
    try writer.writeAll("  ");
    if (argument.required) {
        try writer.print("<{s}>", .{argument.name});
    } else {
        try writer.print("[{s}]", .{argument.name});
    }
    if (argument.repeatable) try writer.writeAll("...");
}

fn writeSpaces(writer: anytype, count: usize) !void {
    const spaces = " " ** 120;
    var remaining = count;
    while (remaining > 0) {
        const chunk = @min(remaining, spaces.len);
        try writer.writeAll(spaces[0..chunk]);
        remaining -= chunk;
    }
}
