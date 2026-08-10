#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/helpers.sh"
source "$DIR/../lib/render.sh"
source "$DIR/../lib/obsidian.sh"
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

test_join_yields_null_for_file_absent_from_metadata() {
  local meta tmp got
  meta='[{"path":"Audit/09 Week-One Action List.md","created":"1765157522206","modified":"1786290000000"}]'
  tmp="$(mktemp)"; printf '%s' "$meta" > "$tmp"
  got="$(normalize_tasks < "$FIXTURES/tasks.json" | join_metadata "$tmp" | jq -r '.[2].modified')"
  rm -f "$tmp"
  assert_eq "$got" "null" "task with absent file gets null modified"
}

test_parse_meta_escapes_quotes_in_path() {
  local got
  got="$(printf 'path\tFoo "Bar".md\ncreated\t123\nmodified\t456\n' | parse_file_meta | jq -r '.path')"
  assert_eq "$got" 'Foo "Bar".md' "quote in filename survives round-trip through jq"
}

test_parse_meta_escapes_backslash_in_path() {
  local got
  got="$(printf 'path\tFoo\\Bar.md\ncreated\t123\nmodified\t456\n' | parse_file_meta | jq -r '.path')"
  assert_eq "$got" 'Foo\Bar.md' "backslash in filename survives round-trip through jq"
}

test_fetch_enriched_fails_loudly_when_tasks_call_fails() {
  local stub rc
  stub="$(mktemp)"
  printf '#!/usr/bin/env bash\necho "Error: no vault focused" >&2\nexit 1\n' > "$stub"
  chmod +x "$stub"
  set +e
  OBSIDIAN_BIN="$stub" fetch_enriched 0 >/dev/null 2>&1; rc=$?
  set -e
  rm -f "$stub"
  assert_eq "$rc" "1" "a failed tasks call must not look like an empty vault"
}

test_render_survives_metadata_missing_a_row() {
  local meta tmp tasks got
  # parse_file_meta emits "" (not null) when the TSV lacks a created row.
  meta="[$(printf 'path\tAudit/09 Week-One Action List.md\nmodified\t1786290000000\n' | parse_file_meta)]"
  tmp="$(mktemp)"; printf '%s' "$meta" > "$tmp"
  tasks="$(normalize_tasks < "$FIXTURES/tasks.json" | join_metadata "$tmp")"
  rm -f "$tmp"
  got="$(printf '%s' "$tasks" | OBSIDIAN_TASKS_NOW=1786248000 render_by_date created "" 2>&1)"
  assert_contains "$got" "Follow-up norm" "a file with no created row must not crash the render"
}

run_tests
