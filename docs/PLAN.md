# Plan: cc-cache-warmer

Keep an idle Claude Code session's prompt cache warm for a few TTL cycles, then
compact it. Requires cmux, herdr or tmux: the plugin types into the session's own pane.

## Flow

```
Stop hook ──▶ kill old timer, spawn timer ──▶ wait 2 s for the transcript
              flush, read TTL, sleep(TTL - margin)
                                      │
UserPromptSubmit ──▶ ours? keep count : reset count, kill timer
                                      │
timer fires ──▶ guards pass? ──▶ pings < N ─▶ send warm prompt, pings++
                                 pings = N ─▶ send /compact, pings++
                                 pings > N ─▶ do nothing
SessionEnd ──▶ kill timer, drop state
```

Each warm prompt ends a turn, so its Stop hook re-arms the next cycle.

## Decisions

- TTL comes from the transcript: the last assistant entry with a nonzero
  `cache_creation` names `ephemeral_1h_input_tokens` or `ephemeral_5m_input_tokens`.
  No such entry means the backend is not reporting a cache. Skip.
- Delay = TTL - min(300, TTL/5). That fires at 55 min for 1h and 4 min for 5m.
- The plugin tells its own prompts from the user's by recording the exact text
  it sent in a `pending` file. UserPromptSubmit compares and consumes it.
- Context below `CC_CACHE_WARMER_MIN_TOKENS` (default 50000) is not worth
  warming. A cold rewrite of a small context is cheap.
- `TERM_PROGRAM` names the innermost multiplexer (`tmux`, `herdr`), else
  `CMUX_SURFACE_ID` means cmux. Pane variables of outer multiplexers leak
  inward, so they never decide alone.
- The timer carries Claude Code's pid and start time from the Stop hook. If
  that process is gone, the pane may hold a shell under Claude Code's last
  screen, so the timer skips.
- The input box must read empty twice, `SETTLE` (1 s) apart. After typing, the
  box must read back as exactly the ping before Enter. The window left is
  the one CLI call between that read and Enter.
- `warmer.log` rotates to `warmer.log.1` past 1 MB.
- cmux's own Stop hook posts a notification for every turn, pings included.
  The plugin cannot stop cmux from posting it, so after its own ping's Stop it
  dismisses the notifications on its surface created at or after the send
  (`sent_at`). That clears the unread marker and the list entry; a banner or
  phone push cmux already delivered stays delivered.
- State lives in `${CLAUDE_PLUGIN_DATA}/<session_id>/`: `timer.<pid>`, `armed_at`,
  `pings`, `pending`, `sent_at`, `quiet`, plus a shared `warmer.log`.

## Failure matrix

| # | state or input | what the operation does | how it can fail | what the caller is told |
|---|---|---|---|---|
| 1 | Stop, cmux pane, 1h cache, big context | arms timer at 3300 s | spawn blocks the hook | log `armed delay=3300`; hook exits 0 fast |
| 2 | Stop, 5m cache | arms timer at 240 s | wrong TTL picked | log `armed delay=240` |
| 3 | Stop, not in cmux, herdr or tmux | nothing | | log `skip: no supported terminal` |
| 4 | Stop, no cache fields in transcript | nothing | | log `skip: no cache info` |
| 5 | Stop, context < min tokens | nothing | | log `skip: small context` |
| 6 | Stop twice (re-arm) | kills first timer, arms second | two timers both fire | exactly one send |
| 7 | timer fires, idle, empty input box, pings 0..N-1 | sends warm prompt, pings++ | cmux send fails | log `warm n/N` or `error: send failed` |
| 8 | timer fires, pings = N | sends `/compact`, pings++ | | log `compact` |
| 9 | Stop after compact (pings > N) | nothing | loop re-arms forever | log `skip: done` |
| 10 | UserPromptSubmit, user text | resets pings, kills timer | stale timer fires on active session | no send |
| 11 | UserPromptSubmit, text equals `pending` | keeps pings, clears `pending` | counter reset by own ping, warms forever | pings survive |
| 12 | timer fires, a `user` or `assistant` record written after arm | nothing | fires mid-turn | log `skip: session active` |
| 13 | timer fires, draft in input box | nothing | clobbers draft | log `skip: draft in input` |
| 14 | timer fires, `read-screen` fails | nothing | types blind | log `skip: cannot read screen` |
| 15 | SessionEnd | kills timer, removes state dir | orphan timer types into a dead pane | no send |
| 16 | hook stdin is not JSON / missing fields | nothing | hook error shown to user | exits 0, log `error: bad input` |
| 17 | Stop fires before the turn's usage line reaches the transcript (seen live) | timer waits 2 s, then reads TTL | reads the previous turn, or nothing | arms normally |
| 18 | UserPromptSubmit on the first prompt, transcript file not created yet (seen live) | resets count | rejected as bad input | no error |
| 19 | Claude Code appends an `away_summary` recap (about 3 min after the turn) or metadata records while idle (seen live) | fires normally | every timer skips as `session active`, so nothing ever warms | log `warm n/N` |
| 20 | Stop after our own ping, cmux posts its turn-complete notification (seen live: body `ok`) | dismisses it | a ping pings your phone and leaves an unread marker every 55 min | log `quiet: dismissed 1` |
| 21 | same, and an older notification of yours is on the surface | dismisses only notifications created at or after the send | wipes the real "done" notification you have not read | older one kept |
| 22 | Stop after your own prompt | nothing | dismisses your real notification | no `list-notifications` call |
| 23 | Stop after our own ping, no notification shows up within 10 s | gives up | loops forever | log `quiet: none` |
| 24 | timer fires, you start typing between the two box reads | nothing | ping typed into your draft | log `skip: draft in input` |
| 25 | you type while the ping is typed | types, no Enter, clears `pending` | Enter submits your text glued to the ping | log `abort: input changed` |
| 26 | Claude Code killed without SessionEnd, its last screen still shows an empty box (seen live) | nothing | ping typed into the shell | log `skip: claude exited` |
| 27 | herdr pane | `herdr pane send-text`, `send-keys enter` | | log `warm 1/3` |
| 28 | tmux pane | `tmux send-keys -l`, `send-keys Enter` | | log `warm 1/3` |
| 29 | tmux inside herdr inside cmux | types into tmux | keys land in the outer pane | no herdr or cmux call |
| 30 | herdr inside cmux | types into herdr | keys land in the cmux surface | no cmux call |
| 31 | log past 1 MB | rotates to `warmer.log.1` | log grows forever on every laptop | new log under 1 KB |
| 32 | `CLAUDE_PID` names no live process when the timer arms | nothing | empty start time matches empty, fails open | log `skip: claude exited` |
| 33 | you send a message after the arm sleep, during the settle wait | the prompt hook kills the timer; it stays registered until it ends | the ping is typed into your active turn | no send |
| 34 | Claude Code exits after the arm sleep, during the settle wait | rechecks the process after settling, sends nothing | ping typed into the shell | log `skip: claude exited` |
| 35 | you type a `❯` while the ping is typed | only the leading prompt marker is ignored, so the box mismatches and Enter stays unpressed | Enter submits your `❯` glued to the ping | log `abort: input changed` |
| 36 | the tmux pane is in copy mode | reads fail, so the guard skips | the ping drives copy-mode bindings | log `skip: cannot read screen` |
