//! Shell completion generation.
//!
//! All three generators are driven by a single `cli.ApplicationSpec`. Nothing
//! in a specification is ever emitted as raw shell source: names, descriptions,
//! values, and external-completer arguments are quoted for the target shell,
//! and external completers are invoked directly rather than through `eval`.

const std = @import("std");
const cli = @import("cli");

/// Where a completion action lives in the specification. Used to derive stable
/// helper-function names for external completers.
const Slot = struct {
    command: ?[]const u8 = null,
    kind: enum { flag, argument },
    name: []const u8,
};

const Scope = struct {
    command: ?cli.CommandSpec,
    flags: []const cli.FlagSpec,

    fn name(self: Scope) ?[]const u8 {
        return if (self.command) |command| command.name else null;
    }
};

fn rootScope(app: cli.ApplicationSpec) Scope {
    return .{ .command = null, .flags = app.flags };
}

fn commandScope(command: cli.CommandSpec) Scope {
    return .{ .command = command, .flags = command.flags };
}

/// True when every positional slot of a command completes the same way, which
/// lets the generators skip positional-index bookkeeping.
fn uniformArguments(command: cli.CommandSpec) bool {
    if (command.arguments.len < 2) return true;
    const first = command.arguments[0].completion;
    for (command.arguments[1..]) |argument| {
        if (!completionEql(first, argument.completion)) return false;
    }
    return true;
}

fn completionEql(a: cli.CompletionKind, b: cli.CompletionKind) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .none, .files, .directories, .commands => true,
        .values => |values| blk: {
            const other = b.values;
            if (values.len != other.len) break :blk false;
            for (values, other) |x, y| {
                if (!std.mem.eql(u8, x, y)) break :blk false;
            }
            break :blk true;
        },
        .external => |external| blk: {
            const other = b.external;
            if (!std.mem.eql(u8, external.executable, other.executable)) break :blk false;
            if (external.arguments.len != other.arguments.len) break :blk false;
            for (external.arguments, other.arguments) |x, y| {
                if (!std.mem.eql(u8, x, y)) break :blk false;
            }
            break :blk true;
        },
    };
}

/// The completion offered for the last positional slot when more values are
/// typed than there are argument specs.
fn trailingArgument(command: cli.CommandSpec) ?cli.ArgumentSpec {
    if (command.arguments.len == 0) return null;
    const last = command.arguments[command.arguments.len - 1];
    return if (last.repeatable) last else null;
}

// ── Escaping ─────────────────────────────────────────────────────────────────

/// Writes an identifier fragment safe for a shell function name.
fn writeIdent(writer: anytype, text: []const u8) !void {
    for (text) |char| {
        if (std.ascii.isAlphanumeric(char) or char == '_') {
            try writer.writeByte(char);
        } else {
            try writer.writeByte('_');
        }
    }
}

/// Writes text inside POSIX single quotes, which quote everything literally.
fn writeQuoted(writer: anytype, text: []const u8) !void {
    try writer.writeByte('\'');
    for (text) |char| {
        if (char == '\'') {
            try writer.writeAll("'\\''");
        } else {
            try writer.writeByte(char);
        }
    }
    try writer.writeByte('\'');
}

/// Writes text inside fish single quotes, where only \ and ' are special.
fn writeFishQuoted(writer: anytype, text: []const u8) !void {
    try writer.writeByte('\'');
    for (text) |char| {
        switch (char) {
            '\\' => try writer.writeAll("\\\\"),
            '\'' => try writer.writeAll("\\'"),
            else => try writer.writeByte(char),
        }
    }
    try writer.writeByte('\'');
}

/// Writes a fragment of a bash `$'...'` string.
fn writeAnsiCFragment(writer: anytype, text: []const u8) !void {
    for (text) |char| {
        switch (char) {
            '\\' => try writer.writeAll("\\\\"),
            '\'' => try writer.writeAll("\\'"),
            '\n' => try writer.writeAll("\\n"),
            '\t' => try writer.writeAll("\\t"),
            '\r' => try writer.writeAll("\\r"),
            else => try writer.writeByte(char),
        }
    }
}

/// Writes a description inside a zsh `_arguments` bracket, where ], [, : and \
/// terminate or split the specification.
fn writeZshDescription(writer: anytype, text: []const u8) !void {
    for (text) |char| {
        switch (char) {
            '\\', ']', '[', ':' => {
                try writer.writeByte('\\');
                try writer.writeByte(char);
            },
            '\'' => try writer.writeAll("'\\''"),
            '\n' => try writer.writeByte(' '),
            else => try writer.writeByte(char),
        }
    }
}

/// Writes text inside a zsh single-quoted string.
fn writeZshQuoted(writer: anytype, text: []const u8) !void {
    for (text) |char| {
        if (char == '\'') {
            try writer.writeAll("'\\''");
        } else if (char == '\n') {
            try writer.writeByte(' ');
        } else {
            try writer.writeByte(char);
        }
    }
}

// ── Shared naming ────────────────────────────────────────────────────────────

fn writePrefix(writer: anytype, app: cli.ApplicationSpec) !void {
    try writer.writeAll("_");
    try writeIdent(writer, app.name);
}

fn writeHelperPrefix(writer: anytype, app: cli.ApplicationSpec) !void {
    try writer.writeAll("__");
    try writeIdent(writer, app.name);
}

fn writeExternalName(writer: anytype, app: cli.ApplicationSpec, slot: Slot) !void {
    try writeSlotFnName(writer, app, slot, "ext");
}

fn writeValuesName(writer: anytype, app: cli.ApplicationSpec, slot: Slot) !void {
    try writeSlotFnName(writer, app, slot, "vals");
}

/// Derives a stable helper-function name from a slot's position in the
/// specification, so definitions and call sites always agree.
fn writeSlotFnName(
    writer: anytype,
    app: cli.ApplicationSpec,
    slot: Slot,
    comptime tag: []const u8,
) !void {
    try writeHelperPrefix(writer, app);
    try writer.writeAll("_" ++ tag ++ "_");
    if (slot.command) |command| {
        try writer.writeAll("cmd_");
        try writeIdent(writer, command);
    } else {
        try writer.writeAll("root");
    }
    try writer.writeAll(switch (slot.kind) {
        .flag => "_f_",
        .argument => "_a_",
    });
    try writeIdent(writer, slot.name);
}

fn writeCommandFnName(writer: anytype, app: cli.ApplicationSpec, command: cli.CommandSpec) !void {
    try writePrefix(writer, app);
    try writer.writeAll("__cmd_");
    try writeIdent(writer, command.name);
}

/// Calls `body` once for every completion action in the specification, in a
/// fixed order, so that helper definitions and their call sites always agree.
fn forEachSlot(
    writer: anytype,
    app: cli.ApplicationSpec,
    comptime body: anytype,
) !void {
    for (app.flags) |flag| {
        try body(writer, app, Slot{ .kind = .flag, .name = flag.name }, cli.flagCompletion(flag));
    }
    for (app.commands) |command| {
        for (command.flags) |flag| {
            try body(
                writer,
                app,
                Slot{ .command = command.name, .kind = .flag, .name = flag.name },
                cli.flagCompletion(flag),
            );
        }
        for (command.arguments) |argument| {
            try body(
                writer,
                app,
                Slot{ .command = command.name, .kind = .argument, .name = argument.name },
                argument.completion,
            );
        }
    }
}

// ── Bash ─────────────────────────────────────────────────────────────────────

pub fn generateBash(writer: anytype, app: cli.ApplicationSpec) !void {
    try writer.writeAll("# bash completion for ");
    try writer.writeAll(app.name);
    try writer.writeAll("\n\n");

    try writeBashHelpers(writer, app);
    try forEachSlot(writer, app, writeBashExternal);

    // Main entry point: locate the command, then dispatch.
    try writePrefix(writer, app);
    try writer.writeAll("() {\n");
    try writer.writeAll(
        \\    local cur prev word i skip
        \\    local zecli_cmd zecli_cmd_index zecli_dashdash
        \\    COMPREPLY=()
        \\    cur="${COMP_WORDS[COMP_CWORD]}"
        \\    prev=""
        \\    if [ "$COMP_CWORD" -gt 0 ]; then
        \\        prev="${COMP_WORDS[COMP_CWORD-1]}"
        \\    fi
        \\    if [ "$cur" = "=" ]; then
        \\        cur=""
        \\    elif [ "$prev" = "=" ] && [ "$COMP_CWORD" -gt 1 ]; then
        \\        prev="${COMP_WORDS[COMP_CWORD-2]}"
        \\    fi
        \\
        \\    zecli_cmd=""
        \\    zecli_cmd_index=0
        \\    zecli_dashdash=0
        \\    i=1
        \\    skip=0
        \\    while [ "$i" -lt "$COMP_CWORD" ]; do
        \\        word="${COMP_WORDS[i]}"
        \\        if [ "$skip" -eq 1 ]; then
        \\            if [ "$word" != "=" ]; then
        \\                skip=0
        \\            fi
        \\            i=$((i+1))
        \\            continue
        \\        fi
        \\        case "$word" in
        \\            --)
        \\                zecli_dashdash=1
        \\                break
        \\                ;;
        \\            --*=*) ;;
        \\
    );
    try writeBashValueFlagCase(writer, app.flags, "            ");
    try writer.writeAll(
        \\            -*) ;;
        \\            *)
        \\                zecli_cmd="$word"
        \\                zecli_cmd_index=$i
        \\                break
        \\                ;;
        \\        esac
        \\        i=$((i+1))
        \\    done
        \\
        \\    if [ -n "$zecli_cmd" ]; then
        \\        case "$zecli_cmd" in
        \\
    );

    for (app.commands) |command| {
        try writer.writeAll("            ");
        try writeBashCommandPattern(writer, command);
        try writer.writeAll(")\n                ");
        try writeCommandFnName(writer, app, command);
        try writer.writeAll("\n                return\n                ;;\n");
    }

    try writer.writeAll(
        \\        esac
        \\        return
        \\    fi
        \\
        \\    if [ "$zecli_dashdash" -eq 1 ]; then
        \\        return
        \\    fi
        \\
        \\    case "$prev" in
        \\
    );
    try writeBashValueDispatch(writer, app, rootScope(app), "        ");
    try writer.writeAll(
        \\    esac
        \\
        \\    if [ "${cur:0:1}" = "-" ]; then
        \\
    );
    try writer.writeAll("        ");
    try writeHelperPrefix(writer, app);
    try writer.writeAll("_words ");
    try writeBashFlagWordList(writer, app.flags);
    try writer.writeAll("\n        return\n    fi\n\n    ");
    try writeHelperPrefix(writer, app);
    try writer.writeAll("_words ");
    try writeBashCommandWordList(writer, app.commands);
    try writer.writeAll("\n}\n\n");

    for (app.commands) |command| try writeBashCommandFn(writer, app, command);

    try writer.writeAll("complete -F ");
    try writePrefix(writer, app);
    try writer.writeAll(" ");
    try writer.writeAll(app.name);
    try writer.writeAll("\n");
}

fn writeBashHelpers(writer: anytype, app: cli.ApplicationSpec) !void {
    // Candidate lists are filtered without expansion so that values containing
    // $, backslashes, quotes, or spaces survive intact. The path helpers turn
    // on `filenames` for their own completion only, so bash escapes spaces and
    // marks directories; setting it on the `complete` registration instead
    // would also mangle ordinary candidates that contain a slash.
    try writeHelperPrefix(writer, app);
    try writer.writeAll(
        \\_words() {
        \\    local word
        \\    COMPREPLY=()
        \\    while IFS= read -r word; do
        \\        [ -z "$word" ] && continue
        \\        case "$word" in
        \\            "$cur"*) COMPREPLY+=("$word") ;;
        \\        esac
        \\    done <<< "$1"
        \\}
        \\
        \\
    );

    try writeHelperPrefix(writer, app);
    try writer.writeAll(
        \\_files() {
        \\    COMPREPLY=()
        \\    compopt -o filenames 2>/dev/null
        \\    while IFS= read -r word; do
        \\        [ -n "$word" ] && COMPREPLY+=("$word")
        \\    done <<< "$(compgen -f -- "$cur")"
        \\}
        \\
        \\
    );

    try writeHelperPrefix(writer, app);
    try writer.writeAll(
        \\_dirs() {
        \\    COMPREPLY=()
        \\    compopt -o filenames 2>/dev/null
        \\    while IFS= read -r word; do
        \\        [ -n "$word" ] && COMPREPLY+=("$word")
        \\    done <<< "$(compgen -d -- "$cur")"
        \\}
        \\
        \\
    );

    try writeHelperPrefix(writer, app);
    try writer.writeAll(
        \\_commands() {
        \\    COMPREPLY=()
        \\    while IFS= read -r word; do
        \\        [ -n "$word" ] && COMPREPLY+=("$word")
        \\    done <<< "$(compgen -c -- "$cur")"
        \\}
        \\
        \\
    );

    // The executable is run directly, never through eval. Its arguments are
    // followed by the current prefix as one argument, stderr is discarded, and
    // a nonzero exit status yields no candidates.
    try writeHelperPrefix(writer, app);
    try writer.writeAll(
        \\_external() {
        \\    local output line
        \\    COMPREPLY=()
        \\    output="$("$@" "$cur" 2>/dev/null)" || return 0
        \\    while IFS= read -r line; do
        \\        [ -n "$line" ] && COMPREPLY+=("$line")
        \\    done <<< "$output"
        \\}
        \\
        \\
    );
}

fn writeBashExternal(
    writer: anytype,
    app: cli.ApplicationSpec,
    slot: Slot,
    kind: cli.CompletionKind,
) anyerror!void {
    const external = switch (kind) {
        .external => |value| value,
        else => return,
    };
    try writeExternalName(writer, app, slot);
    try writer.writeAll("() {\n    ");
    try writeHelperPrefix(writer, app);
    try writer.writeAll("_external ");
    try writeQuoted(writer, external.executable);
    for (external.arguments) |argument| {
        try writer.writeByte(' ');
        try writeQuoted(writer, argument);
    }
    try writer.writeAll("\n}\n\n");
}

/// Emits a `case` branch matching every spelling of every value-taking flag,
/// so that the option's value is skipped when scanning for the command.
fn writeBashValueFlagCase(writer: anytype, flags: []const cli.FlagSpec, indent: []const u8) !void {
    var any = false;
    for (flags) |flag| {
        if (cli.takesValue(flag)) any = true;
    }
    if (!any) return;

    try writer.writeAll(indent);
    var first = true;
    for (flags) |flag| {
        if (!cli.takesValue(flag)) continue;
        try writeBashFlagPatterns(writer, flag, &first);
    }
    try writer.writeAll(")\n");
    try writer.writeAll(indent);
    try writer.writeAll("    skip=1\n");
    try writer.writeAll(indent);
    try writer.writeAll("    ;;\n");
}

fn writeBashFlagPatterns(writer: anytype, flag: cli.FlagSpec, first: *bool) !void {
    if (!first.*) try writer.writeByte('|');
    first.* = false;
    try writer.print("--{s}", .{flag.name});
    for (flag.aliases) |alias| try writer.print("|--{s}", .{alias});
    if (flag.short) |short| try writer.print("|-{c}", .{short});
}

fn writeBashCommandPattern(writer: anytype, command: cli.CommandSpec) !void {
    try writer.writeAll(command.name);
    for (command.aliases) |alias| try writer.print("|{s}", .{alias});
}

/// Emits `case "$prev"` branches completing each value-taking flag's value.
fn writeBashValueDispatch(
    writer: anytype,
    app: cli.ApplicationSpec,
    scope: Scope,
    indent: []const u8,
) !void {
    for (scope.flags) |flag| {
        if (!cli.takesValue(flag)) continue;
        const kind = cli.flagCompletion(flag);
        if (kind == .none) continue;

        try writer.writeAll(indent);
        var first = true;
        try writeBashFlagPatterns(writer, flag, &first);
        try writer.writeAll(")\n");
        try writer.writeAll(indent);
        try writer.writeAll("    ");
        try writeBashAction(writer, app, kind, .{
            .command = scope.name(),
            .kind = .flag,
            .name = flag.name,
        });
        try writer.writeAll("\n");
        try writer.writeAll(indent);
        try writer.writeAll("    return\n");
        try writer.writeAll(indent);
        try writer.writeAll("    ;;\n");
    }
}

fn writeBashAction(
    writer: anytype,
    app: cli.ApplicationSpec,
    kind: cli.CompletionKind,
    slot: Slot,
) !void {
    switch (kind) {
        .none => try writer.writeAll("COMPREPLY=()"),
        .files => {
            try writeHelperPrefix(writer, app);
            try writer.writeAll("_files");
        },
        .directories => {
            try writeHelperPrefix(writer, app);
            try writer.writeAll("_dirs");
        },
        .commands => {
            try writeHelperPrefix(writer, app);
            try writer.writeAll("_commands");
        },
        .values => |values| {
            try writeHelperPrefix(writer, app);
            try writer.writeAll("_words ");
            try writeBashWordList(writer, values);
        },
        .external => try writeExternalName(writer, app, slot),
    }
}

fn writeBashWordList(writer: anytype, words: []const []const u8) !void {
    try writer.writeAll("$'");
    for (words, 0..) |word, i| {
        if (i > 0) try writer.writeAll("\\n");
        try writeAnsiCFragment(writer, word);
    }
    try writer.writeAll("'");
}

fn writeBashFlagWordList(writer: anytype, flags: []const cli.FlagSpec) !void {
    try writer.writeAll("$'");
    var first = true;
    for (flags) |flag| {
        try writeBashFlagWord(writer, flag, &first);
    }
    try writeBashFlagWord(writer, cli.help_flag, &first);
    try writer.writeAll("'");
}

fn writeBashFlagWord(writer: anytype, flag: cli.FlagSpec, first: *bool) !void {
    if (!first.*) try writer.writeAll("\\n");
    first.* = false;
    try writer.print("--{s}", .{flag.name});
    for (flag.aliases) |alias| try writer.print("\\n--{s}", .{alias});
    if (flag.short) |short| try writer.print("\\n-{c}", .{short});
}

fn writeBashCommandWordList(writer: anytype, commands: []const cli.CommandSpec) !void {
    try writer.writeAll("$'");
    var first = true;
    for (commands) |command| {
        if (!first) try writer.writeAll("\\n");
        first = false;
        try writeAnsiCFragment(writer, command.name);
        for (command.aliases) |alias| {
            try writer.writeAll("\\n");
            try writeAnsiCFragment(writer, alias);
        }
    }
    try writer.writeAll("'");
}

fn writeBashCommandFn(
    writer: anytype,
    app: cli.ApplicationSpec,
    command: cli.CommandSpec,
) !void {
    try writeCommandFnName(writer, app, command);
    try writer.writeAll("() {\n");
    try writer.writeAll(
        \\    local j word skip dd pos
        \\    dd=0
        \\    pos=0
        \\    skip=0
        \\    j=$((zecli_cmd_index+1))
        \\    while [ "$j" -lt "$COMP_CWORD" ]; do
        \\        word="${COMP_WORDS[j]}"
        \\        if [ "$skip" -eq 1 ]; then
        \\            if [ "$word" != "=" ]; then
        \\                skip=0
        \\            fi
        \\            j=$((j+1))
        \\            continue
        \\        fi
        \\        if [ "$dd" -eq 1 ]; then
        \\            pos=$((pos+1))
        \\            j=$((j+1))
        \\            continue
        \\        fi
        \\        case "$word" in
        \\            --) dd=1 ;;
        \\            --*=*) ;;
        \\
    );
    try writeBashValueFlagCase(writer, command.flags, "            ");
    try writer.writeAll(
        \\            -*) ;;
        \\            *) pos=$((pos+1)) ;;
        \\        esac
        \\        j=$((j+1))
        \\    done
        \\
        \\    if [ "$dd" -eq 0 ]; then
        \\        case "$prev" in
        \\
    );
    try writeBashValueDispatch(writer, app, commandScope(command), "            ");
    try writer.writeAll(
        \\        esac
        \\        if [ "${cur:0:1}" = "-" ]; then
        \\
    );
    try writer.writeAll("            ");
    try writeHelperPrefix(writer, app);
    try writer.writeAll("_words ");
    try writeBashFlagWordList(writer, command.flags);
    try writer.writeAll("\n            return\n        fi\n    fi\n\n");

    try writeBashPositionals(writer, app, command);
    try writer.writeAll("}\n\n");
}

fn writeBashPositionals(
    writer: anytype,
    app: cli.ApplicationSpec,
    command: cli.CommandSpec,
) !void {
    if (command.arguments.len == 0) {
        try writer.writeAll("    COMPREPLY=()\n");
        return;
    }

    if (uniformArguments(command)) {
        try writer.writeAll("    ");
        try writeBashAction(writer, app, command.arguments[0].completion, .{
            .command = command.name,
            .kind = .argument,
            .name = command.arguments[0].name,
        });
        try writer.writeAll("\n");
        return;
    }

    try writer.writeAll("    case \"$pos\" in\n");
    for (command.arguments, 0..) |argument, i| {
        if (argument.repeatable and i == command.arguments.len - 1) break;
        try writer.print("        {d})\n            ", .{i});
        try writeBashAction(writer, app, argument.completion, .{
            .command = command.name,
            .kind = .argument,
            .name = argument.name,
        });
        try writer.writeAll("\n            ;;\n");
    }

    try writer.writeAll("        *)\n            ");
    if (trailingArgument(command)) |argument| {
        try writeBashAction(writer, app, argument.completion, .{
            .command = command.name,
            .kind = .argument,
            .name = argument.name,
        });
    } else {
        try writer.writeAll("COMPREPLY=()");
    }
    try writer.writeAll("\n            ;;\n    esac\n");
}

// ── Zsh ──────────────────────────────────────────────────────────────────────

pub fn generateZsh(writer: anytype, app: cli.ApplicationSpec) !void {
    try writer.writeAll("#compdef ");
    try writer.writeAll(app.name);
    try writer.writeAll("\n\n");

    // Reads one candidate per line from the completer's stdout; a nonzero exit
    // status or no output yields no candidates, and stderr is discarded.
    try writeHelperPrefix(writer, app);
    try writer.writeAll(
        \\_external() {
        \\    local output line
        \\    local -a candidates
        \\    output="$("$@" "$PREFIX" 2>/dev/null)" || return 1
        \\    candidates=()
        \\    for line in "${(@f)output}"; do
        \\        [[ -n "$line" ]] && candidates+=("$line")
        \\    done
        \\    (( ${#candidates} )) || return 1
        \\    compadd -- "${candidates[@]}"
        \\}
        \\
        \\
    );
    try forEachSlot(writer, app, writeZshExternal);

    for (app.commands) |command| try writeZshCommandFn(writer, app, command);

    try writePrefix(writer, app);
    try writer.writeAll("() {\n");
    try writer.writeAll(
        \\    local context state state_descr line
        \\    local curcontext="$curcontext"
        \\    typeset -A opt_args
        \\    local -a commands
        \\    commands=(
        \\
    );
    for (app.commands) |command| {
        try writeZshCommandEntry(writer, command.name, command.description);
        for (command.aliases) |alias| try writeZshCommandEntry(writer, alias, command.description);
    }
    // -S stops option completion after `--`, matching the parser.
    try writer.writeAll("    )\n\n    _arguments -S -C \\\n");
    for (app.flags) |flag| try writeZshFlag(writer, app, rootScope(app), flag, "        ");
    try writeZshFlag(writer, app, rootScope(app), cli.help_flag, "        ");
    try writer.writeAll(
        \\        '1: :->command' \
        \\        '*:: :->args' && return 0
        \\
        \\    case $state in
        \\        command)
        \\            _describe -t commands 'command' commands && return 0
        \\            ;;
        \\        args)
        \\            curcontext="${curcontext%:*:*}:
    );
    // Narrow the context to the subcommand so per-command zstyles apply.
    try writer.writeAll(app.name);
    try writer.writeAll("-${words[1]}:\"\n            case ${words[1]} in\n");

    for (app.commands) |command| {
        try writer.writeAll("                ");
        try writeBashCommandPattern(writer, command);
        try writer.writeAll(")\n                    ");
        try writeCommandFnName(writer, app, command);
        // Propagate the command function's status: returning 1 unconditionally
        // makes zsh retry the whole completion once per configured matcher,
        // which duplicates every group it produced.
        try writer.writeAll("\n                    return $?\n                    ;;\n");
    }
    try writer.writeAll(
        \\            esac
        \\            ;;
        \\    esac
        \\    return 1
        \\}
        \\
        \\
    );

    // Autoloaded from fpath, this file's body *is* the body of the function
    // named after the file, so it must dispatch rather than only register:
    // otherwise the first completion attempt defines the functions and
    // returns without completing anything. Sourced from a startup file,
    // funcstack is empty and the compdef registration is what's needed.
    try writer.writeAll("if [ \"${funcstack[1]}\" = \"_");
    try writer.writeAll(app.name);
    try writer.writeAll("\" ]; then\n    ");
    try writePrefix(writer, app);
    try writer.writeAll(" \"$@\"\nelse\n    compdef ");
    try writePrefix(writer, app);
    try writer.writeAll(" ");
    try writer.writeAll(app.name);
    try writer.writeAll("\nfi\n");
}

fn writeZshExternal(
    writer: anytype,
    app: cli.ApplicationSpec,
    slot: Slot,
    kind: cli.CompletionKind,
) anyerror!void {
    const external = switch (kind) {
        .external => |value| value,
        else => return,
    };
    try writeExternalName(writer, app, slot);
    try writer.writeAll("() {\n    ");
    try writeHelperPrefix(writer, app);
    try writer.writeAll("_external ");
    try writeQuoted(writer, external.executable);
    for (external.arguments) |argument| {
        try writer.writeByte(' ');
        try writeQuoted(writer, argument);
    }
    try writer.writeAll("\n}\n\n");
}

fn writeZshCommandEntry(writer: anytype, name: []const u8, description: []const u8) !void {
    try writer.writeAll("        '");
    try writeZshQuoted(writer, name);
    try writer.writeAll(":");
    try writeZshQuoted(writer, description);
    try writer.writeAll("'\n");
}

fn writeZshCommandFn(
    writer: anytype,
    app: cli.ApplicationSpec,
    command: cli.CommandSpec,
) !void {
    try writeCommandFnName(writer, app, command);
    try writer.writeAll("() {\n    _arguments -S \\\n");
    for (command.flags) |flag| {
        try writeZshFlag(writer, app, commandScope(command), flag, "        ");
    }
    try writeZshFlag(writer, app, commandScope(command), cli.help_flag, "        ");
    for (command.arguments) |argument| {
        try writeZshArgument(writer, app, command, argument, "        ");
    }
    try writer.writeAll("        && return 0\n    return 1\n}\n\n");
}

fn writeZshFlag(
    writer: anytype,
    app: cli.ApplicationSpec,
    scope: Scope,
    flag: cli.FlagSpec,
    indent: []const u8,
) !void {
    const spelling_count = 1 + flag.aliases.len + @as(usize, if (flag.short != null) 1 else 0);

    try writer.writeAll(indent);
    if (spelling_count > 1) {
        // Exclusion list, then a brace expansion over every spelling.
        try writer.writeAll("'(");
        try writeZshSpellings(writer, flag, ' ');
        try writer.writeAll(")'{");
        try writeZshSpellings(writer, flag, ',');
        try writer.writeAll("}'[");
    } else {
        try writer.writeAll("'");
        try writeZshLongSpelling(writer, flag, flag.name);
        try writer.writeAll("[");
    }

    try writeZshDescription(writer, flag.description);
    try writer.writeAll("]");

    if (cli.takesValue(flag)) {
        try writer.writeAll(":");
        try writeZshDescription(writer, cli.getValueName(flag));
        try writer.writeAll(":");
        try writeZshAction(writer, app, cli.flagCompletion(flag), .{
            .command = scope.name(),
            .kind = .flag,
            .name = flag.name,
        });
    }

    try writer.writeAll("' \\\n");
}

/// A long option that takes a value is spelled `--name=` so that zsh accepts
/// both `--name value` and `--name=value`; a short option that accepts an
/// attached value is spelled `-x+`.
fn writeZshLongSpelling(writer: anytype, flag: cli.FlagSpec, name: []const u8) !void {
    try writer.print("--{s}", .{name});
    if (cli.takesValue(flag)) try writer.writeByte('=');
}

fn writeZshShortSpelling(writer: anytype, flag: cli.FlagSpec, short: u8) !void {
    try writer.print("-{c}", .{short});
    if (cli.takesValue(flag) and flag.attached_short_value) try writer.writeByte('+');
}

fn writeZshSpellings(writer: anytype, flag: cli.FlagSpec, separator: u8) !void {
    var first = true;
    if (flag.short) |short| {
        try writeZshShortSpelling(writer, flag, short);
        first = false;
    }
    if (!first) try writer.writeByte(separator);
    try writeZshLongSpelling(writer, flag, flag.name);
    for (flag.aliases) |alias| {
        try writer.writeByte(separator);
        try writeZshLongSpelling(writer, flag, alias);
    }
}

fn writeZshArgument(
    writer: anytype,
    app: cli.ApplicationSpec,
    command: cli.CommandSpec,
    argument: cli.ArgumentSpec,
    indent: []const u8,
) !void {
    try writer.writeAll(indent);
    try writer.writeAll("'");
    if (argument.repeatable) {
        try writer.writeAll("*:");
    } else if (argument.required) {
        try writer.writeAll(":");
    } else {
        try writer.writeAll("::");
    }
    try writeZshDescription(writer, argument.name);
    try writer.writeAll(":");
    try writeZshAction(writer, app, argument.completion, .{
        .command = command.name,
        .kind = .argument,
        .name = argument.name,
    });
    try writer.writeAll("' \\\n");
}

fn writeZshAction(
    writer: anytype,
    app: cli.ApplicationSpec,
    kind: cli.CompletionKind,
    slot: Slot,
) !void {
    switch (kind) {
        .none => {},
        .files => try writer.writeAll("_files"),
        .directories => try writer.writeAll("_files -/"),
        .commands => try writer.writeAll("_command_names -e"),
        .values => |values| {
            try writer.writeAll("(");
            for (values, 0..) |value, i| {
                if (i > 0) try writer.writeByte(' ');
                try writeZshValueWord(writer, value);
            }
            try writer.writeAll(")");
        },
        .external => try writeExternalName(writer, app, slot),
    }
}

/// Emits one character into the surrounding single-quoted `_arguments`
/// specification, closing and reopening the quote around a literal quote.
fn writeInSpec(writer: anytype, char: u8) !void {
    if (char == '\'') {
        try writer.writeAll("'\\''");
    } else {
        try writer.writeByte(char);
    }
}

/// Writes a single word of a zsh action list. The word is itself quoted for
/// zsh, and that quoting is then escaped again for the enclosing specification
/// string, so a value may contain spaces, quotes, `$`, or backslashes.
fn writeZshValueWord(writer: anytype, value: []const u8) !void {
    var plain = value.len > 0;
    for (value) |char| {
        if (!std.ascii.isAlphanumeric(char) and
            char != '-' and char != '_' and char != '.' and char != '/' and char != '+')
        {
            plain = false;
        }
    }

    if (plain) {
        try writer.writeAll(value);
        return;
    }

    try writeInSpec(writer, '\'');
    for (value) |char| {
        if (char == '\'') {
            // A quote inside a zsh single-quoted word is written '\''.
            for ("'\\''") |escaped| try writeInSpec(writer, escaped);
        } else if (char == '\n') {
            try writeInSpec(writer, ' ');
        } else {
            try writeInSpec(writer, char);
        }
    }
    try writeInSpec(writer, '\'');
}

// ── Fish ─────────────────────────────────────────────────────────────────────

pub fn generateFish(writer: anytype, app: cli.ApplicationSpec) !void {
    try writer.writeAll("# fish completion for ");
    try writer.writeAll(app.name);
    try writer.writeAll("\n\n");
    try writer.writeAll("complete -c ");
    try writeFishQuoted(writer, app.name);
    try writer.writeAll(" -f\n\n");

    try writeFishCommandFn(writer, app);
    try writeFishHelpers(writer, app);
    try forEachSlot(writer, app, writeFishHelper);

    // Root: commands and root options.
    for (app.commands) |command| {
        try writeFishCommandEntry(writer, app, command.name, command.description);
        for (command.aliases) |alias| {
            try writeFishCommandEntry(writer, app, alias, command.description);
        }
    }
    try writer.writeByte('\n');

    for (app.flags) |flag| try writeFishFlag(writer, app, rootScope(app), flag, null);
    try writeFishFlag(writer, app, rootScope(app), cli.help_flag, null);
    try writer.writeByte('\n');

    for (app.commands) |command| {
        try writer.writeAll("# ");
        try writer.writeAll(command.name);
        try writer.writeByte('\n');
        for (command.flags) |flag| try writeFishFlag(writer, app, commandScope(command), flag, command);
        try writeFishFlag(writer, app, commandScope(command), cli.help_flag, command);
        try writeFishPositionals(writer, app, command);
        try writer.writeByte('\n');
    }
}

/// Emits the function that reports which command the current command line
/// names, skipping root options and the values they consume.
fn writeFishCommandFn(writer: anytype, app: cli.ApplicationSpec) !void {
    try writer.writeAll("function ");
    try writeHelperPrefix(writer, app);
    try writer.writeAll(
        \\_command
        \\    set -l tokens (commandline -opc)
        \\    set -e tokens[1]
        \\    set -l skip 0
        \\    for token in $tokens
        \\        if test $skip -eq 1
        \\            set skip 0
        \\            continue
        \\        end
        \\        switch $token
        \\            case '--'
        \\                return 1
        \\
    );
    try writeFishValueFlagCase(writer, app.flags, "            ");
    try writer.writeAll(
        \\            case '--*=*'
        \\            case '-*'
        \\            case '*'
        \\                echo $token
        \\                return 0
        \\        end
        \\    end
        \\    return 1
        \\end
        \\
        \\
    );
}

fn writeFishHelpers(writer: anytype, app: cli.ApplicationSpec) !void {
    try writer.writeAll("function ");
    try writeHelperPrefix(writer, app);
    try writer.writeAll("_no_command\n    not ");
    try writeHelperPrefix(writer, app);
    try writer.writeAll("_command >/dev/null\nend\n\n");

    try writer.writeAll("function ");
    try writeHelperPrefix(writer, app);
    try writer.writeAll("_using_command\n    set -l found (");
    try writeHelperPrefix(writer, app);
    try writer.writeAll(
        \\_command)
        \\    or return 1
        \\    contains -- $found $argv
        \\end
        \\
        \\
    );

    // Everything after `--` is positional, so option completions stop there.
    try writer.writeAll("function ");
    try writeHelperPrefix(writer, app);
    try writer.writeAll(
        \\_after_terminator
        \\    for token in (commandline -opc)
        \\        if test "$token" = '--'
        \\            return 0
        \\        end
        \\    end
        \\    return 1
        \\end
        \\
        \\
    );
}

fn writeFishValueFlagCase(
    writer: anytype,
    flags: []const cli.FlagSpec,
    indent: []const u8,
) !void {
    var any = false;
    for (flags) |flag| {
        if (cli.takesValue(flag)) any = true;
    }
    if (!any) return;

    // Flag spellings use the validated name grammar, so they need no escaping
    // beyond the surrounding quotes.
    try writer.writeAll(indent);
    try writer.writeAll("case");
    for (flags) |flag| {
        if (!cli.takesValue(flag)) continue;
        try writer.print(" '--{s}'", .{flag.name});
        for (flag.aliases) |alias| try writer.print(" '--{s}'", .{alias});
        if (flag.short) |short| try writer.print(" '-{c}'", .{short});
    }
    try writer.writeAll("\n");
    try writer.writeAll(indent);
    try writer.writeAll("    set skip 1\n");
}

fn writeFishCommandEntry(
    writer: anytype,
    app: cli.ApplicationSpec,
    name: []const u8,
    description: []const u8,
) !void {
    try writer.writeAll("complete -c ");
    try writeFishQuoted(writer, app.name);
    try writer.writeAll(" -n '");
    try writeHelperPrefix(writer, app);
    try writer.writeAll("_no_command' -a ");
    try writeFishQuoted(writer, name);
    try writer.writeAll(" -d ");
    try writeFishQuoted(writer, description);
    try writer.writeByte('\n');
}

fn writeFishCondition(
    writer: anytype,
    app: cli.ApplicationSpec,
    command: ?cli.CommandSpec,
    exclude_after_terminator: bool,
) !void {
    try writer.writeAll(" -n '");
    if (command) |spec| {
        // Command names use the validated grammar, so they carry no characters
        // that would need escaping inside this condition string.
        try writeHelperPrefix(writer, app);
        try writer.writeAll("_using_command ");
        try writer.writeAll(spec.name);
        for (spec.aliases) |alias| {
            try writer.writeByte(' ');
            try writer.writeAll(alias);
        }
    } else {
        try writeHelperPrefix(writer, app);
        try writer.writeAll("_no_command");
    }
    if (exclude_after_terminator) {
        try writer.writeAll("; and not ");
        try writeHelperPrefix(writer, app);
        try writer.writeAll("_after_terminator");
    }
    try writer.writeAll("'");
}

fn writeFishFlag(
    writer: anytype,
    app: cli.ApplicationSpec,
    scope: Scope,
    flag: cli.FlagSpec,
    command: ?cli.CommandSpec,
) !void {
    try writer.writeAll("complete -c ");
    try writeFishQuoted(writer, app.name);
    try writeFishCondition(writer, app, command, true);
    try writer.print(" -l {s}", .{flag.name});
    if (flag.short) |short| try writer.print(" -s {c}", .{short});
    // -x, not -r: `require-parameter` still lets fish fall back to filenames
    // alongside the declared values, so a directory-only flag would offer
    // regular files. `exclusive` matches how bash and zsh complete values.
    if (cli.takesValue(flag)) try writer.writeAll(" -x");
    if (flag.description.len > 0) {
        try writer.writeAll(" -d ");
        try writeFishQuoted(writer, flag.description);
    }
    try writeFishValueAction(writer, app, cli.flagCompletion(flag), .{
        .command = scope.name(),
        .kind = .flag,
        .name = flag.name,
    });
    try writer.writeByte('\n');

    // Aliases are separate completions sharing the same behavior.
    for (flag.aliases) |alias| {
        try writer.writeAll("complete -c ");
        try writeFishQuoted(writer, app.name);
        try writeFishCondition(writer, app, command, true);
        try writer.print(" -l {s}", .{alias});
        if (cli.takesValue(flag)) try writer.writeAll(" -x");
        if (flag.description.len > 0) {
            try writer.writeAll(" -d ");
            try writeFishQuoted(writer, flag.description);
        }
        try writeFishValueAction(writer, app, cli.flagCompletion(flag), .{
            .command = scope.name(),
            .kind = .flag,
            .name = flag.name,
        });
        try writer.writeByte('\n');
    }
}

fn writeFishValueAction(
    writer: anytype,
    app: cli.ApplicationSpec,
    kind: cli.CompletionKind,
    slot: Slot,
) !void {
    switch (kind) {
        .none => {},
        .files => try writer.writeAll(" -F"),
        .directories => try writer.writeAll(" -a '(__fish_complete_directories)'"),
        .commands => try writer.writeAll(" -a '(__fish_complete_command)'"),
        .values => {
            try writer.writeAll(" -a '(");
            try writeValuesName(writer, app, slot);
            try writer.writeAll(")'");
        },
        .external => {
            try writer.writeAll(" -a '(");
            try writeExternalName(writer, app, slot);
            try writer.writeAll(")'");
        },
    }
}

/// Fish has no way to quote a candidate containing whitespace inside a
/// `complete -a` list, so both fixed values and external candidates are emitted
/// through a function that prints one candidate per line.
fn writeFishHelper(
    writer: anytype,
    app: cli.ApplicationSpec,
    slot: Slot,
    kind: cli.CompletionKind,
) anyerror!void {
    switch (kind) {
        .values => |values| {
            try writer.writeAll("function ");
            try writeValuesName(writer, app, slot);
            try writer.writeByte('\n');
            for (values) |value| {
                try writer.writeAll("    echo ");
                try writeFishQuoted(writer, value);
                try writer.writeByte('\n');
            }
            try writer.writeAll("end\n\n");
        },
        .external => |external| {
            try writer.writeAll("function ");
            try writeExternalName(writer, app, slot);
            try writer.writeAll("\n    set -l output (");
            try writeFishQuoted(writer, external.executable);
            for (external.arguments) |argument| {
                try writer.writeByte(' ');
                try writeFishQuoted(writer, argument);
            }
            try writer.writeAll(
                \\ (commandline -ct) 2>/dev/null)
                \\    or return
                \\    for line in $output
                \\        if test -n "$line"
                \\            echo $line
                \\        end
                \\    end
                \\end
                \\
                \\
            );
        },
        else => {},
    }
}

fn writeFishPositionals(
    writer: anytype,
    app: cli.ApplicationSpec,
    command: cli.CommandSpec,
) !void {
    if (command.arguments.len == 0) return;

    // Fish has no positional index in `complete`, so a command whose slots
    // complete differently gets an explicit counter function.
    if (uniformArguments(command)) {
        const kind = command.arguments[0].completion;
        if (kind == .none) return;
        try writer.writeAll("complete -c ");
        try writeFishQuoted(writer, app.name);
        try writeFishCondition(writer, app, command, false);
        try writeFishValueAction(writer, app, kind, .{
            .command = command.name,
            .kind = .argument,
            .name = command.arguments[0].name,
        });
        try writer.writeByte('\n');
        return;
    }

    try writeFishPositionalCounter(writer, app, command);

    for (command.arguments, 0..) |argument, i| {
        if (argument.repeatable and i == command.arguments.len - 1) break;
        if (argument.completion == .none) continue;
        try writer.writeAll("complete -c ");
        try writeFishQuoted(writer, app.name);
        try writer.writeAll(" -n '");
        try writeHelperPrefix(writer, app);
        try writer.writeAll("_using_command ");
        try writer.writeAll(command.name);
        for (command.aliases) |alias| {
            try writer.writeByte(' ');
            try writer.writeAll(alias);
        }
        try writer.writeAll("; and test (");
        try writeHelperPrefix(writer, app);
        try writer.writeAll("_pos_");
        try writeIdent(writer, command.name);
        try writer.print(") -eq {d}'", .{i});
        try writeFishValueAction(writer, app, argument.completion, .{
            .command = command.name,
            .kind = .argument,
            .name = argument.name,
        });
        try writer.writeByte('\n');
    }

    if (trailingArgument(command)) |argument| {
        if (argument.completion == .none) return;
        try writer.writeAll("complete -c ");
        try writeFishQuoted(writer, app.name);
        try writer.writeAll(" -n '");
        try writeHelperPrefix(writer, app);
        try writer.writeAll("_using_command ");
        try writer.writeAll(command.name);
        for (command.aliases) |alias| {
            try writer.writeByte(' ');
            try writer.writeAll(alias);
        }
        try writer.writeAll("; and test (");
        try writeHelperPrefix(writer, app);
        try writer.writeAll("_pos_");
        try writeIdent(writer, command.name);
        try writer.print(") -ge {d}'", .{command.arguments.len - 1});
        try writeFishValueAction(writer, app, argument.completion, .{
            .command = command.name,
            .kind = .argument,
            .name = argument.name,
        });
        try writer.writeByte('\n');
    }
}

fn writeFishPositionalCounter(
    writer: anytype,
    app: cli.ApplicationSpec,
    command: cli.CommandSpec,
) !void {
    try writer.writeAll("function ");
    try writeHelperPrefix(writer, app);
    try writer.writeAll("_pos_");
    try writeIdent(writer, command.name);
    try writer.writeAll(
        \\
        \\    set -l tokens (commandline -opc)
        \\    set -e tokens[1]
        \\    set -l count 0
        \\    set -l found 0
        \\    set -l skip 0
        \\    set -l dd 0
        \\    for token in $tokens
        \\        if test $skip -eq 1
        \\            set skip 0
        \\            continue
        \\        end
        \\        if test $found -eq 0
        \\            switch $token
        \\
    );
    try writeFishValueFlagCase(writer, app.flags, "                ");
    try writer.writeAll(
        \\                case '--*=*'
        \\                case '-*'
        \\                case '*'
        \\                    set found 1
        \\            end
        \\            continue
        \\        end
        \\        if test $dd -eq 1
        \\            set count (math $count + 1)
        \\            continue
        \\        end
        \\        switch $token
        \\            case '--'
        \\                set dd 1
        \\
    );
    try writeFishValueFlagCase(writer, command.flags, "            ");
    try writer.writeAll(
        \\            case '--*=*'
        \\            case '-*'
        \\            case '*'
        \\                set count (math $count + 1)
        \\        end
        \\    end
        \\    echo $count
        \\end
        \\
        \\
    );
}
