# Claude Usage Tracker on Autopilot

**Every Claude usage tracker tells you how much you burned. This one makes sure you last the week.**

`claude-usage-autopilot` watches your Claude Code usage limits — the 5-hour window, the weekly quota, per-model buckets — computes your **burn pace**, projects whether you'll hit the weekly limit before it resets, and **acts on it automatically**:

- 📟 **Statusline**: `h35% w37%` — 5-hour and weekly usage always visible, color = verdict
- 🧭 **In-session alerts**: your Claude sessions get told when the budget is in the red, when auth broke, when monitoring went stale — so the model itself starts conserving
- 🔻 **Autonomous eco-mode**: when the pace says "you won't make it to the reset", it switches new sessions to a cheaper model (with careful guards — see below) and switches back after the weekly reset. You do nothing.
- 📈 **History**: one JSONL line every 30 min — `cua history` shows your burn trend
- 🔌 Optional: track **OpenAI Codex CLI** accounts next to Claude (reads local telemetry)

Born from a real Monday: 32% of the weekly quota burned in the first 23 hours — a 2.4x pace, projected 235% by reset. The autopilot caught it, the week survived.

## Why pace, not usage

`37% used` means nothing by itself. 37% on day one is an emergency; 37% on day six is comfortable. The autopilot compares *the fraction of budget burned* against *the fraction of the week elapsed* and turns it into a verdict band:

| Band | Meaning |
|---|---|
| `OK` / `WATCH` | on track — nothing shown, nothing done |
| `SELECTIVE` | burning fast — sessions are advised to delegate and conserve |
| `CONSERVATION` | won't make the reset — **eco-mode engages automatically** |
| `EXHAUSTED` | weekly limit hit |

## Install

macOS + [Claude Code](https://claude.com/claude-code) + `jq` (`brew install jq`).

```bash
git clone https://github.com/sshykvlv/claude-usage-autopilot.git
cd claude-usage-autopilot && ./install.sh
```

Then restart your Claude Code sessions. That's it — no API keys, no accounts: it reads your own usage percentages via your existing Claude Code login.

With optional extras (grind detector + subagent model guard, see below):

```bash
INSTALL_EXTRAS=1 ./install.sh
```

Uninstall (reverts everything, including your original statusline): `cua uninstall`

## Usage

```
cua status        # live snapshot: buckets, pace, projection, band
cua history 30    # burn trend, one line per 30 min
cua eco status    # is eco-mode active
cua eco off       # disengage eco-mode manually
cua doctor        # is everything wired up
```

Most of the time you run nothing: the launchd agent ticks every 30 minutes, the statusline shows the state, and notifications arrive only when something needs you.

## Tracking OpenAI Codex CLI accounts too

Claude is tracked automatically — no setup. Codex is opt-in and manual: it does **not** scan your machine for logins, because a Codex account is just a directory (`CODEX_HOME`), and there's no reliable way to auto-discover which ones you actually use. Add each account's path to `codex_homes` in `~/.config/claude-usage-autopilot/config.json`:

```json
{ "codex_homes": ["~/.codex", "~/.codex-work"] }
```

Each entry is read from that account's local session telemetry (`~/.codex*/sessions/**/rollout-*.jsonl`) — no network calls, no new credentials. Only Codex CLI is supported today; other providers (Gemini CLI, etc.) aren't wired up.

## Autonomous eco-mode — the guards

Flipping someone's model config automatically is dangerous, so every transition is guarded (each guard exists because it caught a real failure during development):

- a config flip **never happens on a single reading** — two consecutive confirming ticks required; extreme readings only warn first
- your manual choices always win: the flip is recorded with an md5 of the file it wrote; **any manual edit after that means no auto-revert** — you get a notification instead
- a lost-update guard protects against racing with `/model` in a live session
- recovery (after the weekly reset) also needs two calm ticks; eco-mode that survives past a reset **cries once a day instead of guessing**
- unknown/stale data never triggers anything — `UNKNOWN` is a band, not an excuse to act

Only **new** sessions pick up the model change — Claude Code reads its config at session start. Notifications tell you exactly what was done and how to undo it (`cua eco off`).

## Optional extras

**Grind detector** — when a session racks up dozens of edits on an expensive model with a bloated context, the model is advised (once) to suggest downshifting or delegating the rest. A `GRIND` token appears in the statusline.

**Subagent model guard** — blocks spawning generic subagents without an explicit `model` (they silently inherit your expensive main-loop model). Custom agents pass through; a retry-cap makes sure automation can never get stuck.

## Telegram notifications (optional)

Put a bot token and chat id into `~/.config/claude-usage-autopilot/config.json` → `notify`. macOS notifications work out of the box.

## Honest limitations

- **macOS only** for now (Keychain, launchd). Linux is the obvious next step — PRs welcome.
- Claude usage comes from the same endpoint the Claude Code UI uses; it is **not a documented public API** and may change. Your token never leaves your machine (the only outbound calls are to Anthropic — and Telegram, if you enable it).
- Percentages are per *your* plan, whatever it is — the provider bakes the plan size into the numbers.
- Codex support reads local session telemetry files; it sees usage from *this* machine's calls only.

## FAQ

**Is this affiliated with Anthropic?** No. Independent open-source tool; "Claude" is used descriptively.

**Does it send my data anywhere?** No. Everything is local files; the only network calls are to Anthropic's usage endpoint (with your own token) and optionally your own Telegram bot.

**Why not just a tracker?** Trackers report. By the time you look, the week is gone. The point here is the closed loop: measure → verdict → act.

## License

MIT
