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
  [ "$result" = "codex --dangerously-bypass-approvals-and-sandbox" ]
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
  [[ "$output" == *"--tools requires a value"* ]]
}

@test "parse_run_args: --split-mode as the last argument with no value errors clearly" {
  # Regression test: this used to fail via shift 2's own error instead of
  # this function's message.
  run parse_run_args "mysession" --split-mode
  [ "$status" -eq 1 ]
  [[ "$output" == *"--split-mode requires a value"* ]]
}

@test "parse_run_args: --tools as the last argument with no value errors clearly" {
  run parse_run_args "mysession" --tools
  [ "$status" -eq 1 ]
  [[ "$output" == *"--tools requires a value"* ]]
}

@test "parse_run_args: rejects a session name containing shell metacharacters" {
  # Regression test: this exact payload created a real file on a remote
  # box before validate_session_name existed (confirmed live).
  run parse_run_args 'x; touch /tmp/pwn'
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

@test "validate_remote_dir: accepts a normal path" {
  # shellcheck disable=SC2088 # intentional: testing the literal string
  # "~/repos", not asking the test shell to expand it.
  validate_remote_dir "~/repos"
}

@test "validate_remote_dir: rejects shell metacharacters" {
  # shellcheck disable=SC2088 # intentional: testing the literal string.
  run ! validate_remote_dir '~/repos; rm -rf /'
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
