#!/usr/bin/env bats
#
# Unit tests for the pure-logic pieces of `codersync` -- string
# resolution/escaping/sanitization and argument parsing. Nothing here
# touches SSH, tmux, or iTerm2: those are exercised by hand against a
# real box (see README.md's "Testing" section), not by this suite.

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
