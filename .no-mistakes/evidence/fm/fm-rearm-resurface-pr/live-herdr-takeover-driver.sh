#!/usr/bin/env bash
# Live driver: real bin/fm-watch-arm.sh + bin/fm-watch.sh on /bin/bash 3.2 against a
# real Herdr lab session (fm-lab-*), real capability probe and real
# herdr-eventwait.py reader. Takes over the watcher while it sits in its event wait.
# Usage: live-herdr-takeover-driver.sh <worktree> <herdr-lab-session> <label>
set -u
WT=$1 S=$2 LABEL=$3
cd "$WT" || exit 1
LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd -P)
bin/fm-lab-home.sh create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmp"
STATE="$LAB/state"
printf 'window=%s:w1:p1\nbackend=herdr\nkind=ship\n' "$S" > "$STATE/demo.meta"
log() { printf '[%s %s] %s\n' "$(date +%T)" "$LABEL" "$*"; }

arm() {  # <pred> [args...]
  local pred=$1; shift
  exec env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH \
    -u HERDR_SESSION -u FM_BACKEND_HERDR_BIN \
    TMPDIR="$LAB/tmp" FM_HOME="$LAB" FM_POLL=40 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 FM_BUSY_TURN_MAX_SECS=999999 FM_STALE_ESCALATE_SECS=999999 \
    FM_WATCH_PREDECESSOR_ARM_PID="$pred" /bin/bash bin/fm-watch-arm.sh "$@"
}
drain() { env -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$LAB" bin/fm-wake-drain.sh "$@"; }

log "bash: $(/bin/bash --version | head -1)"
log "lab home: $LAB  herdr session: $S  pane: w1:p1"
arm "$$" > "$LAB/owner.out" 2>&1 &
OWNER=$!
for _ in $(seq 1 400); do grep -q '^watcher: started pid=' "$LAB/owner.out" && break; sleep 0.05; done
log "owner arm $OWNER: $(cat "$LAB/owner.out")"
WATCHER=$(cat "$STATE/.watch.lock/pid")
# main handles and acknowledges a wake
env -u FM_ROOT_OVERRIDE FM_STATE_OVERRIDE="$STATE" bash -c '. bin/fm-wake-lib.sh; fm_wake_append signal take-over "signal: fixture handled by main"'
drain > /dev/null 2> "$LAB/drain.err"
seq_=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation .*/\1/p' "$LAB/drain.err")
gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$LAB/drain.err")
drain --ack-through "$seq_" --recovery-generation "$gen" > /dev/null 2>&1
ACKED=$(cat "$STATE/.watcher-down")
log "acknowledged marker: $ACKED"
# wait until the watcher's real event reader (herdr-eventwait.py) is subscribed
READER=
for _ in $(seq 1 1200); do [ -n "$WATCHER" ] || break
  READER=$(pgrep -f "herdr-eventwait.py" | while read -r p; do
    a=$p; while [ -n "$a" ] && [ "$a" -gt 1 ]; do [ "$a" = "$WATCHER" ] && { echo "$p"; break; }; a=$(ps -o ppid= -p "$a" | tr -d ' '); done; done | head -1)
  [ -n "$READER" ] && break; sleep 0.05
done
log "watcher $WATCHER is inside its event wait: reader pid=$READER ($(ps -o command= -p "$READER" 2>/dev/null | cut -c1-120))"
sleep 1
T0=$(date +%s)
log "issuing: fm-watch-arm.sh --take-over $OWNER"
arm "" --take-over "$OWNER" > "$LAB/arm.out" 2>&1 &
ARM=$!
for _ in $(seq 1 600); do grep -q '^watcher: started pid=' "$LAB/arm.out" && break; kill -0 "$ARM" 2>/dev/null || break; sleep 0.05; done
T1=$(date +%s)
log "take-over arm output after $((T1 - T0))s:"; sed 's/^/    /' "$LAB/arm.out"
kill -0 "$WATCHER" 2>/dev/null && log "old watcher $WATCHER STILL RUNNING" || log "old watcher $WATCHER is gone"
log "cycle-exit ledger:"; sed 's/^/    /' "$STATE/.watch-cycle-exits.log" 2>/dev/null
NOW=$(cat "$STATE/.watcher-down")
log "marker now: $NOW"
[ "$NOW" = "$ACKED" ] && log "marker UNCHANGED (acknowledgement kept)" || log "marker CHANGED (episode reopened)"
sleep 5
log "take-over arm output 5s later:"; sed 's/^/    /' "$LAB/arm.out"
kill -0 "$ARM" 2>/dev/null && log "fresh cycle still running (quiet)" || log "fresh cycle CLOSED"
grep -q '^check: rearm-resurface' "$LAB/arm.out" && log "RESURFACED: check: rearm-resurface" || log "no rearm-resurface line"
log "stopped owner arm+watcher output (stdout+stderr):"; sed "s/^/    /" "$LAB/owner.out"; grep -q Terminated "$LAB/owner.out" && log "owner output has a Terminated job notice" || log "no Terminated job notice in owner output"
kill -TERM "$ARM" 2>/dev/null; sleep 2
pkill -TERM -P "$OWNER" 2>/dev/null; kill -TERM "$OWNER" 2>/dev/null
FRESH=$(cat "$STATE/.watch.lock/pid" 2>/dev/null)
for _ in $(seq 1 100); do
  pgrep -f "$LAB" >/dev/null || break; sleep 0.1
done
pkill -TERM -f "$LAB" 2>/dev/null
sleep 1
log "scratch left in TMPDIR: [$(find "$LAB/tmp" \( -name 'fm-herdr-eventwait.*' -o -name 'fm-watch-wait.*' \) -print 2>/dev/null | tr '\n' ' ')]"
rm -rf "$LAB"
log "lab home removed"
