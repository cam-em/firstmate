#!/usr/bin/env bash
# Regression test for fm-spawn.sh's live-shell Treehouse parent identity.
#
# Run this file under Bash 5 so BASHPID exposes command-substitution process
# identity. It extracts and executes the production assignment, then proves the
# recorded PID is this still-live spawn shell rather than an exited child.
# No harness, Treehouse, backend, or network command is invoked.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

case ${BASH_VERSINFO[0]} in
  5|6|7|8|9) ;;
  *)
    printf 'skip: fm-spawn live parent PID regression requires Bash 5 or newer (running %s)\n' \
      "$BASH_VERSION"
    exit 0
    ;;
esac

assignment=$(sed -n \
  's/^[[:space:]]*\(TREEHOUSE_LEASE_PARENT_PID=.*\)$/\1/p' \
  "$ROOT/bin/fm-spawn.sh")
[ "$(printf '%s\n' "$assignment" | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "fm-spawn parent PID assignment was not uniquely identifiable"
case "$assignment" in
  TREEHOUSE_LEASE_PARENT_PID=*) ;;
  *) fail "fm-spawn parent PID assignment had an unexpected shape" ;;
esac

FM_STATE_OVERRIDE=$(fm_test_tmproot fm-spawn-parent-pid-state)
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-treehouse-lease-lib.sh
. "$ROOT/bin/fm-treehouse-lease-lib.sh"

live_shell_pid=$BASHPID
# shellcheck disable=SC2294 # Execute the exact single assignment extracted above.
eval "$assignment"
[ "$TREEHOUSE_LEASE_PARENT_PID" = "$live_shell_pid" ] \
  || fail "fm-spawn captured $TREEHOUSE_LEASE_PARENT_PID instead of live Bash 5 shell $live_shell_pid"
fm_treehouse_process_start_identity "$TREEHOUSE_LEASE_PARENT_PID" >/dev/null \
  || fail "fm-spawn captured a Bash 5 parent PID that was already dead"

pass "fm-spawn records its live Bash 5 shell as the Treehouse acquisition parent"
