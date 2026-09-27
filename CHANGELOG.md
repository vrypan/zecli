# Changelog

Versions are listed newest first; changes within a version are listed in the
order they were made.

## 0.5.0 — 2026-09-18

- Add mounted applications: `cli.mount` nests a whole application under a
  command, with its own option scope. Help, diagnostics, and completion for
  bash, zsh, and fish use the full command path.
- Fix zsh completion for passthrough commands when the cursor is before an
  existing `--`.
- **Breaking:** reserve `-h` and `--help`. Validation rejects an option named
  `help`, aliased `help`, or with short name `h` (`error.ReservedName`), which
  the parser could never reach.
- Add `helpWriter(...).width` to pin the help width, so output written to a
  buffer does not depend on the terminal running the program.
- **Breaking:** name environment variables after the command path:
  `app config set --override` reads `APP_CONFIG_SET_OVERRIDE`. Only the invoked
  application's prefix is used; a mounted application's own prefix applies
  only when it runs standalone. Validation rejects options that map to the
  same variable (`error.DuplicateEnvironmentName`).
- `printCommandHelp` on a mounted command prints that application's standalone
  help instead of a usage line rebased onto the bare command name.
- Completion generators no longer allocate memory.
- Buffer help, parse errors, and completion scripts internally, so any writer
  receives a few large writes: a bash script arrives in about four writes
  instead of about a thousand. `cli.bufferedWriter` exposes the same buffer.
- Define the generic bash and zsh completion helpers once per script instead
  of once per mounted application, making scripts about 10% smaller.
- **Breaking:** remove `printCommandList`, `printArguments`, and
  `printOptions`. Print whole help screens with `printApplicationHelp`,
  `printCommandHelp`, or `Invocation.printHelpIfRequested`.

## 0.4.4 — 2026-09-23

- Fix fish completion for file-valued options, which now offer filenames.

## 0.4.3 — 2026-09-22

- Indent and wrap `extra_help` text to the help width.
- Cap help at 80 columns by default. Set `helpWriter(...).max_width`, or
  implement `helpMaxWidth` on a custom writer, to change the cap.

## 0.4.2 — 2026-09-22

- Add terminal-styled help: `HelpStyle` detects terminal support and honors
  `NO_COLOR`, and `helpWriter` applies the choice. Plain output keeps the same
  layout.
- Help uses uppercase section headings, and specifications gain `examples`
  and `help_sections`.

## 0.4.1 — 2026-09-17

- Wrap help to the terminal width. `terminalWidth` queries a file's width.

## 0.4.0 — 2026-09-16

- Add `CommandSpec.double_dash`. In `.positionals` mode, arguments after `--`
  are ordinary positional arguments, so `cat -- @42/out` satisfies a required
  argument; the default `.passthrough` mode keeps them as a separate tail.
  Completion follows the same rule in all three shells.

## 0.3.2 — 2026-08-31

- The release workflow fails when the `build.zig.zon` version does not match
  the tag.

## 0.3.1 — 2026-08-31

- No-value switches read boolean environment values, and `enabled` reports a
  switch's effective state.
- Repeatable options read comma-separated environment values.
- Add release automation: release notes from commit subjects and a GitHub
  release for each pushed tag.

## 0.3.0 — 2026-08-31

- Record declared defaults in parsed values, with `ValueSource` telling
  command-line, environment, and default values apart.
- Add typed accessors: `getValue`, `getValues`, and `getValueAs` with checked
  numeric conversions.
- Read omitted option values from environment variables when
  `ApplicationSpec.prefix` is set.
- **Breaking:** add `Invocation.init`, which parses root options and the
  selected command in one pass, with `Command` accessors,
  `printHelpIfRequested`, and `CommandEnum` for dispatching on canonical
  command names.

## 0.2.3 — 2026-08-30

- `comptimeValidated` raises the compile-time evaluation quota its validation
  needs, so callers no longer have to.

## 0.2.2 — 2026-08-30

- Fix fish value completion, which also offered filenames; bash file
  completion, which did not escape spaces or mark directories; and zsh
  per-command contexts, which ignored per-command zstyles.
- Print help without allocating. **Breaking:** `printCommandList` no longer
  takes an allocator.
- Add `comptimeValidated`, which turns specification mistakes into build
  errors.

## 0.2.1 — 2026-08-29

- Fix zsh completion repeating its candidates once per configured matcher.
- Fix autoloaded zsh completion, which completed nothing on the first Tab.

## 0.2.0 — 2026-08-28

- **Breaking:** describe the whole command line with one `ApplicationSpec`,
  replacing `CommandEntry` and `completion.CompletionSpec`. It drives parsing,
  lookup, help, and completion.
- Add command and long-option aliases; values are recorded under canonical
  names.
- Add `choices` for value-taking options, validated while parsing and shown in
  help and completion.
- Add explicit completion metadata for options and arguments: files,
  directories, commands, fixed values, and external completers, which are run
  directly and read one candidate per line. This replaces completing files for
  arguments named `FILE`.
- Add `validateApplicationSpec` and `validateCommandSpec`.
- Add `printApplicationHelp` and `Parsed.deinit`.
- `helpRequested` stops at `--`.
- Bash, zsh, and fish completion find the command after root options, follow
  aliases, and stop offering options after `--`.
- Add continuous integration on Ubuntu and macOS, including behavioral
  completion tests in all three shells.

## 0.1.2 — 2026-05-09

- First release: a command-line parser with subcommands, generated help, and
  bash, zsh, and fish completion, with an example program.
- Add `helpRequested` to detect `-h` and `--help` before parsing.
