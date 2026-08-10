#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/helpers.sh"
CLI="$DIR/../bin/obsidian-tasks"

test_help_lists_every_command() {
  local out; out="$("$CLI" --help 2>&1)"
  assert_contains "$out" "by-date" "by-date listed"
  assert_contains "$out" "by-file" "by-file listed"
  assert_contains "$out" "pick"    "pick listed"
  assert_contains "$out" "toggle"  "toggle listed"
}

test_no_args_shows_help_and_fails() {
  local rc=0
  "$CLI" >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "bare invocation is an error"
}

test_unknown_command_fails() {
  local rc=0
  "$CLI" bogus-command >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "unknown command is an error"
}

test_toggle_requires_a_ref() {
  local rc=0
  "$CLI" toggle >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "toggle without a ref is an error"
}

test_toggle_dry_run_echoes_command() {
  local out
  out="$(OBSIDIAN_TASKS_DRY_RUN=1 "$CLI" toggle "A.md:3" 2>&1)"
  assert_contains "$out" "ref=A.md:3" "dry run shows the ref"
}

test_toggle_done_flag_uses_done_verb() {
  local out
  out="$(OBSIDIAN_TASKS_DRY_RUN=1 "$CLI" toggle "A.md:3" --done 2>&1)"
  assert_contains "$out" "done" "--done maps to the done verb"
}

run_tests
