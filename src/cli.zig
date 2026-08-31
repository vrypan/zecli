const std = @import("std");

const Allocator = std.mem.Allocator;

pub const ValueKind = enum {
    none,
    string,
    int,
    signed_int,
    float,
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
    /// Set by `findCommand` from the containing application's `prefix`.
    environment_prefix: ?[]const u8 = null,
};

pub const ApplicationSpec = struct {
    name: []const u8,
    prefix: ?[]const u8 = null,
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

/// Stack space for the `[choices: ...]` and `[default: ...]` suffixes, past
/// which `printOption` falls back to its allocator.
const suffix_stack_size = 256;

pub const ValueSource = enum {
    command_line,
    environment,
    default,
};

pub const ParsedValue = union(enum) {
    none,
    string: []const u8,
    int: usize,
    signed_int: i64,
    float: f64,
    bool: bool,
};

pub const FlagValue = struct {
    name: []const u8,
    value: ?[]const u8 = null,
    parsed_value: ParsedValue = .none,
    source: ValueSource = .command_line,
};

pub const GetValueAsError = error{
    IncompatibleValueType,
    IntegerOverflow,
    UnsupportedValueType,
};

pub const Parsed = struct {
    flags: std.ArrayList(FlagValue) = .empty,
    positionals: std.ArrayList([]const u8) = .empty,

    /// Releases the two buffers. Flag names and values are borrowed from argv,
    /// the environment map, and the specification, so they are not freed.
    pub fn deinit(self: *Parsed, allocator: Allocator) void {
        self.flags.deinit(allocator);
        self.positionals.deinit(allocator);
        self.* = .{};
    }

    pub fn present(self: *const Parsed, name: []const u8) bool {
        for (self.flags.items) |flag| {
            if (flag.source == .command_line and std.mem.eql(u8, flag.name, name)) return true;
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

    /// Returns the final effective value when it has exactly type `T`, or null
    /// when the option is absent or has a different value kind.
    pub fn getValue(self: *const Parsed, comptime T: type, name: []const u8) ?T {
        var i = self.flags.items.len;
        while (i > 0) {
            i -= 1;
            const flag = self.flags.items[i];
            if (!std.mem.eql(u8, flag.name, name)) continue;
            return exactValue(T, flag.parsed_value);
        }
        return null;
    }

    /// Iterates over every effective value for a repeatable option in command
    /// line order. An omitted option with a default yields that default once.
    pub fn getValues(self: *const Parsed, comptime T: type, name: []const u8) ValueIterator(T) {
        return .{ .parsed = self, .name = name };
    }

    /// Returns the final effective value converted to `T`, or null when the
    /// option has no effective value. Numeric conversions are checked for
    /// overflow.
    pub fn getValueAs(self: *const Parsed, comptime T: type, name: []const u8) GetValueAsError!?T {
        var i = self.flags.items.len;
        while (i > 0) {
            i -= 1;
            const flag = self.flags.items[i];
            if (!std.mem.eql(u8, flag.name, name)) continue;
            return try convertValue(T, flag);
        }
        return null;
    }
};

pub const ParsedInvocation = struct {
    pub const Command = struct {
        spec: CommandSpec,
        parsed: Parsed,
    };

    root: Parsed = .{},
    command: ?Command = null,
    command_token: ?[]const u8 = null,

    pub fn deinit(self: *ParsedInvocation, allocator: Allocator) void {
        self.root.deinit(allocator);
        if (self.command) |*command| command.parsed.deinit(allocator);
        self.* = .{};
    }
};

pub fn ValueIterator(comptime T: type) type {
    return struct {
        parsed: *const Parsed,
        name: []const u8,
        index: usize = 0,

        pub fn next(self: *@This()) ?T {
            while (self.index < self.parsed.flags.items.len) {
                const flag = self.parsed.flags.items[self.index];
                self.index += 1;
                if (!std.mem.eql(u8, flag.name, self.name)) continue;
                if (exactValue(T, flag.parsed_value)) |value| return value;
            }
            return null;
        }
    };
}

fn exactValue(comptime T: type, value: ParsedValue) ?T {
    return switch (value) {
        .string => |raw| if (T == []const u8) raw else null,
        .int => |number| if (T == usize) number else null,
        .signed_int => |number| if (T == i64) number else null,
        .float => |number| if (T == f64) number else null,
        .bool => |boolean| if (T == bool) boolean else null,
        .none => null,
    };
}

fn convertValue(comptime T: type, flag: FlagValue) GetValueAsError!T {
    if (T == []const u8) return flag.value orelse return error.IncompatibleValueType;
    if (T == bool) return switch (flag.parsed_value) {
        .bool => |value| value,
        else => error.IncompatibleValueType,
    };

    return switch (@typeInfo(T)) {
        .int => switch (flag.parsed_value) {
            .int => |value| std.math.cast(T, value) orelse error.IntegerOverflow,
            .signed_int => |value| std.math.cast(T, value) orelse error.IntegerOverflow,
            else => error.IncompatibleValueType,
        },
        .float => switch (flag.parsed_value) {
            .float => |value| @floatCast(value),
            else => error.IncompatibleValueType,
        },
        else => error.UnsupportedValueType,
    };
}

// ── Lookup ───────────────────────────────────────────────────────────────────

/// Resolves a command token, which may be a canonical name or an alias, to its
/// canonical specification.
pub fn findCommand(application: ApplicationSpec, token: []const u8) ?CommandSpec {
    for (application.commands) |command| {
        if (std.mem.eql(u8, command.name, token)) return resolvedCommand(application, command);
        for (command.aliases) |alias| {
            if (std.mem.eql(u8, alias, token)) return resolvedCommand(application, command);
        }
    }
    return null;
}

fn resolvedCommand(application: ApplicationSpec, command: CommandSpec) CommandSpec {
    var result = command;
    result.environment_prefix = application.prefix;
    return result;
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
    const index = findLongIndex(specs, name) orelse return null;
    return specs[index];
}

fn findLongIndex(specs: []const FlagSpec, name: []const u8) ?usize {
    for (specs, 0..) |spec, i| {
        if (std.mem.eql(u8, spec.name, name)) return i;
        for (spec.aliases) |alias| {
            if (std.mem.eql(u8, alias, name)) return i;
        }
    }
    return null;
}

fn findShort(specs: []const FlagSpec, short: u8) ?FlagSpec {
    const index = findShortIndex(specs, short) orelse return null;
    return specs[index];
}

fn findShortIndex(specs: []const FlagSpec, short: u8) ?usize {
    for (specs, 0..) |spec, i| {
        if (spec.short == short) return i;
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
    InvalidDefaultValue,
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

        if (flag.default_value) |value| {
            _ = parseDefaultValue(flag, value) catch return error.InvalidDefaultValue;
            if (flag.choices.len > 0) {
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

/// Validates a specification at compile time and returns it unchanged, so an
/// invalid specification is a compile error rather than a runtime one and the
/// validation code never reaches the binary:
///
///     const application = cli.comptimeValidated(.{
///         .name = "demo",
///         .description = "A demo",
///         .usage = "demo [options] <command>",
///         .commands = &commands,
///     });
///
/// Every field must be comptime-known. A specification built at runtime has to
/// use `validateApplicationSpec` instead.
pub fn comptimeValidated(comptime application: ApplicationSpec) ApplicationSpec {
    comptime {
        // Validation compares every pair of names in a scope, so its cost grows
        // with the square of the specification, and the default 1000 backwards
        // branches runs out on a real application. Raise the limit enough to
        // walk the specification, then to the bound the comparisons need.
        // @setEvalBranchQuota only ever raises, so a caller that already asked
        // for more keeps it.
        @setEvalBranchQuota(walk_branch_quota);
        @setEvalBranchQuota(validationBranchQuota(application));
        validateApplicationSpec(application) catch |err| @compileError(
            "invalid ApplicationSpec '" ++ application.name ++ "': " ++ @errorName(err),
        );
    }
    return application;
}

/// Enough branches to walk any realistic specification and count its names,
/// which `validationBranchQuota` has to do before it can size the real quota.
const walk_branch_quota = 100_000;

/// Branches per name comparison: each one walks two names and, for an option,
/// its aliases. Deliberately generous, since the quota only caps compile-time
/// evaluation and costs nothing when it is not reached.
const branches_per_comparison = 64;

/// An upper bound on the branches `validateApplicationSpec` needs, from the
/// number of name pairs it compares.
fn validationBranchQuota(comptime application: ApplicationSpec) usize {
    var pairs = scopeNameCount(application.flags);
    pairs *= pairs;

    var command_names: usize = 0;
    for (application.commands) |command| {
        command_names += 1 + command.aliases.len;
        const flag_names = scopeNameCount(command.flags);
        pairs += flag_names * flag_names;
        pairs += command.arguments.len * command.arguments.len;
    }
    pairs += command_names * command_names;

    return walk_branch_quota + branches_per_comparison * pairs;
}

/// Every spelling an option in this scope can be written as.
fn scopeNameCount(flags: []const FlagSpec) usize {
    var count: usize = 0;
    for (flags) |flag| count += 1 + flag.aliases.len;
    return count;
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
    invalid_float,
    invalid_bool,
    invalid_choice,
    invalid_environment_value,
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
    environ: *const std.process.Environ.Map,
) !Parsed {
    var diagnostic = ParseDiagnostic{};
    var parsed = parseInternal(allocator, args, spec.flags, spec.environment_prefix, environ, &diagnostic) catch |err| {
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

/// Parses an application invocation with root options before its command.
/// Root options after the command are not supported by this entry point.
pub fn parseInvocation(
    allocator: Allocator,
    writer: anytype,
    args: []const [:0]const u8,
    application: ApplicationSpec,
    environ: *const std.process.Environ.Map,
) !ParsedInvocation {
    const boundary = rootCommandBoundary(application, args);
    const root_args = args[0..boundary];
    const root_spec = CommandSpec{
        .name = application.name,
        .description = application.description,
        .usage = application.usage,
        .flags = application.flags,
    };

    var diagnostic = ParseDiagnostic{};
    var root = parseInternal(allocator, root_args, application.flags, application.prefix, environ, &diagnostic) catch |err| {
        if (err != error.InvalidArgument) return err;
        try printParseError(writer, root_spec, diagnostic);
        return error.ReportedCliError;
    };
    errdefer root.deinit(allocator);

    if (boundary == args.len) return .{ .root = root };

    const token = args[boundary];
    const command_spec = findCommand(application, token) orelse {
        return .{ .root = root, .command_token = token };
    };
    const command_parsed = try parseCommand(allocator, writer, args[boundary + 1 ..], command_spec, environ);
    return .{
        .root = root,
        .command = .{ .spec = command_spec, .parsed = command_parsed },
        .command_token = token,
    };
}

fn rootCommandBoundary(application: ApplicationSpec, args: []const [:0]const u8) usize {
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (arg.len == 0 or arg[0] != '-' or arg.len == 1 or std.mem.eql(u8, arg, "--")) return i;

        if (arg[1] == '-') {
            const raw = arg[2..];
            const eql_pos = std.mem.indexOfScalar(u8, raw, '=');
            const name = if (eql_pos) |pos| raw[0..pos] else raw;
            const inline_value = eql_pos != null;
            if (findApplicationFlag(application, name)) |flag| {
                if (rootFlagConsumesNext(application, flag, inline_value, args, i)) i += 1;
            }
        } else if (findShort(application.flags, arg[1])) |flag| {
            if (rootFlagConsumesNext(application, flag, arg.len > 2, args, i)) i += 1;
        }
        i += 1;
    }
    return i;
}

fn rootFlagConsumesNext(
    application: ApplicationSpec,
    flag: FlagSpec,
    inline_value: bool,
    args: []const [:0]const u8,
    index: usize,
) bool {
    if (inline_value or flag.value == .none or index + 1 >= args.len) return false;
    if (flag.value != .bool_optional) return true;

    const next = args[index + 1];
    if (next.len == 0 or next[0] == '-') return false;
    return findCommand(application, next) == null;
}

pub fn parse(allocator: Allocator, args: []const [:0]const u8, specs: []const FlagSpec) !Parsed {
    return parseInternal(allocator, args, specs, null, null, null);
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
    environment_prefix: ?[]const u8,
    environ: ?*const std.process.Environ.Map,
    diagnostic: ?*ParseDiagnostic,
) !Parsed {
    var parsed = Parsed{};
    errdefer parsed.deinit(allocator);
    const seen = try allocator.alloc(bool, specs.len);
    defer allocator.free(seen);
    @memset(seen, false);

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
            try parseLong(allocator, args, &i, specs, seen, &parsed, diagnostic);
        } else {
            try parseShort(allocator, args, &i, specs, seen, &parsed, diagnostic);
        }
    }
    if (environment_prefix) |prefix| {
        try appendEnvironment(allocator, &parsed, specs, seen, prefix, environ.?, diagnostic);
    }
    try appendDefaults(allocator, &parsed, specs, seen);
    return parsed;
}

fn appendDefaults(allocator: Allocator, parsed: *Parsed, specs: []const FlagSpec, seen: []bool) !void {
    for (specs, 0..) |spec, i| {
        const value = spec.default_value orelse continue;
        if (seen[i]) continue;
        const parsed_value = try parseDefaultValue(spec, value);
        try parsed.flags.append(allocator, .{
            .name = spec.name,
            .value = value,
            .parsed_value = parsed_value,
            .source = .default,
        });
        seen[i] = true;
    }
}

fn appendEnvironment(
    allocator: Allocator,
    parsed: *Parsed,
    specs: []const FlagSpec,
    seen: []bool,
    prefix: []const u8,
    environ: *const std.process.Environ.Map,
    diagnostic: ?*ParseDiagnostic,
) !void {
    for (specs, 0..) |spec, i| {
        if (seen[i] or !takesValue(spec)) continue;

        var fallback = std.heap.stackFallback(128, allocator);
        const name_allocator = fallback.get();
        var name: std.ArrayList(u8) = .empty;
        defer name.deinit(name_allocator);
        try name.appendSlice(name_allocator, prefix);
        try name.append(name_allocator, '_');
        for (spec.name) |char| {
            try name.append(name_allocator, if (char == '-') '_' else std.ascii.toUpper(char));
        }

        const raw = environ.get(name.items) orelse continue;
        const parsed_value = parseDefaultValue(spec, raw) catch {
            setDiagnostic(diagnostic, .{
                .issue = .invalid_environment_value,
                .flag_name = spec.name,
                .value = raw,
            });
            return error.InvalidArgument;
        };
        if (spec.choices.len > 0 and !containsString(spec.choices, raw)) {
            setDiagnostic(diagnostic, .{
                .issue = .invalid_environment_value,
                .flag_name = spec.name,
                .value = raw,
            });
            return error.InvalidArgument;
        }

        try parsed.flags.append(allocator, .{
            .name = spec.name,
            .value = raw,
            .parsed_value = parsed_value,
            .source = .environment,
        });
        seen[i] = true;
    }
}

fn parseLong(
    allocator: Allocator,
    args: []const [:0]const u8,
    index: *usize,
    specs: []const FlagSpec,
    seen: []bool,
    parsed: *Parsed,
    diagnostic: ?*ParseDiagnostic,
) !void {
    const arg = args[index.*];
    const raw = arg[2..];
    const eql_pos = std.mem.indexOfScalar(u8, raw, '=');
    const name = if (eql_pos) |pos| raw[0..pos] else raw;
    const inline_value = if (eql_pos) |pos| raw[pos + 1 ..] else null;

    const spec_index = findLongIndex(specs, name) orelse {
        setDiagnostic(diagnostic, .{ .issue = .unknown_option, .token = arg });
        return error.InvalidArgument;
    };
    const spec = specs[spec_index];

    const value = try consumeValue(args, index, spec, inline_value, arg, diagnostic);
    try appendFlag(allocator, parsed, spec, spec_index, seen, value);
}

fn parseShort(
    allocator: Allocator,
    args: []const [:0]const u8,
    index: *usize,
    specs: []const FlagSpec,
    seen: []bool,
    parsed: *Parsed,
    diagnostic: ?*ParseDiagnostic,
) !void {
    const arg = args[index.*];
    const body = arg[1..];
    if (body.len == 0) return error.InvalidArgument;

    const spec_index = findShortIndex(specs, body[0]) orelse {
        setDiagnostic(diagnostic, .{ .issue = .unknown_option, .token = arg });
        return error.InvalidArgument;
    };
    const spec = specs[spec_index];

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
    try appendFlag(allocator, parsed, spec, spec_index, seen, value);
}

const ConsumedValue = struct {
    raw: ?[]const u8,
    parsed: ParsedValue,
};

fn consumeValue(
    args: []const [:0]const u8,
    index: *usize,
    spec: FlagSpec,
    inline_value: ?[]const u8,
    token: []const u8,
    diagnostic: ?*ParseDiagnostic,
) !ConsumedValue {
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
            return .{ .raw = null, .parsed = .none };
        },
        .string, .int, .signed_int, .float, .bool_required => {
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
                const value = std.fmt.parseInt(usize, raw, 10) catch {
                    setDiagnostic(diagnostic, .{
                        .issue = .invalid_int,
                        .token = token,
                        .flag_name = spec.name,
                        .value = raw,
                        .expected = getValueName(spec),
                    });
                    return error.InvalidArgument;
                };
                try checkChoices(spec, raw, token, diagnostic);
                return .{ .raw = raw, .parsed = .{ .int = value } };
            }

            if (spec.value == .signed_int) {
                const value = std.fmt.parseInt(i64, raw, 10) catch {
                    setDiagnostic(diagnostic, .{
                        .issue = .invalid_int,
                        .token = token,
                        .flag_name = spec.name,
                        .value = raw,
                        .expected = getValueName(spec),
                    });
                    return error.InvalidArgument;
                };
                try checkChoices(spec, raw, token, diagnostic);
                return .{ .raw = raw, .parsed = .{ .signed_int = value } };
            }

            if (spec.value == .float) {
                const value = std.fmt.parseFloat(f64, raw) catch {
                    setDiagnostic(diagnostic, .{
                        .issue = .invalid_float,
                        .token = token,
                        .flag_name = spec.name,
                        .value = raw,
                        .expected = getValueName(spec),
                    });
                    return error.InvalidArgument;
                };
                try checkChoices(spec, raw, token, diagnostic);
                return .{ .raw = raw, .parsed = .{ .float = value } };
            }

            if (spec.value == .bool_required) {
                const value = parseBool(raw) catch {
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
                return .{ .raw = raw, .parsed = .{ .bool = value } };
            }

            try checkChoices(spec, raw, token, diagnostic);
            return .{ .raw = raw, .parsed = .{ .string = raw } };
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
                break :blk "true";
            };

            const value = parseBool(raw) catch {
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
            return .{ .raw = raw, .parsed = .{ .bool = value } };
        },
    }
}

fn parseDefaultValue(spec: FlagSpec, raw: []const u8) !ParsedValue {
    return switch (spec.value) {
        .none => error.InvalidArgument,
        .string => .{ .string = raw },
        .int => .{ .int = try std.fmt.parseInt(usize, raw, 10) },
        .signed_int => .{ .signed_int = try std.fmt.parseInt(i64, raw, 10) },
        .float => .{ .float = try std.fmt.parseFloat(f64, raw) },
        .bool_required, .bool_optional => .{ .bool = try parseBool(raw) },
    };
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

fn appendFlag(
    allocator: Allocator,
    parsed: *Parsed,
    spec: FlagSpec,
    spec_index: usize,
    seen: []bool,
    value: ConsumedValue,
) !void {
    // Values are always recorded under the canonical name, never under the
    // alias the caller happened to type.
    if (!spec.repeatable) {
        for (parsed.flags.items) |*item| {
            if (std.mem.eql(u8, item.name, spec.name)) {
                item.value = value.raw;
                item.parsed_value = value.parsed;
                seen[spec_index] = true;
                return;
            }
        }
    }
    try parsed.flags.append(allocator, .{
        .name = spec.name,
        .value = value.raw,
        .parsed_value = value.parsed,
    });
    seen[spec_index] = true;
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
        .invalid_float => try writer.print(
            "error: invalid value for '--{s}': expected {s}, got '{s}'\n",
            .{ flag_name, diagnostic.expected orelse "NUMBER", diagnostic.value orelse "" },
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
        .invalid_environment_value => try writer.print(
            "error: invalid environment value for '--{s}': '{s}'\n",
            .{ flag_name, diagnostic.value orelse "" },
        ),
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
    try printCommandList(writer, application.commands);
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

/// Width of "name" or "name, alias, alias", computed without building it, so
/// that the column measuring pass costs no allocation.
fn commandLabelLen(spec: CommandSpec) usize {
    var len = spec.name.len;
    for (spec.aliases) |alias| len += ", ".len + alias.len;
    return len;
}

/// Writes what `commandLabelLen` measures.
fn writeCommandLabel(writer: anytype, spec: CommandSpec) !void {
    try writer.writeAll(spec.name);
    for (spec.aliases) |alias| {
        try writer.writeAll(", ");
        try writer.writeAll(alias);
    }
}

pub fn printCommandList(writer: anytype, commands: []const CommandSpec) !void {
    if (commands.len == 0) return;

    try writer.writeAll("\nCommands:\n");

    var max_label_len: usize = 0;
    for (commands) |command| {
        max_label_len = @max(max_label_len, commandLabelLen(command));
    }

    for (commands) |command| {
        try writer.writeAll("  ");
        try writeCommandLabel(writer, command);
        const description_col = max_label_len + 4;
        try writeSpaces(writer, max_label_len - commandLabelLen(command) + 2);
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
        max_label_len = @max(max_label_len, flagLabelLen(flag));
    }
    if (include_help) {
        max_label_len = @max(max_label_len, flagLabelLen(help_flag));
    }

    for (flags) |flag| {
        try printOption(allocator, writer, flag, max_label_len);
    }

    if (include_help) {
        try printOption(allocator, writer, help_flag, max_label_len);
    }
}

fn printOption(
    allocator: Allocator,
    writer: anytype,
    flag: FlagSpec,
    max_label_len: usize,
) !void {
    try writeFlagLabel(writer, flag);
    const description_col = max_label_len + 2;
    try writeSpaces(writer, max_label_len - flagLabelLen(flag) + 2);

    var line_len = try printWrapped(writer, flag.description, description_col, description_col);

    // The suffixes have to be contiguous for printWrapped to break them on
    // word boundaries, but they are short: a stack buffer covers every
    // realistic option, and the allocator only takes over past that.
    var fallback = std.heap.stackFallback(suffix_stack_size, allocator);
    const suffix_allocator = fallback.get();

    if (flag.choices.len > 0) {
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(suffix_allocator);
        try buffer.appendSlice(suffix_allocator, "[choices: ");
        for (flag.choices, 0..) |choice, i| {
            if (i > 0) try buffer.appendSlice(suffix_allocator, ", ");
            try buffer.appendSlice(suffix_allocator, choice);
        }
        try buffer.append(suffix_allocator, ']');
        line_len = try printWrapped(writer, buffer.items, description_col, line_len);
    }

    if (flag.default_value) |value| {
        const suffix = try std.fmt.allocPrint(suffix_allocator, "[default: {s}]", .{value});
        defer suffix_allocator.free(suffix);
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
/// Width of an option label, computed without building it, so that the column
/// measuring pass costs no allocation.
fn flagLabelLen(spec: FlagSpec) usize {
    // "  -s, " or the six spaces that stand in for a missing short option.
    var len: usize = 6;
    len += "--".len + spec.name.len;
    for (spec.aliases) |alias| len += ", --".len + alias.len;
    len += switch (spec.value) {
        .none => 0,
        // " <NAME>"
        .string, .int, .signed_int, .float, .bool_required => 3 + getValueName(spec).len,
        // "[=NAME]"
        .bool_optional => 3 + getValueName(spec).len,
    };
    return len;
}

/// Writes what `flagLabelLen` measures.
fn writeFlagLabel(writer: anytype, spec: FlagSpec) !void {
    if (spec.short) |short| {
        try writer.writeAll("  -");
        try writer.writeByte(short);
        try writer.writeAll(", ");
    } else {
        try writer.writeAll("      ");
    }

    try writer.writeAll("--");
    try writer.writeAll(spec.name);
    for (spec.aliases) |alias| {
        try writer.writeAll(", --");
        try writer.writeAll(alias);
    }

    const value_name = getValueName(spec);
    switch (spec.value) {
        .none => {},
        .string, .int, .signed_int, .float, .bool_required => {
            try writer.writeAll(" <");
            try writer.writeAll(value_name);
            try writer.writeByte('>');
        },
        .bool_optional => {
            try writer.writeAll("[=");
            try writer.writeAll(value_name);
            try writer.writeByte(']');
        },
    }
}

pub fn getValueName(spec: FlagSpec) []const u8 {
    if (spec.value_name) |name| return name;
    return switch (spec.value) {
        .none => "",
        .string => "VALUE",
        .int => "N",
        .signed_int => "N",
        .float => "NUMBER",
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
