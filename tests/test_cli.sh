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

# --- Finding 2: --since with no following value must not crash under set -u.

test_since_with_no_value_fails_with_message() {
  local out rc=0
  out="$("$CLI" by-date --since 2>&1)" || rc=$?
  assert_eq "$rc" "1" "--since with no value is an error, not a crash"
  assert_contains "$out" "--since requires a value" "helpful message, not an unbound-variable trace"
  if [[ "$out" == *"unbound variable"* ]]; then
    fail "raw unbound-variable error leaked to the user: $out"
  fi
}

test_pick_since_with_no_value_fails_with_message() {
  local out rc=0
  out="$("$CLI" pick --since 2>&1)" || rc=$?
  assert_eq "$rc" "1" "pick --since with no value is an error, not a crash"
  assert_contains "$out" "--since requires a value" "helpful message for pick too"
}

# --- Finding 3: non-numeric / malformed --since must fail cleanly, not leak a
# raw jq error while exiting 0.

test_since_non_numeric_fails_with_message() {
  local out rc=0
  out="$("$CLI" by-date --since abc 2>&1)" || rc=$?
  assert_eq "$rc" "1" "--since abc is an error"
  assert_contains "$out" "--since expects a number of days" "helpful message"
  if [[ "$out" == *"jq: error"* ]]; then
    fail "raw jq error leaked to the user: $out"
  fi
}

test_since_malformed_unit_fails_with_message() {
  local out rc=0
  out="$("$CLI" by-date --since 7days 2>&1)" || rc=$?
  assert_eq "$rc" "1" "--since 7days is an error (only a trailing 'd' is stripped)"
  assert_contains "$out" "--since expects a number of days" "helpful message"
}

# --- Finding 4: by-file must reject unknown options instead of silently
# discarding them, matching by-date's behavior.

test_by_file_rejects_bogus_option() {
  local out rc=0
  out="$("$CLI" by-file --bogus 2>&1)" || rc=$?
  assert_eq "$rc" "1" "by-file --bogus is an error"
  assert_contains "$out" "Unknown option" "same message style as by-date"
}

test_by_file_rejects_since_option() {
  local out rc=0
  out="$("$CLI" by-file --since 7d 2>&1)" || rc=$?
  assert_eq "$rc" "1" "by-file --since 7d is an error, not silently ignored"
  assert_contains "$out" "Unknown option" "by-file does not understand --since"
}

run_tests
