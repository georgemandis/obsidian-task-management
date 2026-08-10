#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/helpers.sh"
source "$DIR/../lib/render.sh"
source "$DIR/../lib/obsidian.sh"
source "$DIR/../lib/fetch.sh"

# Fixed reference point: 2026-08-09 00:00:00 local == 1786248000.
# All expectations below are relative to that midnight.
MID=1786248000

bucket_of() {
  # $1 = epoch milliseconds as a string
  printf '[{"m":"%s"}]' "$1" | jq -r --argjson mid "$MID" "$(bucket_jq_filter)"' .[] | bucket(.m|tonumber)'
}

test_today_is_after_midnight() {
  assert_eq "$(bucket_of 1786290000000)" "Today" "11:40 on the reference day"
}

test_midnight_itself_is_today() {
  assert_eq "$(bucket_of 1786248000000)" "Today" "exactly midnight is Today"
}

test_one_second_before_midnight_is_yesterday() {
  assert_eq "$(bucket_of 1786247999000)" "Yesterday" "23:59:59 the night before"
}

test_two_days_ago_is_this_week() {
  assert_eq "$(bucket_of 1786075200000)" "This week" "2 days before reference"
}

test_eight_days_ago_is_last_week() {
  assert_eq "$(bucket_of 1785556800000)" "Last week" "8 days before reference"
}

test_twenty_days_ago_is_older() {
  assert_eq "$(bucket_of 1784520000000)" "Older" "20 days before reference"
}

test_midnight_epoch_is_a_plausible_timestamp() {
  local m; m="$(midnight_epoch)"
  if [[ ! "$m" =~ ^[0-9]+$ ]]; then fail "midnight_epoch not numeric: $m"; fi
  assert_eq "$(( m % 60 ))" "0" "midnight falls on a minute boundary"
}

test_exactly_24h_before_midnight_is_yesterday() {
  assert_eq "$(bucket_of 1786161600000)" "Yesterday" "exact prior midnight is Yesterday"
}

test_exactly_seven_days_before_is_this_week() {
  assert_eq "$(bucket_of 1785643200000)" "This week" "exact 7-day boundary is This week"
}

test_exactly_fourteen_days_before_is_last_week() {
  assert_eq "$(bucket_of 1785038400000)" "Last week" "exact 14-day boundary is Last week"
}

FIXTURES="$DIR/fixtures"

test_normalize_builds_ref_from_file_and_line() {
  local got
  got="$(normalize_tasks < "$FIXTURES/tasks.json" | jq -r '.[0].ref')"
  assert_eq "$got" "Audit/09 Week-One Action List.md:20" "ref joins file and line"
}

test_normalize_strips_todo_checkbox_prefix() {
  local got
  got="$(normalize_tasks < "$FIXTURES/tasks.json" | jq -r '.[0].text')"
  assert_eq "$got" "Follow-up norm: funnel changes must update the spec test" \
    "prefix stripped, inner colon preserved"
}

test_normalize_strips_done_checkbox_prefix() {
  local got
  got="$(normalize_tasks < "$FIXTURES/tasks.json" | jq -r '.[1].text')"
  assert_eq "$got" "Ship the audit doc" "done prefix stripped"
}

test_normalize_preserves_status() {
  local got
  got="$(normalize_tasks < "$FIXTURES/tasks.json" | jq -r '.[1].status')"
  assert_eq "$got" "x" "status preserved"
}

test_normalize_keeps_all_records() {
  local got
  got="$(normalize_tasks < "$FIXTURES/tasks.json" | jq -r 'length')"
  assert_eq "$got" "3" "no records dropped"
}

ENRICHED='[
  {"status":" ","text":"Chase the invoice","file":"Audit/09 Week-One Action List.md",
   "line":"20","ref":"Audit/09 Week-One Action List.md:20",
   "created":"1765157522206","modified":"1786290000000"},
  {"status":" ","text":"Ask about staging deploy","file":"Meetings/Standup.md",
   "line":"7","ref":"Meetings/Standup.md:7",
   "created":"1786000000000","modified":"1786200000000"},
  {"status":" ","text":"Draft the proposal","file":"Projects/Old Idea.md",
   "line":"3","ref":"Projects/Old Idea.md:3",
   "created":"1760000000000","modified":"1760000000000"}
]'

test_by_date_emits_bucket_headings() {
  local got
  got="$(printf '%s' "$ENRICHED" | OBSIDIAN_TASKS_NOW=1786248000 render_by_date modified "")"
  assert_contains "$got" "## Today" "Today heading present"
  assert_contains "$got" "## Older" "Older heading present"
}

test_by_date_groups_tasks_under_source_file() {
  local got
  got="$(printf '%s' "$ENRICHED" | OBSIDIAN_TASKS_NOW=1786248000 render_by_date modified "")"
  assert_contains "$got" "Audit/09 Week-One Action List.md" "file heading shown"
  assert_contains "$got" "Chase the invoice" "task text shown"
}

test_by_date_omits_empty_buckets() {
  local got
  got="$(printf '%s' "$ENRICHED" | OBSIDIAN_TASKS_NOW=1786248000 render_by_date modified "")"
  if [[ "$got" == *"## Last week"* ]]; then
    fail "Last week bucket is empty and should be omitted"
  fi
}

test_since_filter_excludes_old_files() {
  local got
  got="$(printf '%s' "$ENRICHED" | OBSIDIAN_TASKS_NOW=1786248000 render_by_date modified 7)"
  if [[ "$got" == *"Draft the proposal"* ]]; then
    fail "--since 7d should have excluded a file untouched for months"
  fi
  assert_contains "$got" "Chase the invoice" "recent task retained"
}

test_picker_line_ends_with_ref() {
  local got
  got="$(printf '%s' "$ENRICHED" | OBSIDIAN_TASKS_NOW=1786248000 render_picker modified | head -1)"
  assert_eq "${got##*$'\t'}" "Audit/09 Week-One Action List.md:20" "ref is the last column"
}

test_picker_line_has_five_columns() {
  local got n
  got="$(printf '%s' "$ENRICHED" | OBSIDIAN_TASKS_NOW=1786248000 render_picker modified | head -1)"
  n="$(awk -F'\t' '{print NF}' <<< "$got")"
  assert_eq "$n" "5" "status, text, bucket, file, ref"
}

test_picker_shows_filename_for_searching() {
  local got
  got="$(printf '%s' "$ENRICHED" | OBSIDIAN_TASKS_NOW=1786248000 render_picker modified | head -1)"
  assert_contains "$got" "Audit/09 Week-One Action List.md" "filename visible for search"
}

test_render_by_date_survives_null_timestamps() {
  local e got
  e='[{"status":" ","text":"good","file":"A.md","line":"1","ref":"A.md:1","created":"1786290000000","modified":"1786290000000"},
      {"status":" ","text":"degraded","file":"B.md","line":"2","ref":"B.md:2","created":null,"modified":null}]'
  got="$(printf '%s' "$e" | OBSIDIAN_TASKS_NOW=1786248000 render_by_date modified "" 2>&1)"
  assert_contains "$got" "good" "a null timestamp must not erase healthy tasks"
}

test_render_picker_survives_null_timestamps() {
  local e got
  e='[{"status":" ","text":"degraded","file":"B.md","line":"2","ref":"B.md:2","created":null,"modified":null}]'
  got="$(printf '%s' "$e" | OBSIDIAN_TASKS_NOW=1786248000 render_picker modified 2>&1)"
  assert_contains "$got" "B.md:2" "picker must still emit a row with an unknown timestamp"
}

test_since_boundary_matches_bucket_boundary() {
  local e got
  e='[{"status":" ","text":"exactly seven","file":"A.md","line":"1","ref":"A.md:1","created":"1785643200000","modified":"1785643200000"}]'
  got="$(printf '%s' "$e" | OBSIDIAN_TASKS_NOW=1786248000 render_by_date modified 7)"
  assert_contains "$got" "exactly seven" "a task exactly 7 days old must survive --since 7d"
}

test_render_survives_empty_string_timestamps() {
  local e got
  e='[{"status":" ","text":"GOOD","file":"A.md","line":"1","ref":"A.md:1","created":"1786290000000","modified":"1786290000000"},
      {"status":" ","text":"EMPTYSTR","file":"B.md","line":"2","ref":"B.md:2","created":"","modified":""}]'
  got="$(printf '%s' "$e" | OBSIDIAN_TASKS_NOW=1786248000 render_by_date modified "" 2>&1)"
  assert_contains "$got" "GOOD" "an empty-string timestamp must not erase healthy tasks"
  assert_contains "$got" "EMPTYSTR" "the affected task must still appear"
}

test_picker_survives_empty_string_timestamps() {
  local e got
  e='[{"status":" ","text":"EMPTYSTR","file":"B.md","line":"2","ref":"B.md:2","created":"","modified":""}]'
  got="$(printf '%s' "$e" | OBSIDIAN_TASKS_NOW=1786248000 render_picker modified 2>&1)"
  assert_contains "$got" "B.md:2" "picker must still emit a row for an empty-string timestamp"
}

PICKER_ENRICHED='[
  {"status":" ","text":"Chase the invoice","file":"Audit/09 Week-One Action List.md",
   "line":"20","ref":"Audit/09 Week-One Action List.md:20",
   "created":"1765157522206","modified":"1786290000000"}
]'

# A PATH with every tool run_picker's fallback needs (bash, jq, awk, sed, ...)
# but NOT fzf, even when fzf happens to be installed on the dev/CI machine —
# `PATH="/nonexistent:$PATH"` does not hide a real fzf that appears later in
# the original PATH, so we build an explicit allowlist directory instead.
_build_no_fzf_path() {
  local d="$1" c
  mkdir -p "$d"
  for c in bash jq awk sed mktemp cat printf grep head tr date timeout mkdir rm chmod; do
    local p; p="$(command -v "$c" 2>/dev/null || true)"
    [[ -n "$p" ]] && ln -sf "$p" "$d/$c"
  done
}

# Non-fzf fallback: fzf is absent from PATH, so run_picker prompts with a
# numbered list and reads a selection from stdin. Non-numeric input must be
# rejected before it ever reaches `sed -n "<n>p"` (a raw sed error there is
# the bug this test guards against — see review finding 1).
test_picker_fallback_rejects_non_numeric_input() {
  local out rc no_fzf_dir
  no_fzf_dir="$(mktemp -d)"
  _build_no_fzf_path "$no_fzf_dir"
  set +e
  out="$(printf 'abc\n' | PATH="$no_fzf_dir" OBSIDIAN_TASKS_DRY_RUN=1 OBSIDIAN_BIN=false \
    run_picker "$PICKER_ENRICHED" modified 0 2>&1)"
  rc=$?
  set -e
  rm -rf "$no_fzf_dir"
  assert_eq "$rc" "1" "invalid selection is an error"
  assert_contains "$out" "Invalid selection" "clear message, not a raw sed error"
  if [[ "$out" == *"sed:"* ]]; then
    fail "raw sed error leaked to the user: $out"
  fi
}

# Stale-ref reconciliation: the picker's snapshot (fed as $1) shows one piece
# of text for a ref, but by the time the user selects it and run_picker
# re-fetches, the underlying task text has changed (e.g. the line shifted
# after an edit). The stale selection must be skipped with a message, never
# toggled — and toggling must never be attempted (OBSIDIAN_BIN=false would
# fail loudly with dry-run off, proving obs_task_write was never reached for
# this ref).
test_picker_skips_stale_ref_without_toggling() {
  local stub out rc
  stub="$(mktemp)"
  # Stubbed `obsidian` binary: fetch_enriched's re-fetch calls `obs tasks
  # todo format=json`; return fresh JSON where this task's text has changed
  # since the snapshot passed into run_picker. Any other invocation (e.g. a
  # mutating `task ref=... toggle`) is unexpected for this test and fails.
  cat > "$stub" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "tasks todo format=json")
    printf '[{"status":" ","text":"[ ] Chase the invoice NOW",\
"file":"Audit/09 Week-One Action List.md","line":"21"}]'
    ;;
  "file path=Audit/09 Week-One Action List.md")
    printf 'path\tAudit/09 Week-One Action List.md\ncreated\t1765157522206\nmodified\t1786290000000\n'
    ;;
  *)
    echo "UNEXPECTED CALL: $*" >&2
    exit 1
    ;;
esac
STUB
  chmod +x "$stub"

  local fzf_stub fzf_dir
  fzf_dir="$(mktemp -d)"
  fzf_stub="$fzf_dir/fzf"
  # fzf stub: echoes back whatever it was given on stdin, simulating the user
  # selecting the one and only row (fzf normally strips nothing from stdin).
  printf '#!/usr/bin/env bash\ncat\n' > "$fzf_stub"
  chmod +x "$fzf_stub"

  set +e
  out="$(PATH="$fzf_dir:$PATH" OBSIDIAN_BIN="$stub" \
    run_picker "$PICKER_ENRICHED" modified 0 2>&1)"
  rc=$?
  set -e
  rm -f "$stub"
  rm -rf "$fzf_dir"

  assert_eq "$rc" "0" "a skip is not a failure"
  assert_contains "$out" "Skipped" "stale ref reported as skipped"
  assert_contains "$out" "Audit/09 Week-One Action List.md:20" "the stale ref is named"
}

run_tests
