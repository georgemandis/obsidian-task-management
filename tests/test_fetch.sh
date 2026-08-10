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

# --- Regression: obs() must not drain the process-substitution pipe feeding
# fetch_enriched's per-file metadata loop -------------------------------------
#
# obs() runs `timeout ... "$OBSIDIAN_BIN" "$@"` with inherited stdin. Inside
# fetch_enriched, that call happens inside
#   while IFS= read -r path; do ... obs file path="$path" ... done < <(...)
# A child process that inherits stdin from a `while read` loop fed by a pipe
# will happily drain that pipe itself, so the loop's own `read` starves after
# the very first iteration — every file after the first silently gets no
# metadata, even though `obsidian file path=...` would have answered fine for
# each of them individually. This is invisible to every other test in this
# suite because they all stub metadata for a single file at a time.
#
# The stub below returns three tasks across three distinct files, each with
# real, distinguishable timestamps, so a broken loop is caught by any of the
# three files coming back empty.
test_fetch_enriched_reads_metadata_for_every_file_not_just_the_first() {
  local stub out rc
  stub="$(mktemp)"
  cat > "$stub" <<'STUB'
#!/usr/bin/env bash
# The real `obsidian` binary reads/drains its stdin even for commands that
# never use it (confirmed against the live binary). A stub that ignores
# stdin cannot reproduce the pipe-starvation bug, so mirror that here.
cat >/dev/null
case "$*" in
  "tasks todo format=json")
    printf '[
      {"status":" ","text":"- [ ] one","file":"A.md","line":"1"},
      {"status":" ","text":"- [ ] two","file":"B.md","line":"2"},
      {"status":" ","text":"- [ ] three","file":"C.md","line":"3"}
    ]'
    ;;
  "file path=A.md")
    printf 'path\tA.md\ncreated\t1000000000000\nmodified\t1000000000001\n' ;;
  "file path=B.md")
    printf 'path\tB.md\ncreated\t2000000000000\nmodified\t2000000000001\n' ;;
  "file path=C.md")
    printf 'path\tC.md\ncreated\t3000000000000\nmodified\t3000000000001\n' ;;
  *)
    echo "UNEXPECTED CALL: $*" >&2
    exit 1
    ;;
esac
STUB
  chmod +x "$stub"

  set +e
  out="$(OBSIDIAN_BIN="$stub" fetch_enriched 0 2>&1)"
  rc=$?
  set -e
  rm -f "$stub"

  assert_eq "$rc" "0" "fetch_enriched succeeds with a healthy stub"

  local mod_a mod_b mod_c
  mod_a="$(printf '%s' "$out" | jq -r '.[] | select(.file == "A.md") | .modified')"
  mod_b="$(printf '%s' "$out" | jq -r '.[] | select(.file == "B.md") | .modified')"
  mod_c="$(printf '%s' "$out" | jq -r '.[] | select(.file == "C.md") | .modified')"

  assert_eq "$mod_a" "1000000000001" "first file gets its real modified time"
  assert_eq "$mod_b" "2000000000001" "second file must not be starved by the first obs() call draining stdin"
  assert_eq "$mod_c" "3000000000001" "third file must not be starved either"
}

run_tests
