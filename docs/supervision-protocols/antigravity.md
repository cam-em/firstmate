Mode: Antigravity foreground tool supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted notifications and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. First cycle: run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_WATCH_CHECKPOINT:-180}"`.
3. Ordinary wake: if the command prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle that wake, then start the next checkpoint while supervision remains required.
4. If the command prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, process any queued captain messages, then resume the next checkpoint while work remains in flight.
5. Never use shell `&`, a pipeline, or background tasks for watcher supervision in Antigravity.
   Antigravity 1.1.26+ exposes no background-task-to-model wake interface, so `bin/fm-watch-arm.sh` is not a substitute here.
6. A failed foreground checkpoint tool call means supervision is down.
   Inspect the failure and restore the foreground checkpoint before ending a turn with work under way.
7. The tracked `.agents/hooks.json` injects the startup reminder through Antigravity's `PreInvocation` hook in a primary or second-mate home.
   It is a backstop, not a second supervision owner.

Interactive `agy` TUI sessions are the supported primary host.
Headless `agy --prompt` runs do not provide a persistent conversation for subsequent fleet notifications and are not a Firstmate primary.
