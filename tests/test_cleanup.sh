#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/helpers.sh"
source "$DIR/../lib/render.sh"
source "$DIR/../lib/obsidian.sh"
source "$DIR/../lib/fetch.sh"
source "$DIR/../lib/cleanup.sh"

TASKS='[
  {"status":" ","text":"- [ ]","file":"Meetings/Standup • 2026-08-20.md","line":"28"},
  {"status":" ","text":"- [ ]","file":"Meetings/Standup • 2026-10-13.md","line":"28"},
  {"status":" ","text":"- [ ] 12:30 – 12:45 [[Daily standup • 2026-08-21]]","file":"Daily/2026-08-21.md","line":"9"},
  {"status":" ","text":"- [ ] 12:30 - 12:45 [[Daily standup • 2026-10-13]]","file":"Daily/2026-10-13.md","line":"9"},
  {"status":" ","text":"- [ ] Real task from August","file":"Daily/2026-08-21.md","line":"20"},
  {"status":" ","text":"- [ ]","file":"_/Templates/Meeting Template.md","line":"16"},
  {"status":" ","text":"- [ ]","file":"Projects/Undated.md","line":"3"},
  {"status":"x","text":"- [x]","file":"Meetings/Standup • 2026-08-01.md","line":"5"}
]'

plan() { printf '%s' "$TASKS" | cleanup_plan "2026-10-07"; }

test_cutoff_subtracts_days_from_pinned_today() {
  assert_eq "$(OBSIDIAN_TASKS_TODAY=2026-10-14 cleanup_cutoff 7)" "2026-10-07" "7 days before a pinned today"
}

test_plan_deletes_empty_box_in_old_note() {
  assert_contains "$(plan)" $'delete-empty\tMeetings/Standup • 2026-08-20.md:28' "old empty box is deleted"
}

test_plan_leaves_empty_box_in_recent_note() {
  if [[ "$(plan)" == *"2026-10-13.md:28"* ]]; then fail "recent empty box must be left alone"; fi
}

test_plan_ticks_past_agenda_line_with_en_dash() {
  assert_contains "$(plan)" $'done-agenda\tDaily/2026-08-21.md:9' "past agenda line is ticked"
}

test_plan_leaves_recent_agenda_line() {
  if [[ "$(plan)" == *"Daily/2026-10-13.md:9"* ]]; then fail "this week's agenda must be left alone"; fi
}

test_plan_never_touches_real_tasks() {
  if [[ "$(plan)" == *"Real task"* ]]; then fail "a task with text is not noise"; fi
}

test_plan_skips_notes_without_a_date() {
  if [[ "$(plan)" == *"Undated"* ]]; then fail "undated note must be skipped"; fi
}

test_plan_skips_completed_tasks() {
  if [[ "$(plan)" == *"2026-08-01"* ]]; then fail "completed boxes are not in scope"; fi
}

test_plan_counts() {
  assert_eq "$(plan | wc -l | tr -d ' ')" "2" "exactly the old empty box and the old agenda line"
}

test_filter_ignored_drops_default_template_prefix() {
  local got
  got="$(printf '%s' "$TASKS" | OBSIDIAN_TASKS_IGNORE_FILE=/nonexistent filter_ignored | jq -r '[.[].file] | map(select(startswith("_/Templates/"))) | length')"
  assert_eq "$got" "0" "default ignore drops _/Templates/"
}

test_filter_ignored_reads_prefixes_from_file() {
  local f got
  f="$(mktemp)"
  printf '# comment\nMeetings/   # trailing comment\n\nProjects/\n' > "$f"
  got="$(printf '%s' "$TASKS" | OBSIDIAN_TASKS_IGNORE_FILE="$f" filter_ignored | jq -r 'length')"
  rm -f "$f"
  # 8 tasks minus 3 Meetings minus 1 Projects = 4 (templates are NOT ignored once a file exists)
  assert_eq "$got" "4" "prefixes from the ignore file are applied, defaults are replaced"
}

test_apply_dry_run_writes_nothing() {
  local out
  out="$(plan | OBSIDIAN_TASKS_DRY_RUN=1 OBSIDIAN_BIN=false cleanup_apply 2>&1)"
  assert_contains "$out" "DRY RUN: obsidian task ref=Daily/2026-08-21.md:9 done" "agenda tick is dry-run"
  assert_contains "$out" "DRY RUN: delete empty checkbox Meetings/Standup • 2026-08-20.md:28" "deletion is dry-run"
}

test_apply_deletes_only_empty_lines_and_preserves_the_rest() {
  local vault stub out
  vault="$(mktemp -d)"
  mkdir -p "$vault/Meetings"
  printf 'line one\n- [ ]\n- [ ] keep me\n- [ ]\nlast\n' > "$vault/Meetings/Old • 2026-08-20.md"
  stub="$(mktemp)"
  printf '#!/usr/bin/env bash\ncat >/dev/null\ncase "$*" in\n  vault) printf "name\\tT\\npath\\t%s\\n" ;;\n  task*) echo "Task updated" ;;\n  *) echo "UNEXPECTED $*" >&2; exit 1 ;;\nesac\n' "$vault" > "$stub"
  chmod +x "$stub"
  set +e
  out="$(printf 'delete-empty\tMeetings/Old • 2026-08-20.md:4\t- [ ]\ndelete-empty\tMeetings/Old • 2026-08-20.md:2\t- [ ]\ndelete-empty\tMeetings/Old • 2026-08-20.md:3\t- [ ] keep me\n' \
        | OBSIDIAN_BIN="$stub" cleanup_apply 2>&1)"
  set -e
  local got; got="$(cat "$vault/Meetings/Old • 2026-08-20.md")"
  rm -rf "$vault" "$stub"
  assert_eq "$got" $'line one\n- [ ] keep me\nlast' "both empty boxes removed, the real task and prose untouched"
  assert_contains "$out" "Deleted empty checkbox" "reports the deletion"
}

test_apply_ticks_agenda_through_the_cli() {
  local stub out
  stub="$(mktemp)"
  printf '#!/usr/bin/env bash\ncat >/dev/null\necho "called: $*"\n' > "$stub"
  chmod +x "$stub"
  out="$(printf 'done-agenda\tDaily/2026-08-21.md:9\t- [ ] 12:30 – 12:45 [[x]]\n' | OBSIDIAN_BIN="$stub" cleanup_apply 2>&1)"
  rm -f "$stub"
  assert_contains "$out" "called: task ref=Daily/2026-08-21.md:9 done" "agenda line ticked via obsidian task ... done"
}

test_render_by_file_matches_verbose_layout() {
  local got
  got="$(printf '%s' "$TASKS" | normalize_tasks | jq '[.[0], .[2]]' | render_by_file)"
  # $(...) strips the trailing blank line; the layout still ends each file with one.
  assert_eq "$got" $'Daily/2026-08-21.md\n9\t- [ ] 12:30 – 12:45 [[Daily standup • 2026-08-21]]\n\nMeetings/Standup • 2026-08-20.md\n28\t- [ ]' "file header, line<TAB>raw, blank line"
}

run_tests
