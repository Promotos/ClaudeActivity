# ClaudeActivity

<img src="docs/icon.png" alt="ClaudeActivity app icon" width="120" align="right">

A macOS menu bar indicator that shows whether **Claude is currently exchanging tokens** — both in the **Claude Desktop app** and in **Claude Code**.

| Display | Meaning |
|---|---|
| `zzz` | no activity |
| ▲ red, filled, blinking + rate | sent (prompt going out) |
| ▼ blue, filled, blinking + rate | received (response coming in) |

The arrows carry the same two colors as the usage chart — red leaves the machine, blue comes back. The rate beside them (`938 B/s`, `1.2 kB/s`, `47 kB/s`, `1.8 MB/s`) and the idle `zzz` are drawn in the label color of the menu bar's own appearance, so they stay legible in light and dark mode.

Click the icon to open a menu with the status per source, the time since the last exchange, the total volume since app start, a 30-day usage history, and an autostart toggle.

## Usage history

The menu carries a mirrored bar chart of the last 30 days: one column per day,
**sent growing upwards**, **received growing downwards**, both halves on the same
scale. The axis on the left ends on a rounded version of the busiest day, so the
bars can be read as volumes rather than as relative heights.

Hovering a column dims the rest and shows a bubble with that day's date, both
directions, and the split between Claude Desktop and Claude Code. The bubble
lives in a window of its own, one level above the menu — a menu clips its item
views, so a bubble drawn inside the chart would have to cover the very bars it
describes.

The daily counters are written to
`~/Library/Application Support/ClaudeActivity/usage-history.json` — once a minute
while the app runs and again when it quits — and days older than the window are
dropped on every write. Delete that file to start the history over.

## Installation

### From a release

Download the `.dmg` from the [releases page](https://github.com/Promotos/ClaudeActivity/releases), open it and drag ClaudeActivity onto the Applications folder.

Do that **before** starting it. An app launched straight out of the disk image or out of `~/Downloads` still carries the download quarantine, so macOS runs it from a temporary randomized path that disappears again — which also breaks "Start at Login", because the LaunchAgent would point at a path that no longer exists.

On first launch macOS refuses with *"Apple could not verify that ClaudeActivity is free of malware"*. That is expected: the app is signed ad hoc, not with a paid Apple Developer ID, and is therefore not notarized. To allow it:

1. In that dialog click **Done** — not *Move to Trash*.
2. Open **System Settings → Privacy & Security** and scroll all the way down.
3. Next to the note about ClaudeActivity, click **Open Anyway** and confirm with Touch ID or your password.

If that line is not there, the blocked launch is no longer recent enough — macOS only offers the button for a while after the attempt. Try opening the app again, then look immediately.

macOS then remembers the exception. It is tied to the app's signature rather than to its location, so the app keeps opening from anywhere — but a new release has a new signature, which means the three steps come back once per update. The same instructions ship inside the disk image.

An icon in the menu bar is the only sign that it started — the app has no window and no Dock icon.

### Building it yourself

Requires the Xcode Command Line Tools (`xcode-select --install`). Nothing else — no dependencies, no Homebrew. A self-built app is not quarantined, so none of the above applies.

#### Option A — Xcode

```bash
open ClaudeActivity.xcodeproj
```

Then build and run the `ClaudeActivity` scheme (⌘R). The project has a single app target, is signed ad hoc ("Sign to Run Locally") and needs no development team.

Building from the command line works too:

```bash
xcodebuild -project ClaudeActivity.xcodeproj -scheme ClaudeActivity -configuration Release build
```

#### Option B — build script

For a build without Xcode, only the Command Line Tools:

```bash
chmod +x build.sh
./build.sh
open ClaudeActivity.app
```

`build.sh` compiles `Sources/main.swift` with `swiftc` and assembles the app bundle by hand. It produces the same app as the Xcode project.

Enable autostart from the app's menu ("Start at Login"); it writes a LaunchAgent to `~/Library/LaunchAgents/com.claudeactivity.agent.plist`. Quitting also happens from the menu.

## Project layout

```
Sources/main.swift          the entire app, no dependencies
Resources/Info.plist        bundle metadata for the Xcode target
Resources/AppIcon.icns      the app icon
docs/icon.png               the same artwork for this README
ClaudeActivity.xcodeproj    Xcode project (one app target)
build.sh                    swiftc build without Xcode
make-dmg.sh                 packages the app into a disk image
make-icon.swift             redraws Resources/AppIcon.icns
```

The icon is drawn from code rather than stored as artwork, so it can be changed
without an image editor:

```bash
swift make-icon.swift
```

That regenerates `Resources/AppIcon.icns` at all ten sizes `iconutil` expects,
drawing each one at its native resolution instead of scaling a large rendition
down, and writes `docs/icon.png` alongside it so the image above never drifts
from the icon actually shipped. The colors and proportions sit at the top of
`enum Icon`. The shapes are plain Bezier paths on purpose — Apple's license terms
do not allow SF Symbols in app icons.

## Releasing

```bash
./build.sh && ./make-dmg.sh
```

That produces `build/ClaudeActivity-<version>.dmg` holding the app, a symlink to
`/Applications` for drag-and-drop installing, and a text file repeating the
first-launch instructions from the Installation section — right where someone
needs them.

The app inside is signed ad hoc. Notarizing it, which would remove the
first-launch prompt entirely, requires a paid Apple Developer Program membership
and a Developer ID Application certificate; an Apple Development certificate is
explicitly not enough. That trade is deliberate here: the prompt costs each user
three clicks, once.

Publish the image with:

```bash
gh release create v1.0 build/ClaudeActivity-1.0.dmg --title "ClaudeActivity 1.0" --notes "..."
```

## How the detection works

**Signal 1 — network traffic per process.** The app keeps a `nettop -P -d` running in the background (one sample per second, deltas) and maps every line to a source via its PID. The process list is re-read via `ps` every 5 seconds.

Two pitfalls are handled here:

- **Order of classification.** Claude Code lives in `~/Library/Application Support/Claude/claude-code/<version>/claude.app` — so the path itself contains `claude.app`. That is why `claude-code` is checked *before* `claude.app`.
- **nettop output format.** `-J` does not produce CSV but fixed-width columns separated by spaces, and process names contain spaces themselves (`Claude Helper (Renderer).3511`). So parsing happens from the right: the last two numbers are `bytes_in`/`bytes_out`.

The traffic is spread across several helper processes; the values are summed per source over all fresh samples. The first sample of a nettop run is discarded because it holds cumulative rather than delta values.

**Signal 2 — session transcripts.** In addition, `~/.claude/projects/**/*.jsonl` is checked for recent changes (< 3 s). Claude Code writes there after every message.

After the last hit the arrow keeps blinking for another 2 seconds so it does not flicker during short pauses in the stream.

## nettop and CPU load

nettop polls stdin for key presses. If it inherits an stdin from a GUI app that reports EOF immediately, that poll spins in an endless loop and burns **a whole core** — reproducible with:

```bash
/usr/bin/time nettop -P -d -x -n -s 1 -l 5 -J bytes_in,bytes_out < /dev/null > /dev/null
# 4.01 real   1.44 user   3.48 sys   -> ~123 % CPU
```

The app therefore passes a pipe as stdin that stays open for the entire runtime and never returns EOF. The poll then blocks cleanly and nettop stays well below 1 %.

Also important: `-l 0` does not mean "infinite with a pause". The app uses finite blocks (`-l 1800`) and restarts nettop afterwards.

## When something does not work

The app writes a short log to `~/Library/Logs/ClaudeActivity.log`, recording
starts, stops and every nettop restart — the first place to look if the icon
disappears.

To check the signal sources by hand, best while a response is streaming:

```bash
ps -axww -o pid=,args= | grep -i claude | grep -v grep
```

```bash
nettop -P -d -x -n -l 8 -s 1 -J bytes_in,bytes_out | grep -i claude
```

```bash
find ~/.claude/projects -name '*.jsonl' -mmin -5
```

The first command shows which processes get classified, the second whether
nettop reports traffic for them, the third whether Claude Code has written a
transcript recently.

The knobs are at the top of `Sources/main.swift` under `enum Config`:

- `thresholdIn` / `thresholdOut` — lower bound against keep-alives (250 / 150 B/s). Too high and short responses get swallowed; too low and the icon blinks constantly while idle.
- `activityHold` — how long the arrow keeps glowing.
- `sleepDelay` — how long the arrows stay before the icon falls back to `zzz` (10 s). Long enough that the pauses inside a conversation do not toggle the icon.
- `rateAttack` / `rateRelease` — smoothing of the displayed rate: a burst appears almost at once, the fall-off is drawn out.
- `unitHysteresis` — how far below a boundary the rate has to fall before the unit drops back a step (15 %). Climbing happens right at the boundary.
- `pulseInterval` — blink rate.
- `sampleInterval` — nettop sampling rate; raise it to 2 if the load bothers you.
- `historyDays` — length of the usage history and the width of the chart (30 days).
- `historySaveInterval` — how often the history is flushed to disk (60 s).

After changing anything, rebuild in Xcode or run `./build.sh` again.

## Limitations

- What is measured is the **network volume of the process**, not tokens. Sync, images and telemetry count towards it — the totals are an upper bound, not exact model usage.
- The totals in the menu reset on every app start. Only the daily history survives, and it starts counting the day the app is first run.
- Traffic is booked on the day it is measured, in local time — a session running past midnight is split across two columns.
- With an active VPN or proxy, the process attribution from `nettop` can become inaccurate.

For **usage and limits** (percentages, cost, remaining quota) there are ready-made apps that read `~/.claude` — for example [CCSeva](https://github.com/Iamshankhadeep/ccseva) or [TokenEater](https://github.com/AThevon/TokenEater). They run alongside this one without any problem.

## License

Copyright 2026 Promotos

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for the full text.
