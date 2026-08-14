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
- **Numbered sessions, easy cleanup** — every session gets a small
  numeric ID (`1-`, `2-`, `3-`, ...) so you can list everything running
  on the box with `codersync --list-all` and kill specific ones with
  `codersync --kill 1,3` or a range like `codersync --kill 1-4`, without
  having to type or remember full session names. `codersync --kill-all`
  clears every codersync session on the box in one go (with a
  confirmation prompt first).
- **Works with any SSH-reachable box** — not tied to any specific
  cloud-dev provider. If you can `ssh` into it and it has `tmux`,
  `bash`, and `base64`, it works.
- **Paste images across the ssh boundary** — claude/codex read the
  clipboard on whatever machine they're running on, which is the
  remote box, not your Mac, so a plain paste can't reach an image sitting
  on your local clipboard. `codersync --paste-image` (or `-p`) uploads
  it and puts the resulting remote path on your clipboard instead, so
  your next Cmd+V pastes a path the agent can read normally.
- **Any two CLI agents, not just two** — `--tools` picks which two CLI
  agents run left/right, including the same one twice.
- **One-time setup, not per-run configuration** — `codersync --setup`
  validates connectivity, `tmux`/`bash`/`base64` availability, and that
  the remote directory exists, once; every later invocation just works.
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
  from your own `~/.ssh/config`) with `tmux`, `bash`, and `base64`
  installed. `--setup` checks all three before saving anything.
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
unambiguous if you ever point `codersync` at more than one box. Each
session also gets a small numeric ID prefixed on the remote side (e.g.
`3-devbox-example-com-my-feature`) so you can refer to it later with
`--list-all` / `--kill` instead of typing the full name.

## Usage

```
codersync --setup|-s <ssh-target> [remote-dir]
codersync <session-name> [--split-mode|-m iterm|tmux] [--tools|-t t1,t2] [--safe-mode|-s]
codersync --restore-all|-r
codersync --list-all|-l
codersync --kill|-k <ids>
codersync --kill-all|-K
codersync --paste-image|-p
codersync --help|-h
```

Every flag has the single-letter short form shown next to it.
`--setup`/`-s` and `--safe-mode`/`-s` deliberately share the letter —
they're parsed in two entirely separate contexts (top-level dispatch
decides `--setup`-vs-a-session-name first; `--safe-mode` only exists
within a session-name invocation's own options), so there's no
ambiguity in practice. `--kill-all` gets capital `-K` (not `-k`, which
is the narrower `--kill`) since those two aren't something you want a
one-character-case typo away from each other.

### `codersync --setup|-s <ssh-target> [remote-dir]`

One-time setup. `<ssh-target>` is a plain hostname, `user@host`, or an
alias from your own `~/.ssh/config` — restricted to letters, digits, and
`. _ - @` (this is deliberately narrower than everything `ssh` itself
accepts: it's what gets safely embedded into remote commands and tab
titles). Forms like `host:2222` or a bracketed IPv6 address aren't
accepted directly — put those in a `~/.ssh/config` `Host` alias instead
and pass the alias here. `[remote-dir]` is where the agents start
(default: `~/repos`).

Setup checks the box is reachable over SSH, has `tmux`, `bash`, and
`base64` installed, and that `[remote-dir]` actually exists there —
*before* saving anything (a typo'd path won't fail loudly later:
`tmux` silently falls back to a default directory instead of erroring
on a bad one, so this is the only place that catches it). `codersync`
has no dependency on any specific remote/cloud-dev provider — any box
reachable over plain SSH with those three tools works. As an optional
convenience, if
`<ssh-target>` matches the alias pattern used by the
[Coder](https://coder.com) platform (`coder.*`) and its CLI is
installed locally, setup will also offer to run `coder config-ssh` for
you if that alias doesn't exist yet.

Config lives at `~/.config/codersync/config`.

### `codersync <session-name> [options]`

Opens a new tab and sets up the two-agent split. Options:

- **`--split-mode`/`-m tmux`** (default) — one `tmux` session with two
  panes split server-side. The local side just opens a tab and attaches
  once; with iTerm2 installed that tab opens automatically, and without
  it `codersync` prints the attach command for you to run in any
  terminal yourself instead. You can't attach to just one pane
  independently, since it's one session.
- **`--split-mode`/`-m iterm`** — two separate `tmux` sessions, split
  locally by iTerm2's native scripting API. Lets you attach to just the
  left or right pane independently from elsewhere. Requires iTerm2
  (plus a one-time Automation-permission prompt the first time it
  controls it).
- **`--tools`/`-t t1,t2`** (default: `claude,codex`) — which two CLI
  agents run left/right. See [Supported tools](#supported-tools).
- **`--safe-mode`/`-s`** — drop the auto-approve flag for known
  `--tools`/`-t` keys, so normal permission prompts apply instead of
  the dangerous auto-approve default. See [Security](#security) below.

### `codersync --restore-all|-r`

Reopens a tab for every session that's still alive on the remote box,
based on a local registry (`~/.codersync_sessions`) that every session
name gets appended to. Meant for recovering after your terminal gets
closed: nothing on the remote box was ever lost, this just recreates the
local tabs. Stale entries (sessions no longer alive) are pruned
automatically.

### `codersync --list-all|-l`

Lists every codersync session still alive on the remote box AND
recorded in your local registry (`~/.codersync_sessions`), with its
numeric ID and split mode:

```
ID     MODE     SESSION
1      tmux     devbox-example-com-my-feature
2      iterm    devbox-example-com-another-task
```

This talks directly to the remote `tmux` server, so a session that's
died (killed outside codersync, the box rebooted) correctly drops off
the list even if its registry entry is still there. Both checks are
required, though: a session that's alive on the box but missing from
*this* registry — because you're on a different machine than the one
that created it, or the registry was cleared — won't show up here.
Its tmux session itself is completely unaffected; there's currently no
built-in command to re-adopt it into the registry, so reattach to it
directly with `ssh <ssh-target> -- tmux attach -t <session-name>`
(get the exact name with `ssh <ssh-target> -- tmux list-sessions`).

### `codersync --kill|-k <ids>`

Kills specific sessions on the remote box by ID, leaving everything else
untouched:

```
codersync --kill 1,3      # kill sessions 1 and 3 only
codersync --kill 1-4      # kill sessions 1, 2, 3, and 4
codersync --kill 1,3-5    # mix commas and ranges
```

For an `iterm`-split session this kills both the `claude` and `codex`
tmux sessions behind it; for a `tmux`-split session it kills the single
paired session. Only the local registry entry for a fully-killed session
is cleaned up — everything else on the box is left alone.

### `codersync --kill-all|-K`

Kills every codersync session on the box in one go, including legacy
sessions from before the numeric-ID scheme existed (which `--kill` can't
address individually). Prints the full list of what's about to die and
asks for a `y/N` confirmation first — there's no undo once you say yes.

### `codersync --paste-image|-p`

Claude Code (and most CLI agents) read the clipboard by shelling out to
a *local* utility (`pbpaste` on macOS, `xclip`/`wl-paste` on Linux) on
whatever machine the process is actually running on. Since the whole
point of codersync is running that process on the remote box, a plain
paste there tries to read the *remote* box's clipboard — empty, no
display server — not your Mac's, where the image actually is.

`--paste-image` sidesteps that instead of trying to forward binary
clipboard data live: it reads whatever image is on your local
clipboard (copy a screenshot, or copy an image from a browser/Slack/
Preview — anything that puts image data on the clipboard works),
uploads it to the current target as a real file, and replaces your
clipboard content with that file's path instead of the image:

```
$ codersync --paste-image
Uploaded to devbox.example.com:/tmp/codersync-img-a1b2c3d4e5f6.png
Paste (Cmd+V) into the session to insert the path.
```

Your next `Cmd+V` into the session then pastes that path as plain
text — no binary data crosses the ssh/tmux boundary at all, so there's
nothing for tmux to mangle. Fails clearly if there's no image on the
clipboard, or if it's larger than 25MB (almost certainly the wrong
thing was copied). Bind it to a hotkey with your automation tool of
choice (macOS Shortcuts, Keyboard Maestro, Raycast/Alfred) if you want
one keystroke instead of switching to a terminal to run it.

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

A literal command can also start with a `NAME=value` environment
assignment (an ordinary, valid way to write that under bash), e.g.
`--tools 'OPENAI_API_KEY=sk-... some-agent',claude` — codersync skips
past it when checking that the actual agent binary exists remotely.
That check only understands a plain, unquoted value, though: if the
value itself needs a literal space, prefix with `env` instead of
writing the assignment directly, e.g. `--tools 'env
SOME_VAR="has a space" some-agent',claude` — `env` gets checked for
existence trivially (it's virtually always installed), and the actual
command still runs exactly as typed.

A literal command can't contain a comma, though — `,` is the
separator between the two `--tools` values, with no escaping syntax:
`--tools 'agent --model a,b'` doesn't mean "one tool with a comma in
its flag", it splits into two (wrong) tools at that comma the same as
`claude,codex` would. `--tools` also only ever accepts exactly one
comma (or zero, to use the same tool for both panes) — codersync only
runs two tools, left and right, so `--tools claude,codex,aider` is
rejected outright rather than silently dropping the third.

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
