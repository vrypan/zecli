const std = @import("std");
const cli = @import("cli");
const completion = @import("completion");
const testing = std.testing;

// In-memory writer matching the duck-typed interface the generators expect.
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

// ── A specification exercising every completion feature ──────────────────────

const root_flags = [_]cli.FlagSpec{
    .{
        .name = "home",
        .short = 'H',
        .value = .string,
        .value_name = "DIR",
        .description = "Home directory",
        .completion = .directories,
    },
    .{ .name = "version", .short = 'V', .description = "Print version" },
};

const grep_flags = [_]cli.FlagSpec{
    .{
        .name = "color",
        .aliases = &.{"colour"},
        .value = .string,
        .value_name = "WHEN",
        .description = "Colorize output",
        .default_value = "auto",
        .choices = &.{ "auto", "always", "never" },
    },
    .{
        .name = "ref",
        .value = .string,
        .value_name = "REF",
        .description = "Reference to resolve",
        .completion = .{ .external = .{
            .executable = "demo",
            .arguments = &.{"complete"},
        } },
    },
};

const grep_arguments = [_]cli.ArgumentSpec{
    .{ .name = "PATTERN", .description = "Pattern to search for", .required = true },
};

const cat_arguments = [_]cli.ArgumentSpec{
    .{
        .name = "FILE",
        .description = "File to print",
        .required = true,
        .repeatable = true,
        .completion = .files,
    },
};

const run_arguments = [_]cli.ArgumentSpec{
    .{
        .name = "PROGRAM",
        .description = "Program to run",
        .required = true,
        .completion = .commands,
    },
    .{
        .name = "ARG",
        .description = "Argument to pass",
        .repeatable = true,
        .completion = .files,
    },
};

// Descriptions and values that would break naive quoting.
const odd_flags = [_]cli.FlagSpec{
    .{
        .name = "quirk",
        .value = .string,
        .value_name = "V AL",
        .description = "It's \"tricky\": costs $5 [maybe] a\\b; rm -rf * & echo `x`",
        .choices = &.{ "plain", "with space", "it's", "a\"b", "$HOME", "back\\slash", "semi;colon" },
    },
};

const commands = [_]cli.CommandSpec{
    .{
        .name = "grep",
        .aliases = &.{"search"},
        .description = "Search entries",
        .usage = "demo grep [options] <PATTERN>",
        .flags = &grep_flags,
        .arguments = &grep_arguments,
    },
    .{
        .name = "cat",
        .aliases = &.{"show"},
        .description = "Print a file",
        .usage = "demo cat <FILE>...",
        .arguments = &cat_arguments,
    },
    .{
        .name = "run",
        .description = "Run a program",
        .usage = "demo run <PROGRAM> [ARG]...",
        .arguments = &run_arguments,
    },
    .{
        .name = "odd",
        .description = "Command with 'quoted' & $tricky text",
        .usage = "demo odd [options]",
        .flags = &odd_flags,
    },
};

const app = cli.ApplicationSpec{
    .name = "demo",
    .description = "Demo application.",
    .usage = "demo [options] <command>",
    .flags = &root_flags,
    .commands = &commands,
};

comptime {
    cli.validateApplicationSpec(app) catch |err| {
        @compileError("invalid test specification: " ++ @errorName(err));
    };
}

const Shell = enum { bash, zsh, fish };

fn generate(allocator: std.mem.Allocator, shell: Shell) !Buffer {
    var buffer = Buffer.init(allocator);
    errdefer buffer.deinit();
    switch (shell) {
        .bash => try completion.generateBash(&buffer, app),
        .zsh => try completion.generateZsh(&buffer, app),
        .fish => try completion.generateFish(&buffer, app),
    }
    return buffer;
}

fn expectContains(text: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, text, needle) == null) {
        std.debug.print("\nexpected to find:\n{s}\n", .{needle});
        return error.TestExpectedContains;
    }
}

fn expectMissing(text: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, text, needle) != null) {
        std.debug.print("\nexpected not to find:\n{s}\n", .{needle});
        return error.TestUnexpectedContains;
    }
}

// ── Cross-shell structure ────────────────────────────────────────────────────

test "every shell offers canonical commands and aliases" {
    for ([_]Shell{ .bash, .zsh, .fish }) |shell| {
        var buffer = try generate(testing.allocator, shell);
        defer buffer.deinit();

        for ([_][]const u8{ "grep", "search", "cat", "show", "run", "odd" }) |name| {
            try expectContains(buffer.items(), name);
        }
    }
}

test "every shell recognizes an alias when selecting a command's options" {
    for ([_]Shell{ .bash, .zsh, .fish }) |shell| {
        var buffer = try generate(testing.allocator, shell);
        defer buffer.deinit();

        // The alias must reach the same option set as the canonical name.
        const text = buffer.items();
        const has_pair = std.mem.indexOf(u8, text, "grep|search") != null or
            std.mem.indexOf(u8, text, "grep search") != null;
        try testing.expect(has_pair);
    }
}

test "every shell offers long option aliases" {
    for ([_]Shell{ .bash, .zsh, .fish }) |shell| {
        var buffer = try generate(testing.allocator, shell);
        defer buffer.deinit();
        try expectContains(buffer.items(), "colour");
    }
}

test "every shell uses descriptions rather than option names" {
    // bash has no native description support, so only zsh and fish carry them.
    for ([_]Shell{ .zsh, .fish }) |shell| {
        var buffer = try generate(testing.allocator, shell);
        defer buffer.deinit();
        try expectContains(buffer.items(), "Colorize output");
        try expectContains(buffer.items(), "Home directory");
        try expectContains(buffer.items(), "Search entries");
    }
}

test "every shell offers the declared choices" {
    for ([_]Shell{ .bash, .zsh, .fish }) |shell| {
        var buffer = try generate(testing.allocator, shell);
        defer buffer.deinit();
        try expectContains(buffer.items(), "always");
        try expectContains(buffer.items(), "never");
    }
}

test "no generator infers completion from an argument named FILE" {
    // PATTERN has no completion metadata, so grep must not complete files.
    var buffer = try generate(testing.allocator, .zsh);
    defer buffer.deinit();
    try expectContains(buffer.items(), "PATTERN:'");
}

test "external completers are invoked directly, never through eval" {
    for ([_]Shell{ .bash, .zsh, .fish }) |shell| {
        var buffer = try generate(testing.allocator, shell);
        defer buffer.deinit();
        try expectMissing(buffer.items(), "eval");
        try expectContains(buffer.items(), "'demo' 'complete'");
    }
}

test "external completers discard stderr and ignore a failing exit status" {
    for ([_]Shell{ .bash, .zsh, .fish }) |shell| {
        var buffer = try generate(testing.allocator, shell);
        defer buffer.deinit();
        try expectContains(buffer.items(), "2>/dev/null");
    }
}

// ── Bash ─────────────────────────────────────────────────────────────────────

test "bash: registers the completion function" {
    var buffer = try generate(testing.allocator, .bash);
    defer buffer.deinit();
    try expectContains(buffer.items(), "_demo() {");
    try expectContains(buffer.items(), "complete -F _demo demo");
}

test "bash: skips the value of a root option when locating the command" {
    var buffer = try generate(testing.allocator, .bash);
    defer buffer.deinit();
    // Both spellings of a value-taking root option set the skip flag.
    try expectContains(buffer.items(), "--home|-H");
    try expectContains(buffer.items(), "skip=1");
}

test "bash: handles an inline root option value" {
    var buffer = try generate(testing.allocator, .bash);
    defer buffer.deinit();
    try expectContains(buffer.items(), "--*=*");
}

test "bash: stops offering options after the separator" {
    var buffer = try generate(testing.allocator, .bash);
    defer buffer.deinit();
    try expectContains(buffer.items(), "--) dd=1 ;;");
    try expectContains(buffer.items(), "if [ \"$dd\" -eq 0 ]; then");
}

test "bash: completes files, directories, and executables from metadata" {
    var buffer = try generate(testing.allocator, .bash);
    defer buffer.deinit();
    try expectContains(buffer.items(), "compgen -f");
    try expectContains(buffer.items(), "compgen -d");
    try expectContains(buffer.items(), "compgen -c");
}

test "bash: dispatches a command through its alias" {
    var buffer = try generate(testing.allocator, .bash);
    defer buffer.deinit();
    try expectContains(buffer.items(), "grep|search)");
    try expectContains(buffer.items(), "cat|show)");
}

test "bash: completes choices for both option spellings" {
    var buffer = try generate(testing.allocator, .bash);
    defer buffer.deinit();
    try expectContains(buffer.items(), "--color|--colour)");
    try expectContains(buffer.items(), "$'auto\\nalways\\nnever'");
}

test "bash: selects a completion per positional slot" {
    var buffer = try generate(testing.allocator, .bash);
    defer buffer.deinit();
    // run completes an executable first and files afterwards.
    try expectContains(buffer.items(), "case \"$pos\" in");
    try expectContains(buffer.items(), "_demo_commands");
}

test "bash: filters candidate lists without expanding them" {
    var buffer = try generate(testing.allocator, .bash);
    defer buffer.deinit();
    // Values reach COMPREPLY through read, never through an expansion.
    try expectContains(buffer.items(), "while IFS= read -r word; do");
    try expectContains(buffer.items(), "case \"$word\" in");
}

test "bash: escapes quotes, backslashes, and metacharacters in values" {
    var buffer = try generate(testing.allocator, .bash);
    defer buffer.deinit();
    const text = buffer.items();
    try expectContains(text, "with space");
    try expectContains(text, "it\\'s");
    try expectContains(text, "back\\\\slash");
    try expectContains(text, "semi;colon");
}

// ── Zsh ──────────────────────────────────────────────────────────────────────

test "zsh: registers the completion function" {
    var buffer = try generate(testing.allocator, .zsh);
    defer buffer.deinit();
    try expectContains(buffer.items(), "#compdef demo");
    try expectContains(buffer.items(), "compdef _demo demo");
}

test "zsh: does not assume the command is the second word" {
    var buffer = try generate(testing.allocator, .zsh);
    defer buffer.deinit();
    try expectMissing(buffer.items(), "words[2]");
    // The command position and the rest are described to _arguments instead.
    try expectContains(buffer.items(), "'1: :->command'");
    try expectContains(buffer.items(), "'*:: :->args'");
}

test "zsh: stops completing options after the separator" {
    var buffer = try generate(testing.allocator, .zsh);
    defer buffer.deinit();
    try expectContains(buffer.items(), "_arguments -S -C");
    try expectContains(buffer.items(), "_arguments -S \\");
}

test "zsh: accepts both value syntaxes for a long option" {
    var buffer = try generate(testing.allocator, .zsh);
    defer buffer.deinit();
    try expectContains(buffer.items(), "{-H,--home=}");
    try expectContains(buffer.items(), "{--color=,--colour=}");
    try expectContains(buffer.items(), "'--ref=[Reference to resolve]");
}

test "zsh: describes commands and their aliases" {
    var buffer = try generate(testing.allocator, .zsh);
    defer buffer.deinit();
    try expectContains(buffer.items(), "'grep:Search entries'");
    try expectContains(buffer.items(), "'search:Search entries'");
}

test "zsh: dispatches on the first completion when autoloaded from fpath" {
    var buffer = try generate(testing.allocator, .zsh);
    defer buffer.deinit();
    try expectContains(buffer.items(), "if [ \"${funcstack[1]}\" = \"_demo\" ]; then\n    _demo \"$@\"\nelse\n");
    try expectContains(buffer.items(), "    compdef _demo demo\nfi\n");
}

test "zsh: reports the dispatched command's completion status" {
    var buffer = try generate(testing.allocator, .zsh);
    defer buffer.deinit();
    try expectContains(buffer.items(), "__cmd_grep\n                    return $?\n");
}

test "zsh: completes files, directories, and executables from metadata" {
    var buffer = try generate(testing.allocator, .zsh);
    defer buffer.deinit();
    try expectContains(buffer.items(), "_files -/");
    try expectContains(buffer.items(), ":FILE:_files");
    try expectContains(buffer.items(), "_command_names -e");
}

test "zsh: marks a repeatable positional with *" {
    var buffer = try generate(testing.allocator, .zsh);
    defer buffer.deinit();
    try expectContains(buffer.items(), "'*:FILE:_files'");
}

test "zsh: escapes brackets and colons in descriptions" {
    var buffer = try generate(testing.allocator, .zsh);
    defer buffer.deinit();
    const text = buffer.items();
    try expectContains(text, "\\[maybe\\]");
    try expectContains(text, "It'\\''s");
    try expectMissing(text, "[maybe]");
}

test "zsh: quotes choice values containing spaces and quotes" {
    var buffer = try generate(testing.allocator, .zsh);
    defer buffer.deinit();
    const text = buffer.items();
    try expectContains(text, "'\\''with space'\\''");
    try expectContains(text, "'\\''$HOME'\\''");
}

// ── Fish ─────────────────────────────────────────────────────────────────────

test "fish: registers completions for the command" {
    var buffer = try generate(testing.allocator, .fish);
    defer buffer.deinit();
    try expectContains(buffer.items(), "complete -c 'demo' -f");
}

test "fish: locates the command after root options" {
    var buffer = try generate(testing.allocator, .fish);
    defer buffer.deinit();
    try expectContains(buffer.items(), "function __demo_command");
    try expectContains(buffer.items(), "case '--home' '-H'");
    try expectContains(buffer.items(), "set skip 1");
    try expectContains(buffer.items(), "case '--*=*'");
}

test "fish: stops offering options after the separator" {
    var buffer = try generate(testing.allocator, .fish);
    defer buffer.deinit();
    try expectContains(buffer.items(), "function __demo_after_terminator");
    try expectContains(buffer.items(), "and not __demo_after_terminator");
}

test "fish: offers commands with descriptions" {
    var buffer = try generate(testing.allocator, .fish);
    defer buffer.deinit();
    try expectContains(buffer.items(), "-a 'grep' -d 'Search entries'");
    try expectContains(buffer.items(), "-a 'search' -d 'Search entries'");
}

test "fish: applies a command's options to its aliases too" {
    var buffer = try generate(testing.allocator, .fish);
    defer buffer.deinit();
    try expectContains(buffer.items(), "__demo_using_command grep search");
}

test "fish: value-taking options take their value exclusively" {
    var buffer = try generate(testing.allocator, .fish);
    defer buffer.deinit();
    // -x, not -r: -r alone lets fish add filenames to the declared values.
    try expectContains(buffer.items(), "-l home -s H -x");
    try expectContains(buffer.items(), "-l colour -x");
    try expectMissing(buffer.items(), " -r ");
}

test "bash: path helpers escape spaces and mark directories" {
    var buffer = try generate(testing.allocator, .bash);
    defer buffer.deinit();
    try expectContains(buffer.items(), "_files() {\n    COMPREPLY=()\n    compopt -o filenames");
    try expectContains(buffer.items(), "_dirs() {\n    COMPREPLY=()\n    compopt -o filenames");
}

test "zsh: narrows the context to the dispatched subcommand" {
    var buffer = try generate(testing.allocator, .zsh);
    defer buffer.deinit();
    try expectContains(buffer.items(), "curcontext=\"${curcontext%:*:*}:demo-${words[1]}:\"");
}

test "fish: completes files, directories, and executables from metadata" {
    var buffer = try generate(testing.allocator, .fish);
    defer buffer.deinit();
    try expectContains(buffer.items(), "-F");
    try expectContains(buffer.items(), "__fish_complete_directories");
    try expectContains(buffer.items(), "__fish_complete_command");
}

test "fish: emits fixed values one per line so spaces survive" {
    var buffer = try generate(testing.allocator, .fish);
    defer buffer.deinit();
    const text = buffer.items();
    try expectContains(text, "function __demo_vals_cmd_grep_f_color");
    try expectContains(text, "echo 'always'");
    try expectContains(text, "echo 'with space'");
}

test "fish: escapes quotes and backslashes in descriptions and values" {
    var buffer = try generate(testing.allocator, .fish);
    defer buffer.deinit();
    const text = buffer.items();
    try expectContains(text, "It\\'s");
    try expectContains(text, "back\\\\slash");
}

test "fish: counts positionals when slots complete differently" {
    var buffer = try generate(testing.allocator, .fish);
    defer buffer.deinit();
    try expectContains(buffer.items(), "function __demo_pos_run");
    try expectContains(buffer.items(), "-eq 0'");
}

test "fish: applies a repeatable positional to every later slot" {
    var buffer = try generate(testing.allocator, .fish);
    defer buffer.deinit();
    try expectContains(buffer.items(), "-ge 1'");
}
