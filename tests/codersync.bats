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

@test "find_or_assign_id: allocates a fresh session name when nothing matches" {
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  [ "$(find_or_assign_id "devbox.example.com" "devbox-example-com-foo")" = "1-devbox-example-com-foo" ]
}

@test "find_or_assign_id: reuses the existing entry's raw text for the same target+name" {
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t5-devbox-example-com-foo\n' > "$REGISTRY"
  [ "$(find_or_assign_id "devbox.example.com" "devbox-example-com-foo")" = "5-devbox-example-com-foo" ]
}

@test "find_or_assign_id: reuses an existing entry even when the registry has no trailing newline" {
  # Regression test: `while IFS= read -r line; do ... done < "$REGISTRY"`
  # silently skips the FINAL line of a file that doesn't end in a
  # newline -- `read` still populates `$line` with what it read before
  # hitting EOF, but returns non-zero (no delimiter found), which a
  # bare `while` treats as "nothing left" and drops that line
  # entirely. $REGISTRY ends up without a trailing newline whenever any
  # writer uses `printf '%s'` instead of `printf '%s\n'` for its LAST
  # line (this test uses `printf '%s'` deliberately, to reproduce
  # exactly that shape) -- confirmed live: with a final registry row
  # missing its trailing newline, find_or_assign_id never saw it and
  # minted a fresh duplicate ID ("1-...") instead of reusing the
  # existing one ("2-...").
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf '%s' "devbox.example.com"$'\t'"2-devbox-example-com-bar" > "$REGISTRY"
  [ "$(find_or_assign_id "devbox.example.com" "devbox-example-com-bar")" = "2-devbox-example-com-bar" ]
}

@test "find_or_assign_id: preserves a leading zero instead of reconstructing the canonical form" {
  # Regression test: this used to return only the CANONICAL id (e.g.
  # "8" for a "08-..." entry), and the caller reconstructed
  # "${id}-${suffix}" itself -- discarding the leading zero. A live
  # session already reachable as "pair-08-devbox-example-com-foo" (e.g.
  # after --adopt picked it up) then got a SECOND, differently-spelled
  # session ("pair-8-devbox-example-com-foo") and registry entry every
  # time `codersync foo` re-ran, instead of reattaching to the existing
  # one -- breaking the exact idempotence this function exists to
  # guarantee (confirmed live).
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t08-devbox-example-com-foo\n' > "$REGISTRY"
  [ "$(find_or_assign_id "devbox.example.com" "devbox-example-com-foo")" = "08-devbox-example-com-foo" ]
}

@test "find_or_assign_id: errors on duplicate entries for the same suffix instead of picking one" {
  # Regression test: a leftover pair of entries from the PRIOR version
  # of the leading-zero bug (e.g. both "8-devbox-example-com-foo" and
  # "08-devbox-example-com-foo" registered for the same suffix, from
  # before that bug was fixed) used to make this just return whichever
  # happened to be first on disk -- regardless of which one, if either,
  # is actually still live. Errors instead of guessing, pointing at
  # --restore-all to resolve the duplication first.
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t8-devbox-example-com-foo\ndevbox.example.com\t08-devbox-example-com-foo\n' > "$REGISTRY"
  run find_or_assign_id "devbox.example.com" "devbox-example-com-foo"
  [ "$status" -eq 1 ]
  [[ "$output" == *"multiple registry entries match"* ]]
  [[ "$output" == *"--restore-all"* ]]
}

@test "find_or_assign_id: exact duplicate lines don't count as ambiguous" {
  # Regression test: two IDENTICAL registry lines (a stale double-write,
  # not a genuine ambiguity between two different raw spellings) used
  # to be counted as "2 matches" too, wrongly triggering the same
  # ambiguity error as a real conflict -- confirmed live: --restore-all
  # doesn't actually resolve this shape either (it independently
  # restores each duplicate LINE, leaving both intact), so pointing the
  # user there for THIS case was a dead end.
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t08-devbox-example-com-foo\ndevbox.example.com\t08-devbox-example-com-foo\n' > "$REGISTRY"
  [ "$(find_or_assign_id "devbox.example.com" "devbox-example-com-foo")" = "08-devbox-example-com-foo" ]
}

@test "find_or_assign_id: does not reuse an entry belonging to a different target" {
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  # shellcheck disable=SC2034 # read by next_session_id, called below.
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'some-other-box\t5-devbox-example-com-foo\n' > "$REGISTRY"
  [ "$(find_or_assign_id "devbox.example.com" "devbox-example-com-foo")" = "1-devbox-example-com-foo" ]
}

@test "find_or_assign_id: mints a fresh session name instead of reusing a poisoned registry entry" {
  # Regression test: a registry entry with a broken ID segment (leading
  # zero beyond what canonicalizes sanely, or literally 0) used to be
  # reused verbatim -- next_session_id itself would never assign such a
  # value, so returning it here let it right back out as a real ID.
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t0-devbox-example-com-foo\n' > "$REGISTRY"
  [ "$(find_or_assign_id "devbox.example.com" "devbox-example-com-foo")" = "1-devbox-example-com-foo" ]
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

@test "load_config: TARGET_OVERRIDE (-T) replaces SSH_TARGET and resets REMOTE_DIR to ~" {
  # -T lets a single command reach a DIFFERENT box than the one --setup
  # configured as the default, without overwriting that default. A box
  # reached this way was never --setup, so it has no persisted
  # remote-dir of its own -- REMOTE_DIR resets to the same bare `~`
  # --setup itself defaults to, rather than reusing the CONFIGURED
  # DEFAULT target's own remote-dir against a totally different box.
  CONFIG_FILE="$BATS_TEST_TMPDIR/config"
  printf 'SSH_TARGET=devbox.example.com\nREMOTE_DIR=~/custom\n' > "$CONFIG_FILE"
  TARGET_OVERRIDE="otherbox.example.com"
  SAW_TARGET_OVERRIDE=1
  load_config
  # shellcheck disable=SC2031 # set by load_config above, not visible
  # statically to this checker.
  [ "$SSH_TARGET" = "otherbox.example.com" ]
  [ "$REMOTE_DIR" = "~" ]
  [ "$TARGET_LABEL" = "otherbox-example-com" ]
}

@test "load_config: REMOTE_DIR_OVERRIDE (--remote-dir) wins over the -T default of ~" {
  CONFIG_FILE="$BATS_TEST_TMPDIR/config"
  printf 'SSH_TARGET=devbox.example.com\n' > "$CONFIG_FILE"
  TARGET_OVERRIDE="otherbox.example.com"
  SAW_TARGET_OVERRIDE=1
  # shellcheck disable=SC2088 # intentional: literal `~`, expanded later
  # by the REMOTE shell, not by this one -- same as REMOTE_DIR itself.
  REMOTE_DIR_OVERRIDE="~/otherdir"
  SAW_REMOTE_DIR_OVERRIDE=1
  load_config
  # shellcheck disable=SC2031 # set by load_config above, not visible
  # statically to this checker.
  [ "$SSH_TARGET" = "otherbox.example.com" ]
  # shellcheck disable=SC2031,SC2088 # SC2031: set by load_config above,
  # not visible statically to this checker. SC2088: intentional literal.
  [ "$REMOTE_DIR" = "~/otherdir" ]
}

@test "load_config: --remote-dir alone (no -T) overrides just the remote-dir for this run" {
  CONFIG_FILE="$BATS_TEST_TMPDIR/config"
  # shellcheck disable=SC2088 # intentional: testing the literal string.
  printf 'SSH_TARGET=devbox.example.com\nREMOTE_DIR=~/original\n' > "$CONFIG_FILE"
  # shellcheck disable=SC2088 # intentional literal, see above.
  REMOTE_DIR_OVERRIDE="~/onceoff"
  SAW_REMOTE_DIR_OVERRIDE=1
  load_config
  # shellcheck disable=SC2031 # set by load_config above, not visible
  # statically to this checker.
  [ "$SSH_TARGET" = "devbox.example.com" ]
  # shellcheck disable=SC2031,SC2088 # SC2031: set by load_config above,
  # not visible statically to this checker. SC2088: intentional literal.
  [ "$REMOTE_DIR" = "~/onceoff" ]
}

@test "load_config: rejects an invalid TARGET_OVERRIDE before any network call" {
  CONFIG_FILE="$BATS_TEST_TMPDIR/config"
  printf 'SSH_TARGET=devbox.example.com\n' > "$CONFIG_FILE"
  TARGET_OVERRIDE="bad;target"
  SAW_TARGET_OVERRIDE=1
  run load_config
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid -T/--target"* ]]
}

@test "load_config: rejects an invalid REMOTE_DIR_OVERRIDE" {
  CONFIG_FILE="$BATS_TEST_TMPDIR/config"
  printf 'SSH_TARGET=devbox.example.com\n' > "$CONFIG_FILE"
  REMOTE_DIR_OVERRIDE='bad;dir'
  SAW_REMOTE_DIR_OVERRIDE=1
  run load_config
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid --remote-dir"* ]]
}

@test "load_config: -T '' (empty value) is rejected, not silently treated as no override" {
  # Regression test: the pre-pass only checked for a MISSING value or an
  # option-shaped one ("$2" == -*) -- a bare -T with an empty string
  # slipped through both checks, setting TARGET_OVERRIDE to an empty
  # value. load_config used to gate applying the override on
  # `-n "$TARGET_OVERRIDE"`, which reads an empty string the same as
  # "not provided" and skipped validating it entirely -- a bare
  # `-T ''` before --list-all ran against the configured default with
  # no error at all (confirmed live). SAW_TARGET_OVERRIDE=1 means the
  # flag really was given, so this must now reach validate_ssh_target
  # (which correctly rejects an empty string) instead of being ignored.
  CONFIG_FILE="$BATS_TEST_TMPDIR/config"
  printf 'SSH_TARGET=devbox.example.com\n' > "$CONFIG_FILE"
  TARGET_OVERRIDE=""
  # shellcheck disable=SC2034 # read by load_config below, not visible
  # statically to this checker.
  SAW_TARGET_OVERRIDE=1
  run load_config
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid -T/--target"* ]]
}

@test "load_config: --remote-dir '' (empty value) is rejected, not silently treated as no override" {
  CONFIG_FILE="$BATS_TEST_TMPDIR/config"
  printf 'SSH_TARGET=devbox.example.com\n' > "$CONFIG_FILE"
  REMOTE_DIR_OVERRIDE=""
  # shellcheck disable=SC2034 # read by load_config below, not visible
  # statically to this checker.
  SAW_REMOTE_DIR_OVERRIDE=1
  run load_config
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid --remote-dir"* ]]
}

@test "load_config: with no override at all, behaves exactly as before" {
  CONFIG_FILE="$BATS_TEST_TMPDIR/config"
  # shellcheck disable=SC2088 # intentional: testing the literal string.
  printf 'SSH_TARGET=devbox.example.com\nREMOTE_DIR=~/repos\n' > "$CONFIG_FILE"
  # shellcheck disable=SC2034 # read by load_config below, not visible
  # statically to this checker.
  TARGET_OVERRIDE=""
  # shellcheck disable=SC2034 # read by load_config below, not visible
  # statically to this checker.
  REMOTE_DIR_OVERRIDE=""
  load_config
  # shellcheck disable=SC2031 # set by load_config above, not visible
  # statically to this checker.
  [ "$SSH_TARGET" = "devbox.example.com" ]
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

@test "parse_run_args: replaces spaces in the session name with dashes instead of rejecting it" {
  parse_run_args "This is a test session name"
  [ "$RAW_NAME" = "This-is-a-test-session-name" ]
}

@test "parse_run_args: prints a notice when it substitutes spaces in the session name" {
  run parse_run_args "This is a test session name"
  [ "$status" -eq 0 ]
  [[ "$output" == *"using 'This-is-a-test-session-name'"* ]]
}

@test "parse_run_args: does not print a substitution notice when the name has no spaces" {
  run parse_run_args "mysession"
  [ "$status" -eq 0 ]
  [[ "$output" != *"replaced spaces"* ]]
}

@test "parse_run_args: a name that is only whitespace is rejected, not silently emptied" {
  run parse_run_args "   "
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

# NOTE: every test below uses `run`, not bare `[ "$(normalize_session_name_spaces ...)" = ... ]`,
# specifically so a crash inside the function is actually caught.
# Regression test for a real gap: an earlier `read -ra`-based
# implementation crashed on real bash 3.2 for empty/all-whitespace
# input (`words[*]: unbound variable`, an empty array under this
# script's `set -u` -- confirmed live). The bare `[ "$(...)" = "" ]`
# form used here originally did NOT catch that crash: a crashing
# command substitution still produces empty stdout (nothing was
# printed before it died), which happens to equal the expected ""
# result for that one case, so the assertion passed anyway with the
# function's actual failure silently swallowed. `run` captures the
# real exit status as well as the output, closing that gap.

@test "normalize_session_name_spaces: replaces a single space with a dash" {
  run normalize_session_name_spaces "This is a test session name"
  [ "$status" -eq 0 ]
  [ "$output" = "This-is-a-test-session-name" ]
}

@test "normalize_session_name_spaces: collapses runs of whitespace into one dash" {
  run normalize_session_name_spaces "a   b"
  [ "$status" -eq 0 ]
  [ "$output" = "a-b" ]
}

@test "normalize_session_name_spaces: trims leading and trailing whitespace instead of turning it into a leading/trailing dash" {
  run normalize_session_name_spaces "  a b  "
  [ "$status" -eq 0 ]
  [ "$output" = "a-b" ]
}

@test "normalize_session_name_spaces: folds a tab the same as a space" {
  local tabbed
  tabbed="$(printf 'a\tb')"
  run normalize_session_name_spaces "$tabbed"
  [ "$status" -eq 0 ]
  [ "$output" = "a-b" ]
}

@test "normalize_session_name_spaces: folds an embedded newline the same as any other whitespace" {
  # Regression test: an earlier `read -ra`-based implementation used
  # `read`, which always stops at the first newline no matter what --
  # $'safe\nother' silently truncated to just "safe" instead of folding
  # the newline into '-' like every other whitespace character.
  # Confirmed live as a real risk, not just cosmetic: `codersync
  # --attach $'safe\nother'` resolved (and attached) the WRONG/existing
  # session "safe", silently discarding "other" instead of erroring or
  # matching on the full text.
  local newlined
  newlined="$(printf 'safe\nother')"
  run normalize_session_name_spaces "$newlined"
  [ "$status" -eq 0 ]
  [ "$output" = "safe-other" ]
}

@test "normalize_session_name_spaces: leaves an already-valid name unchanged" {
  run normalize_session_name_spaces "already-fine_123"
  [ "$status" -eq 0 ]
  [ "$output" = "already-fine_123" ]
}

@test "normalize_session_name_spaces: does not touch characters validate_session_name still rejects" {
  # A dot has no whitespace to fold -- normalization must not mask or
  # otherwise alter an actually-invalid character.
  run normalize_session_name_spaces "my.session"
  [ "$status" -eq 0 ]
  [ "$output" = "my.session" ]
}

@test "normalize_session_name_spaces: an all-whitespace input normalizes to empty without crashing" {
  # Regression test: an earlier `read -ra`-based implementation
  # crashed here specifically on real bash 3.2 (`words[*]: unbound
  # variable` -- an empty array reference under this script's
  # `set -u`), rather than cleanly producing an empty string for
  # validate_session_name to then reject as an invalid name.
  run normalize_session_name_spaces "   "
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
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

@test "parse_registry_line: bare (pre-migration) entry falls back to SSH_TARGET when DEFAULT_SSH_TARGET is unset" {
  # DEFAULT_SSH_TARGET is what load_config() actually populates in real
  # usage (see the next test) -- this covers the fallback path for
  # callers that set SSH_TARGET directly without going through
  # load_config at all (e.g. most of the other tests in this file).
  # shellcheck disable=SC2034 # read by parse_registry_line below.
  SSH_TARGET="devbox.example.com"
  parse_registry_line "my-session"
  [ "$ENTRY_TARGET" = "devbox.example.com" ]
  [ "$ENTRY_NAME" = "my-session" ]
}

@test "parse_registry_line: bare entry binds to DEFAULT_SSH_TARGET, not SSH_TARGET, when -T is in effect" {
  # Regression test: -T reassigns $SSH_TARGET for the rest of the
  # current command (see load_config's own comment), but a bare legacy
  # row predates -T entirely and has nothing to do with whichever OTHER
  # box a given -T invocation happens to be reaching this time. Using
  # $SSH_TARGET here let a bare row bound to the real configured
  # default get silently reattributed to whatever box -T pointed at
  # instead -- confirmed live: with a bare row already registered on
  # the configured default (boxA), `codersync -T boxB.example.com
  # --restore-all` saw that row as belonging to boxB, found no live
  # session for it there, and pruned it outright, deleting a
  # perfectly live boxA registration because of an unrelated one-off
  # command aimed at a completely different box. DEFAULT_SSH_TARGET
  # (captured by load_config before applying -T) is what this must
  # resolve to instead.
  # shellcheck disable=SC2030,SC2034 # SC2030: bats-subshell false
  # positive, not actually isolated here. SC2034: read by
  # parse_registry_line below.
  SSH_TARGET="boxB.example.com"
  # shellcheck disable=SC2030,SC2034 # see above.
  DEFAULT_SSH_TARGET="boxA.example.com"
  parse_registry_line "my-session"
  [ "$ENTRY_TARGET" = "boxA.example.com" ]
  [ "$ENTRY_NAME" = "my-session" ]
}

@test "load_config: DEFAULT_SSH_TARGET is the configured default, unaffected by -T" {
  CONFIG_FILE="$BATS_TEST_TMPDIR/config"
  printf 'SSH_TARGET=boxA.example.com\n' > "$CONFIG_FILE"
  # shellcheck disable=SC2034 # read by load_config below, not visible
  # statically to this checker.
  TARGET_OVERRIDE="boxB.example.com"
  # shellcheck disable=SC2034 # read by load_config below, not visible
  # statically to this checker.
  SAW_TARGET_OVERRIDE=1
  load_config
  # shellcheck disable=SC2031 # set by load_config above, not visible
  # statically to this checker.
  [ "$SSH_TARGET" = "boxB.example.com" ]
  # shellcheck disable=SC2031 # set by load_config above, not visible
  # statically to this checker.
  [ "$DEFAULT_SSH_TARGET" = "boxA.example.com" ]
}

@test "restore_all: a bare legacy row on the real default survives a -T run against a different box" {
  # End-to-end version of parse_registry_line's own test above --
  # confirms the fix actually closes the reviewer's exact reproduction:
  # a bare (no-tab) row that predates the per-target registry format,
  # sitting on the CONFIGURED DEFAULT (boxA), must not be mistaken for
  # a boxB entry (and pruned as "not live there") just because THIS one
  # command happens to be aimed at boxB via -T.
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'my-old-job\n' > "$REGISTRY"
  SSH_TARGET="boxB.example.com"
  TARGET_LABEL="boxb-example-com"
  DEFAULT_SSH_TARGET="boxA.example.com"
  # shellcheck disable=SC2329 # invoked indirectly, by restore_all below.
  ssh() { [[ "$*" == *"list-sessions"* ]] && printf ''; }
  run restore_all
  [ "$status" -eq 0 ]
  [[ "$output" != *"Pruning stale entry"* ]]
  # Kept, not pruned -- and normalized to the per-target tagged format
  # in the process (existing behavior for any "different target" entry
  # restore_all preserves, bare or not; the row's SURVIVAL is what this
  # test is actually about).
  [ "$(cat "$REGISTRY")" = "boxA.example.com"$'\t'"my-old-job" ]
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
  CONFIG_DIR="$BATS_TEST_TMPDIR"
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
  CONFIG_DIR="$BATS_TEST_TMPDIR"
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

@test "restore_all: collapses exact duplicate registry lines to a single restore" {
  # Regression test: two IDENTICAL registry lines (a stale double-write
  # from before this de-dup existed) each independently looked "alive"
  # against the same live session and got separately restored/opened
  # -- a tab opened once PER duplicate instead of once total, and the
  # registry rewritten with the same duplicate still intact afterward
  # (confirmed live with a stubbed remote: --restore-all restored/
  # opened the same session TWICE and left both identical lines,
  # meaning find_or_assign_id's own "run --restore-all to fix this"
  # advice for the duplicate-entries case was a dead end for this
  # exact shape).
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t08-devbox-example-com-foo\ndevbox.example.com\t08-devbox-example-com-foo\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by restore_all below.
  ssh() { [[ "$*" == *"list-sessions"* ]] && printf 'pair-08-devbox-example-com-foo\n'; }
  # shellcheck disable=SC2329 # invoked indirectly, by restore_all below.
  remote_setup_tmux_mode() { echo "remote_setup_tmux_mode:$1"; }
  # shellcheck disable=SC2329 # invoked indirectly, by restore_all below.
  open_tab_tmux_mode() { echo "open_tab_tmux_mode:$1"; }
  run restore_all
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restored 1 session(s)."* ]]
  # Restoring/opening called exactly once, not twice.
  [ "$(grep -c "^remote_setup_tmux_mode:" <<< "$output")" -eq 1 ]
  [ "$(grep -c "^open_tab_tmux_mode:" <<< "$output")" -eq 1 ]
  [ "$(cat "$REGISTRY")" = "devbox.example.com"$'\t'"08-devbox-example-com-foo" ]
}

@test "restore_all: does not prune an entry with an unexpired pending marker" {
  # Regression test: the normal creation path releases id.lock right
  # after writing the registry entry, before the remote tmux session
  # actually exists (deliberately, to avoid serializing unrelated
  # invocations -- see the dispatch case's own comment). restore_all
  # used to treat that exact window's registered-but-not-yet-live entry
  # as indistinguishable from a genuinely dead one and prune it --
  # confirmed live by registering an entry, then running --restore-all
  # before the matching tmux session came up: it deleted the entry a
  # moment before the real session appeared, orphaning it. A pending
  # marker (mark_pending) now protects exactly this window.
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  PENDING_FILE="$CONFIG_DIR/pending"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t3-devbox-example-com-foo\n' > "$REGISTRY"
  mark_pending "3-devbox-example-com-foo"
  # shellcheck disable=SC2329 # invoked indirectly, by restore_all below.
  ssh() { [[ "$*" == *"list-sessions"* ]] && printf ''; }
  run restore_all
  [ "$status" -eq 0 ]
  [[ "$output" == *"session creation still in progress, not pruning yet"* ]]
  [[ "$output" != *"Pruning stale entry"* ]]
  [ "$(cat "$REGISTRY")" = "devbox.example.com"$'\t'"3-devbox-example-com-foo" ]
}

@test "restore_all: prunes an entry with an expired pending marker" {
  # A pending marker left behind by a hard crash (kill -9 skips the EXIT
  # trap that would normally clear_pending) must not protect a dead
  # entry forever -- past PENDING_TTL_SECONDS it's treated as stale like
  # any other marker-less dead entry.
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  PENDING_FILE="$CONFIG_DIR/pending"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t3-devbox-example-com-foo\n' > "$REGISTRY"
  mkdir -p "$CONFIG_DIR"
  printf '%s\n' "1"$'\t'"devbox.example.com"$'\t'"3-devbox-example-com-foo" > "$PENDING_FILE"
  # shellcheck disable=SC2329 # invoked indirectly, by restore_all below.
  ssh() { [[ "$*" == *"list-sessions"* ]] && printf ''; }
  run restore_all
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pruning stale entry"* ]]
  [ ! -s "$REGISTRY" ]
}

@test "mark_pending / is_pending / clear_pending round-trip" {
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  PENDING_FILE="$CONFIG_DIR/pending"
  run ! is_pending "devbox.example.com" "3-devbox-example-com-foo"
  mark_pending "3-devbox-example-com-foo"
  is_pending "devbox.example.com" "3-devbox-example-com-foo"
  run ! is_pending "devbox.example.com" "5-devbox-example-com-other"
  run ! is_pending "other.example.com" "3-devbox-example-com-foo"
  clear_pending "3-devbox-example-com-foo"
  run ! is_pending "devbox.example.com" "3-devbox-example-com-foo"
}

@test "is_pending: sees a valid marker even when the pending file has no trailing newline" {
  # Regression test: see find_or_assign_id's identical test for the
  # general shape of this bug (`while IFS= read -r line; do ... done <
  # file` silently drops a file's final line if it doesn't end in a
  # newline). Confirmed live for this exact function: a valid,
  # unexpired marker with no trailing newline (this test's
  # `printf '%s'`, deliberately without the usual trailing \n) was
  # never seen by the read loop at all, so this returned "not pending"
  # for a genuinely in-flight session.
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  PENDING_FILE="$CONFIG_DIR/pending"
  printf '%s' "$(date +%s)"$'\t'"devbox.example.com"$'\t'"3-devbox-example-com-foo" > "$PENDING_FILE"
  is_pending "devbox.example.com" "3-devbox-example-com-foo"
}

@test "clear_pending: does not lose a DIFFERENT session's marker with no trailing newline" {
  # Same underlying bug as is_pending's test above, with a more severe
  # consequence here: the OTHER session's marker (no trailing newline,
  # this test's `printf '%s'`) was never read at all, so it was simply
  # missing from `kept` when the file got rewritten -- silently
  # discarding a genuinely in-flight session's marker while clearing a
  # completely unrelated one's.
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  PENDING_FILE="$CONFIG_DIR/pending"
  printf '%s\n' "$(date +%s)"$'\t'"devbox.example.com"$'\t'"3-devbox-example-com-foo" > "$PENDING_FILE"
  printf '%s' "$(date +%s)"$'\t'"devbox.example.com"$'\t'"5-devbox-example-com-bar" >> "$PENDING_FILE"
  clear_pending "3-devbox-example-com-foo"
  is_pending "devbox.example.com" "5-devbox-example-com-bar"
}

@test "mark_pending: fails clearly when the pending-file lock is already held, without touching the file" {
  # Regression test: mark_pending's append and clear_pending's
  # read-modify-write used to run completely unlocked -- two overlapping
  # creations could interleave so one clear_pending wrote back a stale
  # snapshot after another session's mark_pending had already appended,
  # silently dropping that marker (confirmed live racing two overlapping
  # `codersync <name>` invocations). Simulates a concurrent invocation
  # already holding the (now-separate) pending.lock the same way the
  # existing id.lock contention test above does for session creation/
  # rename, and confirms mark_pending backs off cleanly instead of
  # writing anyway while contended.
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  PENDING_FILE="$CONFIG_DIR/pending"
  mkdir -p "$CONFIG_DIR/pending.lock"
  run mark_pending "3-devbox-example-com-foo"
  [ "$status" -eq 1 ]
  [[ "$output" == *"couldn't acquire the pending-file lock"* ]]
  [ ! -e "$PENDING_FILE" ]
}

@test "clear_pending: fails clearly when the pending-file lock is already held, without rewriting the file" {
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  PENDING_FILE="$CONFIG_DIR/pending"
  printf '%s\n' "1"$'\t'"devbox.example.com"$'\t'"3-devbox-example-com-foo" > "$PENDING_FILE"
  mkdir -p "$CONFIG_DIR/pending.lock"
  run clear_pending "3-devbox-example-com-foo"
  [ "$status" -eq 1 ]
  [[ "$output" == *"couldn't acquire the pending-file lock"* ]]
  # Untouched, not rewritten (which is what would have happened had
  # clear_pending proceeded without the lock): the original marker is
  # still there verbatim.
  [ "$(cat "$PENDING_FILE")" = "1"$'\t'"devbox.example.com"$'\t'"3-devbox-example-com-foo" ]
}

@test "mark_pending: releases the pending-file lock even when the write itself fails" {
  # Regression test: the acquire-lock/do-work/release-lock sequence had
  # no trap -- a write failure (or a Ctrl-C) between acquiring the lock
  # and the explicit release at the end left pending.lock behind,
  # blocking every later pending-file operation for 5s until someone
  # noticed and removed it by hand. Forces the write itself to fail (a
  # PENDING_FILE whose parent directory doesn't exist) to prove the
  # trap, not the normal code path, is what cleans up here.
  #
  # Run in a genuinely separate `bash -c` subshell, NOT via bats' `run`
  # on the function directly -- bats' `run` suppresses errexit around
  # whatever it invokes (that's how it captures a failing exit code
  # without killing the whole test process), so calling mark_pending
  # straight from a `run` never actually triggers the `set -e` exit
  # this test exists to cover: the failed printf's non-zero status was
  # silently ignored and execution just continued on to the explicit
  # trap disarm + release at the end, passing for the wrong reason.
  # Calling it directly without `run` isn't an option either -- that
  # DOES trigger real errexit, but it kills the whole bats worker
  # process outright (confirmed: "Executed 0 instead of expected 1
  # tests") since nothing in the bats harness itself is set up to catch
  # that. A separate `bash -c` process is a real, independent `set -e`
  # script; `run` only captures ITS exit code, without touching
  # errexit inside it.
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  run bash -c '
    set -euo pipefail
    source "'"${BATS_TEST_DIRNAME}"'/../codersync"
    SSH_TARGET="devbox.example.com"
    CONFIG_DIR="'"$CONFIG_DIR"'"
    PENDING_FILE="$CONFIG_DIR/nonexistent-subdir/pending"
    mark_pending "3-devbox-example-com-foo"
  '
  [ "$status" -ne 0 ]
  [ ! -d "$CONFIG_DIR/pending.lock" ]
}

@test "clear_pending: releases the pending-file lock even when the write itself fails" {
  # See mark_pending's test above for why this runs in a separate
  # `bash -c` subshell instead of `run clear_pending ...` directly.
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  PENDING_FILE="$CONFIG_DIR/pending"
  printf '%s\n' "1"$'\t'"devbox.example.com"$'\t'"3-devbox-example-com-foo" > "$PENDING_FILE"
  chmod 000 "$PENDING_FILE"
  run bash -c '
    set -euo pipefail
    source "'"${BATS_TEST_DIRNAME}"'/../codersync"
    SSH_TARGET="devbox.example.com"
    CONFIG_DIR="'"$CONFIG_DIR"'"
    PENDING_FILE="'"$PENDING_FILE"'"
    clear_pending "3-devbox-example-com-foo"
  '
  [ "$status" -ne 0 ]
  [ ! -d "$CONFIG_DIR/pending.lock" ]
  chmod 644 "$PENDING_FILE"
}

@test "clear_pending: does not truncate the file when the READ fails but the write would have succeeded" {
  # Regression test: the previous fix wrapped the read+rewrite in
  # `( set -e; ... ) || rc=$?` -- looks like it should catch either
  # failure, but a subshell used as the operand of `||` doesn't
  # reliably honor an explicit `set -e` for INTERMEDIATE command
  # failures inside it (confirmed in isolation: `( set -e; false; echo
  # reached_anyway ) || true` prints reached_anyway). A write-only
  # $PENDING_FILE (chmod 200 -- plausible from a partial/corrupted
  # permission change, unlike chmod 000 which blocks everything) makes
  # the READ fail but leaves the file WRITABLE -- so with the subshell
  # version, execution carried on past the failed read with an empty
  # `kept`, and the still-succeeding write then truncated the file to
  # empty, silently discarding this OTHER in-flight session's marker
  # too, while still returning status 0 (confirmed live: two markers
  # in the file, "Permission denied" printed, but status=0 and
  # pending_bytes=0 afterward). The fix attaches `|| rc=$?` directly to
  # the read and skips the write entirely if the read didn't succeed,
  # rather than ever risking a rewrite built from an incomplete read.
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  PENDING_FILE="$CONFIG_DIR/pending"
  printf '%s\n%s\n' \
    "1"$'\t'"devbox.example.com"$'\t'"3-devbox-example-com-foo" \
    "2"$'\t'"devbox.example.com"$'\t'"5-devbox-example-com-bar" \
    > "$PENDING_FILE"
  chmod 200 "$PENDING_FILE"
  run clear_pending "3-devbox-example-com-foo"
  chmod 644 "$PENDING_FILE"
  [ "$status" -ne 0 ]
  [ ! -d "$CONFIG_DIR/pending.lock" ]
  # Both markers survive untouched -- not just "something non-empty":
  # a truncate-then-partial-rewrite could still pass a bare
  # non-emptiness check while having lost data.
  [[ "$(cat "$PENDING_FILE")" == *"3-devbox-example-com-foo"* ]]
  [[ "$(cat "$PENDING_FILE")" == *"5-devbox-example-com-bar"* ]]
}

@test "mark_pending: does not clobber an outer id.lock EXIT trap" {
  # Regression test reproducing the dispatch path's EXACT structure:
  # `acquire_id_lock; trap 'release_id_lock' EXIT; ...; mark_pending
  # ...` (see the dispatch case). An earlier version of mark_pending
  # armed its OWN `trap ... EXIT` around its write -- bash EXIT traps
  # are a single global slot, not a stack, so that silently replaced
  # this outer trap, and disarming back to `trap - EXIT` at the end
  # erased it rather than restoring it. If the write then failed, only
  # pending.lock got released; id.lock was left behind with no trap
  # left at all to release it (confirmed live: status=1,
  # id_lock_exists=yes, pending_lock_exists=no).
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  run bash -c '
    set -euo pipefail
    source "'"${BATS_TEST_DIRNAME}"'/../codersync"
    SSH_TARGET="devbox.example.com"
    CONFIG_DIR="'"$CONFIG_DIR"'"
    acquire_id_lock || exit 1
    trap "release_id_lock" EXIT
    PENDING_FILE="$CONFIG_DIR/nonexistent-subdir/pending"
    mark_pending "3-devbox-example-com-foo"
    trap - EXIT
    release_id_lock
  '
  [ "$status" -ne 0 ]
  [ ! -d "$CONFIG_DIR/id.lock" ]
  [ ! -d "$CONFIG_DIR/pending.lock" ]
}

@test "clear_pending: does not clobber an outer id.lock EXIT trap-string" {
  # Same regression as mark_pending's test above, for the OTHER call
  # shape: the dispatch case's cleanup trap is exactly
  # `clear_pending "$SESSION" || true; release_id_lock` (see the
  # dispatch code) -- confirmed live with BOTH id.lock and pending.lock
  # left behind before this fix, since clear_pending's own trap
  # clobbered this one too. Triggers the trap via a plain `false`
  # (standing in for remote setup failing), rather than calling
  # clear_pending directly, to exercise the real trap-string shape.
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  PENDING_FILE="$CONFIG_DIR/pending"
  printf '%s\n' "1"$'\t'"devbox.example.com"$'\t'"3-devbox-example-com-foo" > "$PENDING_FILE"
  chmod 000 "$PENDING_FILE"
  run bash -c '
    set -euo pipefail
    source "'"${BATS_TEST_DIRNAME}"'/../codersync"
    SSH_TARGET="devbox.example.com"
    CONFIG_DIR="'"$CONFIG_DIR"'"
    PENDING_FILE="'"$PENDING_FILE"'"
    acquire_id_lock || exit 1
    trap "clear_pending \"3-devbox-example-com-foo\" || true; release_id_lock" EXIT
    false
  '
  [ "$status" -ne 0 ]
  [ ! -d "$CONFIG_DIR/id.lock" ]
  [ ! -d "$CONFIG_DIR/pending.lock" ]
  chmod 644 "$PENDING_FILE"
}

@test "is_pending: returns status 2 (not 1) when the pending lock is contended, distinct from not-pending" {
  # Regression test: is_pending used to `return 1` for BOTH "definitely
  # not pending" and "couldn't acquire the lock to check" -- callers had
  # no way to tell a contended lock apart from a confirmed-absent
  # marker. Status 2 is a distinct third outcome callers must treat as
  # "don't know" (see the restore_all test below for the consequence of
  # not distinguishing this).
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  PENDING_FILE="$CONFIG_DIR/pending"
  printf '%s\n' "$(date +%s)"$'\t'"devbox.example.com"$'\t'"3-devbox-example-com-foo" > "$PENDING_FILE"
  mkdir -p "$CONFIG_DIR/pending.lock"
  run is_pending "devbox.example.com" "3-devbox-example-com-foo"
  [ "$status" -eq 2 ]
}

@test "restore_all: does not prune an entry when the pending lock is contended (can't tell if it's pending)" {
  # Regression test: restore_all treated is_pending's status 1 as an
  # unconditional "safe to prune" signal -- but status 1 used to also
  # mean "the pending-file lock was contended, couldn't check at all".
  # A FRESH, valid pending marker for this exact entry plus a
  # pre-held pending.lock reproduced the reviewer's exact repro: the
  # registry entry got deleted anyway, even though it was genuinely
  # still being created (confirmed live). Held rather than pruned now,
  # the same "don't know -> don't destroy" rule as an unexpired marker.
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  PENDING_FILE="$CONFIG_DIR/pending"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t3-devbox-example-com-foo\n' > "$REGISTRY"
  printf '%s\n' "$(date +%s)"$'\t'"devbox.example.com"$'\t'"3-devbox-example-com-foo" > "$PENDING_FILE"
  mkdir -p "$CONFIG_DIR/pending.lock"
  # shellcheck disable=SC2329 # invoked indirectly, by restore_all below.
  ssh() { [[ "$*" == *"list-sessions"* ]] && printf ''; }
  run restore_all
  [ "$status" -eq 0 ]
  [[ "$output" == *"couldn't check its pending status"* ]]
  [[ "$output" != *"Pruning stale entry"* ]]
  [ "$(cat "$REGISTRY")" = "devbox.example.com"$'\t'"3-devbox-example-com-foo" ]
}

@test "is_pending: returns status 2 (not 1) when the pending file itself is unreadable" {
  # Regression test: distinct from the lock-contention case above --
  # this is $PENDING_FILE existing but unreadable (chmod 000), which a
  # PREVIOUS round's fix for the lock-contention case didn't cover.
  # `found` stayed at its default of 1 when the read failed outright
  # (couldn't even open the file), so this returned 1 ("confirmed not
  # pending") -- indistinguishable from a clean read that legitimately
  # found nothing (confirmed live, again: a valid, fresh marker plus a
  # chmod 000 $PENDING_FILE still returned 1).
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  PENDING_FILE="$CONFIG_DIR/pending"
  printf '%s\n' "$(date +%s)"$'\t'"devbox.example.com"$'\t'"3-devbox-example-com-foo" > "$PENDING_FILE"
  chmod 000 "$PENDING_FILE"
  run is_pending "devbox.example.com" "3-devbox-example-com-foo"
  chmod 644 "$PENDING_FILE"
  [ "$status" -eq 2 ]
}

@test "restore_all: does not prune an entry when the pending file itself is unreadable" {
  # Same regression as is_pending's test above, end-to-end: a FRESH,
  # valid pending marker for this exact entry plus a chmod 000
  # $PENDING_FILE reproduced the reviewer's exact repro -- the registry
  # entry got deleted anyway (status 0), even though it was genuinely
  # still being created (confirmed live).
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  PENDING_FILE="$CONFIG_DIR/pending"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t3-devbox-example-com-foo\n' > "$REGISTRY"
  printf '%s\n' "$(date +%s)"$'\t'"devbox.example.com"$'\t'"3-devbox-example-com-foo" > "$PENDING_FILE"
  chmod 000 "$PENDING_FILE"
  # shellcheck disable=SC2329 # invoked indirectly, by restore_all below.
  ssh() { [[ "$*" == *"list-sessions"* ]] && printf ''; }
  run restore_all
  chmod 644 "$PENDING_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"couldn't check its pending status"* ]]
  [[ "$output" != *"Pruning stale entry"* ]]
  [ "$(cat "$REGISTRY")" = "devbox.example.com"$'\t'"3-devbox-example-com-foo" ]
  # Regression test: an earlier version of this message named ONLY
  # "pending-file lock contended" -- correct for the lock-contention
  # case, but misleading here (the pending FILE is unreadable, not the
  # lock), pointing the user toward waiting out a lock that was never
  # actually the problem. The message is now generic enough to cover
  # both causes of status 2.
  [[ "$output" == *"pending-file lock contended, or the pending file itself couldn't be read"* ]]
}

@test "is_pending: ignores a malformed (non-numeric) timestamp instead of crashing" {
  # Regression test: is_pending fed the timestamp field straight into
  # `(( now - ts ))` with no validation -- a hand-edited or corrupted
  # pending file with a non-numeric first field crashed the whole
  # command with "abc: unbound variable" under set -u (confirmed live).
  # A malformed row is now just skipped, same as if it weren't there.
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  PENDING_FILE="$CONFIG_DIR/pending"
  printf 'abc\tdevbox.example.com\t3-devbox-example-com-foo\n' > "$PENDING_FILE"
  run is_pending "devbox.example.com" "3-devbox-example-com-foo"
  [ "$status" -eq 1 ]
  [[ "$output" != *"unbound variable"* ]]
}

@test "restore_all: a malformed pending timestamp doesn't crash, entry is treated as prunable" {
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  PENDING_FILE="$CONFIG_DIR/pending"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t3-devbox-example-com-foo\n' > "$REGISTRY"
  printf 'abc\tdevbox.example.com\t3-devbox-example-com-foo\n' > "$PENDING_FILE"
  # shellcheck disable=SC2329 # invoked indirectly, by restore_all below.
  ssh() { [[ "$*" == *"list-sessions"* ]] && printf ''; }
  run restore_all
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pruning stale entry"* ]]
  [ ! -s "$REGISTRY" ]
}

@test "merge_concurrent_registry_additions: reports a registry line not in the caller's seen set" {
  # Direct unit test of the helper restore_all/kill_sessions/
  # kill_all_sessions now use right before their final registry write --
  # confirms it correctly identifies which current on-disk lines the
  # caller's earlier read never saw (a concurrent register_session
  # append), and leaves already-seen ones out.
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t1-devbox-example-com-foo\ndevbox.example.com\t2-devbox-example-com-bar\n' > "$REGISTRY"
  seen=$'\n'"devbox.example.com"$'\t'"1-devbox-example-com-foo"$'\n'
  result="$(merge_concurrent_registry_additions "$seen")"
  [ "$result" = "devbox.example.com"$'\t'"2-devbox-example-com-bar" ]
}

@test "restore_all: fails clearly (does not silently proceed) when id.lock is contended at the final write" {
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t1-devbox-example-com-foo\n' > "$REGISTRY"
  mkdir -p "$CONFIG_DIR/id.lock"
  # shellcheck disable=SC2329 # invoked indirectly, by restore_all below.
  ssh() { [[ "$*" == *"list-sessions"* ]] && printf ''; }
  run restore_all
  [ "$status" -eq 1 ]
  [[ "$output" == *"couldn't acquire the session-ID lock"* ]]
}

@test "restore_all: rechecks pending status under id.lock instead of trusting the initial unlocked scan" {
  # Regression test: the main scan loop's is_pending check (and the
  # $REGISTRY read that fed it) both run WITHOUT id.lock. A concurrent
  # creation writes its registry row (register_session) and its
  # pending marker (mark_pending) in that order, both while holding
  # id.lock -- so this loop can see the freshly-written row (that's how
  # it got into $REGISTRY for the loop to read at all) an instant before
  # the SAME invocation's marker exists, mistake it for genuinely dead,
  # and queue it for pruning. Reproduced here by stubbing is_pending to
  # answer "not pending" on its FIRST call (the un-locked scan) and
  # "pending" on every call after (the marker having since appeared by
  # the time of the locked recheck) -- confirmed live, this exact gap
  # left the registry empty while a fresh pending marker for the pruned
  # entry remained.
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t3-devbox-example-com-foo\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by restore_all below.
  ssh() { [[ "$*" == *"list-sessions"* ]] && printf ''; }
  is_pending_calls=0
  # shellcheck disable=SC2329 # invoked indirectly, by restore_all below.
  is_pending() {
    is_pending_calls=$((is_pending_calls + 1))
    [[ "$is_pending_calls" -eq 1 ]] && return 1
    return 0
  }
  run restore_all
  [ "$status" -eq 0 ]
  [[ "$output" == *"session creation still in progress, not pruning yet."* ]]
  [[ "$output" != *"Pruning stale entry"* ]]
  [ "$(cat "$REGISTRY")" = "devbox.example.com"$'\t'"3-devbox-example-com-foo" ]
}

@test "restore_all: releases id.lock even when the final registry write fails" {
  # Regression test: the acquire-lock/do-work/release-lock sequence
  # around the final merge+write had no trap -- a write failure (or a
  # Ctrl-C) between acquiring id.lock and the explicit release left it
  # behind, blocking every later id.lock operation for 5s. Forces the
  # final write to fail (a read-only $REGISTRY) to prove the trap, not
  # the normal code path, is what releases the lock here.
  #
  # Run in a genuinely separate `bash -c` subshell, NOT via bats' `run`
  # on the function directly -- same reason as mark_pending's test
  # above (bats' `run` suppresses errexit, so it would never actually
  # trigger the `set -e` exit this test exists to cover). No live
  # session for the one registry entry, so it's the "prune" path (no
  # remote_setup_tmux_mode/open_tab_tmux_mode calls to stub) that hits
  # the failing write.
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t1-devbox-example-com-foo\n' > "$REGISTRY"
  chmod 444 "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by restore_all below.
  ssh() { [[ "$*" == *"list-sessions"* ]] && printf ''; }
  export -f ssh
  run bash -c '
    set -euo pipefail
    source "'"${BATS_TEST_DIRNAME}"'/../codersync"
    SSH_TARGET="devbox.example.com"
    CONFIG_DIR="'"$CONFIG_DIR"'"
    REGISTRY="'"$REGISTRY"'"
    restore_all
  '
  [ "$status" -ne 0 ]
  [ ! -d "$CONFIG_DIR/id.lock" ]
  chmod 644 "$REGISTRY"
}

@test "kill_sessions: fails clearly, before killing anything, when id.lock is already held" {
  # Regression test: id.lock used to be acquired only around the final
  # registry cleanup, AFTER remote_kill_session had already run --
  # meaning a concurrent creation could reuse and re-mark-pending (or
  # even fully recreate as live again) the exact row this cleanup was
  # about to drop, since nothing blocked it from starting during the
  # kill itself. Locked across the WHOLE operation now, proven here by
  # holding id.lock from before this even starts: if the lock still
  # only covered the cleanup, ssh would get called (list-sessions, then
  # the kill itself) and "Killing:" would appear before the eventual
  # lock failure at the end -- confirmed live, a targeted kill left
  # registry_bytes=0 with a fresh pending marker for the row it had
  # just dropped.
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t1-devbox-example-com-foo\n' > "$REGISTRY"
  mkdir -p "$CONFIG_DIR/id.lock"
  # shellcheck disable=SC2329 # invoked indirectly, by kill_sessions below.
  ssh() { echo "unexpected: $*" >> "$BATS_TEST_TMPDIR/unexpected_ssh_calls"; }
  run kill_sessions "1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"couldn't acquire the session-ID lock"* ]]
  [[ "$output" != *"Killing:"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/unexpected_ssh_calls" ]
}

@test "kill_all_sessions: fails clearly, before killing anything, when id.lock is already held" {
  # Same regression as kill_sessions above, for --kill-all. The lock is
  # acquired only after the confirmation prompt (not held across a wait
  # on human input), but before the first remote_kill_session call --
  # ssh is stubbed to return the live list (needed so `matches` is
  # non-empty and the prompt is even reached), and the reply is "y", so
  # if the lock were still only around the final cleanup, killing would
  # proceed before the eventual lock failure.
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t1-devbox-example-com-foo\n' > "$REGISTRY"
  mkdir -p "$CONFIG_DIR/id.lock"
  # shellcheck disable=SC2329 # invoked indirectly, by kill_all_sessions.
  ssh() {
    if [[ "$*" == *"list-sessions"* ]]; then
      printf 'pair-1-devbox-example-com-foo\n'
    else
      echo "unexpected: $*" >> "$BATS_TEST_TMPDIR/unexpected_ssh_calls"
    fi
  }
  run kill_all_sessions <<<"y"
  [ "$status" -eq 1 ]
  [[ "$output" == *"couldn't acquire the session-ID lock"* ]]
  [[ "$output" != *"Killing:"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/unexpected_ssh_calls" ]
}

@test "kill_sessions: releases id.lock even when the final registry write fails" {
  # Regression test: no trap around the acquire-lock/kill/write
  # sequence -- a write failure (or Ctrl-C) after the kill but before
  # the explicit release left id.lock behind, blocking every later
  # id.lock operation for 5s. Forces the final write to fail (a
  # read-only $REGISTRY) to prove the trap, not the normal code path,
  # is what releases the lock here.
  #
  # Run in a genuinely separate `bash -c` subshell, NOT via bats' `run`
  # on the function directly -- same reason as mark_pending's test
  # above (bats' `run` suppresses errexit, so it would never actually
  # trigger the `set -e` exit this test exists to cover). The `ssh`
  # stub is exported so the subshell's own `source codersync` (which
  # doesn't define `ssh` itself, unlike remote_setup_tmux_mode etc.)
  # still sees it.
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t1-devbox-example-com-foo\n' > "$REGISTRY"
  chmod 444 "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by kill_sessions below.
  ssh() {
    if [[ "$*" == *"list-sessions"* ]]; then
      printf 'pair-1-devbox-example-com-foo\n'
    fi
  }
  export -f ssh
  run bash -c '
    set -euo pipefail
    source "'"${BATS_TEST_DIRNAME}"'/../codersync"
    SSH_TARGET="devbox.example.com"
    CONFIG_DIR="'"$CONFIG_DIR"'"
    REGISTRY="'"$REGISTRY"'"
    kill_sessions "1"
  '
  [ "$status" -ne 0 ]
  [ ! -d "$CONFIG_DIR/id.lock" ]
  chmod 644 "$REGISTRY"
}

@test "kill_all_sessions: releases id.lock even when the final registry write fails" {
  # See kill_sessions's identical test above for why this runs in a
  # separate `bash -c` subshell.
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t1-devbox-example-com-foo\n' > "$REGISTRY"
  chmod 444 "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by kill_all_sessions.
  ssh() {
    if [[ "$*" == *"list-sessions"* ]]; then
      printf 'pair-1-devbox-example-com-foo\n'
    fi
  }
  export -f ssh
  run bash -c '
    set -euo pipefail
    source "'"${BATS_TEST_DIRNAME}"'/../codersync"
    SSH_TARGET="devbox.example.com"
    CONFIG_DIR="'"$CONFIG_DIR"'"
    REGISTRY="'"$REGISTRY"'"
    kill_all_sessions <<<"y"
  '
  [ "$status" -ne 0 ]
  [ ! -d "$CONFIG_DIR/id.lock" ]
  chmod 644 "$REGISTRY"
}

# --- all_registry_targets / restore_all_all_targets ----------------------

@test "all_registry_targets: enumerates each distinct target exactly once" {
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'boxA\t1-boxA-foo\nboxB\t2-boxB-bar\nboxA\t3-boxA-baz\n' > "$REGISTRY"
  result="$(all_registry_targets)"
  [ "$(printf '%s\n' "$result" | wc -l | tr -d ' ')" -eq 2 ]
  [[ "$result" == *"boxA"* ]]
  [[ "$result" == *"boxB"* ]]
}

@test "all_registry_targets: empty registry yields nothing" {
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  : > "$REGISTRY"
  [ -z "$(all_registry_targets)" ]
}

@test "all_registry_targets: skips an option-shaped poisoned target instead of emitting it" {
  # Regression test: a normal restore_all/list_all_sessions run only
  # ever touches the SINGLE currently-configured target, which was
  # already validated once by --setup or by -T's own load_config check
  # before ever reaching a real ssh call. --all-targets loops targets
  # pulled straight out of the registry instead, with no such
  # guarantee -- a poisoned or legacy-malformed line could have an
  # option-shaped string like "-oProxyCommand=sh" as its target field,
  # which would otherwise reach `ssh` as a bare positional argument and
  # get read as ssh's OWN option instead of a hostname (confirmed live:
  # this is exactly how a stale registry row turns into arbitrary
  # remote command execution). The poisoned target must never appear in
  # the ENUMERATED output (stdout, what callers actually loop over) --
  # the warning naming it on stderr is fine, that's diagnostic text, not
  # something fed back into another command.
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'boxA\t1-boxA-foo\n-oProxyCommand=sh\t2-bad-bar\n' > "$REGISTRY"
  stdout_only="$(all_registry_targets 2>/dev/null)"
  warning="$(all_registry_targets 2>&1 >/dev/null)"
  [[ "$stdout_only" == *"boxA"* ]]
  [[ "$stdout_only" != *"ProxyCommand"* ]]
  [[ "$warning" == *"Skipping invalid/unsafe registry target"* ]]
}

@test "all_registry_targets: skips a target with an internal option-injection character" {
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'good.example.com\t1-good-foo\nbad=target\t2-bad-bar\n' > "$REGISTRY"
  stdout_only="$(all_registry_targets 2>/dev/null)"
  [[ "$stdout_only" == *"good.example.com"* ]]
  [[ "$stdout_only" != *"bad=target"* ]]
}

@test "restore_all_all_targets: never passes a poisoned registry target to ssh" {
  # End-to-end version of all_registry_targets's own poisoned-target
  # tests above: confirms the injection vector is actually closed at
  # the point that matters (ssh is never invoked with the bad value at
  # all), not just that the enumerator's output looks right in
  # isolation.
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  printf 'boxA\t1-boxA-foo\n-oProxyCommand=sh\t2-bad-bar\n' > "$REGISTRY"
  SSH_TARGET="boxA"
  TARGET_LABEL="boxa"
  # shellcheck disable=SC2329 # invoked indirectly, by restore_all_all_targets below.
  ssh() {
    echo "ssh-called-with:$*" >> "$BATS_TEST_TMPDIR/ssh_calls"
    [[ "$*" == *"list-sessions"* ]] && printf 'pair-1-boxA-foo\n'
    return 0
  }
  # shellcheck disable=SC2329 # invoked indirectly, by restore_all_all_targets below.
  remote_setup_tmux_mode() { :; }
  # shellcheck disable=SC2329 # invoked indirectly, by restore_all_all_targets below.
  open_tab_tmux_mode() { :; }
  run restore_all_all_targets
  [ "$status" -eq 0 ]
  [[ "$output" == *"boxA"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/ssh_calls" ] || [[ "$(cat "$BATS_TEST_TMPDIR/ssh_calls")" != *"ProxyCommand"* ]]
  # The poisoned row is left in the registry untouched -- not pruned as
  # "unreachable" (it was never even attempted), not silently dropped
  # either.
  [[ "$(cat "$REGISTRY")" == *"ProxyCommand"* ]]
}

@test "restore_all_all_targets: skips an unreachable target instead of pruning its entries" {
  # Regression test for the exact risk restore_all_all_targets exists to
  # avoid: restore_all itself treats an empty/failed live-session query
  # the same as "genuinely no live sessions" -- correct for a single
  # actively-configured target, but looping over every box in history
  # makes an unreachable (not dead) box far more likely. Without the
  # reachability pre-check, boxB's entry here would have been silently
  # pruned just because the box couldn't be reached this run.
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  printf 'boxA\t1-boxA-foo\nboxB\t2-boxB-bar\n' > "$REGISTRY"
  SSH_TARGET="boxA"
  TARGET_LABEL="boxa"
  # shellcheck disable=SC2329 # invoked indirectly, by restore_all_all_targets below.
  ssh() {
    if [[ "$*" == *"list-sessions"* ]]; then
      [[ "$*" == *"boxA"* ]] && printf 'pair-1-boxA-foo\n'
      return 0
    fi
    [[ "$*" == *"boxB"* ]] && return 1
    return 0
  }
  # shellcheck disable=SC2329 # invoked indirectly, by restore_all_all_targets below.
  remote_setup_tmux_mode() { echo "remote_setup_tmux_mode:$1"; }
  # shellcheck disable=SC2329 # invoked indirectly, by restore_all_all_targets below.
  open_tab_tmux_mode() { echo "open_tab_tmux_mode:$1"; }
  run restore_all_all_targets
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping boxB: unreachable."* ]]
  [[ "$output" == *"=== boxA ==="* ]]
  [[ "$output" == *"remote_setup_tmux_mode:1-boxA-foo"* ]]
  # The unreachable target's entry survives untouched -- not pruned.
  [[ "$(cat "$REGISTRY")" == *"boxB"* ]]
}

@test "restore_all_all_targets: restores an already-reachable target normally" {
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  printf 'boxA\t1-boxA-foo\n' > "$REGISTRY"
  SSH_TARGET="boxA"
  TARGET_LABEL="boxa"
  # shellcheck disable=SC2329 # invoked indirectly, by restore_all_all_targets below.
  ssh() {
    [[ "$*" == *"list-sessions"* ]] && printf 'pair-1-boxA-foo\n'
    return 0
  }
  # shellcheck disable=SC2329 # invoked indirectly, by restore_all_all_targets below.
  remote_setup_tmux_mode() { :; }
  # shellcheck disable=SC2329 # invoked indirectly, by restore_all_all_targets below.
  open_tab_tmux_mode() { :; }
  run restore_all_all_targets
  [ "$status" -eq 0 ]
  [[ "$output" == *"=== boxA ==="* ]]
  [[ "$output" == *"Restored 1 session(s)."* ]]
}

@test "restore_all_all_targets: restores SSH_TARGET/TARGET_LABEL after looping" {
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  printf 'boxA\t1-boxA-foo\n' > "$REGISTRY"
  SSH_TARGET="original.example.com"
  TARGET_LABEL="original-example-com"
  # shellcheck disable=SC2329 # invoked indirectly, by restore_all_all_targets below.
  ssh() {
    [[ "$*" == *"list-sessions"* ]] && printf 'pair-1-boxA-foo\n'
    return 0
  }
  # shellcheck disable=SC2329 # invoked indirectly, by restore_all_all_targets below.
  remote_setup_tmux_mode() { :; }
  # shellcheck disable=SC2329 # invoked indirectly, by restore_all_all_targets below.
  open_tab_tmux_mode() { :; }
  restore_all_all_targets >/dev/null
  [ "$SSH_TARGET" = "original.example.com" ]
  [ "$TARGET_LABEL" = "original-example-com" ]
}

@test "restore_all_all_targets: reports clearly when the registry has no known targets" {
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  : > "$REGISTRY"
  SSH_TARGET="boxA"
  TARGET_LABEL="boxa"
  run restore_all_all_targets
  [ "$status" -eq 0 ]
  [[ "$output" == *"No known targets in the registry yet."* ]]
}

# --- list_all_sessions_all_targets ----------------------------------------

@test "list_all_sessions_all_targets: skips an unreachable target" {
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  printf 'boxA\t1-boxA-foo\nboxB\t2-boxB-bar\n' > "$REGISTRY"
  SSH_TARGET="boxA"
  TARGET_LABEL="boxa"
  # shellcheck disable=SC2329 # invoked indirectly, by list_all_sessions_all_targets below.
  ssh() {
    if [[ "$*" == *"list-sessions"* ]]; then
      [[ "$*" == *"boxA"* ]] && printf 'pair-1-boxA-foo\n'
      return 0
    fi
    [[ "$*" == *"boxB"* ]] && return 1
    return 0
  }
  run list_all_sessions_all_targets
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping boxB: unreachable."* ]]
  [[ "$output" == *"=== boxA ==="* ]]
  [[ "$output" == *"tmux"*"foo"* ]]
}

@test "list_all_sessions_all_targets: reports clearly when the registry has no known targets" {
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  : > "$REGISTRY"
  SSH_TARGET="boxA"
  TARGET_LABEL="boxa"
  run list_all_sessions_all_targets
  [ "$status" -eq 0 ]
  [[ "$output" == *"No known targets in the registry yet."* ]]
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

@test "attach_session: matches a name by typing it with spaces the same as it was created with" {
  # resolve_registered_session normalizes its lookup argument the same
  # way session creation does, so `--attach "my local feature"` finds a
  # session actually named my-local-feature without the caller needing
  # to remember it was auto-hyphenated at creation time.
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
  run attach_session "my local feature"
  [ "$status" -eq 0 ]
  [[ "$output" == *"remote_setup_tmux_mode:my-local-feature"* ]]
}

@test "attach_session: does not silently attach the wrong session when the lookup argument has an embedded newline" {
  # Regression test for the reviewer-reported repro: `codersync --attach
  # $'safe\nother'` used to attach whatever session was actually named
  # "safe", silently discarding "other" instead of folding the newline
  # into '-' (like every other whitespace char) and looking up
  # "safe-other" -- a real risk of resolving/mutating the wrong
  # session, not just a cosmetic truncation. A registry with a "safe"
  # entry but NOT a "safe-other" one, looked up with the newline-joined
  # name, must fail to match "safe" rather than silently succeeding.
  SSH_TARGET="devbox.example.com"
  TARGET_LABEL="devbox-example-com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\tsafe\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by attach_session below.
  ssh() { [[ "$*" == *"list-sessions"* ]] && printf 'pair-safe\n'; }
  local arg
  arg="$(printf 'safe\nother')"
  run attach_session "$arg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no session named 'safe-other'"* ]]
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

@test "attach_session: errors on duplicate registry entries for the same ID instead of picking one" {
  # Regression test: a leftover pair of entries from the PRIOR version
  # of the leading-zero bug (e.g. both "8-devbox-example-com-foo" and
  # "08-devbox-example-com-foo" registered, only one of them actually
  # still live) used to make this just return whichever happened to be
  # first on disk -- --list-all correctly showed the live one, but
  # --attach on the shared ID resolved the OTHER, stale entry and
  # reported it as "registered but not alive" (confirmed live). Errors
  # instead of guessing, pointing at --restore-all to resolve the
  # duplication first.
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t8-devbox-example-com-foo\ndevbox.example.com\t08-devbox-example-com-foo\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by attach_session below.
  ssh() { echo "unexpected: $*" >> "$BATS_TEST_TMPDIR/unexpected_ssh_calls"; }
  run attach_session "8"
  [ "$status" -eq 1 ]
  [[ "$output" == *"multiple registry entries match ID 8"* ]]
  [[ "$output" == *"--restore-all"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/unexpected_ssh_calls" ]
}

@test "attach_session: errors on duplicate registry entries for the same name instead of picking one" {
  # Same duplicate scenario as above, but reached via the labeled-name
  # lookup instead of the numeric-ID one -- both entries share the
  # exact same PARSED_REST ("devbox-example-com-foo"), differing only
  # in their own id's raw formatting.
  SSH_TARGET="devbox.example.com"
  TARGET_LABEL="devbox-example-com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t8-devbox-example-com-foo\ndevbox.example.com\t08-devbox-example-com-foo\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by attach_session below.
  ssh() { echo "unexpected: $*" >> "$BATS_TEST_TMPDIR/unexpected_ssh_calls"; }
  run attach_session "foo"
  [ "$status" -eq 1 ]
  [[ "$output" == *"multiple registry entries match 'foo'"* ]]
  [[ "$output" == *"--restore-all"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/unexpected_ssh_calls" ]
}

@test "attach_session: exact duplicate lines don't count as ambiguous, by ID" {
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t08-devbox-example-com-foo\ndevbox.example.com\t08-devbox-example-com-foo\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by attach_session below.
  ssh() { [[ "$*" == *"list-sessions"* ]] && printf 'pair-08-devbox-example-com-foo\n'; }
  # shellcheck disable=SC2329 # invoked indirectly, by attach_session below.
  remote_setup_tmux_mode() { echo "remote_setup_tmux_mode:$1"; }
  # shellcheck disable=SC2329 # invoked indirectly, by attach_session below.
  open_tab_tmux_mode() { echo "open_tab_tmux_mode:$1"; }
  run attach_session "8"
  [ "$status" -eq 0 ]
  [[ "$output" == *"remote_setup_tmux_mode:08-devbox-example-com-foo"* ]]
}

@test "attach_session: exact duplicate lines don't count as ambiguous, by name" {
  SSH_TARGET="devbox.example.com"
  TARGET_LABEL="devbox-example-com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t08-devbox-example-com-foo\ndevbox.example.com\t08-devbox-example-com-foo\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by attach_session below.
  ssh() { [[ "$*" == *"list-sessions"* ]] && printf 'pair-08-devbox-example-com-foo\n'; }
  # shellcheck disable=SC2329 # invoked indirectly, by attach_session below.
  remote_setup_tmux_mode() { echo "remote_setup_tmux_mode:$1"; }
  # shellcheck disable=SC2329 # invoked indirectly, by attach_session below.
  open_tab_tmux_mode() { echo "open_tab_tmux_mode:$1"; }
  run attach_session "foo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"remote_setup_tmux_mode:08-devbox-example-com-foo"* ]]
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

@test "rename_session: replaces spaces in the new name with dashes instead of rejecting it" {
  # The registry's existing entry already matches what "my new name"
  # normalizes to, so this reaches the fast, network-free
  # already-named-that exit right after the substitution notice prints,
  # keeping this test in the argument-validation-only style used
  # throughout this section.
  SSH_TARGET="devbox.example.com"
  # shellcheck disable=SC2034 # read by rename_session below, to build
  # the candidate new_entry_name it then compares against old_entry_name.
  TARGET_LABEL="devbox-example-com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t1-devbox-example-com-my-new-name\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by rename_session below.
  ssh() { echo "unexpected: $*" >> "$BATS_TEST_TMPDIR/unexpected_ssh_calls"; }
  run rename_session "1" "my new name"
  [ "$status" -eq 1 ]
  [[ "$output" == *"using 'my-new-name'"* ]]
  [[ "$output" == *"already named 'my-new-name'"* ]]
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

@test "list_all_sessions: does not show a live session whose raw text differs from a canonically-matching entry" {
  # End-to-end regression test for the reviewer-reported repro: a
  # registry entry "08-devbox-example-com-foo" (canonical id=8) used to
  # authorize an unrelated live "pair-8-devbox-example-com-foo" (also
  # canonical id=8, but never actually registered under that raw
  # text), showing it in --list-all as if it were the managed session.
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t08-devbox-example-com-foo\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by list_all_sessions below.
  ssh() { [[ "$*" == *"list-sessions"* ]] && printf 'pair-8-devbox-example-com-foo\n'; }
  run list_all_sessions
  [ "$status" -eq 0 ]
  [[ "$output" != *"devbox-example-com-foo"* ]]
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

@test "local_setup: replaces spaces in the session name with dashes instead of rejecting it" {
  # --tools with no value errors before any real tmux call, so this
  # stays within the argument-validation-only scope of this section
  # while still exercising the notice + normalized name.
  run local_setup "my session" --tools
  [ "$status" -eq 1 ]
  [[ "$output" == *"using 'my-session'"* ]]
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
  # Stubbed so this test doesn't depend on claude/codex actually being
  # installed wherever it runs -- "true" is a real, universally
  # available command, so local_setup's own `command -v "$bin1"`/
  # `"$bin2"` existence check passes regardless of environment,
  # letting execution reach the tmux calls this test actually cares
  # about. Confirmed live: this test passed on a machine with
  # claude/codex installed but failed in CI (neither installed there),
  # exiting early with "not found on <host>: claude codex" instead of
  # ever reaching has-session/new-session at all.
  # shellcheck disable=SC2329 # invoked indirectly, by local_setup below.
  command_word_for() { echo "true"; }
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

@test "adopt_sessions: refuses a lone claude- half with no matching codex- counterpart" {
  # Regression test: a real codersync-created iterm session always
  # creates claude-X and codex-X together (remote_setup's own
  # all-or-nothing rollback never leaves just one behind on a fresh
  # create), so a lone "claude-my-orphan" with no "codex-my-orphan" at
  # all is either the surviving half of a pair whose other side was
  # killed separately, or an unrelated live session that merely
  # happens to start with "claude-". Registering it anyway made
  # --adopt report success for something --attach immediately refused
  # as "only one side alive" (confirmed live), and made it trivial to
  # accidentally pull an unrelated claude-*/codex-* session into the
  # registry.
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  : > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by adopt_sessions below.
  ssh() { [[ "$*" == *"list-sessions"* ]] && printf 'claude-my-orphan\n'; }
  run adopt_sessions
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping 'claude-my-orphan'"* ]]
  [[ "$output" != *"Adopted"* ]]
  [ ! -s "$REGISTRY" ]
}

@test "adopt_sessions: refuses a lone codex- half with no matching claude- counterpart" {
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  : > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by adopt_sessions below.
  ssh() { [[ "$*" == *"list-sessions"* ]] && printf 'codex-my-orphan\n'; }
  run adopt_sessions
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping 'codex-my-orphan'"* ]]
  [[ "$output" != *"Adopted"* ]]
  [ ! -s "$REGISTRY" ]
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

@test "adopt_sessions: refuses an iterm pair whose two sides disagree on raw ID formatting" {
  # Regression test: the dedup key (kind:live_id:live_rest) is
  # canonical, but the OLD code registered whichever raw text the
  # FIRST-encountered line happened to have, silently dropping the
  # other side's raw text via that same dedup -- so
  # "claude-08-devbox-example-com-foo" alongside
  # "codex-8-devbox-example-com-foo" (same canonical id=8, but
  # disagreeing raw text) registered only "08-devbox-example-com-foo".
  # --attach 8 afterward found the registered entry's claude- side
  # (grep for "claude-08-...") but not its codex- side (grep for
  # "codex-08-...", which never matches the actual live
  # "codex-8-..."), reporting a genuinely fully-live pair as half dead
  # (confirmed live). The NORMAL claude-X/codex-X pair has IDENTICAL
  # raw text on both sides, so this must NOT fire for that case (see
  # the "registers ... as ONE entry" test above).
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  : > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by adopt_sessions below.
  ssh() {
    if [[ "$*" == *"list-sessions"* ]]; then
      printf 'claude-08-devbox-example-com-foo\ncodex-8-devbox-example-com-foo\n'
    fi
  }
  run adopt_sessions
  [ "$status" -eq 0 ]
  [[ "$output" != *"Adopted"* ]]
  [ ! -s "$REGISTRY" ]
}

@test "adopt_sessions: refuses two separate tmux-mode sessions that canonicalize to the same id/rest" {
  # Regression test: unlike an iterm pair (two lines are EXPECTED for
  # one logical session), tmux mode has exactly one live "pair-"
  # session per logical session -- so "pair-08-devbox-example-com-foo"
  # and "pair-8-devbox-example-com-foo" existing together are two
  # GENUINELY SEPARATE, unrelated live sessions that merely collide
  # once canonicalized. The old dedup key (canonical id+rest) treated
  # the second as "already seen" and silently dropped it entirely --
  # worse, once the first was registered, session_is_owned's own
  # canonical matching meant --kill on that shared ID would kill BOTH
  # live sessions even though only one was ever actually adopted
  # (confirmed live).
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  NEXT_ID_FILE="$CONFIG_DIR/next_id"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  : > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by adopt_sessions below.
  ssh() {
    if [[ "$*" == *"list-sessions"* ]]; then
      printf 'pair-08-devbox-example-com-foo\npair-8-devbox-example-com-foo\n'
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
  session_is_owned "devbox-review-sam-1746"
}

@test "session_is_owned: true for a matching entry even when the registry has no trailing newline" {
  # Regression test: see find_or_assign_id's identical test for the
  # general shape of this bug (a `while IFS= read -r line; do ...` loop
  # over $REGISTRY silently drops the file's final line if it doesn't
  # end in a newline). If that final, unseen line happens to be the
  # only entry matching this session, it's wrongly treated as unowned.
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf '%s' "devbox.example.com"$'\t'"devbox-review-sam-1746" > "$REGISTRY"
  session_is_owned "devbox-review-sam-1746"
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
  run ! session_is_owned "programming"
}

@test "session_is_owned: false for an entry belonging to a different target" {
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'some-other-box\tprogramming\n' > "$REGISTRY"
  run ! session_is_owned "programming"
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
  run ! session_is_owned "0-host-foo"
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
  run ! session_is_owned "1-host-unregistered"
}

@test "session_is_owned: true for an IDed session with a matching registry entry" {
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t1-devbox-example-com-foo\n' > "$REGISTRY"
  session_is_owned "1-devbox-example-com-foo"
}

@test "session_is_owned: an ID must match the entry's own ID too, not just the rest" {
  # A registry entry's rest matching isn't enough on its own -- the ID
  # has to match too, otherwise a valid-but-different-id entry could
  # authorize a session under the wrong id.
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t2-devbox-example-com-foo\n' > "$REGISTRY"
  run ! session_is_owned "1-devbox-example-com-foo"
}

@test "session_is_owned: false for a different raw spelling that canonicalizes to the same id/rest" {
  # Regression test: this used to compare CANONICAL id+rest, so a
  # registry entry "08-devbox-example-com-foo" (canonical id=8) wrongly
  # authorized an unrelated live "pair-8-devbox-example-com-foo" (also
  # canonical id=8, but different raw text, and never actually
  # registered). Confirmed live: --list-all showed the unregistered
  # live session as managed, --attach on it then failed
  # ("registered but not alive", since --attach's OWN lookup already
  # compared raw text correctly and found no match), and --kill on the
  # shared canonical ID killed the live session and deleted the
  # unrelated registry entry it happened to collide with. Ownership
  # must mean "this exact raw text is registered", not "some entry
  # canonicalizes to the same number."
  SSH_TARGET="devbox.example.com"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t08-devbox-example-com-foo\n' > "$REGISTRY"
  run ! session_is_owned "8-devbox-example-com-foo"
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
  CONFIG_DIR="$BATS_TEST_TMPDIR"
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
  CONFIG_DIR="$BATS_TEST_TMPDIR"
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
  CONFIG_DIR="$BATS_TEST_TMPDIR"
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

@test "kill_all_sessions: only removes registry entries for sessions it actually killed" {
  # Regression test: the registry cleanup at the end of kill_all_sessions
  # used to drop EVERY current-target entry unconditionally, not just
  # the ones matching a session actually just killed. Here only ID 3 is
  # live (and gets killed); ID 5 is registered for the same target but
  # has no live tmux session (e.g. a creation still in flight, or a
  # legitimately-preserved half-alive pair) -- it must survive.
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t3-devbox-example-com-foo\ndevbox.example.com\t5-devbox-example-com-bar\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by kill_all_sessions.
  ssh() {
    if [[ "$*" == *"list-sessions"* ]]; then
      printf 'pair-3-devbox-example-com-foo\n'
    fi
  }
  run kill_all_sessions <<<"y"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Killed 1 session(s)."* ]]
  [[ "$(cat "$REGISTRY")" != *"3-devbox-example-com-foo"* ]]
  [[ "$(cat "$REGISTRY")" == *"5-devbox-example-com-bar"* ]]
}

@test "kill_sessions: does not kill an unrelated session sharing the requested ID" {
  # Regression test: --kill <id> matched ANY live session with that
  # exact numeric ID, regardless of whether it was ever registered --
  # confirmed live, an unrelated session literally named
  # "pair-1-not-codersync" was killed by `--kill 1`.
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
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
  CONFIG_DIR="$BATS_TEST_TMPDIR"
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
  CONFIG_DIR="$BATS_TEST_TMPDIR"
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
  CONFIG_DIR="$BATS_TEST_TMPDIR"
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
  CONFIG_DIR="$BATS_TEST_TMPDIR"
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

@test "kill_sessions: does not kill a live session whose raw text differs from a canonically-matching entry" {
  # End-to-end regression test for the reviewer-reported repro: unlike
  # the test above (registry AND live raw text both "08-...", a
  # legitimate match), a registry entry "08-devbox-example-com-foo"
  # must NOT authorize killing an unrelated live
  # "pair-8-devbox-example-com-foo" that merely canonicalizes to the
  # same ID -- confirmed live, --kill 8 used to kill that unrelated
  # live session and then delete the "08-..." registry entry it
  # happened to collide with, even though that session was never
  # actually registered.
  SSH_TARGET="devbox.example.com"
  CONFIG_DIR="$BATS_TEST_TMPDIR"
  REGISTRY="$BATS_TEST_TMPDIR/registry"
  printf 'devbox.example.com\t08-devbox-example-com-foo\n' > "$REGISTRY"
  # shellcheck disable=SC2329 # invoked indirectly, by kill_sessions.
  ssh() {
    if [[ "$*" == *"list-sessions"* ]]; then
      printf 'pair-8-devbox-example-com-foo\n'
    fi
  }
  run kill_sessions "8"
  [[ "$output" == *"no session found for ID 8"* ]]
  [[ "$output" != *"Killing:"* ]]
  [[ "$(cat "$REGISTRY")" == "devbox.example.com"$'\t'"08-devbox-example-com-foo" ]]
}

# --- dispatch: session-creation lifecycle ordering ----------------------

@test "dispatch: mark_pending is written before id.lock is released, not after" {
  # Regression test: mark_pending used to be called AFTER release_id_lock
  # in the creation path's dispatch case, leaving a gap where the
  # registry had the new entry but no pending marker existed yet for
  # restore_all/kill_all_sessions to respect -- confirmed live,
  # --restore-all deleted a freshly-registered entry in exactly that
  # gap. The creation path is inline dispatch code, not a sourced
  # function (see the other dispatch: tests above/below, which run the
  # real script as a subprocess for the same reason), so it can't be
  # driven directly through a stubbed remote_setup the way
  # restore_all/kill_all_sessions are elsewhere in this file. This
  # instead asserts the source-order invariant the actual fix depends
  # on: mark_pending's call site occurs before the release_id_lock that
  # follows it.
  script="${BATS_TEST_DIRNAME}/../codersync"
  # shellcheck disable=SC2016 # single-quoted on purpose: matching the
  # literal text `$SESSION` in codersync's own source, not expanding it.
  mark_line="$(grep -n '^[[:space:]]*mark_pending "\$SESSION"$' "$script" | head -1 | cut -d: -f1)"
  [ -n "$mark_line" ]
  release_line="$(awk -v start="$mark_line" 'NR > start && /^[[:space:]]*release_id_lock$/ { print NR; exit }' "$script")"
  [ -n "$release_line" ]
  [ "$mark_line" -lt "$release_line" ]
}

@test "dispatch: clear_pending's cleanup trap absorbs its own failure so release_id_lock still runs" {
  # Regression test: the dispatch case's cleanup trap used to be the
  # bare semicolon chain `clear_pending "$SESSION"; release_id_lock`.
  # If clear_pending itself failed (e.g. a failed rewrite) while this
  # trap was firing, `set -e` abandons the REST of that same trap
  # string too -- release_id_lock never ran, leaving id.lock behind
  # (confirmed live: reproduced with both id.lock AND pending.lock left
  # behind). Confirmed in isolation too: a plain `false; echo
  # never_runs` as a trap body never prints never_runs under set -e --
  # a failing first command aborts everything after it in the same
  # trap string, trap chaining or not. `|| true` right after
  # clear_pending absorbs its own exit status so release_id_lock is
  # unconditionally reached regardless of whether clear_pending
  # succeeded. This is inline dispatch code, not a sourced function
  # (see the mark_pending ordering test above for the same reason), so
  # this asserts the source text directly rather than driving it.
  script="${BATS_TEST_DIRNAME}/../codersync"
  # shellcheck disable=SC2016 # single-quoted on purpose: matching the
  # literal text `$SESSION` in codersync's own source, not expanding it.
  grep -qF 'clear_pending "$SESSION" || true; release_id_lock' "$script"
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

@test "dispatch: --setup rejects --remote-dir instead of silently discarding it" {
  # Regression test: --setup has its OWN positional [remote-dir]
  # argument, syntactically unrelated to the new global --remote-dir
  # flag -- but the global pre-pass plucks "--remote-dir <value>" out
  # of "$@" for EVERY command, before the dispatch case (or --setup's
  # own arity check) ever sees it. `codersync --setup host
  # --remote-dir /work` used to silently write REMOTE_DIR=~ instead of
  # /work: by the time --setup ran, "--remote-dir /work" was already
  # gone from "$@", with no error pointing at what happened to those
  # two tokens, and --setup's own "at most 2 arguments" check never
  # even got a chance to catch the mismatch since the argument count
  # had already been silently reduced (confirmed live). Checked before
  # any network access, so this never touches a real box or config.
  run "${BATS_TEST_DIRNAME}/../codersync" --setup host --remote-dir /work
  [ "$status" -eq 1 ]
  [[ "$output" == *"doesn't support -T/--target or --remote-dir"* ]]
}

@test "dispatch: --setup rejects -T instead of silently discarding it" {
  run "${BATS_TEST_DIRNAME}/../codersync" -T otherbox.example.com --setup host
  [ "$status" -eq 1 ]
  [[ "$output" == *"doesn't support -T/--target or --remote-dir"* ]]
}

@test "dispatch: --local rejects --remote-dir instead of silently discarding it" {
  # --local never touches SSH_TARGET/REMOTE_DIR at all (see
  # local_setup's own comment) -- there's no remote-dir concept for it
  # whatsoever, so silently swallowing this flag would be even more
  # confusing than for --setup.
  run "${BATS_TEST_DIRNAME}/../codersync" --local foo --remote-dir /work
  [ "$status" -eq 1 ]
  [[ "$output" == *"doesn't support -T/--target or --remote-dir"* ]]
}

@test "dispatch: --local rejects -T instead of silently discarding it" {
  run "${BATS_TEST_DIRNAME}/../codersync" -T otherbox.example.com --local foo
  [ "$status" -eq 1 ]
  [[ "$output" == *"doesn't support -T/--target or --remote-dir"* ]]
}

@test "dispatch: --setup with no -T/--remote-dir at all still works normally" {
  # Baseline: confirms the new rejection check doesn't fire on an
  # ordinary --setup invocation that never mentioned either flag. ssh
  # is stubbed to fail cleanly (no real network call) so this fails on
  # connectivity instead, not on the new check -- distinguished by
  # message content.
  # shellcheck disable=SC2329 # invoked indirectly, by the subprocess below.
  ssh() { return 1; }
  export -f ssh
  run bash -c '
    set -euo pipefail
    "'"${BATS_TEST_DIRNAME}"'/../codersync" --setup somehost.example.com
  '
  [ "$status" -eq 1 ]
  [[ "$output" != *"doesn't support -T/--target or --remote-dir"* ]]
  [[ "$output" == *"Could not reach"* ]]
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

@test "dispatch: --restore-all --all-targets rejects extra trailing arguments" {
  # --all-targets is consumed as ITS OWN recognized flag, not just
  # counted against the arity limit -- confirms a genuine extra
  # argument AFTER --all-targets is still rejected, not silently
  # absorbed the same way --all-targets itself is.
  run "${BATS_TEST_DIRNAME}/../codersync" --restore-all --all-targets extra
  [ "$status" -eq 1 ]
  [[ "$output" == *"got extra"* ]]
}

@test "dispatch: --list-all rejects extra trailing arguments" {
  run "${BATS_TEST_DIRNAME}/../codersync" --list-all extra
  [ "$status" -eq 1 ]
  [[ "$output" == *"got extra"* ]]
}

@test "dispatch: --list-all --all-targets rejects extra trailing arguments" {
  run "${BATS_TEST_DIRNAME}/../codersync" --list-all --all-targets extra
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

# --- dispatch: -T/--target, --remote-dir, --check-dependencies ----------

@test "dispatch: -T requires a value" {
  run "${BATS_TEST_DIRNAME}/../codersync" -T
  [ "$status" -eq 1 ]
  [[ "$output" == *"-T requires a value"* ]]
}

@test "dispatch: --target requires a value, doesn't swallow the next flag as its value" {
  # Same "swallowing" bug class already guarded against for --tools/
  # --split-mode elsewhere in this file: without the `"$2" == -*` check,
  # `--target --list-all` would treat "--list-all" as -T's OWN value
  # instead of erroring, leaving no subcommand at all.
  run "${BATS_TEST_DIRNAME}/../codersync" --target --list-all
  [ "$status" -eq 1 ]
  [[ "$output" == *"--target requires a value"* ]]
}

@test "dispatch: --remote-dir requires a value" {
  run "${BATS_TEST_DIRNAME}/../codersync" --remote-dir
  [ "$status" -eq 1 ]
  [[ "$output" == *"--remote-dir requires a value"* ]]
}

@test "dispatch: -T with an empty value is rejected, not silently ignored" {
  # Regression test: `-T ""` has a value (an empty string), so the
  # pre-pass's own arity check (`$# -lt 2 || "$2" == -*`) doesn't catch
  # it -- it slips through as a "provided" flag with an empty value.
  # `codersync -T "" --list-all` used to just run against the
  # configured default with no error, since load_config's `-n
  # "$TARGET_OVERRIDE"` check reads an empty string the same as "-T
  # wasn't given at all" (confirmed live). Uses FAKE_HOME, not
  # CONFIG_DIR directly -- see the -T position-independence tests above
  # for why (codersync runs as a genuinely separate process here, not
  # sourced).
  FAKE_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$FAKE_HOME/.config/codersync"
  printf 'SSH_TARGET=devbox.example.com\n' > "$FAKE_HOME/.config/codersync/config"
  : > "$FAKE_HOME/.codersync_sessions"
  run bash -c '
    set -euo pipefail
    HOME="'"$FAKE_HOME"'"
    "'"${BATS_TEST_DIRNAME}"'/../codersync" -T "" --list-all
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid -T/--target"* ]]
}

@test "dispatch: --remote-dir with an empty value is rejected, not silently ignored" {
  FAKE_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$FAKE_HOME/.config/codersync"
  printf 'SSH_TARGET=devbox.example.com\n' > "$FAKE_HOME/.config/codersync/config"
  : > "$FAKE_HOME/.codersync_sessions"
  run bash -c '
    set -euo pipefail
    HOME="'"$FAKE_HOME"'"
    "'"${BATS_TEST_DIRNAME}"'/../codersync" --remote-dir "" --list-all
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid --remote-dir"* ]]
}

@test "dispatch: --setup rejects -T \"\" the same as a real -T value" {
  # Regression test: `codersync --setup host.example.com -T ""` used to
  # succeed (the empty value made SAW_TARGET_OVERRIDE's predecessor,
  # `-n "$TARGET_OVERRIDE"`, false, so the --setup/--local rejection
  # check never fired) instead of being rejected the same way a real
  # -T value is for --setup (confirmed live).
  run "${BATS_TEST_DIRNAME}/../codersync" --setup host.example.com -T ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"doesn't support -T/--target or --remote-dir"* ]]
}

@test "dispatch: -T overrides the target regardless of position (before the subcommand)" {
  # FAKE_HOME, not CONFIG_DIR/CONFIG_FILE/REGISTRY directly -- unlike
  # the sourced-function tests elsewhere in this file, codersync here
  # runs as a genuinely separate PROCESS (not sourced), and its own
  # `CONFIG_DIR="$HOME/.config/codersync"` (etc.) at the top of the
  # script unconditionally re-derives those paths from $HOME every time
  # it starts -- pre-setting CONFIG_DIR itself in the subshell below has
  # no effect on the child process at all (confirmed: first attempt at
  # this test silently read the REAL ~/.config/codersync/config instead
  # of the fake one, and only "passed" by coincidence since -T's
  # override masks whatever the config file says anyway).
  FAKE_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$FAKE_HOME/.config/codersync"
  printf 'SSH_TARGET=devbox.example.com\n' > "$FAKE_HOME/.config/codersync/config"
  : > "$FAKE_HOME/.codersync_sessions"
  # shellcheck disable=SC2329 # invoked indirectly, by the subprocess below.
  ssh() { echo "ssh-called-with:$*" >> "$BATS_TEST_TMPDIR/ssh_calls"; }
  export -f ssh
  run bash -c '
    set -euo pipefail
    HOME="'"$FAKE_HOME"'"
    "'"${BATS_TEST_DIRNAME}"'/../codersync" -T otherbox.example.com --list-all
  '
  [ "$status" -eq 0 ]
  [[ "$(cat "$BATS_TEST_TMPDIR/ssh_calls")" == *"otherbox.example.com"* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/ssh_calls")" != *"devbox.example.com"* ]]
}

@test "dispatch: -T overrides the target regardless of position (after the subcommand)" {
  # Same as above but with -T placed AFTER --list-all -- this is the
  # main reason for plucking -T out in a pre-pass before the dispatch
  # case even looks at \$1, rather than teaching each subcommand's own
  # arg parser about it individually. See the previous test's own
  # comment for why this uses FAKE_HOME rather than CONFIG_DIR directly.
  FAKE_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$FAKE_HOME/.config/codersync"
  printf 'SSH_TARGET=devbox.example.com\n' > "$FAKE_HOME/.config/codersync/config"
  : > "$FAKE_HOME/.codersync_sessions"
  # shellcheck disable=SC2329 # invoked indirectly, by the subprocess below.
  ssh() { echo "ssh-called-with:$*" >> "$BATS_TEST_TMPDIR/ssh_calls"; }
  export -f ssh
  run bash -c '
    set -euo pipefail
    HOME="'"$FAKE_HOME"'"
    "'"${BATS_TEST_DIRNAME}"'/../codersync" --list-all -T otherbox.example.com
  '
  [ "$status" -eq 0 ]
  [[ "$(cat "$BATS_TEST_TMPDIR/ssh_calls")" == *"otherbox.example.com"* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/ssh_calls")" != *"devbox.example.com"* ]]
}

@test "dispatch: without -T, the configured default target is used as before" {
  # See the -T test above for why this uses FAKE_HOME rather than
  # CONFIG_DIR directly.
  FAKE_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$FAKE_HOME/.config/codersync"
  printf 'SSH_TARGET=devbox.example.com\n' > "$FAKE_HOME/.config/codersync/config"
  : > "$FAKE_HOME/.codersync_sessions"
  # shellcheck disable=SC2329 # invoked indirectly, by the subprocess below.
  ssh() { echo "ssh-called-with:$*" >> "$BATS_TEST_TMPDIR/ssh_calls"; }
  export -f ssh
  run bash -c '
    set -euo pipefail
    HOME="'"$FAKE_HOME"'"
    "'"${BATS_TEST_DIRNAME}"'/../codersync" --list-all
  '
  [ "$status" -eq 0 ]
  [[ "$(cat "$BATS_TEST_TMPDIR/ssh_calls")" == *"devbox.example.com"* ]]
}

@test "dispatch: --check-dependencies rejects extra trailing arguments" {
  run "${BATS_TEST_DIRNAME}/../codersync" --check-dependencies extra
  [ "$status" -eq 1 ]
  [[ "$output" == *"got extra"* ]]
}

@test "dispatch: --check-dependencies works with -T, without touching the configured default" {
  # See the -T test above for why this uses FAKE_HOME rather than
  # CONFIG_DIR directly.
  FAKE_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$FAKE_HOME/.config/codersync"
  printf 'SSH_TARGET=devbox.example.com\n' > "$FAKE_HOME/.config/codersync/config"
  # shellcheck disable=SC2329 # invoked indirectly, by the subprocess below.
  ssh() { return 0; }
  export -f ssh
  run bash -c '
    set -euo pipefail
    HOME="'"$FAKE_HOME"'"
    "'"${BATS_TEST_DIRNAME}"'/../codersync" -T otherbox.example.com --check-dependencies
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"All dependency checks passed on otherbox.example.com."* ]]
  # The default target on disk is untouched by a -T-scoped command.
  [[ "$(cat "$FAKE_HOME/.config/codersync/config")" == *"devbox.example.com"* ]]
  [[ "$(cat "$FAKE_HOME/.config/codersync/config")" != *"otherbox.example.com"* ]]
}
