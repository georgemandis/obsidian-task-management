#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/helpers.sh"
source "$DIR/../lib/obsidian.sh"

test_ref_file_splits_on_last_colon() {
  assert_eq "$(ref_file "Audit/09 Week-One Action List.md:20")" \
    "Audit/09 Week-One Action List.md" "path extracted"
}

test_ref_line_splits_on_last_colon() {
  assert_eq "$(ref_line "Audit/09 Week-One Action List.md:20")" "20" "line extracted"
}

test_ref_file_tolerates_colon_in_path() {
  assert_eq "$(ref_file "Notes/Meeting: Q3.md:7")" "Notes/Meeting: Q3.md" \
    "splits on the last colon, not the first"
}

test_ref_line_tolerates_colon_in_path() {
  assert_eq "$(ref_line "Notes/Meeting: Q3.md:7")" "7" "line after last colon"
}

test_dry_run_prints_command_without_executing() {
  local out
  out="$(OBSIDIAN_TASKS_DRY_RUN=1 OBSIDIAN_BIN=false obs_task_write "A.md:3" toggle)"
  assert_contains "$out" 'ref=A.md:3' "dry run echoes the ref"
  assert_contains "$out" 'toggle' "dry run echoes the verb"
}

test_write_reports_vault_mismatch_on_not_found() {
  local stub out rc
  stub="$(mktemp)"
  printf '#!/usr/bin/env bash\necho "Error: File \\"X.md\\" not found." \nexit 1\n' > "$stub"
  chmod +x "$stub"
  set +e
  out="$(OBSIDIAN_BIN="$stub" obs_task_write "X.md:1" toggle 2>&1)"; rc=$?
  set -e
  rm -f "$stub"
  assert_eq "$rc" "1" "not-found is a failure"
  assert_contains "$out" "vault" "error mentions the vault"
}

test_write_succeeds_when_cli_succeeds() {
  local stub rc
  stub="$(mktemp)"
  printf '#!/usr/bin/env bash\necho "Task updated"\n' > "$stub"
  chmod +x "$stub"
  set +e
  OBSIDIAN_BIN="$stub" obs_task_write "X.md:1" toggle >/dev/null 2>&1; rc=$?
  set -e
  rm -f "$stub"
  assert_eq "$rc" "0" "clean CLI output is success"
}

test_write_succeeds_silently_with_no_output() {
  local stub rc
  stub="$(mktemp)"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$stub"
  chmod +x "$stub"
  set +e
  OBSIDIAN_BIN="$stub" obs_task_write "X.md:1" toggle >/dev/null 2>&1; rc=$?
  set -e
  rm -f "$stub"
  assert_eq "$rc" "0" "silent success returns 0"
}

test_write_succeeds_when_task_text_contains_not_found() {
  local stub rc
  stub="$(mktemp)"
  printf '#!/usr/bin/env bash\necho "Toggled: why the config was not found"\nexit 0\n' > "$stub"
  chmod +x "$stub"
  set +e
  OBSIDIAN_BIN="$stub" obs_task_write "X.md:1" toggle >/dev/null 2>&1; rc=$?
  set -e
  rm -f "$stub"
  assert_eq "$rc" "0" "successful write is not misread as vault mismatch"
}

test_dry_run_blocks_mutation_through_obs_directly() {
  local stub out
  stub="$(mktemp)"
  printf '#!/usr/bin/env bash\necho "STUB RAN"\n' > "$stub"
  chmod +x "$stub"
  out="$(OBSIDIAN_TASKS_DRY_RUN=1 OBSIDIAN_BIN="$stub" obs task ref="X.md:1" toggle 2>&1)"
  rm -f "$stub"
  if [[ "$out" == *"STUB RAN"* ]]; then
    fail "dry run did not block a mutating call made through obs() directly"
  fi
}

test_dry_run_blocks_uppercase_verb() {
  local stub out
  stub="$(mktemp)"
  printf '#!/usr/bin/env bash\necho "STUB RAN"\n' > "$stub"
  chmod +x "$stub"
  out="$(OBSIDIAN_TASKS_DRY_RUN=1 OBSIDIAN_BIN="$stub" obs task ref="X.md:1" TOGGLE 2>&1)"
  rm -f "$stub"
  if [[ "$out" == *"STUB RAN"* ]]; then
    fail "dry run did not block an uppercase mutating verb"
  fi
}

run_tests
