#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329,SC2016 # helpers run indirectly through check "$@" (older shellcheck calls it SC2317); eval conditions expand when checked
# E2E tests for bin/cache-warmer. One scenario per failure-matrix row in docs/PLAN.md.
# Fake cmux, herdr and tmux on PATH record every call. Artifact: tests/out/results.txt.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WARMER="$ROOT/bin/cache-warmer"
OUT="$ROOT/tests/out"
rm -rf "$OUT" && mkdir -p "$OUT"
RESULTS="$OUT/results.txt"
: >"$RESULTS"
FAILS=0
SLEEP=2 # CC_CACHE_WARMER_DELAY used by every armed timer
FLUSH=2 # the timer waits this long for the transcript before reading it
SETTLE=1 # the timer reads the input box twice, this far apart

# Fake cmux, herdr and tmux: one script under three names. It draws Claude
# Code's input box from $FAKE_BOX. Typed text lands in the box, Enter clears it.
# cmux calls are logged bare, herdr and tmux calls with the tool name in front.
FAKE="$OUT/fake-terminal"
cat >"$FAKE" <<'EOF'
#!/usr/bin/env bash
name=$(basename "$0")
[ "$1" = --json ] && shift
op=call text=
case $name in
  cmux) case $1 in
      read-screen) op=read ;;
      list-notifications) cat "$FAKE_NOTES"; exit 0 ;;
      send) op=type text=$4 ;;
      send-key) op=enter ;;
    esac ;;
  herdr) case $2 in
      read) op=read; [ "$4 $5" = "--source detection" ] || FAKE_SCREEN_FAIL=1 ;; # visible follows the scrollback viewport
      send-text) op=type text=$4 ;;
      send-keys) op=enter ;;
    esac ;;
  tmux) case $1:$4 in
      display-message:*) echo "${FAKE_TMUX_MODE:-0}"; exit 0 ;;
      capture-pane:*) op=read ;;
      send-keys:-l) op=type text=$5 ;;
      send-keys:Enter) op=enter ;;
    esac ;;
esac
case $op in
  read)
    [ -n "${FAKE_SCREEN_FAIL:-}" ] && exit 1
    n=$(($(cat "$FAKE_READS" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$FAKE_READS"
    [ "$n" = "${FAKE_TYPE_ON_READ:-}" ] && printf h >>"$FAKE_BOX"
    rule=────────────────────────────────
    printf '  ⎿  done\n\n%s\n❯ %s\n%s\n  status line\n' "$rule" "$(cat "$FAKE_BOX")" "$rule"
    exit 0 ;;
  type) printf '%s%s' "$text" "${FAKE_USER_TYPES:-}" >>"$FAKE_BOX" ;;
  enter) : >"$FAKE_BOX" ;;
esac
[ "$name" = cmux ] && name= || name="$name "
printf '%s%s\n' "$name" "$*" >>"$FAKE_LOG"
EOF
chmod +x "$FAKE"

# Each scenario's stand-in for the Claude Code process, killed on exit.
CLAUDES=()
trap 'kill "${CLAUDES[@]}" 2>/dev/null' EXIT

# setup NAME: fresh data dir, fake terminals, empty input box, inside cmux.
setup() {
  T="$OUT/$1"
  mkdir -p "$T/bin" "$T/data"
  export CLAUDE_PLUGIN_DATA="$T/data"
  export FAKE_LOG="$T/calls.log" FAKE_BOX="$T/box.txt" FAKE_READS="$T/reads"
  unset TERM_PROGRAM TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID
  export CMUX_SURFACE_ID="SURF-1"
  export CC_CACHE_WARMER_DELAY=$SLEEP
  unset CC_CACHE_WARMER_PINGS CC_CACHE_WARMER_MIN_TOKENS FAKE_SCREEN_FAIL FAKE_TYPE_ON_READ FAKE_USER_TYPES FAKE_TMUX_MODE
  export FAKE_NOTES="$T/notes.json"
  : >"$FAKE_LOG"
  : >"$FAKE_BOX"
  echo '[]' >"$FAKE_NOTES"
  for t in cmux herdr tmux; do ln -sf "$FAKE" "$T/bin/$t"; done
  export PATH="$T/bin:$BASE_PATH"
  sleep 600 &
  CLAUDE_PID=$!
  CLAUDES+=("$CLAUDE_PID")
  export CLAUDE_PID
  TR="$T/transcript.jsonl"
}
BASE_PATH=$PATH

# transcript TTL TOKENS: one assistant entry with a cache write of that TTL.
transcript() {
  local h=0 m=0
  [ "$1" = 1h ] && h=500
  [ "$1" = 5m ] && m=500
  printf '{"type":"assistant","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":%d,"cache_creation_input_tokens":500,"cache_creation":{"ephemeral_1h_input_tokens":%d,"ephemeral_5m_input_tokens":%d}}}}\n' \
    "$2" "$h" "$m" >"$TR"
}

hook() { # hook EVENT [PROMPT]
  jq -nc --arg t "$TR" --arg p "${2:-}" --arg e "$1" \
    '{session_id:"S1",transcript_path:$t,hook_event_name:$e,prompt:$p,cwd:"/"}' |
    "$WARMER" "$1"
}
log() { cat "$CLAUDE_PLUGIN_DATA/warmer.log" 2>/dev/null; }
sends() { grep -cE '^(send|herdr pane send-text|tmux send-keys -t [^ ]+ -l) ' "$FAKE_LOG" || true; }
enters() { grep -cE '^(send-key|herdr pane send-keys|tmux send-keys -t [^ ]+ Enter)' "$FAKE_LOG" || true; }
wait_arm() { sleep $((FLUSH + 1)); }
wait_fire() { sleep $((FLUSH + SLEEP + SETTLE + 2)); }

check() { # check ROW DESC CONDITION...
  local row=$1 desc=$2; shift 2
  if "$@"; then
    echo "PASS row $row: $desc" | tee -a "$RESULTS"
  else
    echo "FAIL row $row: $desc" | tee -a "$RESULTS"
    { echo "--- log"; log; echo "--- calls"; cat "$FAKE_LOG"; } | sed 's/^/    /' | tee -a "$RESULTS"
    FAILS=$((FAILS + 1))
  fi
}
has_log() { log | grep -q -- "$1"; }
no_sends() { [ "$(sends)" -eq 0 ]; }

# Row 1: 1h cache arms at 3300 s, and the hook returns fast.
setup r1; transcript 1h 200000
start=$(date +%s); hook Stop; took=$(($(date +%s) - start))
wait_arm
check 1 "1h cache arms delay=3300, hook returns fast" \
  bash -c "grep -q 'armed ttl=3600 delay=3300' '$CLAUDE_PLUGIN_DATA/warmer.log' && [ $took -le 1 ]"
wait_fire

# Row 2: 5m cache arms at 240 s.
setup r2; transcript 5m 200000; hook Stop; wait_arm
check 2 "5m cache arms delay=240" has_log 'armed ttl=300 delay=240'
wait_fire

# Row 3: outside cmux, herdr and tmux, nothing arms.
setup r3; transcript 1h 200000; unset CMUX_SURFACE_ID; hook Stop
check 3 "no supported terminal skips" has_log 'skip: no supported terminal'

# Row 4: transcript without cache fields.
setup r4; echo '{"type":"assistant","message":{"usage":{"input_tokens":90000}}}' >"$TR"; hook Stop; wait_arm
check 4 "no cache info skips" has_log 'skip: no cache info'

# Row 5: small context.
setup r5; transcript 1h 1000; hook Stop; wait_arm
check 5 "small context skips" has_log 'skip: small context'

# Row 6: re-arm replaces the first timer.
setup r6; transcript 1h 200000; hook Stop; sleep 1; hook Stop; wait_fire
check 6 "two Stops give exactly one send" bash -c "[ \$(grep -c '^send ' '$FAKE_LOG') -eq 1 ]"

# Row 7: idle fire sends a warm prompt and Enter.
setup r7; transcript 1h 200000; hook Stop; wait_fire
check 7 "fire sends warm prompt + enter" \
  bash -c "grep -q '^send --surface SURF-1 .*cache-warmer' '$FAKE_LOG' && grep -q '^send-key --surface SURF-1 enter' '$FAKE_LOG' && grep -q 'warm 1/3' '$CLAUDE_PLUGIN_DATA/warmer.log'"

# Rows 8, 9, 11: a full cycle. Our own prompts keep the count; ping N+1 compacts; then it stops.
setup r8; export CC_CACHE_WARMER_PINGS=2; transcript 1h 200000
hook Stop
for _ in 1 2 3; do
  wait_fire
  sent=$(cat "$CLAUDE_PLUGIN_DATA/S1/pending" 2>/dev/null) || sent=""
  [ -n "$sent" ] && hook UserPromptSubmit "$sent"
  transcript 1h 200000 # the ping's reply lands before its Stop
  hook Stop
done
wait_fire
check 11 "own prompts do not reset the count" has_log 'warm 2/2'
check 8 "ping N+1 sends /compact" bash -c "grep -q '^send --surface SURF-1 /compact' '$FAKE_LOG' && grep -q 'compact' '$CLAUDE_PLUGIN_DATA/warmer.log'"
check 9 "after compact, Stop does not re-arm" \
  bash -c "[ \$(grep -c '^send ' '$FAKE_LOG') -eq 3 ] && grep -q 'skip: done' '$CLAUDE_PLUGIN_DATA/warmer.log'"

# Row 10: a user prompt kills the timer and resets the count.
setup r10; transcript 1h 200000; hook Stop; hook UserPromptSubmit "real question"; wait_fire
check 10 "user prompt cancels the timer" no_sends

# Row 12: a conversation record lands after arm (a turn with no UserPromptSubmit).
setup r12; transcript 1h 200000; hook Stop; sleep $((FLUSH + 1))
printf '{"type":"assistant","timestamp":"%s","message":{"usage":{}}}\n' "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" >>"$TR"; wait_fire
check 12 "activity after arm skips" bash -c "[ \$(grep -c '^send ' '$FAKE_LOG') -eq 0 ] && grep -q 'skip: session active' '$CLAUDE_PLUGIN_DATA/warmer.log'"

# Row 19: Claude Code's idle recap (away_summary) and metadata land after arm (seen live).
setup r19; transcript 1h 200000; hook Stop; sleep $((FLUSH + 1))
printf '{"type":"system","subtype":"away_summary","timestamp":"%s"}\n{"type":"ai-title","aiTitle":"x"}\n' "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" >>"$TR"; wait_fire
check 19 "idle recap after arm still fires" has_log 'warm 1/3'

# Row 13: draft in the input box.
setup r13; transcript 1h 200000; printf 'half a thought' >"$FAKE_BOX"; hook Stop; wait_fire
check 13 "draft in input skips" bash -c "[ \$(grep -c '^send ' '$FAKE_LOG') -eq 0 ] && grep -q 'skip: draft in input' '$CLAUDE_PLUGIN_DATA/warmer.log'"

# Row 14: read-screen fails.
setup r14; transcript 1h 200000; export FAKE_SCREEN_FAIL=1; hook Stop; wait_fire
check 14 "unreadable screen skips" bash -c "[ \$(grep -c '^send ' '$FAKE_LOG') -eq 0 ] && grep -q 'skip: cannot read screen' '$CLAUDE_PLUGIN_DATA/warmer.log'"

# Row 15: SessionEnd kills the timer and drops state.
setup r15; transcript 1h 200000; hook Stop; hook SessionEnd; wait_fire
check 15 "SessionEnd cancels and cleans" bash -c "[ \$(grep -c '^send ' '$FAKE_LOG') -eq 0 ] && [ ! -d '$CLAUDE_PLUGIN_DATA/S1' ]"

# Row 16: garbage stdin.
setup r16; echo 'not json' | "$WARMER" Stop; rc=$?
check 16 "bad input exits 0 and logs" bash -c "[ $rc -eq 0 ] && grep -q 'error: bad input' '$CLAUDE_PLUGIN_DATA/warmer.log'"

# Row 17: the usage line lands after the Stop hook starts (the flush race).
setup r17; transcript 1h 1000; hook Stop; transcript 1h 200000; wait_fire
check 17 "usage written after Stop still arms and fires" has_log 'warm 1/3'

# Row 18: first prompt, before the transcript file exists.
setup r18; hook UserPromptSubmit "first prompt"
check 18 "prompt with no transcript yet is accepted" bash -c "! grep -q error '$CLAUDE_PLUGIN_DATA/warmer.log' 2>/dev/null && [ \$(cat '$CLAUDE_PLUGIN_DATA/S1/pings') -eq 0 ]"

# note ID SURFACE CREATED_AT: the notification list cmux would return.
note() { jq -nc --arg i "$1" --arg s "$2" --arg c "$3" '{id:$i,surface_id:$s,created_at:$c,body:"ok",is_read:false}'; }
now_utc() { date -u +%FT%TZ; }

# ping_turn: our ping is sent, submitted, and its turn ends with a Stop.
ping_turn() {
  transcript 1h 200000; hook Stop; wait_fire
  hook UserPromptSubmit "$(cat "$CLAUDE_PLUGIN_DATA/S1/pending")"
}

# Row 20: cmux's notification for our own ping's turn is dismissed.
setup r20; ping_turn
note N-PING SURF-1 "$(now_utc)" | jq -s . >"$FAKE_NOTES"; hook Stop; sleep 2
check 20 "own ping's notification dismissed" \
  bash -c "grep -q '^dismiss-notification --id N-PING' '$FAKE_LOG' && grep -q 'quiet: dismissed 1' '$CLAUDE_PLUGIN_DATA/warmer.log'"

# Row 21: an older notification on the surface, and one on another surface, stay.
setup r21; ping_turn
{ note N-OLD SURF-1 2020-01-01T00:00:00Z; note N-OTHER SURF-2 "$(now_utc)"; note N-PING SURF-1 "$(now_utc)"; } | jq -s . >"$FAKE_NOTES"
hook Stop; sleep 2
check 21 "only notifications since the send are dismissed" \
  bash -c "grep -q 'dismiss-notification --id N-PING' '$FAKE_LOG' && ! grep -qE 'N-OLD|N-OTHER' '$FAKE_LOG'"

# Row 22: a Stop after your own prompt leaves notifications alone.
setup r22; transcript 1h 200000; hook UserPromptSubmit "real question"
note N-REAL SURF-1 "$(now_utc)" | jq -s . >"$FAKE_NOTES"; hook Stop; sleep 2
check 22 "user turn is not quieted" bash -c "! grep -q 'notification' '$FAKE_LOG'"

# Row 23: no notification ever shows up.
setup r23; ping_turn; hook Stop; sleep 12
check 23 "gives up when nothing arrives" has_log 'quiet: none'

# Row 24: you start typing between the two input-box reads.
setup r24; transcript 1h 200000; export FAKE_TYPE_ON_READ=2; hook Stop; wait_fire
check 24 "typing during the settle wait skips" eval 'no_sends && has_log "skip: draft in input"'

# Row 25: you type while the ping is typed. Enter would submit both.
setup r25; transcript 1h 200000; export FAKE_USER_TYPES=h; hook Stop
for _ in $(seq 30); do has_log abort && break; sleep 1; done
check 25 "a mixed input box is never submitted" \
  eval '[ "$(sends)" -eq 1 ] && [ "$(enters)" -eq 0 ] && has_log "abort: input changed" && [ ! -f "$CLAUDE_PLUGIN_DATA/S1/pending" ]'

# Row 26: Claude Code died without a SessionEnd, so a shell now owns the pane.
setup r26; transcript 1h 200000; hook Stop; wait_arm; kill "$CLAUDE_PID"; wait_fire
check 26 "dead Claude Code process skips" eval 'no_sends && has_log "skip: claude exited"'

# Row 32: CLAUDE_PID names no process at arm time, so there is no start time to match.
setup r32; transcript 1h 200000; kill "$CLAUDE_PID"; sleep 0.2; hook Stop; wait_fire
check 32 "unknown Claude Code start time skips" eval 'no_sends && has_log "skip: claude exited"'

# Row 33: you send a message during the settle wait, after the arm sleep ended.
setup r33; transcript 1h 200000; hook Stop; sleep $((FLUSH + SLEEP)).5; hook UserPromptSubmit "real question"; wait_fire
check 33 "prompt during the settle wait cancels the timer" no_sends

# Row 34: Claude Code exits during the settle wait.
setup r34; transcript 1h 200000; hook Stop; sleep $((FLUSH + SLEEP)).5; kill "$CLAUDE_PID"; wait_fire
check 34 "Claude Code exit during the settle wait skips" eval 'no_sends && has_log "skip: claude exited"'

# Row 35: you type a prompt marker while the ping is typed. Only the leading one is decoration.
setup r35; transcript 1h 200000; export FAKE_USER_TYPES=❯; hook Stop
for _ in $(seq 30); do has_log abort && break; sleep 1; done
check 35 "a typed prompt marker is never submitted" eval '[ "$(enters)" -eq 0 ] && has_log "abort: input changed"'

# Row 36: the tmux pane sits in copy mode, where capture-pane shows the app but keys go to copy-mode bindings.
setup r36; transcript 1h 200000; unset CMUX_SURFACE_ID; export TERM_PROGRAM=tmux TMUX_PANE=%3 FAKE_TMUX_MODE=1; hook Stop; wait_fire
check 36 "tmux copy mode skips" eval 'no_sends && has_log "skip: cannot read screen"'

# Rows 27-30: the innermost terminal gets the keys.
setup r27; transcript 1h 200000; unset CMUX_SURFACE_ID; export TERM_PROGRAM=herdr HERDR_PANE_ID=w0:p1; hook Stop; wait_fire
check 27 "herdr pane, read from the detection source" eval "grep -q '^herdr pane send-text w0:p1 .*cache-warmer' '$FAKE_LOG' && grep -q '^herdr pane send-keys w0:p1 enter' '$FAKE_LOG' && has_log 'warm 1/3'"

setup r28; transcript 1h 200000; unset CMUX_SURFACE_ID; export TERM_PROGRAM=tmux TMUX_PANE=%3; hook Stop; wait_fire
check 28 "tmux pane" eval "grep -q '^tmux send-keys -t %3 -l .*cache-warmer' '$FAKE_LOG' && grep -q '^tmux send-keys -t %3 Enter' '$FAKE_LOG' && has_log 'warm 1/3'"

setup r29; transcript 1h 200000; export TERM_PROGRAM=tmux TMUX_PANE=%3 HERDR_PANE_ID=w0:p1; hook Stop; wait_fire
check 29 "tmux inside herdr inside cmux types into tmux" eval "[ \"\$(sends)\" -eq 1 ] && ! grep -qE '^(herdr|send )' '$FAKE_LOG'"

setup r30; transcript 1h 200000; export TERM_PROGRAM=herdr HERDR_PANE_ID=w0:p1; hook Stop; wait_fire
check 30 "herdr inside cmux types into herdr" eval "[ \"\$(sends)\" -eq 1 ] && ! grep -q '^send ' '$FAKE_LOG'"

# Row 31: the log rotates instead of growing forever.
setup r31; head -c 1100000 /dev/zero | tr '\0' x >"$CLAUDE_PLUGIN_DATA/warmer.log"; unset CMUX_SURFACE_ID; hook Stop
check 31 "log rotates past 1 MB" eval '[ "$(wc -c <"$CLAUDE_PLUGIN_DATA/warmer.log")" -lt 1000 ] && [ -f "$CLAUDE_PLUGIN_DATA/warmer.log.1" ]'

echo "$FAILS failed" | tee -a "$RESULTS"
exit $((FAILS > 0))
