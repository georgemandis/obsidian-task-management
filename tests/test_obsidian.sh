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

# --- Finding 5: macOS has no /usr/bin/timeout. obs() must resolve `timeout`
# or fall back to `gtimeout` (coreutils), and when neither exists it must fail
# with an actionable message rather than letting a 127 masquerade as an
# Obsidian failure.

# A PATH allowlist containing every tool obs() needs except timeout/gtimeout.
_build_no_timeout_path() {
  local d="$1" c
  mkdir -p "$d"
  for c in bash tr printf; do
    local p; p="$(command -v "$c" 2>/dev/null || true)"
    [[ -n "$p" ]] && ln -sf "$p" "$d/$c"
  done
}

test_obs_fails_actionably_when_timeout_is_missing() {
  local no_timeout_dir out rc
  no_timeout_dir="$(mktemp -d)"
  _build_no_timeout_path "$no_timeout_dir"
  set +e
  out="$(PATH="$no_timeout_dir" OBSIDIAN_BIN=false obs tasks format=json 2>&1)"
  rc=$?
  set -e
  rm -rf "$no_timeout_dir"
  assert_eq "$rc" "1" "missing timeout is a clean failure"
  assert_contains "$out" "coreutils" "message points at the fix, not a mysterious exit 127"
}

test_obs_falls_back_to_gtimeout() {
  local d out rc
  d="$(mktemp -d)"
  # Provide a fake gtimeout (coreutils' name) but no `timeout`, alongside the
  # rest of the toolchain obs()/OBSIDIAN_BIN=echo-like stub needs.
  local c
  for c in bash tr printf; do
    local p; p="$(command -v "$c" 2>/dev/null || true)"
    [[ -n "$p" ]] && ln -sf "$p" "$d/$c"
  done
  local stub; stub="$(mktemp)"
  printf '#!/usr/bin/env bash\necho ok\n' > "$stub"
  chmod +x "$stub"
  # gtimeout is invoked as: gtimeout <secs> <OBSIDIAN_BIN> <args...> — drop the
  # seconds and exec the rest, exactly like the real coreutils tool would.
  printf '#!/usr/bin/env bash\nshift\nexec "$@"\n' > "$d/gtimeout"
  chmod +x "$d/gtimeout"
  set +e
  out="$(PATH="$d" OBSIDIAN_BIN="$stub" obs tasks format=json 2>&1)"
  rc=$?
  set -e
  rm -rf "$d"
  rm -f "$stub"
  assert_eq "$rc" "0" "gtimeout fallback succeeds"
  assert_contains "$out" "ok" "call actually ran through gtimeout"
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
