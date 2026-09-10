Mode: Antigravity native checkpoint supervision with a bounded Stop backstop.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted notifications and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. First cycle: run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_WATCH_CHECKPOINT:-180}"`.
3. Ordinary wake: if the command prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle that wake, then start the next checkpoint while supervision remains required.
4. If the command prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, process any queued captain messages, then resume the next checkpoint while work remains in flight.
5. Never use shell `&`, a pipeline, or a detached OS process for watcher supervision in Antigravity.
   The terminal tool may return a native task before a checkpoint finishes, even without shell `&`; retain that task and handle its completion notification as the same checkpoint result, not permission to start a duplicate.
   Native task completion can resume the model, but does not itself schedule a successor; `bin/fm-watch-arm.sh` is not a substitute for this protocol.
6. A failed checkpoint tool call means supervision is down.
   Inspect the failure and restore the checkpoint before ending a turn with work under way.
7. The tracked `.agents/hooks.json` supplies the startup reminder and native primary `Stop` backstop through `bin/fm-antigravity-hook.sh`.
   When it reports `Firstmate supervision required: work remains in flight`, drain and reconcile, then restore one checkpoint before stopping.
   The backstop bounds unsuccessful repair continuations and attempts an independent alarm on exhaustion; it is not a perpetual scheduler or an unattended-delivery guarantee.

Interactive `agy` TUI sessions are the supported primary host.
Headless `agy --prompt` runs do not provide a persistent conversation for subsequent fleet notifications and are not a Firstmate primary.
