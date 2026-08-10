#!/usr/bin/env bash

: "${OBSIDIAN_BIN:=obsidian}"
: "${OBSIDIAN_TIMEOUT:=25}"

# Every CLI call goes through here. The CLI hangs rather than failing when it
# cannot complete, so the timeout is mandatory.
obs() {
  local rc=0
  timeout "$OBSIDIAN_TIMEOUT" "$OBSIDIAN_BIN" "$@" || rc=$?
  if [[ $rc -eq 124 ]]; then
    printf 'obsidian timed out after %ss. Is Obsidian running?\n' "$OBSIDIAN_TIMEOUT" >&2
    return 1
  fi
  return $rc
}

ref_file() { printf '%s' "${1%:*}"; }
ref_line() { printf '%s' "${1##*:}"; }

# $1 = ref (path:line), $2 = verb (toggle|done|todo)
obs_task_write() {
  local ref="$1" verb="$2" out rc=0

  if [[ "${OBSIDIAN_TASKS_DRY_RUN:-}" == "1" ]]; then
    printf 'DRY RUN: obsidian task ref=%s %s\n' "$ref" "$verb"
    return 0
  fi

  out="$(obs task ref="$ref" "$verb" 2>&1)" || rc=$?

  # A ref valid in one vault silently fails in another; surface that clearly.
  if [[ "$out" == *"not found"* ]]; then
    printf 'Could not resolve %s — is the expected vault focused?\n  %s\n' "$ref" "$out" >&2
    return 1
  fi

  [[ -n "$out" ]] && printf '%s\n' "$out"
  return $rc
}
