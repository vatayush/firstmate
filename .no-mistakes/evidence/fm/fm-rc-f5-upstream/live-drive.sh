#!/usr/bin/env bash
# Live drive of bin/fm-pr-check.sh + bin/fm-watch.sh against a disposable lab home and stub forge.
set -u
ROOT=$1 LAB=$2 W=$3 SCEN=$4; shift 4
export FM_HOME=$LAB FORGE_DIR=$W/forge-$SCEN FM_TEST_GH_LOG=$W/gh-$SCEN.log FM_TEST_JQ=$(command -v jq)
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS
export PATH="$W/fakebin:/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -p "$FORGE_DIR"
sweep() {  # one bounded watcher run; prints its stdout (the wake) and rc
  local bound=${1:-25} rc; shift
  rm -f "$LAB/state/.last-check"
  perl -e 'my $b=shift; my $pid=fork; if(!$pid){exec @ARGV} local $SIG{ALRM}=sub{kill "TERM",$pid; waitpid $pid,0; exit 124}; alarm $b; waitpid $pid,0; exit($?>>8)' "$bound" \
    env FM_CHECK_INTERVAL=${SWEEP_INTERVAL:-0} FM_POLL=0.05 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 "$@" "$ROOT/bin/fm-watch.sh" > "$W/watch.out" 2> "$W/watch.err"
  rc=$?
  echo "[watcher rc=$rc] stdout:"; sed 's/^/    /' "$W/watch.out"
}
ack() {
  local err=$W/drain.err seq gen
  "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>"$err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation \(.*\)$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9]* --recovery-generation \(.*\)$/\1/p' "$err")
  [ -n "$seq" ] && "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
}
setup() {  # [meta lines...]
  "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
  mkdir -p "$LAB/wt"; git -C "$LAB/wt" init -q; git -C "$LAB/wt" -c user.name=t -c user.email=t@e.invalid commit -q --allow-empty -m init
  git -C "$LAB/wt" update-ref refs/remotes/origin/main "$(git -C "$LAB/wt" rev-parse HEAD)"
  : > "$LAB/config/pr-merge-on-green"
  printf '%s\n' window=firstmate:fm-task-a endpoint_task_id=task-a "worktree=$LAB/wt" "project=$LAB/wt" kind=ship mode=no-mistakes "$@" > "$LAB/state/task-a.meta"
  echo "\$ fm-pr-check.sh task-a $URL"
  "$ROOT/bin/fm-pr-check.sh" task-a "$URL" 2>&1 | sed 's/^/    /'
  "$ROOT/bin/fm-check-unregister.sh" contributions >/dev/null 2>&1
  echo "registered: $(ls "$LAB/state" | grep task-a | tr '\n' ' ')"
}
URL=https://github.com/o/r/pull/1
HEAD1=0123456789abcdef0123456789abcdef01234567
iso_ago() { jq -nr --argjson a "$1" '(now - $a)|floor|todate'; }
case $SCEN in
  yolo-merge)
    setup yolo=on
    printf '[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"%s","completedAt":"%s"}]' "$(iso_ago 90)" "$(iso_ago 60)" > "$FORGE_DIR/rollup"
    echo "== sweep 1: PR open, CI green 1m ago, CLEAN, task yolo=on"
    sweep 40
    sleep 3
    echo "green marker:"; sed 's/^/    /' "$LAB/state/task-a.pr-poll-green" 2>/dev/null
    echo "automatic merge log:"; sed 's/^/    /' "$LAB/state/task-a.pr-poll-green.log" 2>/dev/null
    echo "forge merge calls:"; grep '^pr merge' "$FM_TEST_GH_LOG" | sed 's/^/    /'
    echo "queued wakes:"; sed 's/^/    /' "$LAB/state/.wake-queue" 2>/dev/null
    ;;
  alarm-no-yolo)
    setup
    printf '[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"%s"}]' "$(iso_ago 1200)" > "$FORGE_DIR/rollup"
    echo "== sweep 1: task WITHOUT yolo, PR green for 20m (forge completion time), CLEAN"
    sweep 40
    echo "forge merge calls: $(grep -c '^pr merge' "$FM_TEST_GH_LOG")"
    ack
    echo "== sweep 2: same head still green -> must stay silent (expect rc=124 bound)"
    sweep 8
    echo "== sweep 3: new head pushed, green 20m -> wakes again once"
    ack; sweep 40 FM_TEST_GH_HEAD=89abcdef0123456789abcdef0123456789abcdef
    echo "forge merge calls: $(grep -c '^pr merge' "$FM_TEST_GH_LOG")"
    ;;
  fresh-green)
    setup
    printf '[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"%s"}]' "$(iso_ago 30)" > "$FORGE_DIR/rollup"
    echo "== sweep: task without yolo, green only 30s -> no alarm yet (expect rc=124)"
    sweep 8
    ;;
  behind-yolo)
    setup yolo=on
    printf '[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"%s"}]' "$(iso_ago 1200)" > "$FORGE_DIR/rollup"
    echo BEHIND > "$FORGE_DIR/merge_state"
    echo "== sweep: yolo=on task, green 20m, merge state BEHIND"
    sweep 40; sleep 2
    echo "forge merge/update-branch calls: $(grep -c '^pr merge\|update-branch' "$FM_TEST_GH_LOG")"
    echo "automatic merge log exists: $([ -e "$LAB/state/task-a.pr-poll-green.log" ] && echo yes || echo no)"
    ;;
  flag-absent)
    setup yolo=on
    rm -f "$LAB/config/pr-merge-on-green"
    : > "$FM_TEST_GH_LOG"
    echo "== sweep: yolo=on task, green, CLEAN, but config/pr-merge-on-green ABSENT (expect rc=124, nothing)"
    sweep 8; sleep 2
    echo "forge merge calls: $(grep -c '^pr merge' "$FM_TEST_GH_LOG")"
    echo "rollup reads: $(grep -c statusCheckRollup "$FM_TEST_GH_LOG")"
    echo "poll read used: $(grep '^pr view' "$FM_TEST_GH_LOG" | sort -u)"
    echo "green marker exists: $([ -e "$LAB/state/task-a.pr-poll-green" ] && echo yes || echo no)"
    ;;
  queued-rerun)
    setup yolo=on
    printf '[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"%s","completedAt":"%s"},{"__typename":"CheckRun","name":"ci","status":"QUEUED","conclusion":null,"startedAt":"0001-01-01T00:00:00Z"}]' "$(iso_ago 1300)" "$(iso_ago 1200)" > "$FORGE_DIR/rollup"
    echo "== sweep: yolo=on, old ci SUCCESS + a QUEUED re-run (zero startedAt), CLEAN -> not green: no merge, no alarm (expect rc=124)"
    sweep 8; sleep 2
    echo "forge merge calls: $(grep -c '^pr merge' "$FM_TEST_GH_LOG")"
    echo "green marker exists: $([ -e "$LAB/state/task-a.pr-poll-green" ] && echo yes || echo no)"
    ;;
  failed-then-passed)
    setup yolo=on
    : > "$LAB/config/pr-degraded-watch"
    printf '[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"FAILURE","startedAt":"%s"},{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"%s","completedAt":"%s"}]' "$(iso_ago 300)" "$(iso_ago 200)" "$(iso_ago 100)" > "$FORGE_DIR/rollup"
    echo "== sweep: yolo=on, ci FAILURE then passing re-run at same head, degraded flag also on, CLEAN"
    SWEEP_INTERVAL=300 sweep 40; sleep 3
    echo "forge merge calls:"; grep '^pr merge' "$FM_TEST_GH_LOG" | sed 's/^/    /'
    echo "queued wakes:"; cut -f3- "$LAB/state/.wake-queue" 2>/dev/null | sed 's/^/    /'
    ;;
  refused)
    setup yolo=on
    : > "$FORGE_DIR/refuse"
    printf '[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"%s"}]' "$(iso_ago 1200)" > "$FORGE_DIR/rollup"
    echo "== sweep 1: yolo=on, green 20m, CLEAN; forge accepts 'pr merge' but PR stays OPEN (merge does not land); alarm window 5s"
    SWEEP_INTERVAL=3600 sweep 8 FM_PR_GREEN_ALARM_SECS=5; sleep 4
    echo "automatic merge log:"; sed 's/^/    /' "$LAB/state/task-a.pr-poll-green.log"
    ack; sleep 3
    echo "== sweep 2: after the alarm window"
    sweep 40 FM_PR_GREEN_ALARM_SECS=5
    ack; echo "== sweep 3: same head again -> silent, no retry (expect rc=124)"
    SWEEP_INTERVAL=3600 sweep 8 FM_PR_GREEN_ALARM_SECS=5; sleep 2
    echo "forge merge calls total: $(grep -c '^pr merge' "$FM_TEST_GH_LOG")"
    ;;
esac
