#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/helpers.sh"
source "$DIR/../lib/render.sh"

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

run_tests
