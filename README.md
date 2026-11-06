# cc-cache-warmer

A Claude Code plugin that keeps an idle session's prompt cache warm for a few
cache lifetimes, then runs `/compact` on it.

When you leave a session idle past its cache TTL (1 hour on a Claude
subscription, 5 minutes on an API key), your next message rewrites the whole
context into the cache. On a long session that rewrite is the most expensive
turn you send. This plugin sends a short keep-alive prompt just before the
cache expires, so the next turn reads the cache instead of rewriting it. After
a few pings it compacts the session and stops, so a session you never come
back to leaves a small summary to rewrite instead of the full context.

> **Requires [cmux](https://github.com/manaflow-ai/cmux), [herdr](https://herdr.dev)
> or tmux 3.2+.** A hook can't submit a prompt to Claude Code, so the plugin
> types into the session's own pane. `TERM_PROGRAM` picks the innermost one:
> Claude Code in tmux inside herdr gets tmux. iTerm2 and other terminals aren't
> supported yet. PRs welcome. Claude Code must pass `CLAUDE_PID` to hooks
> (v2.1.214 or later).

## How it works

```
you stop typing
      │
Stop hook ──▶ timer: wait 2 s, read the cache TTL from the transcript
      │
      ▼  sleep TTL - 5 min (55 min for 1h, 4 min for 5m)
guards: Claude Code alive? session idle? input box empty twice, 1 s apart?
      │
      ├─ pings < N ─▶ type the keep-alive prompt ─▶ reply ends a turn ─▶ Stop again
      ├─ pings = N ─▶ type /compact
      └─ pings > N ─▶ nothing, until you send a message
```

Enter submits the whole input box, so the plugin presses it only after it
reads its own text back alone in the box. If you type while it types, it
leaves the ping unsent in your box and logs `abort: input changed`.

Any message you type cancels the pending timer and resets the count. The
plugin compares each prompt with the text it last sent, so its own pings
don't reset the count.

cmux posts a notification every time a turn ends, pings included. Only cmux
lets the plugin clear it; on herdr and tmux a ping leaves its turn-done marker. After each
ping's turn, the plugin dismisses the notifications on its pane created since
it sent the ping, so pings don't leave unread markers. Notifications you had
not read yet stay. A banner or phone push cmux already delivered can't be
recalled.

Measured on a 70k-token session: the keep-alive turn read 70,471 tokens from
the cache, wrote 133, and produced 4 output tokens.

## What it saves

A keep-alive costs one cache read. The turn it saves costs a full 1h cache
write. Prices below are Anthropic's API rates for a 180k-token context (close
to the 181,533 tokens a live ping read in the session that tested this).

| | Claude Opus 5.5 | Claude Sonnet 5 |
|---|---:|---:|
| Base input | $4.00/MTok | $2.00/MTok |
| 1h cache write (2x) | $8.00/MTok | $4.00/MTok |
| Cache read | $0.20/MTok (0.05x) | $0.20/MTok (0.1x) |
| **Cold resume** (rewrite 180k) | **$1.44** | **$0.72** |
| One keep-alive (read 180k, plus a short reply) | ~$0.04 | ~$0.04 |
| Warm resume (read 180k) | $0.036 | $0.036 |

What that means per idle gap on Opus 5.5:

```
you come back after...     without plugin   with plugin (3 pings, then compact)
under 1 h                  $0.04            $0.04    cache still warm, no ping sent
1 h to ~3 h 40 min         $1.44            ≤ $0.17  1-3 pings + warm resume
never                      $0               ~$0.12   3 pings, plus one /compact turn
after the compact          $1.44            summary-sized cold write
```

On Opus 5.5 a full warm-and-come-back cycle costs about a tenth of one cold
resume, so the plugin pays for itself if you return to at least 1 idle session
in 12 inside the warm window. On Sonnet 5 a read is a larger share of a write:
the cycle costs about a fifth of a cold resume, and the bar is 1 in 6. On a subscription you pay in usage limits rather
than dollars. The dollar figures show the ratios at API prices.

## Prior art: oh-my-pi

[oh-my-pi](https://github.com/can1357/oh-my-pi) (omp) has both halves of this
built into the agent loop, which is where the idea came from. Claude Code
exposes no hook that can send a request, so this plugin drives the terminal
instead.

| | oh-my-pi | cc-cache-warmer |
|---|---|---|
| **Cache warming** | Since 18.3.5. Shortly before a cache entry expires, the agent replays its last request and cuts it off at the first generated token. | Types a keep-alive prompt, which becomes a real turn. |
| Transcript growth | None | One short user and assistant turn per ping |
| When it warms | Only when the expected avoided-miss cost beats the refresh cost by $0.05. Stops as soon as a refresh misses. | Up to `CC_CACHE_WARMER_PINGS` times on contexts over `CC_CACHE_WARMER_MIN_TOKENS` |
| TTLs covered | `providers.cacheWarming: idle` (the default) covers 5-minute entries only | 1h and 5m, read from the transcript |
| **Idle compaction** | `compaction.idleEnabled` (default off). Compacts after `idleTimeoutSeconds` (300) idle when context exceeds `idleThresholdTokens` (200k). Does not auto-continue. | Types `/compact` after the last ping |
| How the two combine | Independent settings | One sequence: warm N times, then compact |

Sources: `packages/coding-agent/CHANGELOG.md` (18.3.5) and `docs/compaction.md`
in the oh-my-pi repo.

## Install

```sh
claude plugin marketplace add STRML/cc-cache-warmer
claude plugin install cc-cache-warmer@cc-cache-warmer
```

Run Claude Code inside a cmux, herdr or tmux pane. Anywhere else, the plugin
logs a skip and does nothing.

## Settings

Set these as environment variables before you start `claude`.

| Variable | Default | Meaning |
|---|---|---|
| `CC_CACHE_WARMER_PINGS` | `3` | Keep-alive pings before `/compact`. |
| `CC_CACHE_WARMER_MIN_TOKENS` | `50000` | Smaller contexts aren't worth warming. |
| `CC_CACHE_WARMER_DELAY` | TTL - 5 min | Seconds to wait before each ping. For testing. |

## When it does nothing

Each skip is logged to `warmer.log` in the plugin's data directory
(`~/.claude/plugins/data/<plugin-id>/`).

| Log line | Cause |
|---|---|
| `skip: no supported terminal` | Not inside cmux, herdr or tmux. |
| `skip: no CLAUDE_PID` | Claude Code did not pass its pid to the hook. Update to v2.1.214 or later. |
| `skip: claude exited` | The Claude Code process that armed the timer is gone, so a shell may own the pane. |
| `skip: no cache info` | The transcript has no cache write. Non-Anthropic backends often report none. |
| `skip: small context` | The context is below `CC_CACHE_WARMER_MIN_TOKENS`. |
| `skip: session active` | A message or reply landed after the timer armed. Idle recaps and metadata records do not count. |
| `skip: draft in input` | You left text in the input box. The plugin won't type over it. |
| `skip: cannot read screen` | Reading the pane failed, or no input box is visible (for example, a permission prompt is open). |
| `skip: done` | The session is compacted. The next message you send restarts the cycle. |
| `abort: input changed` | The input box held more than the ping after typing it. Enter was not pressed. |
| `quiet: none` | No notification for the ping's turn showed up within 10 s, so nothing was dismissed. |

## Tests

```sh
./tests/e2e.sh
```

Each scenario matches one row of the failure matrix in
[docs/PLAN.md](docs/PLAN.md). Fake `cmux`, `herdr` and `tmux` on `PATH` record every call. The
results land in `tests/out/results.txt`. CI runs shellcheck and the suite on
Linux and macOS on pushes to main and on every pull request.

## License

MIT
