#!/usr/bin/env bash
# Shared model-to-runtime safety predicates.
#
# A model belongs to the Claude/Anthropic family when its provider-qualified
# id starts with `anthropic/`, or when its final id/alias is `claude-*`, `opus`,
# `sonnet`, `haiku`, or `fable`, case-insensitively.
# Claude/Anthropic models must run through the `claude` harness so their usage
# follows the captain's Claude Code subscription instead of another runtime's
# provider credentials.
#
# This file is sourced by spawn, control-plane relaunch, and bootstrap dispatch
# validation so the classification has one executable owner.

fm_model_is_claude() {  # <model>
  local model=${1:-} lowered leaf
  [ -n "$model" ] && [ "$model" != default ] || return 1
  lowered=$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')
  case "$lowered" in
    anthropic/*) return 0 ;;
  esac
  leaf=${lowered##*/}
  case "$leaf" in
    claude-*|opus|sonnet|haiku|fable) return 0 ;;
  esac
  return 1
}

fm_model_runtime_is_invalid() {  # <harness> <model>
  local harness=${1:-} model=${2:-}
  fm_model_is_claude "$model" && [ "$harness" != claude ]
}
