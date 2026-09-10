#!/usr/bin/env bash
# Portable behavior tests for the Google Antigravity CLI (`agy`) adapter.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-antigravity-harness)

clear_identity_env() {
  env -u ANTIGRAVITY_AGENT -u AI_AGENT -u CLAUDECODE -u GEMINI_CLI \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u PI_CODING_AGENT -u FM_PI_HARNESS \
    -u GROK_AGENT "$@"
}

test_marker_precedence_and_ai_agent_rejection() {
  local out
  out=$(ANTIGRAVITY_AGENT=1 PI_CODING_AGENT=true FM_PI_HARNESS=pi AI_AGENT=pi "$HARNESS")
  [ "$out" = antigravity ] || fail "Antigravity's own marker must outrank inherited Pi identity, got '$out'"
  out=$(clear_identity_env AI_AGENT=antigravity "$HARNESS")
  [ "$out" != antigravity ] || fail "AI_AGENT must never claim Antigravity identity"
  out=$(clear_identity_env ANTIGRAVITY_AGENT=0 "$HARNESS")
  [ "$out" != antigravity ] || fail "only ANTIGRAVITY_AGENT=1 is the verified marker"
  pass "fm-harness.sh: Antigravity marker precedence rejects inherited AI_AGENT"
}

test_exact_agy_ancestry_only() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/ancestry")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' "${FAKE_PS_COMM:?}" ;;
  *"args="*) printf '%s\n' "${FAKE_PS_ARGS:-}" ;;
  *"ppid="*) printf '1\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  out=$(clear_identity_env FAKE_PS_COMM=/Users/u/.local/bin/agy FAKE_PS_ARGS='agy' PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = antigravity ] || fail "exact agy ancestry must identify Antigravity, got '$out'"
  out=$(clear_identity_env FAKE_PS_COMM=agy-helper FAKE_PS_ARGS='agy-helper' PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != antigravity ] || fail "agy-helper must not claim Antigravity identity"
  out=$(clear_identity_env FAKE_PS_COMM=node FAKE_PS_ARGS='node app.js --model agy' PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != antigravity ] || fail "an unrelated argument mentioning agy must not claim identity"
  pass "fm-harness.sh: only exact agy ancestry claims Antigravity"
}

test_control_and_busy_contracts() {
  local out
  fm_control_harness_supported antigravity || fail "antigravity must be a supported harness"
  [ "$(fm_control_harness_family agy-1.1.26)" = antigravity ] || fail "agy* records must normalize to antigravity"
  [ "$(fm_control_interrupt_key antigravity)" = Escape ] || fail "Antigravity interrupt must be Escape"
  [ "$(fm_control_interrupt_repeat antigravity)" = 1 ] || fail "Antigravity interrupt must be one key"
  [ -z "$(fm_control_interrupt_clear_key antigravity)" ] || fail "Antigravity interrupt must not clear the composer"
  [ "$(fm_control_exit_command antigravity)" = /quit ] || fail "Antigravity exit must be /quit"
  fm_control_harness_supports_kind antigravity ship || fail "Antigravity must support workers"
  fm_control_harness_supports_kind antigravity scout || fail "Antigravity must support scouts"
  fm_control_harness_supports_kind antigravity secondmate || fail "Antigravity must support second mates"
  out=$(fm_control_harness_wiring_paths antigravity /wt /state task-a)
  [ "$out" = /state/task-a.antigravity-hooks/.agents/hooks.json ] \
    || fail "unexpected Antigravity wiring path: '$out'"
  printf 'working  esc to cancel\n' | fm_busy_lines_match antigravity \
    || fail "Antigravity's stable busy footer must match"
  ! printf 'Working...\n' | fm_busy_lines_match antigravity \
    || fail "Antigravity must not borrow Pi's busy signature"
  pass "control and busy owners carry Antigravity's verified mechanics"
}

test_separated_shell_glyph_requires_antigravity_identity() {
  local caps screen typed
  caps=$(printf 'styled=0\ncursor=0\nidentity=1\nrows=40')
  screen=$(printf '%s\n' '────────────────────' '>' '────────────────────')
  typed=$(printf '%s\n' '────────────────────' '> queued steer' '────────────────────')
  [ "$(fm_composer_classify_screen "$caps" "$screen")" = need-identity ] \
    || fail "the separated Antigravity shape must request live identity"
  [ "$(fm_composer_classify_screen "$caps" "$screen" '' $'antigravity\tidle')" = empty ] \
    || fail "idle Antigravity plus its separator pair must prove empty"
  [ "$(fm_composer_classify_screen "$caps" "$typed" '' $'antigravity\tidle')" = pending ] \
    || fail "typed Antigravity composer content must remain pending"
  [ "$(fm_composer_classify_screen "$caps" "$screen" '' $'pi\tidle')" = pending ] \
    || fail "Pi identity must not reinterpret a shell-like > as furniture"
  [ "$(fm_composer_classify_screen "$caps" "$screen" '' probe-absent)" = unknown ] \
    || fail "a separator pair with no live identity must remain unknown"
  [ "$(fm_composer_classify_screen "$caps" '>' '' $'antigravity\tidle')" = unknown ] \
    || fail "a bare > must remain a dead-shell prompt under Antigravity identity"
  pass "composer classifier gates Antigravity's > row on identity plus structure"
}

test_hook_transport_and_task_lifecycle() {
  local state id gen turn out
  state="$TMP_ROOT/hook-state"
  id=agy-hook
  turn="$state/$id.turn-ended"
  mkdir -p "$state"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id") || fail "could not arm task activity"
  out=$(printf '{}\n' | "$ROOT/bin/fm-antigravity-hook.sh" task-busy "$state" "$id" "$gen")
  [ "$out" = '{}' ] || fail "PreInvocation task hook must emit an empty object"
  case "$(fm_busy_record_read "$state" "$id")" in busy\ antigravity-hook\ *) ;; *) fail "task hook did not publish busy" ;; esac
  out=$(printf '{}\n' | "$ROOT/bin/fm-antigravity-hook.sh" task-stop "$state" "$id" "$gen" "$turn")
  [ "$(printf '%s' "$out" | jq -r .decision)" = stop ] || fail "Stop hook must allow termination"
  [ -f "$turn" ] || fail "Stop hook must publish the turn-end edge"
  case "$(fm_busy_record_read "$state" "$id")" in idle\ antigravity-hook\ *) ;; *) fail "task hook did not settle activity" ;; esac
  jq -e '
    has("firstmate-sessionstart") and
    ."firstmate-sessionstart".PreInvocation[0].command == "../bin/fm-antigravity-hook.sh sessionstart" and
    ."firstmate-shell-seatbelts".PreToolUse[0].matcher == "run_command" and
    ."firstmate-delegation-seatbelt".PreToolUse[0].matcher == "*"
  ' "$ROOT/.agents/hooks.json" >/dev/null || fail "tracked Antigravity primary hooks have the wrong native schema"
  pass "Antigravity hook transport publishes task lifecycle and native primary wiring"
}

make_primary_fixture() {
  local fixture=$1
  mkdir -p "$fixture/state"
  printf '# Firstmate\n' > "$fixture/AGENTS.md"
  ln -s "$ROOT/bin" "$fixture/bin"
  git -C "$fixture" init -q
}

test_native_pretool_deny_transport() {
  local fixture payload out status
  fixture="$TMP_ROOT/primary"
  make_primary_fixture "$fixture"
  payload='{"toolCall":{"name":"run_command","args":{"CommandLine":"bin/fm-watch-arm.sh && echo bundled"}}}'
  out=$(printf '%s\n' "$payload" | FM_ROOT_OVERRIDE="$fixture" FM_HOME="$fixture" \
    "$ROOT/bin/fm-arm-pretool-check.sh" --antigravity)
  status=$?
  [ "$status" -eq 0 ] || fail "Antigravity deny transport must exit zero for the hook host"
  [ "$(printf '%s' "$out" | jq -r .decision)" = deny ] || fail "watcher-arm seatbelt did not emit native deny"

  payload='{"toolCall":{"name":"run_command","args":{"CommandLine":"cd projects/example"}}}'
  out=$(printf '%s\n' "$payload" | FM_ROOT_OVERRIDE="$fixture" FM_HOME="$fixture" \
    "$ROOT/bin/fm-cd-pretool-check.sh" --antigravity)
  [ "$(printf '%s' "$out" | jq -r .decision)" = deny ] || fail "cd seatbelt did not emit native deny"

  # invoke_subagent and send_message are the exact Antigravity 1.1.26 tool
  # names observed in a live Gemini delegation turn.
  payload='{"toolCall":{"name":"invoke_subagent","args":{}}}'
  out=$(printf '%s\n' "$payload" | FM_ROOT_OVERRIDE="$fixture" FM_HOME="$fixture" \
    "$ROOT/bin/fm-subagent-pretool-check.sh" --antigravity)
  [ "$(printf '%s' "$out" | jq -r .decision)" = deny ] || fail "delegation seatbelt did not emit native deny"
  pass "Antigravity PreToolUse payloads receive native deny responses"
}

test_spawn_builds_canonical_antigravity_launch() {
  local case_dir home proj wt fakebin id launchlog out launch hooks
  case_dir="$TMP_ROOT/spawn"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  launchlog="$case_dir/launch.log"
  id=agy-spawn
  fm_test_spawn_home "$home" antigravity
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" agy-spawn-worktree \
    || fail "could not create the canonical Antigravity isolated worktree"
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '1.1.26\n' ;;
  models) printf 'gemini-test-low\tGemini Test Low\ngemini-test-medium\tGemini Test Medium\nother-model\tOther Model\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/agy"
  : > "$launchlog"
  if ! out=$(FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$home" "$wt" "$fakebin" \
    "$id" "$proj" --harness antigravity --model gemini-test-low --effort low \
    --mode no-mistakes --yolo off); then
    fail "Antigravity spawn failed: $out"
  fi
  launch=$(cat "$launchlog")
  assert_contains "$launch" "--dangerously-skip-permissions" "spawn omitted autonomous permission mode"
  assert_contains "$launch" "--add-dir '$wt'" "spawn omitted the exact isolated project"
  assert_contains "$launch" "--add-dir '$home/state/$id.antigravity-hooks'" "spawn omitted the hook overlay"
  assert_contains "$launch" "--model 'gemini-test-low'" "spawn omitted the selected Gemini model"
  assert_contains "$launch" "--effort 'low'" "spawn omitted native effort"
  assert_contains "$launch" "--prompt-interactive" "spawn did not select the persistent TUI"
  assert_contains "$launch" "env -u AI_AGENT" "spawn did not clear inherited generic identity"
  hooks="$home/state/$id.antigravity-hooks/.agents/hooks.json"
  jq -e '."firstmate-task-lifecycle".PreInvocation[0].command and ."firstmate-task-lifecycle".Stop[0].command' \
    "$hooks" >/dev/null || fail "spawn did not write native task hook schema"
  jq -e '."firstmate-task-lifecycle".PreInvocation[0].command | contains("fm-antigravity-hook.sh") and contains("task-busy")' \
    "$hooks" >/dev/null || fail "task hook omitted busy transport"
  jq -e '."firstmate-task-lifecycle".Stop[0].command | contains("fm-antigravity-hook.sh") and contains("task-stop")' \
    "$hooks" >/dev/null || fail "task hook omitted Stop transport"
  pass "fm-spawn.sh builds the canonical Antigravity worker launch and isolated hooks"
}

test_spawn_defaults_to_gemini_and_enforces_verified_boundaries() {
  local case_dir home proj proj_other proj_old wt fakebin id launchlog out launch status
  case_dir="$TMP_ROOT/spawn-gemini-only"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  launchlog="$case_dir/launch.log"
  id=agy-default
  fm_test_spawn_home "$home" antigravity
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" agy-default-worktree \
    || fail "could not create the default-model isolated worktree"
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '1.1.26\n' ;;
  models) printf 'gemini-test-low\tGemini Test Low\ngemini-test-medium\tGemini Test Medium\nother-model\tOther Model\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/agy"
  : > "$launchlog"
  if ! out=$(FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$home" "$wt" "$fakebin" \
    "$id" "$proj" --harness antigravity --effort medium --mode no-mistakes --yolo off); then
    fail "default-model Antigravity spawn failed: $out"
  fi
  launch=$(cat "$launchlog")
  assert_contains "$launch" "--model 'gemini-test-medium'" \
    "default Antigravity selection did not prefer the requested Gemini effort"
  assert_grep 'model=gemini-test-medium' "$home/state/$id.meta" \
    "task record did not persist the concrete Gemini selection"

  id=agy-other-family
  wt="$case_dir/wt-other"
  proj_other="$case_dir/project-other"
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj_other" "$wt" agy-other-worktree \
    || fail "could not create the non-Gemini refusal worktree"
  : > "$launchlog"
  set +e
  out=$(FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$home" "$wt" "$fakebin" \
    "$id" "$proj_other" --harness antigravity --model other-model --effort low \
    --mode no-mistakes --yolo off)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "Antigravity must reject a model outside the Gemini family"
  assert_contains "$out" "adapter is Gemini-only" "non-Gemini refusal did not explain the boundary"
  [ ! -s "$launchlog" ] || fail "a refused non-Gemini model must launch no pane command"

  id=agy-old-version
  wt="$case_dir/wt-old"
  proj_old="$case_dir/project-old"
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj_old" "$wt" agy-old-worktree \
    || fail "could not create the old-version refusal worktree"
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '1.1.25\n' ;;
  models) printf 'gemini-test-low\tGemini Test Low\n' ;;
esac
exit 0
SH
  : > "$launchlog"
  set +e
  out=$(FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$home" "$wt" "$fakebin" \
    "$id" "$proj_old" --harness antigravity --model gemini-test-low --effort low \
    --mode no-mistakes --yolo off)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "Antigravity must reject a CLI older than 1.1.26"
  assert_contains "$out" "1.1.26 or newer is required" \
    "old-version refusal did not explain the verified floor"
  [ ! -s "$launchlog" ] || fail "a refused old Antigravity CLI must launch no pane command"
  pass "fm-spawn.sh defaults to Gemini and enforces model and version boundaries"
}

test_positional_secondmate_adapter_reaches_antigravity_launch() {
  local case_dir home wt fakebin id launchlog sm out launch
  case_dir="$TMP_ROOT/secondmate-positional"
  home="$case_dir/home"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  launchlog="$case_dir/launch.log"
  id=agy-secondmate
  fm_test_spawn_home "$home" codex
  sm="$case_dir/secondmate-home"
  mkdir -p "$sm/data" "$sm/.agents"
  ln -s "$ROOT/bin" "$sm/bin"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
  printf '{}\n' > "$sm/.agents/hooks.json"
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '1.1.26\n' ;;
  models) printf 'gemini-test-low\tGemini Test Low\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/agy"
  : > "$launchlog"
  if ! out=$(FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$home" "$wt" "$fakebin" \
    "$id" "$sm" antigravity --model gemini-test-low --effort low --secondmate); then
    fail "positional Antigravity secondmate spawn failed: $out"
  fi
  assert_contains "$out" "spawned $id harness=antigravity kind=secondmate" \
    "positional adapter was not classified as the secondmate harness"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "--add-dir '$sm'" \
    "positional Antigravity secondmate did not launch in its persistent home"
  assert_not_contains "$launch" "$home/state/$id.antigravity-hooks" \
    "persistent Antigravity secondmate received a worker hook overlay"
  pass "fm-spawn.sh accepts Antigravity through the positional secondmate interface"
}

test_remote_secondmate_preflight_accepts_antigravity() {
  local case_dir home fakebin id out status
  case_dir="$TMP_ROOT/remote-secondmate"
  home="$case_dir/home"
  fakebin=$(fm_fakebin "$case_dir/fake")
  id=agy-remote
  fm_test_spawn_home "$home" codex
  printf -- '- %s - remote Antigravity fixture (host: remote-mac; root: /remote/firstmate; home: /remote/agy; scope: adapter routing; projects: ; added 2026-09-04)\n' \
    "$id" > "$home/data/secondmates.md"
  cat > "$fakebin/fake-ssh" <<'SH'
#!/usr/bin/env bash
exit 255
SH
  chmod +x "$fakebin/fake-ssh"
  set +e
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SSH_BIN="$fakebin/fake-ssh" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-spawn.sh" "$id" --harness antigravity --secondmate 2>&1)
  status=$?
  set -e
  [ "$status" -eq 255 ] || fail "remote Antigravity route did not reach readiness, rc=$status: $out"
  assert_contains "$out" "readiness could not be confirmed" \
    "remote Antigravity route was rejected before remote readiness"
  assert_not_contains "$out" "requires a verified harness adapter" \
    "remote Antigravity route still failed the verified-adapter preflight"
  pass "fm-spawn.sh accepts Antigravity through the remote secondmate interface"
}

# Exercise the real Herdr adapter, shared composer, daemon guards, and submit
# loop. Only the native terminal boundary is faked; the defect cannot be hidden
# by stubbing busy_state or composer_state to the desired answer.
test_background_delivery_boundary() (
  local state FIXTURE_RULE=background_tasks_working FIXTURE_NATIVE=working FIXTURE_AGENT=agy FIXTURE_MODE=land out rc
  state="$TMP_ROOT/delivery"
  mkdir -p "$state"
  export FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$state" FM_DAEMON_PRIMARY_HARNESS=antigravity
  export FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET=fixture:w1:p1
  export FM_BACKEND_HERDR_SUBMIT_POLLS=1 FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0
  export FM_INJECT_CONFIRM_SLEEP=0
  . "$ROOT/bin/fm-supervise-daemon.sh"
  fm_backend_source herdr
  LOG="$state/log"
  touch "$state/.afk" "$LOG"
  screen_file="$state/screen"
  initial=$(printf '%s\n' '────────────────────' '>' '────────────────────' \
    '  ● [12:00:01] sleep 600 running' '  ↓ 5 more' '────────────────────' \
    '? for shortcuts     Gemini 3.8 Flash · low · 9 task(s) · /tasks')
  printf '%s\n' "$initial" > "$screen_file"
  fm_backend_target_exists() { return 0; }
  # shellcheck disable=SC2329 # Called through the production backend dispatcher.
  fm_backend_herdr_target_ready() { fm_backend_herdr_parse_target "$1"; }
  # shellcheck disable=SC2329 # Native I/O boundary used by the production adapter.
  fm_backend_herdr_cli() {
    shift
    case "$1 $2" in
      'agent get') jq -n --arg a "$FIXTURE_AGENT" --arg s "$FIXTURE_NATIVE" '{result:{agent:{agent:$a,agent_status:$s}}}' ;;
      'agent explain')
        [ "$FIXTURE_RULE" != unreadable ] || return 1
        jq -n --arg rule "$FIXTURE_RULE" '{agent:"agy",state:"working",matched_rule:{id:$rule},evaluated_rules:[
          {id:"permission_prompt",matched:($rule == "permission_prompt")},
          {id:"spinner_working",matched:($rule == "spinner_working")},
          {id:"background_tasks_working",matched:true}]}'
        ;;
      'pane read') cat "$screen_file" ;;
      'pane send-text')
        printf 'typed\n' >> "$state/sends"
        printf '%s\n' "$initial" | sed 's/^>$/ > injected result/' > "$screen_file"
        ;;
      'pane send-keys')
        printf 'enter\n' >> "$state/enters"
        [ "$FIXTURE_MODE" != land ] || printf '%s\n' "$initial" > "$screen_file"
        ;;
      *) return 1 ;;
    esac
  }
  [ "$(fm_backend_busy_state herdr fixture:w1:p1)" = busy ] || fail 'worker aggregate must remain busy'
  [ "$(fm_backend_busy_state herdr fixture:w1:p1 delivery)" = idle ] || fail 'background-only activity must be input-idle'
  [ "$(fm_backend_composer_state herdr fixture:w1:p1)" = empty ] || fail 'three-rule background footer hid the prompt'
  printf 'actionable result\n' > "$state/.subsuper-escalations"
  escalate_flush "$state" || fail 'background-only primary still starves injection'
  [ ! -s "$state/.subsuper-escalations" ] || fail 'confirmed delivery did not retire buffer'
  [ "$(wc -l < "$state/sends" | tr -d ' ')" = 1 ] || fail 'message must be typed once'
  ! grep -q 'inject deferred' "$LOG" || fail 'background-only primary deferred'

  # A swallowed Enter must NOT be confirmed by the unchanged aggregate working
  # level, either through wait_for_working or the queued-Enter conversion.
  FIXTURE_MODE=swallow
  out=$(fm_backend_herdr_send_text_submit fixture:w1:p1 result 2 0 0)
  [ "$out" = pending ] || fail "unchanged aggregate working falsely confirmed a swallowed Enter: $out"
  [ "$(wc -l < "$state/sends" | tr -d ' ')" = 2 ] || fail 'Enter retry retyped the message'
  [ "$(wc -l < "$state/enters" | tr -d ' ')" = 3 ] || fail 'swallowed Enter was not retried exactly once'
  rc=0
  printf 'another result\n' > "$state/.subsuper-escalations"
  escalate_flush "$state" || rc=$?
  [ "$rc" -ne 0 ] && [ -s "$state/.subsuper-escalations" ] || fail 'pending input lost its escalation obligation'
  printf '%s\n' "$initial" > "$screen_file"
  FIXTURE_RULE=spinner_working
  pane_is_busy fixture:w1:p1 herdr || fail 'real native generation must defer'
  FIXTURE_RULE=unreadable
  [ "$(fm_backend_busy_state herdr fixture:w1:p1 delivery)" = unknown ] || fail 'missing explanation must be unknown'
  [ "$(fm_backend_composer_state herdr fixture:w1:p1)" = unknown ] || fail 'missing explanation must not prove empty'
  FIXTURE_RULE=new_unknown_rule
  [ "$(fm_backend_composer_state herdr fixture:w1:p1)" = unknown ] || fail 'unrecognized rule must not prove empty'
  FIXTURE_RULE=unreadable
  printf '%s\nesc to cancel\n' "$initial" > "$screen_file"
  [ "$(fm_backend_busy_state herdr fixture:w1:p1 delivery)" = busy ] || fail 'rendered generation must survive loss of native explanation'
  pane_is_busy fixture:w1:p1 herdr || fail 'rendered generation must independently defer'
  FIXTURE_RULE=background_tasks_working
  printf '>\n' > "$screen_file"
  [ "$(fm_backend_composer_state herdr fixture:w1:p1)" = unknown ] || fail 'dead shell accepted'
  printf '%s\nChoose permission: yes/no\n' "$initial" > "$screen_file"
  [ "$(fm_backend_composer_state herdr fixture:w1:p1)" = unknown ] || fail 'modal footer accepted'
  FIXTURE_AGENT=pi
  [ "$(fm_backend_busy_state herdr fixture:w1:p1 delivery)" = busy ] || fail 'Antigravity exception leaked into Pi'
  pass 'delivery boundary: background-only injection lands once; genuine busy, pending, unknown, modal and shell remain protected'
)

test_primary_stop_backstop() (
  local home shell out
  home="$TMP_ROOT/stop-primary"
  make_primary_fixture "$home"
  shell="$home/agy"
  ln -s /bin/bash "$shell"
  # A real process with the harness executable path owns the fixture lock.
  # No fake watcher or source-byte assertion can turn a fresh beacon into a
  # live successor; the actual shared guard must reject that counterfactual.
  run_stop() {
    # shellcheck disable=SC2016 # Expanded by the real child shell owning .lock.
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" FM_WEDGE_ALARM_EXEC=discard \
      "$shell" -c 'echo $$ > "$FM_HOME/state/.lock"; for execution in "$@"; do
        printf "{\"conversationId\":\"fixture\",\"executionNum\":%s,\"fullyIdle\":false}" "$execution" |
          "$FM_HOME/bin/fm-antigravity-hook.sh" primary-stop
      done' agy "$@"
  }
  out=$(run_stop 1)
  [ "$(printf '%s' "$out" | jq -r .decision)" = stop ] || fail "empty fleet must allow stop: $out"
  touch "$home/state/task.meta" "$home/state/.last-watcher-beat"
  out=$(run_stop 1 1 2 3 4 5)
  [ "$(printf '%s' "$out" | jq -sr '[.[]|select(.decision == "continue")]|length')" = 4 ] \
    || fail "native Stop must dedupe executionNum and bound repair continuations: $out"
  [ "$(printf '%s' "$out" | jq -sr '.[0].reason')" = 'Firstmate supervision required: work remains in flight' ] \
    || fail 'missing successor must return the native continuation reason'
  [ -s "$home/state/.antigravity-stop-alarm.log" ] || fail 'exhausted continuation budget must produce independent failure evidence'
  out=$(printf '{"conversationId":"foreign","executionNum":1,"fullyIdle":false}' | \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-antigravity-hook.sh" primary-stop)
  [ "$out" = '{}' ] || fail 'foreign session must not control this home'
  out=$(printf 'not json' | "$ROOT/bin/fm-antigravity-hook.sh" primary-stop)
  [ "$out" = '{}' ] || fail 'malformed input must be inert'
  pass 'primary Stop: native continuation, real owner scope, fresh-beacon negative, bounded repair and independent alarm'
)

test_background_delivery_boundary || exit 1
if [ "${FM_TEST_ANTIGRAVITY_DELIVERY_ONLY:-0}" = 1 ]; then exit 0; fi
test_primary_stop_backstop || exit 1
test_marker_precedence_and_ai_agent_rejection
test_exact_agy_ancestry_only
test_control_and_busy_contracts
test_separated_shell_glyph_requires_antigravity_identity
test_hook_transport_and_task_lifecycle
test_native_pretool_deny_transport
test_spawn_builds_canonical_antigravity_launch
test_spawn_defaults_to_gemini_and_enforces_verified_boundaries
test_positional_secondmate_adapter_reaches_antigravity_launch
test_remote_secondmate_preflight_accepts_antigravity
