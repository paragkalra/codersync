#!/usr/bin/env bats
#
# Unit tests for the pure-logic pieces of `codersync` -- string
# resolution/escaping/sanitization and argument parsing. Nothing here
# touches SSH, tmux, or iTerm2: those are exercised by hand against a
# real box (see README.md's "Testing" section), not by this suite.

bats_require_minimum_version 1.5.0

setup() {
  # shellcheck disable=SC1091
  source "${BATS_TEST_DIRNAME}/../codersync"
}

# --- resolve_tool ------------------------------------------------------

@test "resolve_tool: claude, dangerous mode (default)" {
  result="$(resolve_tool claude mysession 0)"
  [ "$result" = "claude -n mysession --dangerously-skip-permissions" ]
}

@test "resolve_tool: claude, safe mode" {
  result="$(resolve_tool claude mysession 1)"
  [ "$result" = "claude -n mysession" ]
}

@test "resolve_tool: codex, dangerous mode" {
  result="$(resolve_tool codex mysession 0)"
  [ "$result" = "codex --dangerously-bypass-approvals-and-sandbox -s danger-full-access" ]
}

@test "resolve_tool: codex, safe mode" {
  result="$(resolve_tool codex mysession 1)"
  [ "$result" = "codex" ]
}

@test "resolve_tool: agy, dangerous mode" {
  result="$(resolve_tool agy mysession 0)"
  [ "$result" = "agy --dangerously-skip-permissions" ]
}

@test "resolve_tool: aider, dangerous mode" {
  result="$(resolve_tool aider mysession 0)"
  [ "$result" = "aider --yes-always" ]
}

@test "resolve_tool: kimi, dangerous mode" {
  result="$(resolve_tool kimi mysession 0)"
  [ "$result" = "kimi --yolo" ]
}

@test "resolve_tool: unknown key passes through literally, ignoring safe mode" {
  result="$(resolve_tool 'some-agent --already-has-a-flag' mysession 1)"
  [ "$result" = "some-agent --already-has-a-flag" ]
}

@test "resolve_tool: safe mode defaults to dangerous when omitted" {
  result="$(resolve_tool claude mysession)"
  [ "$result" = "claude -n mysession --dangerously-skip-permissions" ]
}

# --- command_word_for -----------------------------------------------------

@test "command_word_for: plain command with no assignment returns the first word" {
  result="$(command_word_for 'claude -n mysession --dangerously-skip-permissions')"
  [ "$result" = "claude" ]
}

@test "command_word_for: skips a single leading NAME=value assignment" {
  # Regression test: a raw --tools value is documented as the exact
  # command to run, and "VAR=value cmd" is an ordinary, valid way to
  # write that under bash -- but a flat "\${cmd%% *}" split took the
  # assignment itself as the thing to existence-check, so a perfectly
  # runnable command was reported as "not found" (confirmed live).
  result="$(command_word_for 'OPENAI_API_KEY=sk-xxx some-agent --flag')"
  [ "$result" = "some-agent" ]
}

@test "command_word_for: skips multiple leading assignments" {
  result="$(command_word_for 'FOO=1 BAR=2 some-agent --flag')"
  [ "$result" = "some-agent" ]
}

@test "command_word_for: an assignment with no command after it returns the assignment itself" {
  # Degenerate/malformed input -- there's no real command to find, so
  # this just returns what's there rather than looping or erroring.
  result="$(command_word_for 'FOO=1')"
  [ "$result" = "FOO=1" ]
}

@test "command_word_for: does not treat an --flag=value as an assignment" {
  # "--flag=value" doesn't match NAME=value (NAME can't start with a
  # dash), so this must still be read as the actual command, not skipped.
  result="$(command_word_for '--not-a-var=value some-agent')"
  [ "$result" = "--not-a-var=value" ]
}

@test "command_word_for: known limitation -- a quoted space in the assignment's value still splits it apart" {
  # Documenting, not asserting correctness: FOO='bar baz' some-agent is
  # valid bash (an assignment whose VALUE contains a literal space),
  # but this is a plain space-splitter, not a shell parser -- it has no
  # way to know the space is inside quotes. Fixing that fully would
  # require having bash itself evaluate the string (eval/set --), which
  # would also execute any $(...)/backtick substitution embedded in the
  # value, immediately and locally -- a worse risk than this narrow
  # parsing gap. README documents the `env NAME=value cmd` workaround.
  result="$(command_word_for "FOO='bar baz' some-agent --flag")"
  [ "$result" = "baz'" ]
}

@test "command_word_for: the documented env-prefix workaround resolves cleanly" {
  # "env" itself doesn't match NAME=value (no "="), so it's returned
  # immediately as the first word -- "env" is virtually always
  # installed, so the existence check trivially passes instead of
  # wrongly aborting, even though the space in the value would
  # otherwise trip up the plain assignment-skipping above.
  result="$(command_word_for "env FOO='bar baz' some-agent --flag")"
  [ "$result" = "env" ]
}

# --- as_escape ----------------------------------------------------------

@test "as_escape: plain string is unchanged" {
  result="$(as_escape 'hello world')"
  [ "$result" = "hello world" ]
}

@test "as_escape: escapes a double quote" {
  result="$(as_escape 'say "hi"')"
  [ "$result" = 'say \"hi\"' ]
}

@test "as_escape: escapes a backslash" {
  result="$(as_escape 'a\b')"
  [ "$result" = 'a\\b' ]
}

@test "as_escape: escapes backslash before quote (order matters)" {
  # If quotes were escaped before backslashes, this would double-escape
  # and corrupt the result -- backslash must be escaped first.
  result="$(as_escape 'a\"b')"
  [ "$result" = 'a\\\"b' ]
}

# --- b64 (round-trip only; encoding format is an implementation detail) -

@test "b64: round-trips a plain string" {
  encoded="$(b64 'hello world')"
  decoded="$(printf '%s' "$encoded" | base64 -d)"
  [ "$decoded" = "hello world" ]
}

@test "b64: round-trips a string with quotes and semicolons" {
  original='bash -c "echo hi; sleep 1"'
  encoded="$(b64 "$original")"
  decoded="$(printf '%s' "$encoded" | base64 -d)"
  [ "$decoded" = "$original" ]
}

@test "b64: output never contains an embedded newline, even for long input" {
  # Regression test: every call site embeds this output as ONE bare
  # token in a remote heredoc (e.g. `echo \${cmd1_b64} | base64 -d`),
  # which requires it to stay on a single line. macOS's own BSD base64
  # doesn't wrap by default, but a GNU coreutils base64 earlier in PATH
  # (a common Homebrew setup) wraps at 76 characters -- a long enough
  # resolved command would otherwise split across multiple lines in the
  # generated remote script and fail to decode correctly.
  original="claude -n a-very-long-session-name-that-is-long-enough-to-trigger-line-wrapping-in-a-76-column-wrapping-base64-implementation --dangerously-skip-permissions"
  encoded="$(b64 "$original")"
  [[ "$encoded" != *$'\n'* ]]
  decoded="$(printf '%s' "$encoded" | base64 -d)"
  [ "$decoded" = "$original" ]
}

# --- remote_kill_session ---------------------------------------------

@test "remote_kill_session: never passes the raw session name as an ssh argument" {
  # Regression test: `ssh ... tmux kill-session -t "$name"` used to pass
  # the name as a separate ssh argument, but ssh rejoins a multi-arg
  # remote command with plain spaces before the remote shell parses it --
  # so a name containing shell metacharacters became remote shell syntax
  # (confirmed live with a session named "pair-1-x; touch /tmp/pwn"). The
  # name must now only ever appear base64-encoded, never as a raw arg or
  # raw heredoc text.
  # shellcheck disable=SC2030 # read by remote_kill_session below, but
  # that cross-function global dependency isn't visible statically.
  SSH_TARGET="devbox.example.com"
  # shellcheck disable=SC2329 # invoked indirectly, by remote_kill_session.
  ssh() {
    printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/args"
    cat > "$BATS_TEST_TMPDIR/stdin"
  }
  remote_kill_session 'pair-1-x; touch /tmp/pwn'
  run cat "$BATS_TEST_TMPDIR/args"
  [[ "$output" != *';'* ]]
  [[ "$output" != *'touch'* ]]
  decoded="$(grep -o 'echo [A-Za-z0-9+/=]*' "$BATS_TEST_TMPDIR/stdin" | awk '{print $2}' | base64 -d)"
  [ "$decoded" = 'pair-1-x; touch /tmp/pwn' ]
}

@test "remote_kill_session: also removes the session's own launch script(s)" {
  # Regression test: nothing ever cleaned up a session's /tmp launch
  # script -- killing a session BEFORE it was ever attached to (so the
  # script's own self-delete line never ran) left the file behind
  # indefinitely, confirmed live with over a dozen leftover scripts
  # accumulated purely from --kill'ing test sessions during development.
  # shellcheck disable=SC2030 # read by remote_kill_session below, but
  # that cross-function global dependency isn't visible statically.
  SSH_TARGET="devbox.example.com"
  # shellcheck disable=SC2329 # invoked indirectly, by remote_kill_session.
  ssh() { cat > "$BATS_TEST_TMPDIR/stdin"; }
  remote_kill_session 'pair-3-devbox-example-com-foo'
  run cat "$BATS_TEST_TMPDIR/stdin"
  # shellcheck disable=SC2016 # intentional: checking for this literal
  # (unexpanded) text in the captured remote script, not expanding it.
  [[ "$output" == *'rm -f -- /tmp/codersync-"$name"-*.sh'* ]]
}

@test "remote_kill_session: skips the /tmp cleanup for a name containing a path separator" {
  # Regression test: `name` becomes a literal path segment in the rm
  # glob -- quoting prevents shell injection, but doesn't neutralize `/`
  # as a path separator, so a name like this could otherwise traverse
  # outside /tmp entirely. The session itself still gets killed
  # (tmux kill-session is safe for any content via base64 encoding);
  # only the path-based cleanup is skipped.
  # shellcheck disable=SC2030 # read by remote_kill_session below, but
  # that cross-function global dependency isn't visible statically.
  SSH_TARGET="devbox.example.com"
  # shellcheck disable=SC2329 # invoked indirectly, by remote_kill_session.
  ssh() { cat > "$BATS_TEST_TMPDIR/stdin"; }
  remote_kill_session 'pair-1-host/../../victim'
  run cat "$BATS_TEST_TMPDIR/stdin"
  [[ "$output" == *'tmux kill-session'* ]]
  [[ "$output" != *'rm -f'* ]]
}

# --- random_suffix --------------------------------------------------------

@test "random_suffix: produces a non-empty alphanumeric string" {
  result="$(random_suffix)"
  [ -n "$result" ]
  [[ "$result" =~ ^[A-Za-z0-9]+$ ]]
}

@test "random_suffix: two calls produce different values" {
  # Not a strict guarantee (it's random), but a collision here would be
  # astronomically unlikely and almost certainly indicate a real bug.
  first="$(random_suffix)"
  second="$(random_suffix)"
  [ "$first" != "$second" ]
}

# --- next_session_id / find_or_assign_id / parse_numbered_session -------

@test "next_session_id: starts at 1 and increments" {
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  [ "$(next_session_id)" = "1" ]
  [ "$(next_session_id)" = "2" ]
  [ "$(next_session_id)" = "3" ]
}

@test "next_session_id: resets to 1 with a warning on a non-numeric file" {
  # Regression test: bash arithmetic on a non-numeric value (e.g. from a
  # hand-edited or truncated-mid-write file) used to be a fatal error
  # under `set -e`, crashing the whole invocation.
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  printf 'abc' > "$NEXT_ID_FILE"
  run next_session_id
  [ "$status" -eq 0 ]
  [ "$output" = "codersync: ${NEXT_ID_FILE} contained an invalid value ('abc') -- resetting the session-ID counter to 1.
1" ]
}

@test "next_session_id: resets to 1 on a negative value instead of producing a negative ID" {
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  printf -- '-1' > "$NEXT_ID_FILE"
  result="$(next_session_id 2>/dev/null)"
  [ "$result" = "1" ]
}

@test "next_session_id: resets to 1 instead of emitting ID 0" {
  # Regression test: 0 passed the "non-negative integer" check, so a
  # next_id file containing "0" emitted session ID 0 -- IDs are
  # documented (and expected by --list-all/--kill) as starting at 1.
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  printf '0' > "$NEXT_ID_FILE"
  result="$(next_session_id 2>/dev/null)"
  [ "$result" = "1" ]
}

@test "next_session_id: a leading-zero value doesn't crash on bash's octal parsing" {
  # Regression test: bash arithmetic treats a leading-zero numeral as
  # octal -- "08"/"09" are a hard crash under `set -e` (8/9 aren't valid
  # octal digits), which this exact value used to trigger.
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  printf '08' > "$NEXT_ID_FILE"
  run next_session_id
  [ "$status" -eq 0 ]
  [ "$output" = "8" ]
}

@test "next_session_id: canonicalizes a leading-zero value instead of silently misreading it as octal" {
  # "010" is valid octal (== decimal 8) -- without the 10# fix, this
  # silently returned/persisted the wrong number instead of erroring.
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  printf '010' > "$NEXT_ID_FILE"
  [ "$(next_session_id)" = "10" ]
  [ "$(cat "$NEXT_ID_FILE")" = "11" ]
}

@test "next_session_id: resets to 1 on a value that would overflow 64-bit arithmetic" {
  # Regression test: bash integers are signed 64-bit -- a value with way
  # more digits than any real ID used to wrap to a large negative number
  # instead of erroring (confirmed live with a 44-digit value), and even
  # the 64-bit max itself wrapped to a negative number on the `+1` below.
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  printf '999999999999999999999999999999999999999999' > "$NEXT_ID_FILE"
  result="$(next_session_id 2>/dev/null)"
  [ "$result" = "1" ]
}

@test "next_session_id: resets to 1 on the 64-bit signed max instead of wrapping negative" {
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  printf '9223372036854775807' > "$NEXT_ID_FILE"
  result="$(next_session_id 2>/dev/null)"
  [ "$result" = "1" ]
}

@test "parse_numbered_session: extracts a leading numeric ID" {
  parse_numbered_session "claude-" "claude-3-devbox-example-com-foo"
  [ "$PARSED_ID" = "3" ]
  [ "$PARSED_REST" = "devbox-example-com-foo" ]
}

@test "parse_numbered_session: legacy session with no ID leaves PARSED_ID empty" {
  parse_numbered_session "claude-" "claude-devbox-review-alex-8349"
  [ "$PARSED_ID" = "" ]
  [ "$PARSED_REST" = "devbox-review-alex-8349" ]
}

@test "parse_numbered_session: canonicalizes a leading-zero ID instead of crashing on octal" {
  # Regression test: a live tmux session literally named
  # "pair-08-host-foo" used to reach printf '%06d' with the raw "08" and
  # crash there ("08: invalid octal number") -- PARSED_ID must be the
  # canonical decimal form.
  parse_numbered_session "pair-" "pair-08-host-foo"
  [ "$PARSED_ID" = "8" ]
  [ "$PARSED_REST" = "host-foo" ]
}

@test "parse_numbered_session: treats a pathologically long ID segment as no ID at all" {
  # Regression test: a 21-digit ID used to reach printf '%06d' as-is and
  # crash ("Result too large") -- an ID this broken should be treated
  # the same as a legacy session with no ID, not crash downstream.
  parse_numbered_session "pair-" "pair-123456789012345678901-host-foo"
  [ "$PARSED_ID" = "" ]
  [ "$PARSED_REST" = "123456789012345678901-host-foo" ]
}

@test "parse_numbered_session: treats a zero ID segment as no ID at all" {
  parse_numbered_session "pair-" "pair-0-host-foo"
  [ "$PARSED_ID" = "" ]
  [ "$PARSED_REST" = "0-host-foo" ]
}

@test "find_or_assign_id: allocates a fresh ID when nothing matches" {
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  [ "$(find_or_assign_id "devbox.example.com" "devbox-example-com-foo")" = "1" ]
}

@test "find_or_assign_id: reuses the existing ID for the same target+name" {
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t5-devbox-example-com-foo\n' > "$REGISTRY"
  [ "$(find_or_assign_id "devbox.example.com" "devbox-example-com-foo")" = "5" ]
}

@test "find_or_assign_id: does not reuse an ID belonging to a different target" {
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  # shellcheck disable=SC2034 # read by next_session_id, called below.
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'some-other-box\t5-devbox-example-com-foo\n' > "$REGISTRY"
  [ "$(find_or_assign_id "devbox.example.com" "devbox-example-com-foo")" = "1" ]
}

@test "find_or_assign_id: mints a fresh ID instead of reusing a poisoned registry entry" {
  # Regression test: a registry entry with a broken ID segment (leading
  # zero beyond what canonicalizes sanely, or literally 0) used to be
  # reused verbatim -- next_session_id itself would never assign such a
  # value, so returning it here let it right back out as a real ID.
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t0-devbox-example-com-foo\n' > "$REGISTRY"
  [ "$(find_or_assign_id "devbox.example.com" "devbox-example-com-foo")" = "1" ]
}

# --- parse_kill_spec -----------------------------------------------------

@test "parse_kill_spec: comma-separated list" {
  result="$(parse_kill_spec '1,2,4' | tr '\n' ',')"
  [ "$result" = "1,2,4," ]
}

@test "parse_kill_spec: a range" {
  result="$(parse_kill_spec '1-4' | tr '\n' ',')"
  [ "$result" = "1,2,3,4," ]
}

@test "parse_kill_spec: a mix of single values and ranges" {
  result="$(parse_kill_spec '1,3-5,8' | tr '\n' ',')"
  [ "$result" = "1,3,4,5,8," ]
}

@test "parse_kill_spec: de-duplicates and sorts" {
  result="$(parse_kill_spec '4,1,1,2' | tr '\n' ',')"
  [ "$result" = "1,2,4," ]
}

@test "parse_kill_spec: rejects a backwards range" {
  run parse_kill_spec '5-2'
  [ "$status" -eq 1 ]
  [[ "$output" == *"start must be <= end"* ]]
}

@test "parse_kill_spec: rejects a non-numeric token" {
  run parse_kill_spec 'abc'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid --kill token"* ]]
}

@test "parse_kill_spec: accepts a range right at the max size" {
  result="$(parse_kill_spec '1-1000' | wc -l | tr -d ' ')"
  [ "$result" = "1000" ]
}

@test "parse_kill_spec: rejects a range that's too large instead of expanding it" {
  # Regression test: a huge range (e.g. a typo like "1-999999999") used
  # to be expanded into an in-memory array one ID at a time before any
  # remote work even started, which could hang or exhaust memory locally.
  run parse_kill_spec '1-999999999'
  [ "$status" -eq 1 ]
  [[ "$output" == *"spans more than"* ]]
}

@test "parse_kill_spec: a leading-zero range doesn't crash on bash's octal parsing" {
  # Regression test: bash arithmetic treats a leading-zero numeral as
  # octal -- "08"/"09" are a hard crash (8/9 aren't valid octal digits),
  # which this exact range used to trigger with no IDs parsed at all.
  result="$(parse_kill_spec '08-09' | tr '\n' ',')"
  [ "$result" = "8,9," ]
}

@test "parse_kill_spec: canonicalizes a leading-zero single value" {
  result="$(parse_kill_spec '08')"
  [ "$result" = "8" ]
}

@test "parse_kill_spec: rejects ID 0 as a single value" {
  # Regression test: "0" (and "000", after leading-zero canonicalization)
  # used to pass through as a real ID, even though next_session_id never
  # assigns 0 -- IDs are documented as starting at 1.
  run parse_kill_spec '0'
  [ "$status" -eq 1 ]
  [[ "$output" == *"IDs start at 1"* ]]
}

@test "parse_kill_spec: rejects a range that includes 0" {
  run parse_kill_spec '0-1'
  [ "$status" -eq 1 ]
  [[ "$output" == *"IDs start at 1"* ]]
}

# --- load_config ----------------------------------------------------------

@test "load_config: accepts a valid config" {
  CONFIG_FILE="$BATS_TEST_TMPDIR/config"
  printf 'SSH_TARGET=devbox.example.com\nREMOTE_DIR=~/repos\n' > "$CONFIG_FILE"
  load_config
  # shellcheck disable=SC2031 # set by load_config's `source`, not
  # visible to shellcheck's static analysis.
  [ "$SSH_TARGET" = "devbox.example.com" ]
}

@test "load_config: rejects a config with an unsafe SSH_TARGET" {
  # Regression test: SSH_TARGET/REMOTE_DIR used to be trusted unchecked
  # after sourcing, so a hand-edited or pre-validation-era config value
  # like this (quoted here so *sourcing* it is safe -- the point is that
  # its CONTENT is unsafe once spliced unquoted into remote heredocs
  # further down, confirmed live) used to flow straight through.
  CONFIG_FILE="$BATS_TEST_TMPDIR/config"
  printf "SSH_TARGET='x; touch /tmp/pwn'\nREMOTE_DIR=~/repos\n" > "$CONFIG_FILE"
  run load_config
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid SSH_TARGET"* ]]
}

@test "load_config: rejects a config with an unsafe REMOTE_DIR" {
  CONFIG_FILE="$BATS_TEST_TMPDIR/config"
  printf "SSH_TARGET=devbox.example.com\nREMOTE_DIR='x; touch /tmp/pwn'\n" > "$CONFIG_FILE"
  run load_config
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid REMOTE_DIR"* ]]
}

@test "load_config: never executes config content, even when rejecting it" {
  # Regression test: load_config used to `source` the file before
  # validating anything, so a line like this one ran immediately as a
  # real shell command -- confirmed live -- even though the resulting
  # (empty) SSH_TARGET was correctly rejected right after. Reading the
  # file with plain `read`/regex instead of `source` means a line that
  # doesn't match either expected key is just rejected outright, never
  # executed.
  CONFIG_FILE="$BATS_TEST_TMPDIR/config"
  marker="$BATS_TEST_TMPDIR/executed"
  printf 'SSH_TARGET=devbox.example.com\ntouch %s\n' "$marker" > "$CONFIG_FILE"
  run load_config
  [ "$status" -eq 1 ]
  [[ "$output" == *"unrecognized line"* ]]
  [ ! -e "$marker" ]
}

@test "load_config: recovers the literal REMOTE_DIR value, undoing setup()'s %q tilde-escape" {
  CONFIG_FILE="$BATS_TEST_TMPDIR/config"
  # shellcheck disable=SC2088 # intentional: testing the literal string.
  printf 'SSH_TARGET=devbox.example.com\nREMOTE_DIR=%s\n' "$(printf '%q' '~/repos')" > "$CONFIG_FILE"
  load_config
  # shellcheck disable=SC2031,SC2088 # SC2031: set by load_config above,
  # not visible statically to this checker. SC2088: intentional literal.
  [ "$REMOTE_DIR" = "~/repos" ]
}

@test "load_config: accepts a legacy single-quoted SSH_TARGET without forcing --setup again" {
  # Regression test: setup() used to always wrap the value in a literal
  # pair of single quotes (SSH_TARGET='devbox.example.com') before %q-quoting
  # was introduced. Without stripping that one legacy quote pair, an
  # existing config from that version breaks on upgrade even though the
  # underlying value was always valid.
  CONFIG_FILE="$BATS_TEST_TMPDIR/config"
  printf "SSH_TARGET='devbox.example.com'\nREMOTE_DIR=~/repos\n" > "$CONFIG_FILE"
  load_config
  # shellcheck disable=SC2031 # set by load_config above, not visible
  # statically to this checker.
  [ "$SSH_TARGET" = "devbox.example.com" ]
}

@test "load_config: accepts a legacy single-quoted REMOTE_DIR without forcing --setup again" {
  CONFIG_FILE="$BATS_TEST_TMPDIR/config"
  # shellcheck disable=SC2088 # intentional: testing the literal string.
  printf "SSH_TARGET=devbox.example.com\nREMOTE_DIR='~/repos'\n" > "$CONFIG_FILE"
  load_config
  # shellcheck disable=SC2031,SC2088 # SC2031: set by load_config above,
  # not visible statically to this checker. SC2088: intentional literal.
  [ "$REMOTE_DIR" = "~/repos" ]
}

# --- sanitize_label -------------------------------------------------------

@test "sanitize_label: leaves a plain hostname unchanged" {
  result="$(sanitize_label 'myworkspace')"
  [ "$result" = "myworkspace" ]
}

@test "sanitize_label: replaces dots (tmux target-parser separator)" {
  result="$(sanitize_label 'coder.myworkspace')"
  [ "$result" = "coder-myworkspace" ]
}

@test "sanitize_label: replaces @ and : (user@host:port)" {
  result="$(sanitize_label 'user@host:2222')"
  [ "$result" = "user-host-2222" ]
}

@test "sanitize_label: replaces slashes" {
  result="$(sanitize_label 'host/path')"
  [ "$result" = "host-path" ]
}

@test "sanitize_label: replaces all separator types together" {
  result="$(sanitize_label 'user@host.example.com:22/x')"
  [ "$result" = "user-host-example-com-22-x" ]
}

# --- split_tools ----------------------------------------------------------

@test "split_tools: splits a two-item list" {
  split_tools "claude,codex"
  [ "$TOOL1" = "claude" ]
  [ "$TOOL2" = "codex" ]
}

@test "split_tools: preserves a raw command containing its own comma-free spaces" {
  split_tools "claude,gemini --some-flag"
  [ "$TOOL1" = "claude" ]
  [ "$TOOL2" = "gemini --some-flag" ]
}

@test "split_tools: a single value with no comma puts everything in both slots" {
  # Documents actual behavior rather than prescribing it: with no comma,
  # %%,* and #*, both return the whole string unchanged.
  split_tools "onlyone"
  [ "$TOOL1" = "onlyone" ]
  [ "$TOOL2" = "onlyone" ]
}

@test "split_tools: trims a trailing space before the comma" {
  # Regression test: TOOL1 used to stay "claude " (trailing space) --
  # resolve_tool's case-statement match is exact, so that missed the
  # known claude key entirely and silently fell through to running the
  # literal, un-flagged text "claude " instead.
  split_tools "claude ,codex"
  [ "$TOOL1" = "claude" ]
  [ "$TOOL2" = "codex" ]
}

@test "split_tools: trims a leading space after the comma" {
  # Regression test: TOOL2 used to stay " codex" (leading space) --
  # command_word_for read an empty executable word from that, so setup
  # failed despite " codex" being a perfectly valid shell command.
  split_tools "claude, codex"
  [ "$TOOL1" = "claude" ]
  [ "$TOOL2" = "codex" ]
}

@test "split_tools: trims whitespace on both sides of both slots" {
  split_tools "  claude  ,  codex  "
  [ "$TOOL1" = "claude" ]
  [ "$TOOL2" = "codex" ]
}

@test "split_tools: does not trim internal whitespace within a literal command" {
  split_tools "claude,gemini --some-flag"
  [ "$TOOL2" = "gemini --some-flag" ]
}

# --- trim_whitespace --------------------------------------------------

@test "trim_whitespace: strips leading and trailing spaces" {
  result="$(trim_whitespace '  hello  ')"
  [ "$result" = "hello" ]
}

@test "trim_whitespace: leaves internal whitespace alone" {
  result="$(trim_whitespace '  hello world  ')"
  [ "$result" = "hello world" ]
}

@test "trim_whitespace: handles an all-whitespace string" {
  result="$(trim_whitespace '   ')"
  [ "$result" = "" ]
}

@test "trim_whitespace: handles an already-trimmed string" {
  result="$(trim_whitespace 'hello')"
  [ "$result" = "hello" ]
}

# --- tools_split_is_valid -----------------------------------------------

@test "tools_split_is_valid: true for a normal two-item split" {
  split_tools "claude,codex"
  tools_split_is_valid "claude,codex"
}

@test "tools_split_is_valid: true when a single value fills both slots" {
  split_tools "onlyone"
  tools_split_is_valid "onlyone"
}

@test "tools_split_is_valid: false for a trailing empty slot" {
  # Regression test: --tools aider, used to silently launch aider plus
  # the DEFAULT codex (dangerous-mode flag and all, unless --safe-mode
  # was also given) instead of erroring on the empty second slot.
  split_tools "aider,"
  run ! tools_split_is_valid "aider,"
}

@test "tools_split_is_valid: false for a leading empty slot" {
  split_tools ",aider"
  run ! tools_split_is_valid ",aider"
}

@test "tools_split_is_valid: false for both slots empty" {
  split_tools ","
  run ! tools_split_is_valid ","
}

@test "tools_split_is_valid: false for an entirely empty value" {
  split_tools ""
  run ! tools_split_is_valid ""
}

@test "tools_split_is_valid: false for more than one comma" {
  # Regression test: --tools claude,codex,aider used to silently become
  # tool1=claude, tool2="codex,aider" (split_tools only ever considers
  # the first comma) -- surfacing later as a confusing "not found" for
  # the literal text "codex,aider" instead of a clear error about the
  # actual problem (a typo, or an unsupported third agent).
  split_tools "claude,codex,aider"
  run ! tools_split_is_valid "claude,codex,aider"
}

@test "tools_split_is_valid: false for four comma-separated values" {
  split_tools "a,b,c,d"
  run ! tools_split_is_valid "a,b,c,d"
}

# --- parse_run_args ---------------------------------------------------

@test "parse_run_args: defaults with just a session name" {
  parse_run_args "mysession"
  [ "$RAW_NAME" = "mysession" ]
  [ "$SPLIT_MODE" = "tmux" ]
  [ "$TOOLS" = "claude,codex" ]
  [ "$SAFE_MODE" = "0" ]
}

@test "parse_run_args: --split-mode override" {
  parse_run_args "mysession" --split-mode iterm
  [ "$SPLIT_MODE" = "iterm" ]
}

@test "parse_run_args: --tools override" {
  parse_run_args "mysession" --tools "agy,aider"
  [ "$TOOLS" = "agy,aider" ]
}

@test "parse_run_args: --safe-mode sets the flag" {
  parse_run_args "mysession" --safe-mode
  [ "$SAFE_MODE" = "1" ]
}

@test "parse_run_args: all options combined" {
  parse_run_args "mysession" --split-mode iterm --tools "agy,aider" --safe-mode
  [ "$RAW_NAME" = "mysession" ]
  [ "$SPLIT_MODE" = "iterm" ]
  [ "$TOOLS" = "agy,aider" ]
  [ "$SAFE_MODE" = "1" ]
}

@test "parse_run_args: -m/-t/-s are accepted as shorthands for --split-mode/--tools/--safe-mode" {
  parse_run_args "mysession" -m iterm -t "agy,aider" -s
  [ "$SPLIT_MODE" = "iterm" ]
  [ "$TOOLS" = "agy,aider" ]
  [ "$SAFE_MODE" = "1" ]
}

@test "parse_run_args: -t followed immediately by a short flag errors instead of swallowing it" {
  # Regression test: the original --tools/--safe-mode swallowing bug
  # (fixed long before -t/-s existed) only checked for a *long* flag
  # (--*) in the value slot -- broadened to -* so the short forms don't
  # reopen the exact same hole, e.g. "-t -s" silently setting
  # TOOLS="-s" and leaving SAFE_MODE unset.
  run parse_run_args "mysession" -t -s
  [ "$status" -eq 1 ]
  [[ "$output" == *"--tools/-t requires a value"* ]]
}

@test "parse_run_args: rejects an invalid --split-mode value" {
  run parse_run_args "mysession" --split-mode bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"--split-mode must be"* ]]
}

@test "parse_run_args: rejects an unknown flag" {
  run parse_run_args "mysession" --nonsense-flag
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown argument"* ]]
}

@test "parse_run_args: --tools followed immediately by another flag errors instead of swallowing it" {
  # Regression test: this used to silently set TOOLS="--safe-mode" and
  # leave SAFE_MODE=0, discarding the user's actual --safe-mode request.
  run parse_run_args "mysession" --tools --safe-mode
  [ "$status" -eq 1 ]
  [[ "$output" == *"--tools/-t requires a value"* ]]
}

@test "parse_run_args: --split-mode as the last argument with no value errors clearly" {
  # Regression test: this used to fail via shift 2's own error instead of
  # this function's message.
  run parse_run_args "mysession" --split-mode
  [ "$status" -eq 1 ]
  [[ "$output" == *"--split-mode/-m requires a value"* ]]
}

@test "parse_run_args: --tools as the last argument with no value errors clearly" {
  run parse_run_args "mysession" --tools
  [ "$status" -eq 1 ]
  [[ "$output" == *"--tools/-t requires a value"* ]]
}

@test "parse_run_args: rejects a session name containing shell metacharacters" {
  # Regression test: this exact payload created a real file on a remote
  # box before validate_session_name existed (confirmed live).
  run parse_run_args 'x; touch /tmp/pwn'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid session name"* ]]
}

@test "parse_run_args: rejects an option-like first argument instead of treating it as a session name" {
  # Regression test: `codersync --typo` (or `--safe-mode` with its
  # session-name argument left off by mistake) used to be silently
  # accepted as a literal session name named "--typo".
  run parse_run_args "--typo"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid session name"* ]]
}

# --- input validation (session-name/remote-dir/ssh-target injection) ----

@test "validate_session_name: accepts letters, digits, dash, underscore" {
  validate_session_name "my-session_123"
}

@test "validate_session_name: rejects a semicolon" {
  run ! validate_session_name 'x; touch /tmp/pwn'
}

@test "validate_session_name: rejects a dot (breaks tmux target parsing)" {
  run ! validate_session_name "my.session"
}

@test "validate_session_name: rejects a space" {
  run ! validate_session_name "my session"
}

@test "validate_session_name: rejects a leading dash" {
  # Regression test: without this, `codersync --typo` or `codersync
  # --safe-mode` (missing its session-name argument) fell through the
  # dispatch's unrecognized-flag cases and got silently treated as a
  # literal session name instead of erroring.
  run ! validate_session_name "--typo"
}

@test "validate_session_name: still accepts a dash later in the name" {
  validate_session_name "my-feature"
}

@test "validate_remote_dir: accepts a normal path" {
  # shellcheck disable=SC2088 # intentional: testing the literal string
  # "~/repos", not asking the test shell to expand it.
  validate_remote_dir "~/repos"
}

@test "validate_remote_dir: rejects shell metacharacters" {
  # shellcheck disable=SC2088 # intentional: testing the literal string.
  run ! validate_remote_dir '~/repos; rm -rf /'
}

@test "validate_remote_dir: rejects a leading dash" {
  # Regression test: a value like "-", "-P", or "--" passed the flat
  # character check, then reached `cd \${remote_dir}` unquoted in
  # setup()'s existence check, where a leading dash is read by `cd`
  # itself as an OPTION rather than a literal directory -- so the check
  # could report success without ever proving anything about a real path.
  run ! validate_remote_dir '-'
  run ! validate_remote_dir '-P'
  run ! validate_remote_dir '--'
}

@test "validate_remote_dir: still accepts a dash later in the path" {
  # shellcheck disable=SC2088 # intentional: testing the literal string.
  validate_remote_dir '~/my-project-dir'
}

@test "validate_ssh_target: accepts a plain hostname" {
  validate_ssh_target "devbox.example.com"
}

@test "validate_ssh_target: accepts user@host" {
  validate_ssh_target "user@devbox.example.com"
}

@test "validate_ssh_target: rejects shell metacharacters" {
  run ! validate_ssh_target 'devbox.example.com; rm -rf /'
}

@test "validate_ssh_target: rejects a leading dash (ssh/scp can read it as an option)" {
  # Regression test: a flat character-class check let a value like "-oX"
  # or "-V" through -- these later reach ssh unquoted, where a leading
  # dash is interpreted as an OPTION rather than a hostname.
  run ! validate_ssh_target '-V'
  run ! validate_ssh_target '-vvv'
  run ! validate_ssh_target '-'
}

@test "validate_ssh_target: rejects a bare @ or all-dots value" {
  run ! validate_ssh_target '@'
  run ! validate_ssh_target '...'
}

@test "validate_ssh_target: rejects a doubled @ (two user@ prefixes)" {
  run ! validate_ssh_target 'user@@host'
}

@test "validate_ssh_target: accepts an IP address" {
  validate_ssh_target '192.168.1.1'
}

# --- iterm2_available / open_tab_tmux_mode fallback ---------------------

@test "open_tab_tmux_mode: falls back to printed instructions when iTerm2 is unavailable" {
  # shellcheck disable=SC2034 # read by open_tab_tmux_mode below, but
  # that cross-function global dependency isn't visible statically.
  SSH_TARGET="devbox.example.com"
  # Mocks out the real check -- this suite has no network/GUI dependency.
  iterm2_available() { return 1; }
  run open_tab_tmux_mode "mysession"
  [ "$status" -eq 0 ]
  [[ "$output" == *"iTerm2 not found"* ]]
  [[ "$output" == *"tmux attach -t pair-mysession"* ]]
}

# --- parse_registry_line -------------------------------------------------

@test "parse_registry_line: splits a target-tagged entry" {
  parse_registry_line "$(printf 'devbox.example.com\tmy-session')"
  [ "$ENTRY_TARGET" = "devbox.example.com" ]
  [ "$ENTRY_NAME" = "my-session" ]
}

@test "parse_registry_line: bare (pre-migration) entry takes the current target" {
  # shellcheck disable=SC2034 # read by parse_registry_line below.
  SSH_TARGET="devbox.example.com"
  parse_registry_line "my-session"
  [ "$ENTRY_TARGET" = "devbox.example.com" ]
  [ "$ENTRY_NAME" = "my-session" ]
}

# --- restore_all: unsafe-entry defense --------------------------------

@test "restore_all: drops a poisoned-ID entry instead of restoring it" {
  # Regression test: an entry like "0-devbox-example-com-foo" passes
  # validate_session_name (every character is allowed) but has a
  # digit-shaped first segment that fails canonicalization (0 is never
  # a valid ID) -- the same poisoned shape session_is_owned() already
  # rejects for --list-all/--kill/--kill-all. restore_all had its own,
  # separate gating logic that never applied that check, so this entry
  # was rejected everywhere else but still restored here -- confirmed
  # live, it called remote_setup_tmux_mode with "0-devbox-example-com-foo"
  # outright. The live session list below deliberately includes a
  # matching "pair-0-devbox-example-com-foo" (reproducing the exact scenario
  # that made restore_all think there was something to restore); any
  # ssh call OTHER than the initial list-sessions one -- i.e.
  # remote_setup_tmux_mode actually trying to (re)create it -- gets
  # recorded, so the test can confirm that never happens.
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t0-devbox-example-com-foo\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by restore_all below.
  ssh() {
    if [[ "$*" == *"list-sessions"* ]]; then
      printf 'pair-0-devbox-example-com-foo\n'
      return 0
    fi
    echo "unexpected: $*" >> "$BATS_TEST_TMPDIR/unexpected_ssh_calls"
  }
  run restore_all
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping unsafe registry entry"* ]]
  [[ "$output" == *"0-devbox-example-com-foo"* ]]
  [[ "$output" == *"Dropped 1 unsafe registry entry"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/unexpected_ssh_calls" ]
  [ ! -s "$REGISTRY" ]
}

@test "restore_all: drops an unsafe registry entry instead of restoring it" {
  # Regression test: entry_name gets spliced unquoted into a remote bash
  # heredoc by remote_setup/remote_setup_tmux_mode -- a registry entry
  # like this one (hand-edited, or left over from a pre-validation
  # version of this script) used to flow straight through and execute on
  # the remote box (confirmed live). ssh is stubbed to a no-op: if this
  # entry were treated as safe, remote_setup would call it, so an empty
  # stub proves it never reaches that point.
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\tpair-x; touch /tmp/pwn\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by restore_all below.
  ssh() { :; }
  run restore_all
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping unsafe registry entry"* ]]
  [[ "$output" == *"Dropped 1 unsafe registry entry"* ]]
  [ ! -s "$REGISTRY" ]
}

# --- attach_session -----------------------------------------------------

@test "attach_session: errors on an unregistered ID without touching the network" {
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  : > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by attach_session below.
  ssh() { echo "unexpected: $*" >> "$BATS_TEST_TMPDIR/unexpected_ssh_calls"; }
  run attach_session "3"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no session with ID 3"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/unexpected_ssh_calls" ]
}

@test "attach_session: errors on an invalid ID (0) without touching the network" {
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  : > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by attach_session below.
  ssh() { echo "unexpected: $*" >> "$BATS_TEST_TMPDIR/unexpected_ssh_calls"; }
  run attach_session "0"
  [ "$status" -eq 1 ]
  [[ "$output" == *"isn't a valid session ID"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/unexpected_ssh_calls" ]
}

@test "attach_session: finds a registered ID belonging to a different target's entry as not found" {
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'some-other-box\t3-some-other-box-foo\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by attach_session below.
  ssh() { echo "unexpected: $*" >> "$BATS_TEST_TMPDIR/unexpected_ssh_calls"; }
  run attach_session "3"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no session with ID 3"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/unexpected_ssh_calls" ]
}

@test "attach_session: errors on an unregistered name without touching the network" {
  SSH_TARGET="devbox.example.com"
  # shellcheck disable=SC2034 # read by attach_session below (it builds
  # "${TARGET_LABEL}-${arg}" to match against), invisible to shellcheck
  # since that function lives in the sourced codersync file, not here.
  TARGET_LABEL="devbox-example-com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  : > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by attach_session below.
  ssh() { echo "unexpected: $*" >> "$BATS_TEST_TMPDIR/unexpected_ssh_calls"; }
  run attach_session "my-feature"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no session named 'my-feature'"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/unexpected_ssh_calls" ]
}

@test "attach_session: errors on an invalid name without touching the network" {
  # No TARGET_LABEL here: validate_session_name rejects "bad;name"
  # before attach_session ever reaches the line that would read it.
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  : > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by attach_session below.
  ssh() { echo "unexpected: $*" >> "$BATS_TEST_TMPDIR/unexpected_ssh_calls"; }
  run attach_session "bad;name"
  [ "$status" -eq 1 ]
  [[ "$output" == *"isn't a valid session ID or name"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/unexpected_ssh_calls" ]
}

@test "attach_session: a purely-numeric arg is read as an ID, never as a literal name" {
  # Regression guard for the documented precedent (same as --kill): even
  # though "3" is technically a valid session NAME too, a registry entry
  # whose NAME happens to be "3" must not match a numeric lookup for ID 3.
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\tdevbox-example-com-3\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by attach_session below.
  ssh() { echo "unexpected: $*" >> "$BATS_TEST_TMPDIR/unexpected_ssh_calls"; }
  run attach_session "3"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no session with ID 3"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/unexpected_ssh_calls" ]
}

@test "attach_session: matches a live leading-zero session by its canonical ID" {
  # Regression test: entry_name used to be reconstructed from the
  # canonical id + rest ("8-devbox-example-com-foo"), instead of using
  # the matched registry line's raw text. A session recorded as
  # "08-devbox-example-com-foo" (--list-all shows it as ID 8, same
  # canonicalization as everywhere else) has a live tmux session
  # literally named "pair-08-devbox-example-com-foo" -- the
  # reconstructed "pair-8-..." string never matched that, so
  # attach_session incorrectly treated it as not alive (confirmed live,
  # same bug shape kill_sessions' own comment describes and avoids).
  # remote_setup_tmux_mode/open_tab_tmux_mode are stubbed to record what
  # they're called with, instead of doing real ssh/iTerm2 work -- this
  # test only needs to confirm the RIGHT session gets recognized as
  # alive and handed off, not that the full live attach flow works
  # end-to-end (that part stays live-only, same as restore_all's
  # equivalent success path).
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t08-devbox-example-com-foo\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by attach_session below.
  ssh() { [[ "$*" == *"list-sessions"* ]] && printf 'pair-08-devbox-example-com-foo\n'; }
  # shellcheck disable=SC2329 # invoked indirectly, by attach_session below.
  remote_setup_tmux_mode() { echo "remote_setup_tmux_mode:$1"; }
  # shellcheck disable=SC2329 # invoked indirectly, by attach_session below.
  open_tab_tmux_mode() { echo "open_tab_tmux_mode:$1"; }
  run attach_session "8"
  [ "$status" -eq 0 ]
  [[ "$output" == *"remote_setup_tmux_mode:08-devbox-example-com-foo"* ]]
  [[ "$output" == *"open_tab_tmux_mode:08-devbox-example-com-foo"* ]]
}

@test "attach_session: falls back to a label-less exact name match (a codersync --local session)" {
  # Regression coverage for resolve_registered_session's fallback: a
  # session created via `codersync --local` has no target-label prefix
  # baked into its rest at all (unlike a normally client-created one),
  # so the primary "${TARGET_LABEL}-${arg}" match can never find it --
  # this confirms the unprefixed fallback does.
  SSH_TARGET="devbox.example.com"
  TARGET_LABEL="devbox-example-com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\tmy-local-feature\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by attach_session below.
  ssh() { [[ "$*" == *"list-sessions"* ]] && printf 'pair-my-local-feature\n'; }
  # shellcheck disable=SC2329 # invoked indirectly, by attach_session below.
  remote_setup_tmux_mode() { echo "remote_setup_tmux_mode:$1"; }
  # shellcheck disable=SC2329 # invoked indirectly, by attach_session below.
  open_tab_tmux_mode() { echo "open_tab_tmux_mode:$1"; }
  run attach_session "my-local-feature"
  [ "$status" -eq 0 ]
  [[ "$output" == *"remote_setup_tmux_mode:my-local-feature"* ]]
}

@test "attach_session: a labeled match still wins over a same-named label-less fallback" {
  SSH_TARGET="devbox.example.com"
  TARGET_LABEL="devbox-example-com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\tdevbox-example-com-foo\ndevbox.example.com\tfoo\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by attach_session below.
  ssh() { [[ "$*" == *"list-sessions"* ]] && printf 'pair-devbox-example-com-foo\npair-foo\n'; }
  # shellcheck disable=SC2329 # invoked indirectly, by attach_session below.
  remote_setup_tmux_mode() { echo "remote_setup_tmux_mode:$1"; }
  # shellcheck disable=SC2329 # invoked indirectly, by attach_session below.
  open_tab_tmux_mode() { echo "open_tab_tmux_mode:$1"; }
  run attach_session "foo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"remote_setup_tmux_mode:devbox-example-com-foo"* ]]
}

# --- rename_session -------------------------------------------------------

@test "rename_session: rejects an invalid new name without touching the network" {
  # No TARGET_LABEL: arg "1" is numeric, so resolve_registered_session
  # never reaches the branch that reads it.
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t1-devbox-example-com-foo\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by rename_session below.
  ssh() { echo "unexpected: $*" >> "$BATS_TEST_TMPDIR/unexpected_ssh_calls"; }
  run rename_session "1" "bad;name"
  [ "$status" -eq 1 ]
  [[ "$output" == *"isn't a valid session name"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/unexpected_ssh_calls" ]
}

@test "rename_session: rejects a purely-numeric new name" {
  # A session named a bare number would be unreachable by name
  # afterward, since --attach/--kill always read a numeric argument as
  # an ID first.
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t1-devbox-example-com-foo\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by rename_session below.
  ssh() { echo "unexpected: $*" >> "$BATS_TEST_TMPDIR/unexpected_ssh_calls"; }
  run rename_session "1" "42"
  [ "$status" -eq 1 ]
  [[ "$output" == *"can't be a plain number"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/unexpected_ssh_calls" ]
}

@test "rename_session: errors when the given ID doesn't resolve to any session" {
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  : > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by rename_session below.
  ssh() { echo "unexpected: $*" >> "$BATS_TEST_TMPDIR/unexpected_ssh_calls"; }
  run rename_session "3" "new-name"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no session with ID 3"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/unexpected_ssh_calls" ]
}

@test "rename_session: errors when the new name is the same as the current one" {
  SSH_TARGET="devbox.example.com"
  # shellcheck disable=SC2034 # read by rename_session below, to build
  # the candidate new_entry_name it then compares against old_entry_name.
  TARGET_LABEL="devbox-example-com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t1-devbox-example-com-foo\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by rename_session below.
  ssh() { echo "unexpected: $*" >> "$BATS_TEST_TMPDIR/unexpected_ssh_calls"; }
  run rename_session "1" "foo"
  [ "$status" -eq 1 ]
  [[ "$output" == *"already named 'foo'"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/unexpected_ssh_calls" ]
}

@test "rename_session: rejects renaming to a name already in use on this target" {
  SSH_TARGET="devbox.example.com"
  # shellcheck disable=SC2034 # read by rename_session below, to build
  # the candidate new_entry_name it then checks for a collision.
  TARGET_LABEL="devbox-example-com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t1-devbox-example-com-foo\ndevbox.example.com\t2-devbox-example-com-bar\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by rename_session below.
  ssh() { echo "unexpected: $*" >> "$BATS_TEST_TMPDIR/unexpected_ssh_calls"; }
  run rename_session "1" "bar"
  [ "$status" -eq 1 ]
  [[ "$output" == *"'bar' is already in use"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/unexpected_ssh_calls" ]
}

@test "rename_session: errors when the resolved session isn't alive anymore" {
  SSH_TARGET="devbox.example.com"
  # shellcheck disable=SC2034 # read by rename_session below, to build
  # the candidate new_entry_name before it checks liveness.
  TARGET_LABEL="devbox-example-com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t1-devbox-example-com-foo\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by rename_session below.
  ssh() { [[ "$*" == *"list-sessions"* ]] && printf ''; }
  run rename_session "1" "new-name"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not alive on ${SSH_TARGET} anymore"* ]]
}

@test "rename_session: refuses to rename when the destination tmux name already exists" {
  # Regression test: without this preflight, remote_rename went ahead and
  # renamed claude-* successfully, then failed renaming codex-* because
  # codex-<new> already existed (an unrelated live session) -- leaving
  # the pair permanently split between old and new names, with the
  # registry (rewritten only on full success) reflecting neither.
  # Checked here entirely from the same `live` listing already fetched,
  # before ever attempting the actual remote rename.
  SSH_TARGET="devbox.example.com"
  # shellcheck disable=SC2034 # read by rename_session below, to build
  # the candidate new_entry_name checked against the destination.
  TARGET_LABEL="devbox-example-com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t1-devbox-example-com-foo\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by rename_session below.
  ssh() {
    if [[ "$*" == *"list-sessions"* ]]; then
      printf 'claude-1-devbox-example-com-foo\ncodex-1-devbox-example-com-foo\ncodex-1-devbox-example-com-bar\n'
    else
      echo "unexpected: $*" >> "$BATS_TEST_TMPDIR/unexpected_ssh_calls"
    fi
  }
  run rename_session "1" "bar"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a live tmux session already exists at 'codex-1-devbox-example-com-bar'"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/unexpected_ssh_calls" ]
  [[ "$(cat "$REGISTRY")" == "devbox.example.com"$'\t'"1-devbox-example-com-foo" ]]
}

@test "rename_session: refuses to rename a tmux-mode session onto an unrelated claude-/codex- pair" {
  # Regression test: the preflight above used to be gated by the
  # SOURCE session's own mode ($has_pair/$has_claude/$has_codex), so
  # renaming a tmux-mode (pair-only) session only checked for a
  # colliding pair-<new>, never claude-<new>/codex-<new> -- but
  # session_is_owned only ever matches on id+rest, never on which
  # prefix a live session actually uses, so an unrelated live
  # claude-/codex- pair at the destination name got silently adopted as
  # owned the moment the registry was rewritten to the same id+rest
  # (confirmed live: --list-all/--kill then treated it as owned too).
  SSH_TARGET="devbox.example.com"
  # shellcheck disable=SC2034 # read by rename_session below, to build
  # the candidate new_entry_name checked against the destination.
  TARGET_LABEL="devbox-example-com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t1-devbox-example-com-foo\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by rename_session below.
  ssh() {
    if [[ "$*" == *"list-sessions"* ]]; then
      printf 'pair-1-devbox-example-com-foo\nclaude-1-devbox-example-com-bar\ncodex-1-devbox-example-com-bar\n'
    else
      echo "unexpected: $*" >> "$BATS_TEST_TMPDIR/unexpected_ssh_calls"
    fi
  }
  run rename_session "1" "bar"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a live tmux session already exists at 'claude-1-devbox-example-com-bar'"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/unexpected_ssh_calls" ]
  [[ "$(cat "$REGISTRY")" == "devbox.example.com"$'\t'"1-devbox-example-com-foo" ]]
}

@test "rename_session: fails clearly when the session-ID lock is already held" {
  # Simulates a concurrent codersync invocation (session creation or
  # another --rename) already holding the lock -- confirms rename_session
  # doesn't proceed (or touch the network) while it's contended, rather
  # than racing past it.
  SSH_TARGET="devbox.example.com"
  TARGET_LABEL="devbox-example-com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t1-devbox-example-com-foo\n' > "$REGISTRY"
  mkdir -p "$CONFIG_DIR/id.lock"
  # shellcheck disable=SC2329 # invoked indirectly, by rename_session below.
  ssh() { echo "unexpected: $*" >> "$BATS_TEST_TMPDIR/unexpected_ssh_calls"; }
  run rename_session "1" "bar"
  [ "$status" -eq 1 ]
  [[ "$output" == *"couldn't acquire the session-ID lock"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/unexpected_ssh_calls" ]
}

@test "rename_session: renames a live tmux-mode session and updates the registry" {
  SSH_TARGET="devbox.example.com"
  # shellcheck disable=SC2034 # read by rename_session below, to build
  # the new registry-stored session name.
  TARGET_LABEL="devbox-example-com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t1-devbox-example-com-foo\ndevbox.example.com\t2-devbox-example-com-other\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by rename_session below.
  ssh() { if [[ "$*" == *"list-sessions"* ]]; then printf 'pair-1-devbox-example-com-foo\n'; fi; }
  run rename_session "1" "bar"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Renamed '1-devbox-example-com-foo' to '1-devbox-example-com-bar'"* ]]
  [[ "$(cat "$REGISTRY")" == *$'devbox.example.com\t1-devbox-example-com-bar'* ]]
  [[ "$(cat "$REGISTRY")" == *$'devbox.example.com\t2-devbox-example-com-other'* ]]
  [[ "$(cat "$REGISTRY")" != *"1-devbox-example-com-foo"* ]]
}

@test "rename_session: renames a live iterm-mode (claude-/codex-) pair" {
  SSH_TARGET="devbox.example.com"
  # shellcheck disable=SC2034 # read by rename_session below, to build
  # the new registry-stored session name.
  TARGET_LABEL="devbox-example-com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t1-devbox-example-com-foo\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by rename_session below.
  ssh() {
    if [[ "$*" == *"list-sessions"* ]]; then
      printf 'claude-1-devbox-example-com-foo\ncodex-1-devbox-example-com-foo\n'
    fi
  }
  run rename_session "1" "bar"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Renamed '1-devbox-example-com-foo' to '1-devbox-example-com-bar'"* ]]
  [[ "$(cat "$REGISTRY")" == "devbox.example.com"$'\t'"1-devbox-example-com-bar" ]]
}

@test "rename_session: preserves a legacy no-ID session's ID-less shape" {
  SSH_TARGET="devbox.example.com"
  # shellcheck disable=SC2034 # read by resolve_registered_session below.
  TARGET_LABEL="devbox-example-com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\tdevbox-example-com-foo\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by rename_session below.
  ssh() { if [[ "$*" == *"list-sessions"* ]]; then printf 'pair-devbox-example-com-foo\n'; fi; }
  run rename_session "foo" "bar"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Renamed 'devbox-example-com-foo' to 'devbox-example-com-bar'"* ]]
  [[ "$(cat "$REGISTRY")" == "devbox.example.com"$'\t'"devbox-example-com-bar" ]]
}

# --- list_all_sessions ---------------------------------------------------

@test "list_all_sessions: SESSION column strips the target-label prefix" {
  # Regression test: this column used to show the raw PARSED_REST
  # ("${TARGET_LABEL}-${RAW_NAME}"), which looked directly usable as a
  # name for --attach/--rename but wasn't -- passing it back verbatim
  # double-prefixed the lookup and never matched anything (confirmed
  # live). --attach/--rename take the bare RAW_NAME and reconstruct the
  # label internally themselves, so this column now strips it too.
  SSH_TARGET="devbox.example.com"
  # shellcheck disable=SC2034 # read by list_all_sessions below, to
  # strip it from each row's displayed rest.
  TARGET_LABEL="devbox-example-com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t3-devbox-example-com-my-feature\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by list_all_sessions below.
  ssh() { [[ "$*" == *"list-sessions"* ]] && printf 'pair-3-devbox-example-com-my-feature\n'; }
  run list_all_sessions
  [ "$status" -eq 0 ]
  [[ "$output" == *"my-feature"* ]]
  [[ "$output" != *"devbox-example-com-my-feature"* ]]
}

@test "list_all_sessions: leaves a rest untouched if it doesn't start with the target label" {
  # A hand-created or pre-labeling legacy session's rest might not
  # start with "${TARGET_LABEL}-" at all -- the strip must be a no-op
  # then, not mangle it.
  SSH_TARGET="devbox.example.com"
  # shellcheck disable=SC2034 # read by list_all_sessions below, to
  # strip it from each row's displayed rest.
  TARGET_LABEL="devbox-example-com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\tsome-other-name\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by list_all_sessions below.
  ssh() { [[ "$*" == *"list-sessions"* ]] && printf 'pair-some-other-name\n'; }
  run list_all_sessions
  [ "$status" -eq 0 ]
  [[ "$output" == *"some-other-name"* ]]
}

# --- local_setup ----------------------------------------------------------
#
# Only the argument-validation paths, which all return before ever
# calling a real `tmux` -- the actual session-creation/attach success
# path needs a real tmux binary and is live-verified by hand instead
# (see README.md's "Testing" section).

@test "local_setup: rejects an invalid session name" {
  run local_setup "bad;name"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid session name"* ]]
}

@test "local_setup: rejects a purely-numeric session name" {
  # Regression test: a --local session is created label-less (no
  # numeric-ID prefix), so a numeric NAME would be permanently
  # unaddressable once adopted -- resolve_registered_session always
  # reads a purely-numeric argument as wanting an ID lookup, never a
  # name, and this session was never assigned an ID at all.
  run local_setup "42"
  [ "$status" -eq 1 ]
  [[ "$output" == *"can't be a plain number"* ]]
}

@test "local_setup: --tools requires a value" {
  run local_setup "myfeature" --tools
  [ "$status" -eq 1 ]
  [[ "$output" == *"--tools/-t requires a value"* ]]
}

@test "local_setup: --tools followed immediately by another flag errors instead of swallowing it" {
  run local_setup "myfeature" --tools --safe-mode
  [ "$status" -eq 1 ]
  [[ "$output" == *"--tools/-t requires a value"* ]]
}

@test "local_setup: rejects a malformed --tools value" {
  run local_setup "myfeature" --tools "claude,codex,aider"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is malformed"* ]]
}

@test "local_setup: rejects an unknown flag" {
  run local_setup "myfeature" --split-mode iterm
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown argument"* ]]
}

@test "local_setup: does not kill another session if new-session loses a create race" {
  # Regression test: `tmux has-session` and `tmux new-session` aren't
  # atomic -- another invocation can create "$pair_tmux" in between.
  # Stubs tmux so has-session reports "doesn't exist yet" (this
  # invocation's own view, a moment before the race), but new-session
  # still fails (the other invocation won in between) -- confirms the
  # cleanup trap, which this script's own `set -e` fires immediately
  # on that failure, never calls kill-session at all: it's only armed
  # AFTER new-session succeeds, precisely so a lost race can't kill
  # the winner's own, now-live session under the same name (confirmed
  # live: arming it before new-session let exactly that happen, with a
  # stubbed tmux reproducing the reported race).
  # shellcheck disable=SC2329 # invoked indirectly, by local_setup below.
  tmux() {
    case "$1" in
      has-session) return 1 ;;
      new-session) return 1 ;;
      *) echo "unexpected tmux call: $*" >> "$BATS_TEST_TMPDIR/unexpected_tmux_calls"; return 1 ;;
    esac
  }
  run local_setup "race-test"
  [ "$status" -eq 1 ]
  [[ "$output" == *"couldn't create local session"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/unexpected_tmux_calls" ]
}

# --- adopt_sessions ---------------------------------------------------------

@test "adopt_sessions: registers an unregistered tmux-mode (pair-only) session" {
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  : > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by adopt_sessions below.
  ssh() { [[ "$*" == *"list-sessions"* ]] && printf 'pair-my-local-feature\n'; }
  run adopt_sessions
  [ "$status" -eq 0 ]
  [[ "$output" == *"Adopted: my-local-feature"* ]]
  [[ "$(cat "$REGISTRY")" == "devbox.example.com"$'\t'"my-local-feature" ]]
}

@test "adopt_sessions: registers under the LIVE session's own name, not a pre-existing registry entry's" {
  # Regression test: session_is_owned() calls parse_numbered_session()
  # internally while scanning the registry -- like every call site of
  # that function, it sets the GLOBAL PARSED_ID/PARSED_REST as a side
  # effect. Reading those globals again right after a "not owned"
  # result (this function's own `&& continue` takes that branch) used
  # to pick up whatever the registry's LAST-scanned line happened to
  # parse to, not the live session actually being considered here --
  # confirmed live: an unrelated already-registered entry existing
  # anywhere in the registry caused every genuinely-unregistered
  # session to be "adopted" under THAT unrelated entry's name instead
  # of its own, repeatedly, no-oping harmlessly via register_session's
  # own dedup check rather than ever registering the right thing.
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t51-coder-pkbox-unrelated-existing-entry\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by adopt_sessions below.
  ssh() {
    if [[ "$*" == *"list-sessions"* ]]; then
      printf 'pair-51-coder-pkbox-unrelated-existing-entry\npair-my-local-feature\n'
    fi
  }
  run adopt_sessions
  [ "$status" -eq 0 ]
  [[ "$output" == *"Adopted: my-local-feature"* ]]
  [[ "$output" != *"unrelated-existing-entry"* ]]
  [[ "$(cat "$REGISTRY")" == *$'devbox.example.com\tmy-local-feature'* ]]
  # Exactly two lines total: the pre-existing entry, untouched, plus
  # the one genuinely new adoption -- not a duplicate of the first.
  [ "$(wc -l < "$REGISTRY")" -eq 2 ]
}

@test "adopt_sessions: refuses to register a live session with an unsafe name" {
  # Regression test: entry_name is built from a LIVE tmux session
  # name, not something this tool already validated at creation time
  # -- a hand-created or otherwise poisoned live session used to get
  # written straight into the registry unvalidated (confirmed live:
  # "pair-x;touch /tmp/pwn" got adopted verbatim as "x;touch /tmp/pwn").
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  : > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by adopt_sessions below.
  ssh() { [[ "$*" == *"list-sessions"* ]] && printf 'pair-x;touch /tmp/pwn\n'; }
  run adopt_sessions
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping unsafe live session name"* ]]
  [[ "$output" != *"Adopted"* ]]
  [ ! -s "$REGISTRY" ]
}

@test "adopt_sessions: registers an unregistered iterm-mode (claude-/codex-) pair as ONE entry" {
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  : > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by adopt_sessions below.
  ssh() {
    if [[ "$*" == *"list-sessions"* ]]; then
      printf 'claude-my-local-feature\ncodex-my-local-feature\n'
    fi
  }
  run adopt_sessions
  [ "$status" -eq 0 ]
  [[ "$(cat "$REGISTRY")" == "devbox.example.com"$'\t'"my-local-feature" ]]
  # Exactly one registry line, not two -- confirms the claude-/codex-
  # pair collapsed into a single logical adoption.
  [ "$(wc -l < "$REGISTRY")" -eq 1 ]
}

@test "adopt_sessions: preserves a numeric ID on an unregistered session that already has one" {
  # Covers the case where a client machine's own creation raced ahead
  # of --adopt somehow, or a registry was hand-edited/cleared -- the
  # live session's own ID (baked into its literal tmux name) is kept
  # as-is, not stripped or renumbered.
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  : > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by adopt_sessions below.
  ssh() { [[ "$*" == *"list-sessions"* ]] && printf 'pair-5-devbox-example-com-foo\n'; }
  run adopt_sessions
  [ "$status" -eq 0 ]
  [[ "$(cat "$REGISTRY")" == "devbox.example.com"$'\t'"5-devbox-example-com-foo" ]]
}

@test "adopt_sessions: preserves a leading-zero ID's raw text, not the canonicalized form" {
  # Regression test: entry_name used to be reconstructed from the
  # CANONICALIZED live_id ("8"), not the raw post-prefix text ("08"
  # in this case) -- so a live "pair-08-devbox-example-com-foo" got
  # registered as "8-devbox-example-com-foo". The actual live tmux
  # session is still literally named "pair-08-...", so every later
  # lookup (attach_session/rename_session grep the live list for
  # "pair-8-..." instead) reported the just-adopted session as
  # "registered but not alive" (confirmed live).
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  : > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by adopt_sessions below.
  ssh() { [[ "$*" == *"list-sessions"* ]] && printf 'pair-08-devbox-example-com-foo\n'; }
  run adopt_sessions
  [ "$status" -eq 0 ]
  [[ "$(cat "$REGISTRY")" == "devbox.example.com"$'\t'"08-devbox-example-com-foo" ]]
}

@test "adopt_sessions: skips a poisoned invalid-ID live session instead of registering it" {
  # Regression test: a raw post-prefix segment that LOOKS like an ID
  # attempt but fails canonicalization (e.g. "0-...", 0 is never a
  # valid ID) parses as PARSED_ID="" (parse_numbered_session treats it
  # as "no ID", folding the whole thing into PARSED_REST) -- so the
  # existing validate_session_name check alone doesn't catch it (the
  # character set is perfectly safe). Registering it anyway made
  # --adopt report success for a session that was never actually made
  # manageable, since session_is_owned/find_or_assign_id already
  # refuse to trust that exact shape everywhere else.
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  : > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by adopt_sessions below.
  ssh() { [[ "$*" == *"list-sessions"* ]] && printf 'pair-0-devbox-example-com-foo\n'; }
  run adopt_sessions
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping poisoned live session name"* ]]
  [[ "$output" != *"Adopted"* ]]
  [ ! -s "$REGISTRY" ]
}

@test "adopt_sessions: refuses to adopt when an unrelated cross-kind session shares the same name" {
  # Regression test: ownership (session_is_owned) matches on id+rest
  # alone, with no notion of which prefix (pair- vs claude-/codex-) a
  # live session actually uses. Adopting a tmux-mode "pair-same" while
  # an UNRELATED iterm-mode "claude-same"/"codex-same" pair also
  # exists live registered a single entry that then satisfied
  # ownership for BOTH, silently merging two unrelated sessions into
  # one logical identity (confirmed live).
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  : > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by adopt_sessions below.
  ssh() {
    if [[ "$*" == *"list-sessions"* ]]; then
      printf 'pair-same\nclaude-same\ncodex-same\n'
    fi
  }
  run adopt_sessions
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping 'pair-same'"* ]]
  [[ "$output" == *"skipping 'claude-same'"* || "$output" == *"skipping 'codex-same'"* ]]
  [[ "$output" != *"Adopted"* ]]
  [ ! -s "$REGISTRY" ]
}

@test "adopt_sessions: refuses a cross-kind collision even when the raw text differs (leading zero vs canonical)" {
  # Same ambiguity as above, but the two live sessions have DIFFERENT
  # raw text ("08-..." vs "8-...") that canonicalizes to the SAME
  # id/rest -- confirming the check compares canonical id/rest, not
  # just literal text equality.
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  : > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by adopt_sessions below.
  ssh() {
    if [[ "$*" == *"list-sessions"* ]]; then
      printf 'pair-08-devbox-example-com-foo\nclaude-8-devbox-example-com-foo\ncodex-8-devbox-example-com-foo\n'
    fi
  }
  run adopt_sessions
  [ "$status" -eq 0 ]
  [[ "$output" != *"Adopted"* ]]
  [ ! -s "$REGISTRY" ]
}

@test "adopt_sessions: advances next_id past an adopted numeric ID" {
  # Regression test: adopt_sessions preserved a live session's own
  # numeric ID into the registry without ever advancing this client's
  # own next_session_id() counter -- so the very next `codersync
  # <name>` invocation could mint that SAME ID again, producing two
  # registry entries for the same target both claiming it (confirmed
  # live/reproduced with a stub: adopting "pair-1-..." while the
  # counter was still at its default of 1 left find_or_assign_id
  # returning 1 again for a brand-new session).
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  : > "$REGISTRY"
  echo "1" > "$NEXT_ID_FILE"
  # shellcheck disable=SC2329 # invoked indirectly, by adopt_sessions below.
  ssh() { [[ "$*" == *"list-sessions"* ]] && printf 'pair-5-devbox-example-com-foo\n'; }
  run adopt_sessions
  [ "$status" -eq 0 ]
  [ "$(cat "$NEXT_ID_FILE")" = "6" ]
}

@test "adopt_sessions: skips a session that's already registered" {
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\tmy-local-feature\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by adopt_sessions below.
  ssh() { [[ "$*" == *"list-sessions"* ]] && printf 'pair-my-local-feature\n'; }
  run adopt_sessions
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing new to adopt"* ]]
  [[ "$output" != *"Adopted"* ]]
  [ "$(wc -l < "$REGISTRY")" -eq 1 ]
}

@test "adopt_sessions: reports nothing to adopt when there's no live session at all" {
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  : > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by adopt_sessions below.
  ssh() { [[ "$*" == *"list-sessions"* ]] && printf ''; }
  run adopt_sessions
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing new to adopt"* ]]
}

# --- session_is_owned / unrelated-session sweep defense ----------------

@test "session_is_owned: true when a no-ID rest has a matching registry entry" {
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\tdevbox-review-sam-1746\n' > "$REGISTRY"
  session_is_owned "" "devbox-review-sam-1746"
}

@test "session_is_owned: false for a no-ID rest with no matching entry" {
  # This is the crux of the original fix: a bare prefix (claude-/codex-/
  # pair-) alone is also just an ordinary tmux session name someone
  # might use for something unrelated -- "pair-programming" or
  # "claude-notes" are not codersync's, and shouldn't be treated as such
  # just because they happen to start with a recognized prefix.
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\tdevbox-review-sam-1746\n' > "$REGISTRY"
  run ! session_is_owned "" "programming"
}

@test "session_is_owned: false for an entry belonging to a different target" {
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'some-other-box\tprogramming\n' > "$REGISTRY"
  run ! session_is_owned "" "programming"
}

@test "session_is_owned: skips a poisoned entry instead of authorizing a matching broken session" {
  # Regression test: an entry like "0-host-foo" has a digit-shaped first
  # segment that fails canonicalization (0 is never a valid ID) -- this
  # used to fall through to matching its raw, un-split text as if it
  # were an ordinary legacy rest, so a live session with that exact
  # broken shape ("pair-0-host-foo") got authorized purely because a
  # registry entry happened to share the same broken shape.
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t0-host-foo\n' > "$REGISTRY"
  run ! session_is_owned "" "0-host-foo"
}

@test "session_is_owned: an IDed session needs a matching registry entry, not just a plausible-looking rest" {
  # Regression test: this used to be trusted by naming shape alone --
  # first "a prefix plus any valid ID" (confirmed live: an unrelated
  # session literally named "pair-1-not-codersync" was still
  # listed/killed), then "a prefix plus a valid ID AND a rest starting
  # with the target's label" (confirmed live again: for a target
  # labeled e.g. "host", "pair-1-host-unregistered" still matched --
  # common target labels make that prefix trivial to collide with by
  # accident). Only a real, exact registry entry counts now.
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t1-host-registered\n' > "$REGISTRY"
  run ! session_is_owned "1" "host-unregistered"
}

@test "session_is_owned: true for an IDed session with a matching registry entry" {
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t1-devbox-example-com-foo\n' > "$REGISTRY"
  session_is_owned "1" "devbox-example-com-foo"
}

@test "session_is_owned: an ID must match the entry's own ID too, not just the rest" {
  # A registry entry's rest matching isn't enough on its own -- the ID
  # has to match too, otherwise a valid-but-different-id entry could
  # authorize a session under the wrong id.
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t2-devbox-example-com-foo\n' > "$REGISTRY"
  run ! session_is_owned "1" "devbox-example-com-foo"
}

@test "kill_all_sessions: does not sweep in an unrelated session with a matching prefix" {
  # Regression test: --kill-all used to treat ANY live session starting
  # with claude-/codex-/pair- as codersync-owned. Verified live: a
  # stubbed remote session list containing "pair-programming" and
  # "claude-notes" (neither registered, neither ID-shaped) got offered
  # and killed by --kill-all as if they were real codersync sessions.
  # "pair-3-devbox-example-com-foo" has an ID but is also NOT registered here --
  # confirmed live, an unrelated but ID-shaped session used to be swept
  # in too, before ownership required full registry-backing. Answers
  # "n" at the confirmation prompt -- this test only needs to check
  # what's OFFERED (the printed list), not actually kill anything.
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  : > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by kill_all_sessions.
  ssh() {
    if [[ "$*" == *"list-sessions"* ]]; then
      printf 'pair-programming\nclaude-notes\npair-3-devbox-example-com-foo\n'
    fi
  }
  run kill_all_sessions <<<"n"
  [[ "$output" != *"pair-programming"* ]]
  [[ "$output" != *"claude-notes"* ]]
  [[ "$output" != *"pair-3-devbox-example-com-foo"* ]]
}

@test "kill_all_sessions: still includes a registry-backed IDed session" {
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t3-devbox-example-com-foo\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by kill_all_sessions.
  ssh() {
    if [[ "$*" == *"list-sessions"* ]]; then
      printf 'pair-3-devbox-example-com-foo\n'
    fi
  }
  run kill_all_sessions <<<"n"
  [[ "$output" == *"pair-3-devbox-example-com-foo"* ]]
}

@test "kill_all_sessions: still includes a registry-backed legacy session" {
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\tprogramming\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by kill_all_sessions.
  ssh() {
    if [[ "$*" == *"list-sessions"* ]]; then
      printf 'pair-programming\n'
    fi
  }
  run kill_all_sessions <<<"n"
  [[ "$output" == *"pair-programming"* ]]
}

@test "kill_sessions: does not kill an unrelated session sharing the requested ID" {
  # Regression test: --kill <id> matched ANY live session with that
  # exact numeric ID, regardless of whether it was ever registered --
  # confirmed live, an unrelated session literally named
  # "pair-1-not-codersync" was killed by `--kill 1`.
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  : > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by kill_sessions.
  ssh() {
    if [[ "$*" == *"list-sessions"* ]]; then
      printf 'pair-1-not-codersync\n'
    fi
  }
  run kill_sessions "1"
  [[ "$output" == *"no session found for ID 1"* ]]
  [[ "$output" != *"Killing"* ]]
}

@test "kill_sessions: does not kill an ID-shaped session with no matching registry entry" {
  # Same as above, but with a rest that LOOKS plausible for the current
  # target (used to pass an earlier, looser version of this check that
  # only required the rest to start with the target's label) -- still
  # not owned without an actual registry entry to back it.
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  : > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by kill_sessions.
  ssh() {
    if [[ "$*" == *"list-sessions"* ]]; then
      printf 'pair-1-devbox-example-com-unregistered\n'
    fi
  }
  run kill_sessions "1"
  [[ "$output" == *"no session found for ID 1"* ]]
  [[ "$output" != *"Killing"* ]]
}

@test "kill_sessions: still kills a session with a matching registry entry" {
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t1-devbox-example-com-foo\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by kill_sessions.
  ssh() {
    if [[ "$*" == *"list-sessions"* ]]; then
      printf 'pair-1-devbox-example-com-foo\n'
    fi
  }
  run kill_sessions "1"
  [[ "$output" == *"Killing: pair-1-devbox-example-com-foo"* ]]
}

@test "kill_sessions: removes a non-canonical registry entry, not a reconstructed raw string" {
  # Regression test: cleanup used to reconstruct the registry key as
  # "${id}-${rest}" (e.g. "8-devbox-example-com-foo", using the CANONICAL id)
  # and grep for that exact text -- but the on-disk registry entry for a
  # leading-zero live session is still literally "08-devbox-example-com-foo",
  # so the reconstructed string never matched it and the stale entry
  # was left behind after every kill (confirmed live). Entries are now
  # compared by their own PARSED (id, rest), not a reconstructed string.
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t08-devbox-example-com-foo\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by kill_sessions.
  ssh() {
    if [[ "$*" == *"list-sessions"* ]]; then
      printf 'pair-08-devbox-example-com-foo\n'
    fi
  }
  kill_sessions "8" >/dev/null
  [ ! -s "$REGISTRY" ]
}

@test "kill_sessions: matches a live leading-zero ID that --list-all would show as canonical" {
  # Regression test: a live session literally named "pair-08-host-foo"
  # canonicalizes to ID 8 in --list-all, but kill_sessions used to
  # pre-grep the live list for the literal text "-8-", which never
  # matches "-08-" -- so --kill 8 (or --kill 08, which canonicalizes to
  # the same request) reported "no session found" for something
  # --list-all had just shown as killable. Candidates are now found by
  # parsing/canonicalizing every live session instead.
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t08-devbox-example-com-foo\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by kill_sessions.
  ssh() {
    if [[ "$*" == *"list-sessions"* ]]; then
      printf 'pair-08-devbox-example-com-foo\n'
    fi
  }
  run kill_sessions "8"
  [[ "$output" == *"Killing: pair-08-devbox-example-com-foo"* ]]
}

# --- dispatch: rejects unexpected trailing arguments -------------------

@test "dispatch: --setup rejects extra trailing arguments" {
  # Regression test: `codersync --setup host dir extra` used to silently
  # drop "extra" with no warning. Runs the real script as a subprocess
  # (not sourced) since this is dispatch-level, CLI-argument-count logic,
  # not a sourced function -- but the check happens before setup() ever
  # runs, so this never touches the network or any real config.
  run "${BATS_TEST_DIRNAME}/../codersync" --setup host dir extra
  [ "$status" -eq 1 ]
  [[ "$output" == *"got extra"* ]]
}

@test "dispatch: --setup with no target shows usage with an example" {
  # Checked before any SSH/network access inside setup(), so this never
  # touches the network or any real config.
  run "${BATS_TEST_DIRNAME}/../codersync" --setup
  [ "$status" -eq 1 ]
  [[ "$output" == *"Example: codersync --setup"* ]]
}

@test "dispatch: --setup help shows usage instead of trying to SSH into a host named 'help'" {
  # Regression test: "help" passes validate_ssh_target (it's just
  # letters), so without this special case setup() would attempt a real
  # SSH connection to a host literally named "help" instead of showing
  # guidance -- confusing for anyone reaching for the common `<command>
  # help` convention.
  run "${BATS_TEST_DIRNAME}/../codersync" --setup help
  [ "$status" -eq 1 ]
  [[ "$output" == *"Example: codersync --setup"* ]]
}

@test "dispatch: --setup --help and --setup -h also show usage, not a real setup attempt" {
  run "${BATS_TEST_DIRNAME}/../codersync" --setup --help
  [ "$status" -eq 1 ]
  [[ "$output" == *"Example: codersync --setup"* ]]

  run "${BATS_TEST_DIRNAME}/../codersync" --setup -h
  [ "$status" -eq 1 ]
  [[ "$output" == *"Example: codersync --setup"* ]]
}

@test "dispatch: --restore-all rejects extra trailing arguments" {
  # Same as --setup above -- checked before load_config, so this never
  # touches the network or any real config either.
  run "${BATS_TEST_DIRNAME}/../codersync" --restore-all extra
  [ "$status" -eq 1 ]
  [[ "$output" == *"got extra"* ]]
}

@test "dispatch: --list-all rejects extra trailing arguments" {
  run "${BATS_TEST_DIRNAME}/../codersync" --list-all extra
  [ "$status" -eq 1 ]
  [[ "$output" == *"got extra"* ]]
}

@test "dispatch: --paste-image rejects extra trailing arguments" {
  # Checked before load_config, so this never touches the network,
  # clipboard, or any real config either.
  run "${BATS_TEST_DIRNAME}/../codersync" --paste-image extra
  [ "$status" -eq 1 ]
  [[ "$output" == *"got extra"* ]]
}

@test "dispatch: -p is accepted as a shorthand for --paste-image" {
  # Same arity check, same code path -- -p extra should be rejected the
  # exact same way --paste-image extra is, proving the alias reaches the
  # same case branch rather than falling through to the catch-all
  # "unknown session name" dispatch.
  run "${BATS_TEST_DIRNAME}/../codersync" -p extra
  [ "$status" -eq 1 ]
  [[ "$output" == *"got extra"* ]]
  [[ "$output" == *"-p"* ]]
}

@test "dispatch: -s is accepted as a shorthand for --setup" {
  run "${BATS_TEST_DIRNAME}/../codersync" -s host dir extra
  [ "$status" -eq 1 ]
  [[ "$output" == *"got extra"* ]]
  [[ "$output" == *"-s"* ]]
}

@test "dispatch: -r is accepted as a shorthand for --restore-all" {
  run "${BATS_TEST_DIRNAME}/../codersync" -r extra
  [ "$status" -eq 1 ]
  [[ "$output" == *"got extra"* ]]
  [[ "$output" == *"-r"* ]]
}

@test "dispatch: -l is accepted as a shorthand for --list-all" {
  run "${BATS_TEST_DIRNAME}/../codersync" -l extra
  [ "$status" -eq 1 ]
  [[ "$output" == *"got extra"* ]]
  [[ "$output" == *"-l"* ]]
}

@test "dispatch: -K is accepted as a shorthand for --kill-all" {
  run "${BATS_TEST_DIRNAME}/../codersync" -K extra
  [ "$status" -eq 1 ]
  [[ "$output" == *"got extra"* ]]
  [[ "$output" == *"-K"* ]]
}

@test "dispatch: -k is accepted as a shorthand for --kill (missing-ids check, no real config needed)" {
  # -k with no <ids> argument at all -- rejected before load_config, so
  # this never touches the network or any real config either.
  run "${BATS_TEST_DIRNAME}/../codersync" -k
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage: codersync --kill|-k"* ]]
}

@test "dispatch: -k rejects extra trailing arguments the same as --kill does" {
  run "${BATS_TEST_DIRNAME}/../codersync" -k 1 2
  [ "$status" -eq 1 ]
  [[ "$output" == *"got extra"* ]]
  [[ "$output" == *"-k"* ]]
}

@test "dispatch: --sync-skills rejects extra trailing arguments" {
  # Checked before load_config, so this never touches the network or
  # any real config either.
  run "${BATS_TEST_DIRNAME}/../codersync" --sync-skills extra
  [ "$status" -eq 1 ]
  [[ "$output" == *"got extra"* ]]
}

@test "dispatch: -y is accepted as a shorthand for --sync-skills" {
  # Same arity check, same code path -- -y extra should be rejected the
  # exact same way --sync-skills extra is, proving the alias reaches
  # the same case branch rather than falling through to the catch-all
  # "unknown session name" dispatch.
  run "${BATS_TEST_DIRNAME}/../codersync" -y extra
  [ "$status" -eq 1 ]
  [[ "$output" == *"got extra"* ]]
  [[ "$output" == *"-y"* ]]
}

@test "dispatch: --attach requires an id-or-name argument (missing-arg check, no real config needed)" {
  # Checked before load_config, so this never touches the network or
  # any real config either.
  run "${BATS_TEST_DIRNAME}/../codersync" --attach
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage: codersync --attach|-a"* ]]
}

@test "dispatch: --attach rejects extra trailing arguments" {
  run "${BATS_TEST_DIRNAME}/../codersync" --attach 3 extra
  [ "$status" -eq 1 ]
  [[ "$output" == *"got extra"* ]]
}

@test "dispatch: -a is accepted as a shorthand for --attach" {
  # Same arity check, same code path -- -a with extra args should be
  # rejected the exact same way --attach is, proving the alias reaches
  # the same case branch rather than falling through to the catch-all
  # "unknown session name" dispatch.
  run "${BATS_TEST_DIRNAME}/../codersync" -a 3 extra
  [ "$status" -eq 1 ]
  [[ "$output" == *"got extra"* ]]
  [[ "$output" == *"-a"* ]]
}

@test "dispatch: --rename requires two arguments (missing-arg check, no real config needed)" {
  # Checked before load_config, so this never touches the network or
  # any real config either.
  run "${BATS_TEST_DIRNAME}/../codersync" --rename 3
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage: codersync --rename|-R"* ]]
}

@test "dispatch: --rename rejects extra trailing arguments" {
  run "${BATS_TEST_DIRNAME}/../codersync" --rename 3 new-name extra
  [ "$status" -eq 1 ]
  [[ "$output" == *"got extra"* ]]
}

@test "dispatch: -R is accepted as a shorthand for --rename" {
  # Same arity check, same code path -- -R with extra args should be
  # rejected the exact same way --rename is, proving the alias reaches
  # the same case branch rather than falling through to the catch-all
  # "unknown session name" dispatch.
  run "${BATS_TEST_DIRNAME}/../codersync" -R 3 new-name extra
  [ "$status" -eq 1 ]
  [[ "$output" == *"got extra"* ]]
  [[ "$output" == *"-R"* ]]
}

@test "dispatch: --local requires a session name" {
  # Checked directly in the dispatch case, before local_setup (and so
  # before any tmux call) is ever reached.
  run "${BATS_TEST_DIRNAME}/../codersync" --local
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage: codersync --local|-L"* ]]
}

@test "dispatch: -L is accepted as a shorthand for --local" {
  run "${BATS_TEST_DIRNAME}/../codersync" -L
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage: codersync --local|-L"* ]]
}

@test "dispatch: --adopt rejects extra trailing arguments" {
  run "${BATS_TEST_DIRNAME}/../codersync" --adopt extra
  [ "$status" -eq 1 ]
  [[ "$output" == *"got extra"* ]]
}

@test "dispatch: -d is accepted as a shorthand for --adopt" {
  run "${BATS_TEST_DIRNAME}/../codersync" -d extra
  [ "$status" -eq 1 ]
  [[ "$output" == *"got extra"* ]]
  [[ "$output" == *"-d"* ]]
}
