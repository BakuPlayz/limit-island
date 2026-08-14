# Limit Island

See what your coding agents are doing, approve what they ask for, and jump back to
them — from the unused space around your MacBook's notch.

Limit Island watches the CLI agents running in your terminals. At rest it shows a
status dot per session and a one-line quota readout beside the camera housing.
Click it and a panel drops down with every session: what it is working on, which
terminal it is in, how long it has been going. When Claude Code needs permission,
the Allow and Deny buttons appear there, so you never leave your editor.

The app has no Dock icon; it lives in the menu bar.

> [!IMPORTANT]
> **Everything stays on your Mac.** Limit Island talks to your CLIs over a local
> Unix socket and reads your own provider sessions for quota. Nothing is sent to
> any service of ours, because there isn't one.

## Quick start

### Before you begin

You need:

- **macOS 14 or later.** A notched display is ideal; on any other display Limit
  Island shows the same content as a floating bar at the top centre.
- **Xcode or Apple's Command Line Tools** to build the app. Full Xcode is needed
  only to run the test suite.
- At least one of: [Claude Code](https://claude.com/claude-code), the
  [Codex CLI](https://github.com/openai/codex), or the Gemini CLI.

### Install and run

This project does not publish a release build yet, so build it from source:

```sh
git clone <repository-url>
cd vibe-usage
make run
```

`make run` creates `LimitIsland.app` in this folder and launches it. Look for the
small gauge icon in the menu bar.

To run it automatically after signing in, add `LimitIsland.app` in **System
Settings → General → Login Items**.

### Turn on agent monitoring

1. Click the gauge icon in the menu bar, then **Settings…**
2. Limit Island installs its Claude hook automatically when it finds `claude` on
   your PATH. Its Codex terminal hook is installed after the first Codex session is
   observed. Both can be reviewed, retried, or removed in **Settings → Agents**.
3. Start `claude` in a terminal. It appears in the notch panel straight away.

Installing adds Limit Island's entries to `~/.claude/settings.json`. Your existing
settings are kept untouched, a timestamped backup is written to
`~/Library/Application Support/LimitIsland/backups/` first, and **Remove hooks**
takes out only the entries Limit Island added.

**Codex needs no setup to appear.** It is read from the transcripts it already
writes to `~/.codex/sessions`, so its sessions and live activity show up on their
own. Installing its `notify` line is optional and does one thing: it is the only
moment Codex reveals which terminal it is running in, so *jumping* to a Codex
session needs it. That edit adds a single top-level `notify` key to
`~/.codex/config.toml` and leaves every `[projects."…"]` entry exactly as it was.

If Limit Island is not running, the installed hooks do nothing at all — they exit
immediately and your CLI behaves exactly as it would without them.

### Add an account for quota

1. In **Settings → Accounts**, if a signed-in Codex, Claude, or Gemini CLI appears
   under **Detected on this Mac**, choose **Add**.
2. Otherwise select **Add account…**, choose a provider, and finish its sign-in.

## Use it day to day

### Read the strip

At rest the strip carries two things:

- **Pinned account readouts**, one on each side of the notch. Their provider logo
  sits nearest the camera housing. Claude shows its compact five-hour reading while
  the notch is closed; Codex shows its weekly reading instead. Opening the notch
  shows the weekly reading for each pinned account.
  Choose Codex and Claude accounts for the left and right slots in
  **Settings → Agents**; an account can only occupy one side.
- Both sides reserve the same stable width even before anything is pinned. An
  unpinned side stays empty, so the notch never shifts when pins change.

The countdown is set at the same weight as the percentage, deliberately. Once a
window is nearly spent, `11%` tells you to stop but `4h1m` tells you when you can
start again — so as the percentage falls, the emphasis moves to the time. Readouts
below 50% turn amber and below 10% turn red.

All tracked accounts are listed in the panel.

### The panel

Click the strip and it expands into a panel below the notch. Each row is one
conversation: status dot, what you asked for, what it is doing right now, badges for
the provider and terminal, and elapsed time. Click a row to jump to it. Click the
strip again, or anywhere outside, to close it.

Clicking rather than hovering is deliberate. The pointer's route to the strip runs
straight through the camera housing, which cannot be hovered at all, so hover-to-open
was a matter of luck and opened by accident on the way to the menu bar.

The panel opens by itself whenever an agent needs you — a permission request, or a
question waiting in its terminal — and refuses to close until you have dealt with it.

Rows are ordered with anything waiting on you first. A finished session disappears
after a couple of minutes; one that is merely quiet stays for half an hour, because
an agent can spend a long time thinking or waiting on a build.

### Approve without switching apps

When Claude Code wants to run something, the card shows the tool and its target —
a coloured diff for an edit, the command for `Bash`, the rendered Markdown for a
plan. **⌃⌘Y** allows, **⌃⌘N** denies. The panel never takes focus, so the shortcuts
work from wherever you are typing.

They are Control-Command rather than plain ⌘Y/⌘N on purpose. The shortcuts are read
by a global monitor, and ⌘Y is Redo in several apps while ⌘N is New almost
everywhere — a stray press in your editor must never answer a permission request you
had not read.

Three things this does not do:

- **It never decides for you.** If you do not answer within eight minutes, or you
  quit Limit Island, or you answer in the terminal instead, the decision goes back
  to Claude Code's own prompt. A timeout is never a denial.
- **It does not re-ask what you already settled.** Your `permissions.allow` and
  `permissions.deny` rules in `~/.claude/settings.json` and your project's
  `.claude/settings.json` are evaluated first. A call those rules cover runs
  without a card.
- **It stays out of auto mode.** A session in auto-accept or with permissions
  bypassed is never interrupted — you already answered the question. It still shows
  up in the panel with its activity and its jump target; it just does not ask.

| Session mode | What the notch does |
| --- | --- |
| Default | Shows a card for the tools in the list below |
| Auto-accept edits (⇧⇥) | Edits pass through; a `Bash` command still asks |
| Bypass permissions | Nothing asks |
| Plan mode | Only the finished plan is offered for approval |

Which tools are routed through the notch is the **Approve from the notch** setting
on the Agents tab. The default is the destructive set:
`Bash|Edit|MultiEdit|Write|NotebookEdit|WebFetch|ExitPlanMode`.

### Jump to a session

Clicking a row raises the terminal it is running in, as precisely as that terminal
allows:

Idle agents remain in this list, including after a turn finishes. A row is removed
only when the CLI sends `SessionEnd` or its captured agent process has exited.
Recent Codex rollouts are replayed when the app launches so an agent that was
already waiting at its prompt is visible without requiring another command.

| Terminal | Lands on |
| --- | --- |
| iTerm2 | the exact session, by `ITERM_SESSION_ID` |
| Terminal.app | the exact tab, matched by tty |
| tmux | the exact pane, then the hosting terminal |
| Ghostty 1.3+ | the exact terminal, using its AppleScript terminal ID |
| kitty, WezTerm | the exact window or pane, via their own CLI |
| Warp, Alacritty, VS Code, Cursor, Zed | the owning application |

macOS asks for Automation permission the first time. If it is declined, the island
offers a link to Privacy settings and a Retry action. When several terminal surfaces
match one session, the island shows a chooser and remembers that choice until the
session ends. kitty remote control is never enabled silently: the island explains
the change, backs up `kitty.conf`, and waits for explicit confirmation.
If an exact tab or pane identifier is missing or stale, clicking still activates or
launches the owning terminal application; an exact-match failure is never a dead end.

### What each CLI can do

| | Claude Code | Codex |
| --- | --- | --- |
| Show sessions and activity | ✅ | ✅ |
| Title from your prompt | ✅ | ✅ |
| Respect its auto mode | ✅ | ✅ |
| Jump to the terminal | ✅ | with `notify` installed |
| Approve from the notch | ✅ | — |
| Quota readout | ✅ | ✅ |

Only Claude Code has a hook that waits for a reply, so only Claude Code can be
answered from the notch. Codex is followed through its own session transcripts,
which give live activity but no way to answer it. This is stated in Settings too
rather than left to be discovered.

Gemini is currently switched off. Its code and tests are still in the repository —
re-enabling it is one line in `Provider.isAvailable` — but it has no hook system to
monitor sessions with, so it was crowding the two providers that do.

### Menu-bar controls

| Menu item | Shortcut | What it does |
| --- | --- | --- |
| **Refresh now** | ⌘R | Re-reads every configured account now. |
| **Settings…** | ⌘, | Opens accounts and agent settings. |
| **Quit Limit Island** | ⌘Q | Stops Limit Island and releases anything waiting. |

## Sign in and manage accounts

You may add a provider more than once. Every browser-added account has its own
isolated session, so personal and work sign-ins do not share cookies.

- **Codex** — if you have run `codex login`, choose **Add** under **Detected on
  this Mac**; no browser needed. Otherwise **Add account… → Codex**.
- **Claude** — if you are signed in with `claude`, choose **Add**. Otherwise
  **Add account… → Claude** and sign in to claude.ai in the window that opens.
- **Gemini** — if the `gemini` CLI is signed in, choose **Add**. Otherwise
  **Add account… → Gemini**; Google opens consent in your normal browser.

Use the **⋯** menu on a row to rename it, reopen sign-in, sign out, or remove it.

### Why macOS only asks about the keychain once

A CLI login lives in the login keychain, and reading another application's item is
what raises the macOS authorization panel. Limit Island reads each one **once**,
then mirrors it into a keychain item of its own — an item this app created opens
without a prompt, so later launches never touch the CLI's item at all. It goes back
to the original only when the mirrored copy has expired or the provider rejects it.

`Scripts/build-app.sh` also creates a stable local signing certificate
(`LimitIsland Local`) the first time you build. That matters because the keychain
remembers "Always Allow" per code signature: ad-hoc signing produces a new identity
on every build, which is what used to make the prompt come back after each rebuild.

## Privacy and local storage

| Data | Location |
| --- | --- |
| Account list and last readings | `UserDefaults` (`limit-island.meters`, `limit-island.meter-usage`) |
| Mirrored CLI credentials | Login keychain, service `com.limitisland.credentials` |
| Gemini token from our own sign-in | Login keychain, `com.limitisland.gemini-oauth` |
| Codex CLI token | Read in place from `~/.codex/auth.json`; never copied. |
| Hook socket | `~/Library/Application Support/LimitIsland/hook.sock`, mode 0600 |
| Settings backups | `~/Library/Application Support/LimitIsland/backups/` |
| Browser sessions | One isolated `WKWebsiteDataStore` per browser-added account |

Session data is held in memory only and is never written to disk. Saved readings
contain percentages, reset timestamps, and the time of the last read — not prompts,
chats, or model activity.

## Troubleshooting

| What you see | What to do |
| --- | --- |
| No sessions appear | Check **Agents → Hooks installed**. If it says the hooks point at an older copy, the app was moved; choose **Reinstall hooks**. |
| A card never appears for a tool | It is either outside the **Approve from the notch** list, or one of your own permission rules already covers it. |
| **Sign in required** | Reopen sign-in from **⋯** for Codex or Claude. For Gemini, remove and add the account again. |
| Nothing near the menu bar | With no accounts and no sessions there is nothing to draw, so the strip hides. |
| Jumping raises the app but not the tab | That terminal has no scripting interface, or Automation permission was declined (**System Settings → Privacy & Security → Automation**). |
| A quota stays `—` | The account returned no reading. Check the logs below. |
| `make test` cannot find `Testing` | Install full Xcode; the Command Line Tools do not include the test frameworks. |

To watch what the app is doing:

```sh
log stream --predicate 'subsystem == "com.limitisland"'
```

## Caveats

Limit Island reads the same provider endpoints their own clients use. They are not
public APIs and can change without notice:

- `chatgpt.com/backend-api/wham/usage`
- `claude.ai/api/organizations` and `.../usage`
- `cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` and `:retrieveUserQuota`

The hook payload shapes are likewise a CLI implementation detail. Provider changes
can therefore make a reading or a session detail unavailable. This is an unofficial
personal project and is not affiliated with or endorsed by OpenAI, Anthropic, or
Google.

## Development

```sh
make app     # build LimitIsland.app
make run     # build and launch
make test    # run the test suite (needs Xcode)
make clean   # remove the app bundle and .build
```

### Google OAuth client

The Gemini sign-in runs as the public installed-app client that the Gemini CLI
itself ships — that is what makes its Code Assist quota readable, and it needs no
setup. To run as your own client instead, set either pair before building:

```sh
GOOGLE_OAUTH_CLIENT_ID=… GOOGLE_OAUTH_CLIENT_SECRET=… make app
```

`make app` writes those into the built bundle's `Info.plist` only, never into
`Scripts/Info.plist`, so a private client cannot be committed. For a plain
`swift run`, use `LIMIT_ISLAND_GOOGLE_CLIENT_ID` / `LIMIT_ISLAND_GOOGLE_CLIENT_SECRET`
in the environment, which take precedence over both.

### Source layout

```
Sources/LimitIsland/
  App/                 app lifecycle and notch-window placement
  Core/                state, models, logging, keychain, and the credential broker
  Features/
    Accounts/          account detection, settings, and browser sign-in
    Island/            the strip, the panel, session rows, permission cards
    Providers/         Codex, Claude, Gemini, OAuth, and usage parsing
    Sessions/          hook server, hook installer, session state, terminal jump
  UI/                  reusable provider presentation
  Resources/           bundled provider logos

Sources/LimitIslandHook/
  main.swift           the helper each CLI runs per hook event

Tests/LimitIslandTests/
  Accounts/            account and credential tests
  Providers/           OAuth, parsing, and provider credential tests
  Sessions/            hook protocol, installer, permission rules, session state
  UI/                  layout and presentation tests
```

The parsing, layout, hook, permission-rule, and session logic are covered by tests.
AppKit and WebKit integration are not. See [IMPROVEMENTS.md](IMPROVEMENTS.md) for
known future work.

## Licence

This project currently has no licence file. Default copyright applies, so no
permissions are granted to others until a licence is added.
