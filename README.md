# ClaudeActivity

A macOS menu bar indicator that shows whether **Claude is currently exchanging tokens** — both in the **Claude Desktop app** and in **Claude Code**.

| Display | Meaning |
|---|---|
| `zzz` | no activity |
| ▲ filled, blinking + rate | sent (prompt going out) |
| ▼ filled, blinking + rate | received (response coming in) |

All icons are template images, so macOS tints them to match the menu bar — legible in both light and dark mode. Next to the arrows is the current rate (`938 B/s`, `1.2 kB/s`, `47 kB/s`, `1.8 MB/s`).

Click the icon to open a menu with the status per source, the time since the last exchange, the total volume since app start, and an autostart toggle.

## Installation

Requires the Xcode Command Line Tools (`xcode-select --install`). Nothing else — no dependencies, no Homebrew.

### Option A — Xcode

```bash
open ClaudeActivity.xcodeproj
```

Then build and run the `ClaudeActivity` scheme (⌘R). The project has a single app target, is signed ad hoc ("Sign to Run Locally") and needs no development team.

Building from the command line works too:

```bash
xcodebuild -project ClaudeActivity.xcodeproj -scheme ClaudeActivity -configuration Release build
```

### Option B — build script

For a build without Xcode, only the Command Line Tools:

```bash
chmod +x build.sh diagnose.sh benchmark.sh
./build.sh
open ClaudeActivity.app
```

`build.sh` compiles `Sources/main.swift` with `swiftc` and assembles the app bundle by hand. It produces the same app as the Xcode project.

Enable autostart from the app's menu ("Start at Login"); it writes a LaunchAgent to `~/Library/LaunchAgents/com.claudeactivity.agent.plist`. Quitting also happens from the menu.

## Project layout

```
Sources/main.swift          the entire app, no dependencies
Resources/Info.plist        bundle metadata for the Xcode target
ClaudeActivity.xcodeproj    Xcode project (one app target)
build.sh                    swiftc build without Xcode
diagnose.sh                 checks the signal sources
benchmark.sh                measures the CPU cost of nettop variants
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

```bash
./diagnose.sh    # processes, raw nettop output, transcript folder
./benchmark.sh   # CPU cost of various nettop variants
```

The knobs are at the top of `Sources/main.swift` under `enum Config`:

- `thresholdIn` / `thresholdOut` — lower bound against keep-alives (250 / 150 B/s). Too high and short responses get swallowed; too low and the icon blinks constantly while idle.
- `activityHold` — how long the arrow keeps glowing.
- `pulseInterval` — blink rate.
- `sampleInterval` — nettop sampling rate; raise it to 2 if the load bothers you.

After changing anything, rebuild in Xcode or run `./build.sh` again.

## Limitations

- What is measured is the **network volume of the process**, not tokens. Sync, images and telemetry count towards it — the totals are an upper bound, not exact model usage.
- The counters reset on every app start; nothing is persisted.
- With an active VPN or proxy, the process attribution from `nettop` can become inaccurate.

For **usage and limits** (percentages, cost, remaining quota) there are ready-made apps that read `~/.claude` — for example [CCSeva](https://github.com/Iamshankhadeep/ccseva) or [TokenEater](https://github.com/AThevon/TokenEater). They run alongside this one without any problem.
