#!/usr/bin/env bash
# Live replay of the Herdr + Claude stranded-doorbell bug in an isolated
# fm-lab-* Herdr session (every herdr call routed through bin/fm-herdr-lab.sh).
# Usage: herdr-lag-replay.sh <code-root-under-test> <scenario...>
# Scenarios: short-pause long-pause fragment-ring draft-skip
set -u
CODE_ROOT=$1; shift
WT=/Users/pashupati/.no-mistakes/worktrees/1d27782a5a0a/01M5TG9KBKQ94KNAPZ794NMA7Y
LAB_HELPER=$WT/bin/fm-herdr-lab.sh
. "$WT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name lagreplay)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-lag-replay.XXXXXX")
FAKEBIN=$TMP_ROOT/fakebin; mkdir -p "$FAKEBIN"
INBOX=$TMP_ROOT/replaytask.inbox; mkdir -p "$INBOX/handled"
PIDFILE=$TMP_ROOT/claude.pid
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

cleanup() {
  [ -s "$PIDFILE" ] && kill -CONT "$(cat "$PIDFILE")" 2>/dev/null
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" && log "teardown ok: $SESSION"
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
args=("\$@"); n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ] && [ "\${args[\$((n-1))]}" = "$SESSION" ]; then
  args=("\${args[@]:0:\$((n-2))}")
else echo "wrapper refused" >&2; exit 98; fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || { log "provision failed"; exit 1; }
export PATH="$FAKEBIN:$ORIGINAL_PATH"
export FM_BACKEND_HERDR_PROOF_WAIT=${PROOF_WAIT:-8}
export FM_STATE_OVERRIDE=$TMP_ROOT/state; mkdir -p "$FM_STATE_OVERRIDE"
. "$CODE_ROOT/bin/backends/herdr.sh"
log "code under test: $CODE_ROOT (proof wait $FM_BACKEND_HERDR_PROOF_WAIT s)"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
WS_JSON=$(lab workspace create --cwd "$TMP_ROOT" --label fm-lagreplay --no-focus) || exit 1
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') || exit 1
TARGET="$SESSION:$PANE"
log "lab target $TARGET; claude $(PATH=$ORIGINAL_PATH claude --version | head -1); $(PATH=$ORIGINAL_PATH herdr --version)"
# exec replaces the pane's interactive shell, so no job-control shell steals
# the tty back when the replay SIGSTOPs Claude.
lab pane run "$PANE" "echo \$\$ > $PIDFILE; exec env FM_TASK_INBOX=$INBOX CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null || exit 1

wait_idle() {
  local i=0 trusted=0 screen st
  while [ "$i" -lt 120 ]; do
    screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
    case "$screen" in
      *'bypass permissions on'*)
        st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
        case "$st" in idle|done) return 0 ;; esac ;;
      *'Yes, I trust this folder'*)
        [ "$trusted" = 1 ] || { trusted=1; lab pane send-keys "$PANE" down enter >/dev/null; } ;;
    esac
    i=$((i + 1)); sleep 1
  done
  return 1
}
show_composer() {
  local st c
  st=$(fm_backend_herdr_composer_state "$TARGET" 2>/dev/null)
  c=$(fm_backend_herdr_composer_content "$TARGET" 2>/dev/null)
  log "composer_state=$st content=[$c]"
}
snap() { log "--- pane ($1) ---"; lab pane read "$PANE" --source visible 2>/dev/null | sed '/^[[:space:]]*$/d' | tail -n 14; log "---"; }
clear_composer() { local k; for k in 1 2 3 4 5 6 7 8; do fm_backend_herdr_send_key "$TARGET" C-u >/dev/null; done; sleep 1; }
wait_token() {  # <token> -> 0 when it shows >=2 times (prompt + reply)
  local i=0 n
  while [ "$i" -lt 60 ]; do
    n=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null | grep -F -c "$1" || true)
    [ "$n" -ge 2 ] && return 0
    i=$((i + 1)); sleep 1
  done
  return 1
}

wait_idle || { log "claude never idle"; snap boot; exit 1; }
CPID=$(cat "$PIDFILE"); log "claude pid $CPID ($(ps -o comm= -p "$CPID"))"
DOORBELL=$(. "$CODE_ROOT/bin/fm-task-inbox-lib.sh"; fm_task_inbox_doorbell_line "$INBOX/0001.msg")
log "doorbell (${#DOORBELL} chars): $DOORBELL"
RC=0

for sc in "$@"; do
  wait_idle || { log "not idle before $sc"; RC=1; continue; }
  log "===== scenario: $sc ====="
  [ "$(fm_backend_herdr_composer_state "$TARGET")" = empty ] || { log "composer not empty before $sc"; show_composer; RC=1; continue; }
  case "$sc" in
    short-pause)
      TOKEN="FMLAGSHORT$$_$RANDOM"
      kill -STOP "$CPID"; log "SIGSTOP claude (paused across the typing)"
      out=$TMP_ROOT/short.verdict
      ( fm_backend_herdr_send_text_submit "$TARGET" "Reply with exactly $TOKEN and nothing else." 2 0.4 0.3 > "$out" ) &
      sp=$!
      sleep 3; kill -CONT "$CPID"; log "SIGCONT claude after 3s"
      wait "$sp"; v=$(cat "$out"); log "verdict=$v"
      if wait_token "$TOKEN"; then log "token reply rendered: prompt was submitted"; landed=1; else landed=0; fi
      snap short-pause; show_composer
      if [ "$landed" = 1 ] && [ "$v" != send-failed ]; then log "RESULT short-pause: PASS"; else log "RESULT short-pause: FAIL"; RC=1; fi
      ;;
    long-pause)
      kill -STOP "$CPID"; log "SIGSTOP claude (paused longer than the proof wait)"
      v=$(fm_backend_herdr_send_text_submit "$TARGET" "$DOORBELL" 2 0.4 0.3); log "verdict=$v (claude still stopped)"
      sleep 1; kill -CONT "$CPID"; log "SIGCONT claude"
      sleep 6; snap long-pause; show_composer
      st=$(fm_backend_herdr_composer_state "$TARGET")
      if [ "$v" = send-failed ] && [ "$st" = empty ]; then log "RESULT long-pause: PASS (nothing stranded)"; else log "RESULT long-pause: FAIL (verdict=$v state=$st)"; RC=1; fi
      clear_composer
      ;;
    fragment-ring)
      frag=${DOORBELL:0:110}
      log "planting leading fragment (${#frag} chars): [$frag]"
      fm_backend_herdr_send_literal "$TARGET" "$frag"; sleep 2; show_composer
      rrc=0; ( . "$CODE_ROOT/bin/fm-task-inbox-lib.sh"; fm_task_inbox_ring herdr "$TARGET" "$INBOX/0001.msg" ) || rrc=$?
      log "fm_task_inbox_ring rc=$rrc (0 rang, 1 skipped)"
      sleep 4; snap fragment-ring; show_composer
      st=$(fm_backend_herdr_composer_state "$TARGET")
      if [ "$rrc" = 0 ] && [ "$st" != pending ]; then log "RESULT fragment-ring: PASS (fragment submitted)"; else log "RESULT fragment-ring: FAIL (rc=$rrc state=$st)"; RC=1; fi
      [ "$st" = pending ] && clear_composer
      ;;
    draft-skip)
      draft="please also refactor the parser before lunch"
      fm_backend_herdr_send_literal "$TARGET" "$draft"; sleep 2; show_composer
      rrc=0; ( . "$CODE_ROOT/bin/fm-task-inbox-lib.sh"; fm_task_inbox_ring herdr "$TARGET" "$INBOX/0001.msg" ) || rrc=$?
      log "fm_task_inbox_ring rc=$rrc (0 rang, 1 skipped)"
      sleep 2; show_composer
      c=$(fm_backend_herdr_composer_content "$TARGET")
      if [ "$rrc" = 1 ] && [ "$c" = "$draft" ]; then log "RESULT draft-skip: PASS (draft untouched)"; else log "RESULT draft-skip: FAIL"; RC=1; fi
      clear_composer
      ;;
  esac
done
log "overall rc=$RC"
exit "$RC"
