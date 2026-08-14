# codersync

Open one terminal tab, get two AI coding agents running side by side on a
remote dev box — persistent, auto-reconnecting, and outliving your laptop
closing.

```
$ codersync my-feature
```

opens a new tab split into two panes, each SSH'd into your configured
remote box, running two CLI coding agents (Claude Code and Codex by
default) inside `tmux`. Close your laptop, lose wifi, restart your
machine — the agents keep running on the remote box regardless, and
`codersync` reattaches automatically.

## Why

Running long AI coding sessions over a plain SSH terminal has a few
recurring problems: the session dies the moment your laptop sleeps or
your network blips, closing the terminal loses your place, and running
two agents side by side to compare/pair them means manually wiring up
splits and remembering exactly which flags skip the confirmation
prompts. `codersync` exists to make all of that a non-issue.

## Features

- **One command, two agents side by side** — a single terminal tab,
  split into a left/right pane, each running a different (or the same)
  CLI coding agent.
- **Survives everything** — agents run inside `tmux` on the remote box,
  not in your local terminal. Closing your laptop, a wifi blip, or a VPN
  reconnect doesn't kill the session; each pane detects the drop and
  reattaches automatically within a couple of seconds.
- **Crash recovery** — `codersync --restore-all` reopens tabs for every
  session still alive on the remote box, even if you closed your
  terminal entirely. Nothing on the box is ever lost; this just
  recreates the local view.
- **Works with any SSH-reachable box** — not tied to any specific
  cloud-dev provider. If you can `ssh` into it and it has `tmux`, it
  works.
- **Any two CLI agents, not just two** — `--tools` picks which two CLI
  agents run left/right, including the same one twice.
- **One-time setup, not per-run configuration** — `codersync --setup`
  validates connectivity and `tmux` availability once; every later
  invocation just works.
- **Two split strategies** — split server-side in `tmux` (default; opens
  the tab automatically with iTerm2, or just prints the attach command
  when it's not installed, so the remote side works with any terminal
  regardless) or split locally via iTerm2's native scripting API (lets
  you attach to just one pane independently from elsewhere, but requires
  iTerm2, no fallback).
- **Fails loudly, not silently** — a missing tool or unreachable box
  produces a clear error before anything is created, not a tab that
  quietly does nothing.

## Prerequisites

- A box reachable over `ssh` (any hostname, `user@host`, or an alias
  from your own `~/.ssh/config`) with `tmux` installed.
- At least one CLI coding agent installed on that box (see
  [Supported tools](#supported-tools) below).
- macOS, for the local side. `--split-mode tmux` (default) uses iTerm2's
  scripting API to open the tab when iTerm2 is installed, and otherwise
  prints the attach command for you to run in any terminal yourself.
  `--split-mode iterm` requires iTerm2 — there's no fallback for that
  mode, since the split itself is done via iTerm2's own API.

## Installation

```
git clone https://github.com/<you>/codersync.git
cd codersync
ln -s "$(pwd)/codersync" ~/.local/bin/codersync   # or anywhere on your PATH
```

## Quickstart

```
# One-time setup: point codersync at your box
codersync --setup devbox.example.com

# Every time after that
codersync my-feature
```

`my-feature` becomes the session name; the box name gets folded in
automatically (e.g. `devbox-example-com-my-feature`) so names stay
unambiguous if you ever point `codersync` at more than one box.

## Usage

```
codersync --setup <ssh-target> [remote-dir]
codersync <session-name> [--split-mode iterm|tmux] [--tools t1,t2] [--safe-mode]
codersync --restore-all
codersync --help
```

### `codersync --setup <ssh-target> [remote-dir]`

One-time setup. `<ssh-target>` is anything you'd pass to `ssh` directly —
a plain hostname, `user@host`, or an alias from your own `~/.ssh/config`.
`[remote-dir]` is where the agents start (default: `~/repos`).

Setup checks the box is reachable over SSH and has `tmux` installed
*before* saving anything. `codersync` has no dependency on any specific
remote/cloud-dev provider — any box reachable over plain SSH with `tmux`
works. As an optional convenience, if `<ssh-target>` matches the alias
pattern used by the [Coder](https://coder.com) platform (`coder.*`) and
its CLI is installed locally, setup will also offer to run `coder
config-ssh` for you if that alias doesn't exist yet.

Config lives at `~/.config/codersync/config`.

### `codersync <session-name> [options]`

Opens a new tab and sets up the two-agent split. Options:

- **`--split-mode tmux`** (default) — one `tmux` session with two panes
  split server-side. The local side just opens a tab and attaches once;
  with iTerm2 installed that tab opens automatically, and without it
  `codersync` prints the attach command for you to run in any terminal
  yourself instead. You can't attach to just one pane independently,
  since it's one session.
- **`--split-mode iterm`** — two separate `tmux` sessions, split locally
  by iTerm2's native scripting API. Lets you attach to just the left or
  right pane independently from elsewhere. Requires iTerm2 (plus a
  one-time Automation-permission prompt the first time it controls it).
- **`--tools t1,t2`** (default: `claude,codex`) — which two CLI agents
  run left/right. See [Supported tools](#supported-tools).
- **`--safe-mode`** — drop the auto-approve flag for known `--tools`
  keys, so normal permission prompts apply instead of the dangerous
  auto-approve default. See [Security](#security) below.

### `codersync --restore-all`

Reopens a tab for every session that's still alive on the remote box,
based on a local registry (`~/.codersync_sessions`) that every session
name gets appended to. Meant for recovering after your terminal gets
closed: nothing on the remote box was ever lost, this just recreates the
local tabs. Stale entries (sessions no longer alive) are pruned
automatically.

## Supported tools

`--tools` accepts either of these short keys (which auto-append that
tool's skip-approval flag) or a literal command for anything else:

| Key      | Resolves to                                      |
|----------|---------------------------------------------------|
| `claude` | `claude --dangerously-skip-permissions -n <session>` |
| `codex`  | `codex --dangerously-bypass-approvals-and-sandbox` |
| `agy`    | `agy --dangerously-skip-permissions` ([Antigravity CLI](https://antigravity.google/docs/cli/using), successor to the now-discontinued Gemini CLI) |
| `aider`  | `aider --yes-always` |
| `kimi`   | `kimi --yolo` ([Kimi Code CLI](https://moonshotai.github.io/kimi-code/)) |

Anything not on this list is run as a literal command, so any CLI agent
works even without a short key — just give the exact command including
its own skip-approval flag:

```
codersync my-feature --tools claude,'some-agent --some-flag'
```

The same tool can be used for both panes too: `--tools claude,claude`.

## Security

By default, every known `--tools` key launches with that tool's
auto-approve/skip-permissions flag — the agent will read, edit, and
execute commands **without asking for confirmation**. This is
intentional (the whole point is a hands-off session you can walk away
from), but it means you should only point `codersync` at a box/directory
you trust, the same way you would running any of these tools directly
with their dangerous flag.

Use `--safe-mode` to disable this and get normal permission prompts
instead:

```
codersync my-feature --safe-mode
```

`--safe-mode` only affects known `--tools` keys. If you pass a literal
command via `--tools`, whether it's dangerous is entirely up to what you
typed — just don't include a skip-approval flag if you don't want one.

## How it works

- Sessions are created **idle** (a plain shell, no agent running yet)
  because `tmux` sizes a detached session at a default 80x24 before any
  client attaches. Starting the agent immediately and then resizing
  produced visibly broken rendering for some TUIs. A `tmux
  client-attached` hook fires the actual launch the instant a real
  client attaches (and removes itself after firing once), so the agent's
  first render happens at its real, final size.
- Connections use real OpenSSH rather than provider-specific SSH
  wrappers. Some of those (e.g. the Coder platform's `coder ssh`) have
  their own pty implementation that reports the wrong terminal size to
  the remote host regardless of the real pane size.
- Each pane's attach command runs in a retry loop, so a dropped
  connection (sleep, wifi, VPN) just reattaches a couple of seconds
  after the connection is back — the agent itself was never
  interrupted, since it was running in `tmux` on the remote box the
  whole time.
- Tool availability is checked on the remote box *before* creating
  anything, so a missing tool fails with a clear message instead of
  silently opening a tab that does nothing.

## Troubleshooting

**Can't select/copy text in a pane.** The agents enable terminal mouse
reporting for their own scrolling, which intercepts a plain click-drag.
Hold **Option** while you click-drag to force a normal text selection,
then copy as usual.

**Mouse click doesn't switch focus between panes.** `tmux`'s own mouse
mode is off by default. Use `Ctrl+b` then an arrow key (`←`/`→`) to
switch panes instead.

**"codersync: not found on \<host\>: \<tool\>".** The tool you asked for
via `--tools` (or the default `claude`/`codex`) isn't installed on the
remote box. Install it there, or check the spelling.

## Testing

Pure-logic functions (tool resolution, escaping, sanitization, argument
parsing) have a [bats-core](https://github.com/bats-core/bats-core) unit
test suite that runs with no network/tmux/iTerm2 dependency:

```
brew install bats-core shellcheck
bats tests/
shellcheck codersync
```

Everything that actually talks to SSH/tmux/iTerm2 needs a real reachable
box and has been exercised by hand against one; there's no mocked
integration suite for that layer.

## Contributing

Issues and PRs welcome. Since this drives real SSH/tmux/AppleScript
automation across several nested quoting layers, please include the
`shellcheck`/`bats` output for any change touching `codersync` itself.

## License

[MIT](LICENSE)
