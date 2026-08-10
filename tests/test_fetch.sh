#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/helpers.sh"
source "$DIR/../lib/render.sh"
source "$DIR/../lib/fetch.sh"
FIXTURES="$DIR/fixtures"

test_parse_meta_extracts_path_with_spaces() {
  local got
  got="$(parse_file_meta < "$FIXTURES/file-meta.tsv" | jq -r '.path')"
  assert_eq "$got" "Audit/09 Week-One Action List.md" "path with spaces intact"
}

test_parse_meta_extracts_modified() {
  local got
  got="$(parse_file_meta < "$FIXTURES/file-meta.tsv" | jq -r '.modified')"
  assert_eq "$got" "1786290000000" "modified epoch ms"
}

test_parse_meta_extracts_created() {
  local got
  got="$(parse_file_meta < "$FIXTURES/file-meta.tsv" | jq -r '.created')"
  assert_eq "$got" "1765157522206" "created epoch ms"
}

test_join_attaches_timestamps_to_tasks() {
  local meta tmp got
  meta='[{"path":"Audit/09 Week-One Action List.md","created":"1765157522206","modified":"1786290000000"},
        {"path":"Meetings/Standup.md","created":"1786000000000","modified":"1786100000000"}]'
  tmp="$(mktemp)"; printf '%s' "$meta" > "$tmp"
  got="$(normalize_tasks < "$FIXTURES/tasks.json" | join_metadata "$tmp" | jq -r '.[0].modified')"
  rm -f "$tmp"
  assert_eq "$got" "1786290000000" "task inherits its file's modified time"
}

test_join_leaves_no_task_without_timestamps() {
  local meta tmp got
  meta='[{"path":"Audit/09 Week-One Action List.md","created":"1765157522206","modified":"1786290000000"},
        {"path":"Meetings/Standup.md","created":"1786000000000","modified":"1786100000000"}]'
  tmp="$(mktemp)"; printf '%s' "$meta" > "$tmp"
  got="$(normalize_tasks < "$FIXTURES/tasks.json" | join_metadata "$tmp" \
        | jq -r '[.[] | select(.modified == null)] | length')"
  rm -f "$tmp"
  assert_eq "$got" "0" "every task got metadata"
}

run_tests
