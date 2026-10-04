#!/usr/bin/env bash
# Durable recovery journal for an ordinary task's Treehouse lease lifecycle.
#
# state/<task-id>.treehouse-lease is created atomically before `treehouse get`
# can reserve a copy.
# It starts in phase=intent with acquisition_state=not-started, records the
# helper as helper-ready, then records both the helper and the gated
# `treehouse get` request by PID plus process-start identity before releasing
# that request.
# The helper advances the journal to settled or observed only after the request
# exits.
# It advances to acquired as structured output is validated, advances to
# published once ordinary task metadata owns the lease, and is removed only
# after a successful spawn commit or a confirmed lease return.
# phase=cleanup is the typed recovery state used while teardown retires durable
# task records before making lease return its final fallible cleanup operation.
# Crash point                 Durable state              Recovery rule
# Before get                  intent:not-started or      No request was released;
#                             intent:helper-ready        wait for the helper to die,
#                                                       then confirm holder state.
# During get                  intent:running             Preserve while either exact
#                                                       process remains alive.
# After get, before meta      intent:running, then       Preserve while the helper is
#                             settled or observed        publishing; after both exact
#                                                       processes are gone, reconcile
#                                                       holder state.
# After meta publication      published, then cleanup    Require --force for journal-only
#                                                       recovery and return exact identity.
# A v2 running intent lacks request-process identity and a v1 intent lacks all
# process proof, so an empty status preserves either for manual reconciliation.
# Exact phases also record the worktree and lease identity but recovery still
# confirms them against current Treehouse state before conditionally returning
# anything.
#
# This file owns the journal format and atomic mutation helpers.

FM_TREEHOUSE_LEASE_JOURNAL_SCHEMA='fm-treehouse-task-lease.v3'
FM_TREEHOUSE_LEASE_JOURNAL_V2_SCHEMA='fm-treehouse-task-lease.v2'
FM_TREEHOUSE_LEASE_JOURNAL_LEGACY_SCHEMA='fm-treehouse-task-lease.v1'

fm_treehouse_process_start_identity() {  # <pid>
  local pid=$1 proc_root stat_line starttime out
  local -a stat_fields
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if [ -r "$proc_root/$pid/stat" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in ''|*[!0-9]*) return 1 ;; esac
    printf 'proc-starttime=%s\n' "$starttime"
    return 0
  fi
  out=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  out=${out#"${out%%[![:space:]]*}"}
  [ -n "$out" ] || return 1
  printf 'ps-lstart=%s\n' "$out"
}

fm_treehouse_lease_journal_path() {  # <state-dir> <task-id>
  printf '%s/%s.treehouse-lease\n' "$1" "$2"
}

fm_treehouse_lease_journal_value() {  # <journal> <key>
  local journal=$1 key=$2 count
  count=$(grep -c "^$key=" "$journal" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  grep "^$key=" "$journal" | cut -d= -f2-
}

fm_treehouse_lease_journal_write() {  # <journal> <task-id> <home> <project> <backend> <target> <requested-holder> <phase> <worktree> <lease-id> <lease-holder> <acquisition-state> <helper-pid> <helper-start> <request-pid> <request-start>
  local journal=$1 task_id=$2 home=$3 project=$4 backend=$5 target=$6
  local requested_holder=$7 phase=$8 worktree=$9 lease_id=${10} lease_holder=${11}
  local acquisition_state=${12} acquisition_pid=${13} acquisition_identity=${14}
  local request_pid=${15} request_identity=${16}
  local tmp old_umask value
  case "$journal" in /*.treehouse-lease) ;; *) return 1 ;; esac
  case "$task_id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$home" in /*) ;; *) return 1 ;; esac
  case "$project" in /*) ;; *) return 1 ;; esac
  [ -n "$requested_holder" ] || return 1
  case "$phase" in intent|settled|observed|acquired|published|cleanup) ;; *) return 1 ;; esac
  case "$acquisition_state" in not-started|helper-ready|running|finished|not-applicable) ;; *) return 1 ;; esac
  case "$acquisition_state" in
    not-started|not-applicable)
      [ -z "$acquisition_pid" ] && [ -z "$acquisition_identity" ] \
        && [ -z "$request_pid" ] && [ -z "$request_identity" ] || return 1
      ;;
    helper-ready)
      case "$acquisition_pid" in ''|*[!0-9]*) return 1 ;; esac
      [ -n "$acquisition_identity" ] || return 1
      [ -z "$request_pid" ] && [ -z "$request_identity" ] || return 1
      ;;
    running|finished)
      case "$acquisition_pid:$request_pid" in
        *[!0-9:]*|:*|*:) return 1 ;;
      esac
      [ -n "$acquisition_identity" ] && [ -n "$request_identity" ] || return 1
      ;;
  esac
  case "$phase:$acquisition_state" in
    intent:not-started|intent:helper-ready|intent:running|settled:finished|observed:finished|\
    acquired:finished|published:finished|cleanup:not-applicable) ;;
    *) return 1 ;;
  esac
  for value in "$task_id" "$home" "$project" "$backend" "$target" \
      "$requested_holder" "$phase" "$worktree" "$lease_id" "$lease_holder" \
      "$acquisition_state" "$acquisition_pid" "$acquisition_identity" \
      "$request_pid" "$request_identity"; do
    case "$value" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  done
  mkdir -p "$(dirname "$journal")" || return 1
  tmp="$journal.tmp.${BASHPID:-$$}.$RANDOM"
  old_umask=$(umask)
  umask 077
  {
    printf 'schema=%s\n' "$FM_TREEHOUSE_LEASE_JOURNAL_SCHEMA"
    printf 'task_id=%s\n' "$task_id"
    printf 'home=%s\n' "$home"
    printf 'project=%s\n' "$project"
    printf 'backend=%s\n' "$backend"
    printf 'target=%s\n' "$target"
    printf 'requested_holder=%s\n' "$requested_holder"
    printf 'phase=%s\n' "$phase"
    printf 'worktree=%s\n' "$worktree"
    printf 'lease_id=%s\n' "$lease_id"
    printf 'lease_holder=%s\n' "$lease_holder"
    printf 'acquisition_state=%s\n' "$acquisition_state"
    printf 'acquisition_pid=%s\n' "$acquisition_pid"
    printf 'acquisition_identity=%s\n' "$acquisition_identity"
    printf 'request_pid=%s\n' "$request_pid"
    printf 'request_identity=%s\n' "$request_identity"
  } > "$tmp" || {
    umask "$old_umask"
    rm -f -- "$tmp"
    return 1
  }
  umask "$old_umask"
  mv -f -- "$tmp" "$journal" || {
    rm -f -- "$tmp"
    return 1
  }
}

fm_treehouse_lease_journal_load() {  # <journal> <expected-task-id>
  local journal=$1 expected_id=$2 schema
  FM_TREEHOUSE_LEASE_TASK_ID=
  FM_TREEHOUSE_LEASE_HOME=
  FM_TREEHOUSE_LEASE_PROJECT=
  FM_TREEHOUSE_LEASE_BACKEND=
  FM_TREEHOUSE_LEASE_TARGET=
  FM_TREEHOUSE_LEASE_REQUESTED_HOLDER=
  FM_TREEHOUSE_LEASE_PHASE=
  FM_TREEHOUSE_LEASE_WORKTREE=
  FM_TREEHOUSE_LEASE_ID=
  FM_TREEHOUSE_LEASE_HOLDER=
  FM_TREEHOUSE_LEASE_ACQUISITION_STATE=
  FM_TREEHOUSE_LEASE_ACQUISITION_PID=
  FM_TREEHOUSE_LEASE_ACQUISITION_IDENTITY=
  FM_TREEHOUSE_LEASE_REQUEST_PID=
  FM_TREEHOUSE_LEASE_REQUEST_IDENTITY=
  FM_TREEHOUSE_LEASE_PROCESS_PROOF=
  [ -f "$journal" ] && [ ! -L "$journal" ] || return 1
  schema=$(fm_treehouse_lease_journal_value "$journal" schema) || return 1
  case "$schema" in
    "$FM_TREEHOUSE_LEASE_JOURNAL_SCHEMA") ;;
    "$FM_TREEHOUSE_LEASE_JOURNAL_V2_SCHEMA") ;;
    "$FM_TREEHOUSE_LEASE_JOURNAL_LEGACY_SCHEMA") ;;
    *) return 1 ;;
  esac
  FM_TREEHOUSE_LEASE_TASK_ID=$(fm_treehouse_lease_journal_value "$journal" task_id) || return 1
  [ "$FM_TREEHOUSE_LEASE_TASK_ID" = "$expected_id" ] || return 1
  FM_TREEHOUSE_LEASE_HOME=$(fm_treehouse_lease_journal_value "$journal" home) || return 1
  FM_TREEHOUSE_LEASE_PROJECT=$(fm_treehouse_lease_journal_value "$journal" project) || return 1
  # shellcheck disable=SC2034 # Public loader fields consumed by sourcing scripts.
  FM_TREEHOUSE_LEASE_BACKEND=$(fm_treehouse_lease_journal_value "$journal" backend) || return 1
  # shellcheck disable=SC2034 # Public loader fields consumed by sourcing scripts.
  FM_TREEHOUSE_LEASE_TARGET=$(fm_treehouse_lease_journal_value "$journal" target) || return 1
  FM_TREEHOUSE_LEASE_REQUESTED_HOLDER=$(fm_treehouse_lease_journal_value "$journal" requested_holder) || return 1
  FM_TREEHOUSE_LEASE_PHASE=$(fm_treehouse_lease_journal_value "$journal" phase) || return 1
  FM_TREEHOUSE_LEASE_WORKTREE=$(fm_treehouse_lease_journal_value "$journal" worktree) || return 1
  FM_TREEHOUSE_LEASE_ID=$(fm_treehouse_lease_journal_value "$journal" lease_id) || return 1
  FM_TREEHOUSE_LEASE_HOLDER=$(fm_treehouse_lease_journal_value "$journal" lease_holder) || return 1
  if [ "$schema" = "$FM_TREEHOUSE_LEASE_JOURNAL_SCHEMA" ]; then
    FM_TREEHOUSE_LEASE_ACQUISITION_STATE=$(fm_treehouse_lease_journal_value "$journal" acquisition_state) || return 1
    FM_TREEHOUSE_LEASE_ACQUISITION_PID=$(fm_treehouse_lease_journal_value "$journal" acquisition_pid) || return 1
    FM_TREEHOUSE_LEASE_ACQUISITION_IDENTITY=$(fm_treehouse_lease_journal_value "$journal" acquisition_identity) || return 1
    FM_TREEHOUSE_LEASE_REQUEST_PID=$(fm_treehouse_lease_journal_value "$journal" request_pid) || return 1
    FM_TREEHOUSE_LEASE_REQUEST_IDENTITY=$(fm_treehouse_lease_journal_value "$journal" request_identity) || return 1
    FM_TREEHOUSE_LEASE_PROCESS_PROOF=complete
  elif [ "$schema" = "$FM_TREEHOUSE_LEASE_JOURNAL_V2_SCHEMA" ]; then
    FM_TREEHOUSE_LEASE_ACQUISITION_STATE=$(fm_treehouse_lease_journal_value "$journal" acquisition_state) || return 1
    FM_TREEHOUSE_LEASE_ACQUISITION_PID=$(fm_treehouse_lease_journal_value "$journal" acquisition_pid) || return 1
    FM_TREEHOUSE_LEASE_ACQUISITION_IDENTITY=$(fm_treehouse_lease_journal_value "$journal" acquisition_identity) || return 1
    FM_TREEHOUSE_LEASE_PROCESS_PROOF=helper-only
  else
    FM_TREEHOUSE_LEASE_ACQUISITION_STATE=legacy
  fi
  case "$FM_TREEHOUSE_LEASE_HOME" in /*) ;; *) return 1 ;; esac
  case "$FM_TREEHOUSE_LEASE_PROJECT" in /*) ;; *) return 1 ;; esac
  [ -n "$FM_TREEHOUSE_LEASE_REQUESTED_HOLDER" ] || return 1
  case "$FM_TREEHOUSE_LEASE_PHASE" in
    intent|settled|observed) ;;
    acquired|published|cleanup)
      case "$FM_TREEHOUSE_LEASE_WORKTREE" in /*) ;; *) return 1 ;; esac
      [ -n "$FM_TREEHOUSE_LEASE_ID" ] \
        && [ "$FM_TREEHOUSE_LEASE_HOLDER" = "$FM_TREEHOUSE_LEASE_REQUESTED_HOLDER" ] \
        || return 1
      ;;
    *) return 1 ;;
  esac
  case "$FM_TREEHOUSE_LEASE_ACQUISITION_STATE" in
    legacy) ;;
    not-started|not-applicable)
      [ -z "$FM_TREEHOUSE_LEASE_ACQUISITION_PID" ] \
        && [ -z "$FM_TREEHOUSE_LEASE_ACQUISITION_IDENTITY" ] \
        && [ -z "$FM_TREEHOUSE_LEASE_REQUEST_PID" ] \
        && [ -z "$FM_TREEHOUSE_LEASE_REQUEST_IDENTITY" ] \
        || return 1
      ;;
    helper-ready)
      case "$FM_TREEHOUSE_LEASE_ACQUISITION_PID" in ''|*[!0-9]*) return 1 ;; esac
      [ -n "$FM_TREEHOUSE_LEASE_ACQUISITION_IDENTITY" ] || return 1
      [ -z "$FM_TREEHOUSE_LEASE_REQUEST_PID" ] \
        && [ -z "$FM_TREEHOUSE_LEASE_REQUEST_IDENTITY" ] || return 1
      ;;
    running|finished)
      case "$FM_TREEHOUSE_LEASE_ACQUISITION_PID" in ''|*[!0-9]*) return 1 ;; esac
      [ -n "$FM_TREEHOUSE_LEASE_ACQUISITION_IDENTITY" ] || return 1
      if [ "$FM_TREEHOUSE_LEASE_PROCESS_PROOF" = complete ]; then
        case "$FM_TREEHOUSE_LEASE_REQUEST_PID" in ''|*[!0-9]*) return 1 ;; esac
        [ -n "$FM_TREEHOUSE_LEASE_REQUEST_IDENTITY" ] || return 1
      fi
      ;;
    *) return 1 ;;
  esac
  if [ "$FM_TREEHOUSE_LEASE_ACQUISITION_STATE" != legacy ]; then
    case "$FM_TREEHOUSE_LEASE_PHASE:$FM_TREEHOUSE_LEASE_ACQUISITION_STATE" in
      intent:not-started|intent:helper-ready|intent:running|settled:finished|observed:finished|\
      acquired:finished|published:finished|cleanup:not-applicable) ;;
      *) return 1 ;;
    esac
  fi
}

fm_treehouse_lease_journal_remove() {  # <journal>
  local journal=$1
  if [ ! -e "$journal" ] && [ ! -L "$journal" ]; then
    return 0
  fi
  [ -f "$journal" ] && [ ! -L "$journal" ] || return 1
  rm -f -- "$journal"
}
