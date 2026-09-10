#!/usr/bin/env bash
# Antigravity hook adapter for Firstmate.
#
# Usage:
#   fm-antigravity-hook.sh sessionstart
#   fm-antigravity-hook.sh primary-stop
#   fm-antigravity-hook.sh task-busy <state-dir> <task-id> <generation>
#   fm-antigravity-hook.sh task-stop <state-dir> <task-id> <generation> <turn-ended-file>
#
# Antigravity discovers .agents/hooks.json in every --add-dir root. The task
# launcher points one added directory at a Firstmate-owned overlay so projects'
# own customization remains untouched. Hook stdin is consumed but never trusted
# for task identity: spawn bakes the canonical state directory, safe task id,
# and fresh busy generation into the isolated hook file.
#
# PreInvocation opens semantic busy state before the model starts or resumes.
# Stop settles that state and publishes the ordinary turn-end edge. Sessionstart
# reuses Firstmate's read-only startup nudge and returns Antigravity's documented
# PreInvocation injectSteps.ephemeralMessage shape.
# Primary Stop translates the shared guard into native continue/stop JSON.
# It is owner-scoped and never uses fullyIdle as model activity: background
# jobs can keep that false after a completed response. Three consecutive repair
# continuations are allowed per home/session failure episode, deduplicated by
# executionNum; recovery clears the budget. Exhaustion records and attempts an
# independent wedge alarm rather than an unbounded model loop. This is a
# backstop, not a detached watcher scheduler. Native checkpoint completion owns
# returning the result; the primary must schedule its successor.
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

usage() {
  echo "usage: $0 sessionstart | primary-stop | task-busy <state-dir> <task-id> <generation> | task-stop <state-dir> <task-id> <generation> <turn-ended-file>" >&2
  exit 2
}

primary_stop() {
  local payload root home state conversation execution owner identity rc=0
  local record lock count=0 previous='' prior_session='' prior_owner='' tmp reason
  payload=$(cat 2>/dev/null || true)
  command -v jq >/dev/null 2>&1 || { printf '{}\n'; return; }
  conversation=$(printf '%s' "$payload" | jq -er '
    select(type == "object" and (.fullyIdle | type) == "boolean") |
    .conversationId | select(type == "string" and test("^[A-Za-z0-9._-]+$"))
  ' 2>/dev/null) || { printf '{}\n'; return; }
  execution=$(printf '%s' "$payload" | jq -er '.executionNum | select(type == "number" and . >= 0 and . == floor)' 2>/dev/null) \
    || { printf '{}\n'; return; }
  root=${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}
  home=${FM_HOME:-$root}
  state=${FM_STATE_OVERRIDE:-$home/state}
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$SCRIPT_DIR/fm-session-lock-lib.sh"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  if ! fm_primary_scope_matches "$root" "$state" || ! fm_session_lock_owned_by_self "$state"; then
    printf '{}\n'; return
  fi
  owner=$(cat "$state/.lock")
  identity=$(fm_pid_identity "$owner") || { printf '{}\n'; return; }
  record="$state/.antigravity-stop-budget"
  lock="$state/.antigravity-stop-budget.lock"
  fm_lock_try_acquire "$lock" || { printf '{}\n'; return; }
  printf '%s' "$payload" | "$SCRIPT_DIR/fm-turnend-guard.sh" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 2 ]; then
    rm -f "$record"
    fm_lock_release "$lock"
    printf '{"decision":"stop"}\n'; return
  fi
  if [ -f "$record" ]; then
    prior_session=$(jq -r '.conversation // empty' "$record" 2>/dev/null) || prior_session=''
    prior_owner=$(jq -r '.owner // empty' "$record" 2>/dev/null) || prior_owner=''
    if [ "$prior_session" = "$conversation" ] && [ "$prior_owner" = "$identity" ]; then
      count=$(jq -r '.count // 0' "$record" 2>/dev/null) || count=0
      previous=$(jq -r '.execution // empty' "$record" 2>/dev/null) || previous=''
    fi
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  [ "$previous" = "$execution" ] || count=$((count + 1))
  # Publish the budget before returning a continuation, so repeated Stop calls
  # cannot create another allowance after a crash or a duplicate hook delivery.
  tmp=$(mktemp "$record.XXXXXX") || { fm_lock_release "$lock"; printf '{}\n'; return; }
  if ! jq -n --arg conversation "$conversation" --arg owner "$identity" \
    --arg execution "$execution" --argjson count "$count" \
    '{conversation:$conversation,owner:$owner,execution:$execution,count:$count}' > "$tmp" \
    || ! mv -f "$tmp" "$record"; then
    rm -f "$tmp"
    fm_lock_release "$lock"
    printf '{}\n'; return
  fi
  fm_lock_release "$lock"
  if [ "$count" -le 3 ]; then
    printf '{"decision":"continue","reason":"Firstmate supervision required: work remains in flight"}\n'
  else
    if [ "$count" -eq 4 ] && [ "$previous" != "$execution" ]; then
      reason='Antigravity supervision is down: three repair continuations did not restore monitoring. Keep the session attended and repair supervision before relying on it.'
      # Reuse the bounded, backend-independent notifier; never inject into the
      # same primary whose continuation/delivery is failing. Sourcing normally
      # disables notifications, so explicitly retain the entrypoint's setting.
      local alarm_exec=${FM_WEDGE_ALARM_EXEC-}
      # shellcheck source=bin/fm-supervise-daemon.sh
      . "$SCRIPT_DIR/fm-supervise-daemon.sh"
      FM_WEDGE_ALARM_EXEC=$alarm_exec
      LOG="$state/.antigravity-stop-alarm.log"
      log "$reason"
      wedge_alarm_notify "$reason" "$record" || true
    fi
    printf '{"decision":"stop"}\n'
  fi
}

mode=${1:-}
case "$mode" in
  primary-stop)
    [ "$#" -eq 1 ] || usage
    primary_stop
    ;;
  sessionstart)
    [ "$#" -eq 1 ] || usage
    cat >/dev/null
    message=$(
      FM_SESSIONSTART_HOOK_MODE=1 \
        "$SCRIPT_DIR/fm-sessionstart-nudge.sh" 2>/dev/null || true
    )
    if [ -n "$message" ]; then
      jq -n --arg message "$message" \
        '{injectSteps:[{ephemeralMessage:$message}]}'
    else
      printf '{}\n'
    fi
    ;;
  task-busy)
    [ "$#" -eq 4 ] || usage
    cat >/dev/null
    "$SCRIPT_DIR/fm-busy-event.sh" apply "$2" "$3" busy \
      --gen "$4" --source antigravity-hook --event pre-invocation >/dev/null 2>&1 || true
    printf '{}\n'
    ;;
  task-stop)
    [ "$#" -eq 5 ] || usage
    cat >/dev/null
    "$SCRIPT_DIR/fm-busy-event.sh" apply "$2" "$3" idle \
      --gen "$4" --source antigravity-hook --event stop >/dev/null 2>&1 || true
    : > "$5"
    printf '{"decision":"stop"}\n'
    ;;
  *) usage ;;
esac
