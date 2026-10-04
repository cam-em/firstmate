#!/usr/bin/env bash
# Regression tests for fm-spawn.sh's pre-acquisition Treehouse lease journal.
#
# Every case uses fake tmux and Treehouse commands, an explicit tmux backend,
# no ambient runtime markers, and a temporary FM_HOME. A failure after
# `treehouse get` must leave a durable journal that fm-teardown can reconcile.
# The process-crash case also blocks a fake get after its helper identity is
# durable, kills only the parent spawn, and proves recovery preserves the
# journal until that exact helper finishes.
# No test launches a real harness, touches a real Treehouse pool, or uses the
# network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-lease-recovery)
REAL_MV=$(command -v mv)

make_case() {  # <name> <task-id>
  local name=$1 id=$2 case_dir home project worktree fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$home/data/$id" "$home/state" "$home/config"
  printf '%s\n' codex > "$home/config/crew-harness"
  printf '%s\n' tmux > "$home/config/backend"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise durable lease recovery for $id.

## Firstmate spec
Preserve the Treehouse lease identity across a failed spawn.
EOF
  fm_git_worktree "$project" "$worktree" "lease-$name"
  touch "$home/state/.last-watcher-beat"

  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  get)
    holder=
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --lease-holder) holder=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -f "${FM_FAKE_JOURNAL:?}" ] \
       && grep -Fxq 'phase=intent' "$FM_FAKE_JOURNAL"; then
      printf '%s\n' intent-before-get >> "${FM_FAKE_TREEHOUSE_LOG:?}"
    fi
    case "${FM_FAKE_FAILURE_MODE:?}" in
      slow)
        printf '%s\n' "$$" > "${FM_FAKE_SLOW_REQUEST_PID:?}"
        : > "${FM_FAKE_SLOW_STARTED:?}"
        while [ ! -f "${FM_FAKE_SLOW_RELEASE:?}" ]; do
          /bin/sleep 0.05
        done
        : > "${FM_FAKE_SLOW_LEASE:?}"
        printf '{"path":"%s","lease_id":"lease-%s","lease_holder":"%s"}\n' \
          "$FM_FAKE_TREEHOUSE_PATH" "$FM_FAKE_TASK_ID" "$holder"
        ;;
      malformed) printf '%s\n' 'not-json' ;;
      holder-mismatch)
        printf '{"path":"%s","lease_id":"lease-%s","lease_holder":"wrong-holder"}\n' \
          "$FM_FAKE_WORKTREE" "$FM_FAKE_TASK_ID" ;;
      nonabsolute)
        printf '{"path":"relative-worktree","lease_id":"lease-%s","lease_holder":"%s"}\n' \
          "$FM_FAKE_TASK_ID" "$holder" ;;
      *)
        printf '{"path":"%s","lease_id":"lease-%s","lease_holder":"%s"}\n' \
          "$FM_FAKE_TREEHOUSE_PATH" "$FM_FAKE_TASK_ID" "$holder" ;;
    esac
    ;;
  status)
    if [ -f "${FM_FAKE_SLOW_STARTED:?}" ] \
       && [ ! -f "${FM_FAKE_SLOW_LEASE:?}" ]; then
      printf '%s\n' '[]'
      exit 0
    fi
    printf '[{"path":"%s","status":"leased","lease_id":"lease-%s","lease_holder":"%s"}]\n' \
      "${FM_FAKE_STATUS_PATH:-$FM_FAKE_WORKTREE}" "$FM_FAKE_TASK_ID" "$FM_FAKE_EXPECTED_HOLDER"
    ;;
  return)
    printf '%s\n' "$*" >> "${FM_FAKE_TREEHOUSE_LOG:?}"
    ;;
esac
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    if [ "${FM_FAKE_FAILURE_MODE:-}" = meta-prepare ]; then
      chmod 500 "$FM_FAKE_STATE"
    fi
    if [ "${FM_FAKE_FAILURE_MODE:-}" = pane-settle ]; then
      printf '%s\n' "$FM_FAKE_PROJECT"
    else
      printf '%s\n' "$FM_FAKE_TREEHOUSE_PATH"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf '%s\n' firstmate; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
last=
for arg in "$@"; do last=$arg; done
if [ "${FM_FAKE_FAILURE_MODE:-}" = meta-publish ] \
   && [ "$last" = "$FM_FAKE_STATE/$FM_FAKE_TASK_ID.meta" ]; then
  exit 1
fi
exec "$FM_REAL_MV" "$@"
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/sleep" "$fakebin/mv"
  printf '%s\n' "$case_dir|$home|$project|$worktree|$fakebin"
}

run_spawn() {  # <record> <task-id> <failure-mode>
  local record=$1 id=$2 mode=$3 case_dir home project worktree fakebin treehouse_path rc=0
  IFS='|' read -r case_dir home project worktree fakebin <<EOF
$record
EOF
  treehouse_path=$worktree
  [ "$mode" != isolation ] || treehouse_path="$case_dir/not-a-git-worktree"
  mkdir -p "$treehouse_path"
  (
    unset HERDR_ENV HERDR_PANE_ID HERDR_SESSION TMUX TMUX_PANE
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_CONFIG_OVERRIDE="$home/config" FM_PROJECTS_OVERRIDE="$home/projects" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_FAILURE_MODE="$mode" \
      FM_FAKE_TASK_ID="$id" FM_FAKE_STATE="$home/state" \
      FM_FAKE_PROJECT="$project" FM_FAKE_WORKTREE="$worktree" \
      FM_FAKE_TREEHOUSE_PATH="$treehouse_path" \
      FM_FAKE_EXPECTED_HOLDER="$id@$home" \
      FM_FAKE_JOURNAL="$home/state/$id.treehouse-lease" \
      FM_FAKE_TREEHOUSE_LOG="$case_dir/treehouse.log" FM_REAL_MV="$REAL_MV" \
      FM_FAKE_SLOW_STARTED="$case_dir/slow.started" \
      FM_FAKE_SLOW_RELEASE="$case_dir/slow.release" \
      FM_FAKE_SLOW_LEASE="$case_dir/slow.lease" \
      FM_FAKE_SLOW_REQUEST_PID="$case_dir/slow.request-pid" \
      PATH="$fakebin:$PATH" \
      "$SPAWN" "$id" "$project" --mode no-mistakes --yolo off 2>&1
  ) || rc=$?
  chmod 700 "$home/state" 2>/dev/null || true
  return "$rc"
}

run_recovery() {  # <record> <task-id> <force-or-empty>
  local record=$1 id=$2 force=$3 case_dir home project worktree fakebin status_path
  IFS='|' read -r case_dir home project worktree fakebin <<EOF
$record
EOF
  status_path=$worktree
  case "$id" in *isolation*) status_path="$case_dir/not-a-git-worktree" ;; esac
  (
    unset HERDR_ENV HERDR_PANE_ID HERDR_SESSION TMUX TMUX_PANE
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_CONFIG_OVERRIDE="$home/config" FM_FAKE_FAILURE_MODE=recovery \
      FM_FAKE_TASK_ID="$id" FM_FAKE_WORKTREE="$worktree" \
      FM_FAKE_STATUS_PATH="$status_path" \
      FM_FAKE_EXPECTED_HOLDER="$id@$home" \
      FM_FAKE_TREEHOUSE_LOG="$case_dir/treehouse.log" \
      FM_FAKE_SLOW_STARTED="$case_dir/slow.started" \
      FM_FAKE_SLOW_RELEASE="$case_dir/slow.release" \
      FM_FAKE_SLOW_LEASE="$case_dir/slow.lease" \
      FM_FAKE_SLOW_REQUEST_PID="$case_dir/slow.request-pid" \
      PATH="$fakebin:$PATH" \
      "$TEARDOWN" "$id" ${force:+"$force"} 2>&1
  )
}

write_v3_journal() {  # <journal> <id> <home> <project> <phase> <worktree> <lease-id> <lease-holder> <state> <helper-pid> <helper-start> <request-pid> <request-start>
  local journal=$1 id=$2 home=$3 project=$4 phase=$5 worktree=$6 lease_id=$7 lease_holder=$8
  local state=$9 helper_pid=${10} helper_start=${11} request_pid=${12} request_start=${13}
  cat > "$journal" <<EOF
schema=fm-treehouse-task-lease.v3
task_id=$id
home=$home
project=$project
backend=tmux
target=firstmate:fm-$id
requested_holder=$id@$home
phase=$phase
worktree=$worktree
lease_id=$lease_id
lease_holder=$lease_holder
acquisition_state=$state
acquisition_pid=$helper_pid
acquisition_identity=$helper_start
request_pid=$request_pid
request_identity=$request_start
EOF
}

test_failure_journals_are_recoverable() {
  local mode phase needs_force id record case_dir home project worktree fakebin out rc journal returned_path
  while IFS='|' read -r mode phase needs_force; do
    [ -n "$mode" ] || continue
    id="lease-$mode"
    record=$(make_case "$mode" "$id")
    IFS='|' read -r case_dir home project worktree fakebin <<EOF
$record
EOF
    out=$(run_spawn "$record" "$id" "$mode")
    rc=$?
    [ "$rc" -ne 0 ] || fail "$mode: injected spawn failure unexpectedly succeeded"
    journal="$home/state/$id.treehouse-lease"
    assert_present "$journal" "$mode: failed spawn did not preserve a lease journal"
    assert_grep "phase=$phase" "$journal" "$mode: journal recorded the wrong recovery phase"
    assert_grep "requested_holder=$id@$home" "$journal" "$mode: journal lost the requested holder"
    assert_absent "$home/state/$id.meta" "$mode: failed spawn left ordinary task metadata"
    assert_grep 'intent-before-get' "$case_dir/treehouse.log" \
      "$mode: Treehouse get ran before the durable intent existed"

    if [ "$needs_force" = yes ]; then
      out=$(run_recovery "$record" "$id" "")
      rc=$?
      [ "$rc" -ne 0 ] || fail "$mode: potentially launched lease recovered without --force"
      assert_present "$journal" "$mode: refused recovery removed the lease journal"
      out=$(run_recovery "$record" "$id" --force)
      rc=$?
    else
      out=$(run_recovery "$record" "$id" "")
      rc=$?
    fi
    expect_code 0 "$rc" "$mode: journal recovery should return the recorded lease"
    assert_absent "$journal" "$mode: successful recovery left the lease journal"
    returned_path=$worktree
    [ "$mode" != isolation ] || returned_path="$case_dir/not-a-git-worktree"
    assert_grep "return --force --if-lease-id lease-$id --if-lease-holder $id@$home $returned_path" \
      "$case_dir/treehouse.log" "$mode: recovery did not conditionally return the current lease"
    rm -rf "$home/state/.$id.meta.spawn."* 2>/dev/null || true
  done <<'ROWS'
malformed|settled|no
holder-mismatch|observed|no
nonabsolute|observed|no
pane-settle|acquired|yes
isolation|acquired|yes
meta-prepare|acquired|yes
meta-publish|acquired|yes
ROWS
  pass "spawn failures preserve recoverable holder or exact Treehouse lease journals"
}

test_existing_recovery_journal_is_never_replaced() {
  local id record case_dir home project worktree fakebin out rc journal
  id=lease-existing-journal
  record=$(make_case existing-journal "$id")
  IFS='|' read -r case_dir home project worktree fakebin <<EOF
$record
EOF
  journal="$home/state/$id.treehouse-lease"
  printf '%s\n' 'existing-recovery-evidence' > "$journal"
  rc=0
  out=$(run_spawn "$record" "$id" malformed) || rc=$?
  [ "$rc" -ne 0 ] || fail "existing-journal: spawn unexpectedly replaced recovery state"
  assert_contains "$out" "interrupted Treehouse lease acquisition" \
    "existing-journal: spawn did not explain the recovery gate"
  [ "$(cat "$journal")" = existing-recovery-evidence ] \
    || fail "existing-journal: refusal removed or replaced the prior recovery evidence"
  assert_absent "$case_dir/treehouse.log" \
    "existing-journal: refusal still requested another Treehouse lease"
  pass "spawn preserves an existing Treehouse recovery journal until teardown reconciles it"
}

test_inflight_acquisition_survives_parent_spawn_crash() {
  local id record case_dir home project worktree fakebin journal out rc spawn_pid helper_pid
  id=lease-slow-parent-crash
  record=$(make_case slow-parent-crash "$id")
  IFS='|' read -r case_dir home project worktree fakebin <<EOF
$record
EOF
  journal="$home/state/$id.treehouse-lease"
  (
    unset HERDR_ENV HERDR_PANE_ID HERDR_SESSION TMUX TMUX_PANE
    exec env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_SPAWN_NO_GUARD=1 \
      FM_FAKE_FAILURE_MODE=slow FM_FAKE_TASK_ID="$id" \
      FM_FAKE_STATE="$home/state" FM_FAKE_PROJECT="$project" \
      FM_FAKE_WORKTREE="$worktree" FM_FAKE_TREEHOUSE_PATH="$worktree" \
      FM_FAKE_EXPECTED_HOLDER="$id@$home" FM_FAKE_JOURNAL="$journal" \
      FM_FAKE_TREEHOUSE_LOG="$case_dir/treehouse.log" FM_REAL_MV="$REAL_MV" \
      FM_FAKE_SLOW_STARTED="$case_dir/slow.started" \
      FM_FAKE_SLOW_RELEASE="$case_dir/slow.release" \
      FM_FAKE_SLOW_LEASE="$case_dir/slow.lease" \
      FM_FAKE_SLOW_REQUEST_PID="$case_dir/slow.request-pid" PATH="$fakebin:$PATH" \
      "$SPAWN" "$id" "$project" --mode no-mistakes --yolo off
  ) > "$case_dir/spawn.out" 2>&1 &
  spawn_pid=$!

  for _ in $(seq 1 200); do
    [ -f "$case_dir/slow.started" ] && break
    kill -0 "$spawn_pid" 2>/dev/null || break
    /bin/sleep 0.01
  done
  assert_present "$case_dir/slow.started" \
    "parent-crash: fake Treehouse get never reached its blocked acquisition"
  assert_present "$journal" "parent-crash: acquisition began without a durable journal"
  assert_grep 'phase=intent' "$journal" \
    "parent-crash: journal did not retain intent while get was blocked"
  assert_grep 'acquisition_state=running' "$journal" \
    "parent-crash: journal did not record the live helper state"
  helper_pid=$(sed -n 's/^acquisition_pid=//p' "$journal")
  case "$helper_pid" in ''|*[!0-9]*) fail "parent-crash: journal did not record a helper pid" ;; esac

  kill -KILL "$spawn_pid"
  wait "$spawn_pid" 2>/dev/null || true
  rc=0
  out=$(run_recovery "$record" "$id" "") || rc=$?
  [ "$rc" -ne 0 ] || fail "parent-crash: recovery succeeded while acquisition helper was live"
  assert_contains "$out" "still has its exact" \
    "parent-crash: recovery did not identify a live acquisition process"
  assert_present "$journal" \
    "parent-crash: refused recovery removed the helper's only durable journal"
  assert_absent "$case_dir/slow.lease" \
    "parent-crash: blocked fake acquisition completed before its release"

  : > "$case_dir/slow.release"
  for _ in $(seq 1 200); do
    [ -f "$case_dir/slow.lease" ] && ! kill -0 "$helper_pid" 2>/dev/null && break
    /bin/sleep 0.01
  done
  assert_present "$case_dir/slow.lease" \
    "parent-crash: surviving acquisition helper did not complete after release"
  kill -0 "$helper_pid" 2>/dev/null \
    && fail "parent-crash: acquisition helper remained live after publishing its result"
  assert_present "$journal" \
    "parent-crash: completed request lost its recovery journal"

  rc=0
  out=$(run_recovery "$record" "$id" "") || rc=$?
  expect_code 0 "$rc" "parent-crash: settled lease recovery should succeed"
  assert_absent "$journal" "parent-crash: successful recovery left its journal"
  assert_grep "return --force --if-lease-id lease-$id --if-lease-holder $id@$home $worktree" \
    "$case_dir/treehouse.log" \
    "parent-crash: recovery did not return the exact late-created lease"
  pass "in-flight Treehouse acquisition survives parent spawn crash until exact recovery"
}

test_request_survives_helper_crash_without_losing_journal() {
  local id record case_dir home project worktree fakebin journal out rc spawn_pid helper_pid request_pid returns
  id=lease-helper-crash
  record=$(make_case helper-crash "$id")
  IFS='|' read -r case_dir home project worktree fakebin <<EOF
$record
EOF
  journal="$home/state/$id.treehouse-lease"
  (
    unset HERDR_ENV HERDR_PANE_ID HERDR_SESSION TMUX TMUX_PANE
    exec env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_SPAWN_NO_GUARD=1 \
      FM_FAKE_FAILURE_MODE=slow FM_FAKE_TASK_ID="$id" \
      FM_FAKE_STATE="$home/state" FM_FAKE_PROJECT="$project" \
      FM_FAKE_WORKTREE="$worktree" FM_FAKE_TREEHOUSE_PATH="$worktree" \
      FM_FAKE_EXPECTED_HOLDER="$id@$home" FM_FAKE_JOURNAL="$journal" \
      FM_FAKE_TREEHOUSE_LOG="$case_dir/treehouse.log" FM_REAL_MV="$REAL_MV" \
      FM_FAKE_SLOW_STARTED="$case_dir/slow.started" \
      FM_FAKE_SLOW_RELEASE="$case_dir/slow.release" \
      FM_FAKE_SLOW_LEASE="$case_dir/slow.lease" \
      FM_FAKE_SLOW_REQUEST_PID="$case_dir/slow.request-pid" PATH="$fakebin:$PATH" \
      "$SPAWN" "$id" "$project" --mode no-mistakes --yolo off
  ) > "$case_dir/spawn.out" 2>&1 &
  spawn_pid=$!

  for _ in $(seq 1 200); do
    [ -f "$case_dir/slow.started" ] && grep -Fxq 'acquisition_state=running' "$journal" 2>/dev/null && break
    /bin/sleep 0.01
  done
  assert_present "$case_dir/slow.started" \
    "helper-crash: fake Treehouse get never reached its blocked acquisition"
  assert_grep 'acquisition_state=running' "$journal" \
    "helper-crash: request process identity was not durable before get"
  helper_pid=$(sed -n 's/^acquisition_pid=//p' "$journal")
  request_pid=$(sed -n 's/^request_pid=//p' "$journal")
  [ "$request_pid" = "$(cat "$case_dir/slow.request-pid")" ] \
    || fail "helper-crash: journal did not identify the actual Treehouse request process"

  kill -KILL "$spawn_pid"
  wait "$spawn_pid" 2>/dev/null || true
  kill -KILL "$helper_pid" 2>/dev/null || true
  for _ in $(seq 1 100); do
    kill -0 "$helper_pid" 2>/dev/null || break
    /bin/sleep 0.01
  done
  kill -0 "$request_pid" 2>/dev/null \
    || fail "helper-crash: Treehouse request did not survive its helper as required by the regression"
  rc=0
  out=$(run_recovery "$record" "$id" "") || rc=$?
  [ "$rc" -ne 0 ] || fail "helper-crash: recovery erased a journal while its request was live"
  assert_contains "$out" "exact request pid $request_pid" \
    "helper-crash: recovery did not name the surviving request"
  assert_present "$journal" \
    "helper-crash: refused recovery removed the request's only durable journal"
  assert_absent "$case_dir/slow.lease" \
    "helper-crash: blocked request completed before release"

  : > "$case_dir/slow.release"
  for _ in $(seq 1 200); do
    [ -f "$case_dir/slow.lease" ] && ! kill -0 "$request_pid" 2>/dev/null && break
    /bin/sleep 0.01
  done
  assert_present "$case_dir/slow.lease" \
    "helper-crash: surviving request did not publish its lease after release"
  kill -0 "$request_pid" 2>/dev/null \
    && fail "helper-crash: request remained live after publishing its lease"
  assert_grep 'phase=intent' "$journal" \
    "helper-crash: an absent helper unexpectedly advanced the journal"

  rc=0
  out=$(run_recovery "$record" "$id" "") || rc=$?
  expect_code 0 "$rc" "helper-crash: completed request should recover its exact lease"
  assert_absent "$journal" "helper-crash: successful recovery left its journal"
  returns=$(grep -c '^return ' "$case_dir/treehouse.log" 2>/dev/null || true)
  [ "$returns" -eq 1 ] || fail "helper-crash: exact recovery returned the lease $returns times"
  pass "a Treehouse request that outlives its helper retains recoverable ownership"
}

test_crash_point_before_get_is_safe() {
  local id record case_dir home project worktree fakebin journal out rc
  id=lease-crash-before-get
  record=$(make_case crash-before-get "$id")
  IFS='|' read -r case_dir home project worktree fakebin <<EOF
$record
EOF
  journal="$home/state/$id.treehouse-lease"
  write_v3_journal "$journal" "$id" "$home" "$project" intent "" "" "" \
    not-started "" "" "" ""
  : > "$case_dir/slow.started"
  rc=0
  out=$(run_recovery "$record" "$id" "") || rc=$?
  expect_code 0 "$rc" "before-get: a never-released request should settle empty"
  assert_absent "$journal" "before-get: empty never-started intent was not retired"
  assert_contains "$out" "no active Treehouse lease remained" \
    "before-get: recovery did not report the empty holder state"
  pass "crash before get clears only a proven never-started intent"
}

test_crash_point_after_get_before_meta_is_safe() {
  local id record case_dir home project worktree fakebin journal out rc
  id=lease-crash-after-get
  record=$(make_case crash-after-get "$id")
  IFS='|' read -r case_dir home project worktree fakebin <<EOF
$record
EOF
  journal="$home/state/$id.treehouse-lease"
  write_v3_journal "$journal" "$id" "$home" "$project" observed "$worktree" \
    "lease-$id" "$id@$home" finished 99999991 dead-helper-start \
    99999992 dead-request-start
  rc=0
  out=$(run_recovery "$record" "$id" "") || rc=$?
  expect_code 0 "$rc" "after-get: observed lease should be returned before metadata exists"
  assert_absent "$journal" "after-get: recovered observed lease left its journal"
  assert_grep "return --force --if-lease-id lease-$id --if-lease-holder $id@$home $worktree" \
    "$case_dir/treehouse.log" "after-get: recovery did not return the observed lease"
  pass "crash after get and before metadata returns the observed lease"
}

test_crash_point_after_meta_requires_force() {
  local id record case_dir home project worktree fakebin journal out rc
  id=lease-crash-after-meta
  record=$(make_case crash-after-meta "$id")
  IFS='|' read -r case_dir home project worktree fakebin <<EOF
$record
EOF
  journal="$home/state/$id.treehouse-lease"
  write_v3_journal "$journal" "$id" "$home" "$project" published "$worktree" \
    "lease-$id" "$id@$home" finished 99999991 dead-helper-start \
    99999992 dead-request-start
  rc=0
  out=$(run_recovery "$record" "$id" "") || rc=$?
  [ "$rc" -ne 0 ] || fail "after-meta: published lease recovered without discard authority"
  assert_contains "$out" "rerun with --force" \
    "after-meta: refusal did not preserve the launched-worker gate"
  assert_present "$journal" "after-meta: refusal removed the published journal"
  rc=0
  out=$(run_recovery "$record" "$id" --force) || rc=$?
  expect_code 0 "$rc" "after-meta: forced published recovery should return the exact lease"
  assert_absent "$journal" "after-meta: successful recovery left its journal"
  pass "crash after metadata publication retains the force-gated exact return"
}

test_legacy_intent_without_helper_identity_is_preserved() {
  local id record case_dir home project worktree fakebin journal out rc
  id=lease-legacy-intent
  record=$(make_case legacy-intent "$id")
  IFS='|' read -r case_dir home project worktree fakebin <<EOF
$record
EOF
  journal="$home/state/$id.treehouse-lease"
  cat > "$journal" <<EOF
schema=fm-treehouse-task-lease.v1
task_id=$id
home=$home
project=$project
backend=tmux
target=firstmate:fm-$id
requested_holder=$id@$home
phase=intent
worktree=
lease_id=
lease_holder=
EOF
  : > "$case_dir/slow.started"
  rc=0
  out=$(run_recovery "$record" "$id" "") || rc=$?
  [ "$rc" -ne 0 ] || fail "legacy-intent: recovery erased an acquisition with no completion proof"
  assert_contains "$out" "completion for $id cannot be proven" \
    "legacy-intent: refusal did not explain the conservative migration behavior"
  assert_present "$journal" \
    "legacy-intent: an empty status removed the only recovery evidence"
  assert_absent "$case_dir/treehouse.log" \
    "legacy-intent: empty status recovery attempted to return a lease"
  pass "legacy acquisition intent stays preserved when helper completion cannot be proven"
}

test_failure_journals_are_recoverable
test_existing_recovery_journal_is_never_replaced
test_crash_point_before_get_is_safe
test_inflight_acquisition_survives_parent_spawn_crash
test_request_survives_helper_crash_without_losing_journal
test_crash_point_after_get_before_meta_is_safe
test_crash_point_after_meta_requires_force
test_legacy_intent_without_helper_identity_is_preserved

echo "# all fm-spawn-lease-recovery tests passed"
