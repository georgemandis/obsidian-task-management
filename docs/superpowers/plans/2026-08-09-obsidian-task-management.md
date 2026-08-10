# Obsidian Global Task Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Shell scripts wrapping the `obsidian` CLI that group vault tasks by date or file and toggle them from the terminal.

**Architecture:** A single dispatcher (`bin/obsidian-tasks`) delegating to sourced library functions. One fetch enriches task JSON with per-file timestamps; every renderer consumes that same structure. The `ref=<path:line>` string is the universal task handle — read and write share one identifier, so no index or state file exists.

**Tech Stack:** bash, `jq` 1.8, `awk` (BSD), `fzf` 0.74, and the `obsidian` CLI. Tests use plain bash assertions — no framework.

## Global Constraints

- **Target vault is whatever Obsidian has focused.** `vault=` is documented but non-functional; never pass it.
- **Every `obsidian` invocation must be wrapped in `timeout`.** The CLI hangs rather than failing when it cannot complete.
- **Never toggle a real task in a test.** Automated tests use fixtures only. The CLI smoke test (Task 8) is manual and requires explicit user consent.
- **Date math lives in `jq`, not `date`.** Avoids BSD/GNU divergence. The caller passes a precomputed midnight epoch via `--argjson`.
- **Timestamps from the CLI are epoch milliseconds** (strings in JSON, e.g. `"1768155505675"`). Divide by 1000 before comparing to epoch seconds.
- **Parse refs by splitting on the LAST colon** (`${ref%:*}` / `${ref##*:}`). Paths may legally contain colons.
- **Shebang:** `#!/usr/bin/env bash` — never a hardcoded `/bin/bash`.
- **`set -euo pipefail`** at the top of every executable script.

---

## File Structure

| File | Responsibility |
|---|---|
| `lib/obsidian.sh` | Every `obsidian` CLI invocation. Timeout wrapping, error detection, dry-run. |
| `lib/fetch.sh` | Build enriched task JSON: fetch tasks, fetch per-file metadata, join. |
| `lib/render.sh` | Pure formatting: date bucketing, grouping, line rendering. |
| `bin/obsidian-tasks` | Argument parsing and command dispatch. |
| `tests/run.sh` | Test runner — discovers and executes `tests/test_*.sh`. |
| `tests/helpers.sh` | Assertion helpers. |
| `tests/fixtures/` | Sample task JSON and file-metadata TSV. |

Library files are sourced, not executed. Each defines functions in one responsibility area and has no side effects at source time.

---

### Task 1: Test harness

**Files:**
- Create: `tests/helpers.sh`
- Create: `tests/run.sh`
- Test: `tests/test_helpers.sh`

**Interfaces:**
- Produces: `assert_eq <actual> <expected> <message>`, `assert_contains <haystack> <needle> <message>`, `fail <message>`. All return 0 on pass, print a diagnostic and return 1 on failure. `tests/run.sh` exits non-zero if any test file fails.

- [ ] **Step 1: Write the failing test**

Create `tests/test_helpers.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

test_assert_eq_passes() {
  assert_eq "abc" "abc" "identical strings match"
}

test_assert_eq_fails_on_difference() {
  if assert_eq "abc" "xyz" "should fail" 2>/dev/null; then
    fail "assert_eq returned success for differing strings"
  fi
}

test_assert_contains_finds_substring() {
  assert_eq "$(assert_contains "hello world" "wor" "substring" && echo ok)" "ok" \
    "assert_contains succeeds when needle present"
}

test_assert_contains_fails_when_absent() {
  if assert_contains "hello" "zzz" "should fail" 2>/dev/null; then
    fail "assert_contains returned success when needle absent"
  fi
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_helpers.sh`
Expected: FAIL — `helpers.sh: No such file or directory`

- [ ] **Step 3: Write minimal implementation**

Create `tests/helpers.sh`:

```bash
#!/usr/bin/env bash

fail() {
  printf '  FAIL: %s\n' "$1" >&2
  return 1
}

assert_eq() {
  local actual="$1" expected="$2" msg="${3:-}"
  if [[ "$actual" != "$expected" ]]; then
    printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$msg" "$expected" "$actual" >&2
    return 1
  fi
  return 0
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '  FAIL: %s\n    expected to contain: %s\n    actual: %s\n' "$msg" "$needle" "$haystack" >&2
    return 1
  fi
  return 0
}

# Runs every function in the sourcing file whose name starts with test_.
run_tests() {
  local failed=0 name
  for name in $(declare -F | awk '{print $3}' | grep '^test_' || true); do
    if "$name"; then
      printf '  ok  %s\n' "$name"
    else
      printf '  ERR %s\n' "$name"
      failed=1
    fi
  done
  return $failed
}
```

Append to `tests/test_helpers.sh`:

```bash
run_tests
```

Create `tests/run.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

failed=0
for f in test_*.sh; do
  printf '%s\n' "$f"
  bash "$f" || failed=1
done

if [[ $failed -ne 0 ]]; then
  printf '\nFAILED\n' >&2
  exit 1
fi
printf '\nAll tests passed\n'
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `chmod +x tests/run.sh && bash tests/run.sh`
Expected: PASS — four `ok test_*` lines, then `All tests passed`

- [ ] **Step 5: Commit**

```bash
git add tests/helpers.sh tests/run.sh tests/test_helpers.sh
git commit -m "test: add bash test harness with assertion helpers"
```

---

### Task 2: Date bucketing

**Files:**
- Create: `lib/render.sh`
- Test: `tests/test_render.sh`

**Interfaces:**
- Produces: `bucket_jq_filter()` — echoes a jq function definition string defining `bucket(ms)`. Callers embed it in a jq program and must pass `--argjson mid <midnight_epoch_seconds>`. Returns one of: `Today`, `Yesterday`, `This week`, `Last week`, `Older`.
- Produces: `midnight_epoch()` — echoes today's local midnight as epoch seconds.

**Why buckets are midnight-anchored:** an elapsed-hours calculation would place last night's 11pm edit in "Today" when run at 10am the next morning. Boundaries are calendar-day edges measured from local midnight.

- [ ] **Step 1: Write the failing test**

Create `tests/test_render.sh`:

```bash
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

run_tests
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_render.sh`
Expected: FAIL — `lib/render.sh: No such file or directory`

- [ ] **Step 3: Write minimal implementation**

Create `lib/render.sh`:

```bash
#!/usr/bin/env bash

# Today's local midnight as epoch seconds. BSD date; -f "%H:%M:%S" reinterprets
# today's date with a zeroed clock.
midnight_epoch() {
  date -j -f "%H:%M:%S" "00:00:00" +%s
}

# Emits a jq function `bucket(ms)` mapping epoch milliseconds to a bucket label.
# Requires the caller to pass --argjson mid <midnight epoch seconds>.
#
# $d is whole days between the timestamp and today's midnight:
#   negative -> after midnight (today), 0 -> the day before, and so on.
bucket_jq_filter() {
  cat <<'JQ'
def bucket(ms):
  (((($mid - (ms/1000)) / 86400) | floor)) as $d
  | if   $d < 0  then "Today"
    elif $d < 1  then "Yesterday"
    elif $d < 7  then "This week"
    elif $d < 14 then "Last week"
    else "Older" end;
JQ
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: PASS — all `test_render` cases ok

- [ ] **Step 5: Commit**

```bash
git add lib/render.sh tests/test_render.sh
git commit -m "feat: add midnight-anchored date bucketing"
```

---

### Task 3: Task JSON normalization

**Files:**
- Modify: `lib/render.sh`
- Create: `tests/fixtures/tasks.json`
- Modify: `tests/test_render.sh`

**Interfaces:**
- Produces: `normalize_tasks()` — reads raw `obsidian tasks format=json` on stdin, writes JSON array on stdout. Each object gains `ref` (`"<file>:<line>"`) and has `text` stripped of its `- [ ] ` / `- [x] ` checkbox prefix.

- [ ] **Step 1: Write the failing test**

Create `tests/fixtures/tasks.json` — a trimmed sample of real CLI output, including a nested path with a space and a task whose text contains a colon:

```json
[
  {
    "status": " ",
    "text": "- [ ] Follow-up norm: funnel changes must update the spec test",
    "file": "Audit/09 Week-One Action List.md",
    "line": "20"
  },
  {
    "status": "x",
    "text": "- [x] Ship the audit doc",
    "file": "Audit/09 Week-One Action List.md",
    "line": "24"
  },
  {
    "status": " ",
    "text": "- [ ] Ask about staging deploy",
    "file": "Meetings/Standup.md",
    "line": "7"
  }
]
```

Append to `tests/test_render.sh` (before the trailing `run_tests`):

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_render.sh`
Expected: FAIL — `normalize_tasks: command not found`

- [ ] **Step 3: Write minimal implementation**

Append to `lib/render.sh`:

```bash
# stdin: raw `obsidian tasks format=json`
# stdout: same records plus `ref`, with the checkbox prefix stripped from `text`.
normalize_tasks() {
  jq '[ .[] | . + {
        ref: "\(.file):\(.line)",
        text: (.text | sub("^\\s*-\\s*\\[.\\]\\s*"; ""))
      } ]'
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/render.sh tests/test_render.sh tests/fixtures/tasks.json
git commit -m "feat: normalize task JSON with ref and stripped text"
```

---

### Task 4: File metadata parsing

**Files:**
- Create: `lib/fetch.sh`
- Create: `tests/fixtures/file-meta.tsv`
- Create: `tests/test_fetch.sh`

**Interfaces:**
- Produces: `parse_file_meta()` — reads `obsidian file path=<p>` TSV on stdin, writes one JSON object `{path, created, modified}` on stdout. Timestamps stay strings (epoch ms).
- Produces: `join_metadata()` — takes a metadata-JSON-array file path as `$1`, reads normalized tasks on stdin, writes tasks each joined with their file's `created` and `modified`.

- [ ] **Step 1: Write the failing test**

Create `tests/fixtures/file-meta.tsv` (tab-separated, matching real CLI output):

```
path	Audit/09 Week-One Action List.md
name	09 Week-One Action List
extension	md
size	5994
created	1765157522206
modified	1786290000000
```

Create `tests/test_fetch.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_fetch.sh`
Expected: FAIL — `lib/fetch.sh: No such file or directory`

- [ ] **Step 3: Write minimal implementation**

Create `lib/fetch.sh`:

```bash
#!/usr/bin/env bash

# stdin: `obsidian file path=<p>` TSV output
# stdout: {"path":..., "created":..., "modified":...}
parse_file_meta() {
  awk -F'\t' '
    { m[$1] = $2 }
    END {
      printf "{\"path\":\"%s\",\"created\":\"%s\",\"modified\":\"%s\"}\n",
        m["path"], m["created"], m["modified"]
    }'
}

# $1: path to a JSON file holding an array of parse_file_meta objects
# stdin: normalized tasks; stdout: tasks with created/modified attached
join_metadata() {
  local meta_file="$1"
  jq --slurpfile meta "$meta_file" '
    ($meta[0] | INDEX(.path)) as $byPath
    | [ .[] | . + {
          created:  ($byPath[.file].created  // null),
          modified: ($byPath[.file].modified // null)
        } ]'
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/fetch.sh tests/test_fetch.sh tests/fixtures/file-meta.tsv
git commit -m "feat: parse file metadata TSV and join onto tasks"
```

---

### Task 5: CLI wrapper

**Files:**
- Create: `lib/obsidian.sh`
- Create: `tests/test_obsidian.sh`

**Interfaces:**
- Produces: `obs()` — wraps every `obsidian` call with `timeout ${OBSIDIAN_TIMEOUT:-25}`. On timeout (exit 124) prints "Is Obsidian running?" to stderr and returns 1.
- Produces: `obs_task_write(ref, verb)` — runs `obsidian task ref=<ref> <verb>`. Honors `OBSIDIAN_TASKS_DRY_RUN=1` by printing the command instead. Detects `not found` in output and returns 1 with a vault-mismatch message.
- Produces: `ref_file(ref)` / `ref_line(ref)` — split on the LAST colon.

**Testability:** `obs` calls the binary named by `OBSIDIAN_BIN` (default `obsidian`), so tests point it at a stub.

- [ ] **Step 1: Write the failing test**

Create `tests/test_obsidian.sh`:

```bash
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
  printf '#!/usr/bin/env bash\necho "Error: File \\"X.md\\" not found." \n' > "$stub"
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

run_tests
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_obsidian.sh`
Expected: FAIL — `lib/obsidian.sh: No such file or directory`

- [ ] **Step 3: Write minimal implementation**

Create `lib/obsidian.sh`:

```bash
#!/usr/bin/env bash

: "${OBSIDIAN_BIN:=obsidian}"
: "${OBSIDIAN_TIMEOUT:=25}"

# Every CLI call goes through here. The CLI hangs rather than failing when it
# cannot complete, so the timeout is mandatory.
obs() {
  local rc=0
  timeout "$OBSIDIAN_TIMEOUT" "$OBSIDIAN_BIN" "$@" || rc=$?
  if [[ $rc -eq 124 ]]; then
    printf 'obsidian timed out after %ss. Is Obsidian running?\n' "$OBSIDIAN_TIMEOUT" >&2
    return 1
  fi
  return $rc
}

ref_file() { printf '%s' "${1%:*}"; }
ref_line() { printf '%s' "${1##*:}"; }

# $1 = ref (path:line), $2 = verb (toggle|done|todo)
obs_task_write() {
  local ref="$1" verb="$2" out rc=0

  if [[ "${OBSIDIAN_TASKS_DRY_RUN:-}" == "1" ]]; then
    printf 'DRY RUN: obsidian task ref=%s %s\n' "$ref" "$verb"
    return 0
  fi

  out="$(obs task ref="$ref" "$verb" 2>&1)" || rc=$?

  # A ref valid in one vault silently fails in another; surface that clearly.
  if [[ "$out" == *"not found"* ]]; then
    printf 'Could not resolve %s — is the expected vault focused?\n  %s\n' "$ref" "$out" >&2
    return 1
  fi

  [[ -n "$out" ]] && printf '%s\n' "$out"
  return $rc
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/obsidian.sh tests/test_obsidian.sh
git commit -m "feat: add obsidian CLI wrapper with timeout and dry-run"
```

---

### Task 6: Fetch pipeline and rendering

**Files:**
- Modify: `lib/fetch.sh`
- Modify: `lib/render.sh`
- Modify: `tests/test_render.sh`

**Interfaces:**
- Produces: `fetch_enriched(all_flag)` — `$1` is `1` to include done tasks, else `0`. Writes the enriched task array to stdout. Makes one `tasks` call plus one `file` call per distinct file.
- Produces: `render_by_date(field, since_days)` — reads enriched JSON, writes grouped text. `field` is `modified` or `created`; `since_days` empty for no filter.
- Produces: `render_picker(field)` — reads enriched JSON, writes one TSV line per task: `status<TAB>text<TAB>bucket<TAB>file<TAB>ref`.

**Note on picker columns:** the file is a *visible* column so filename search works; only the trailing ref is hidden (fzf `--with-nth=1..-2`).

- [ ] **Step 1: Write the failing test**

Append to `tests/test_render.sh` (before `run_tests`):

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_render.sh`
Expected: FAIL — `render_by_date: command not found`

- [ ] **Step 3: Write minimal implementation**

Append to `lib/render.sh`:

```bash
# Tests override the clock via OBSIDIAN_TASKS_NOW.
_ref_midnight() {
  if [[ -n "${OBSIDIAN_TASKS_NOW:-}" ]]; then
    printf '%s' "$OBSIDIAN_TASKS_NOW"
  else
    midnight_epoch
  fi
}

# $1 = modified|created, $2 = since-days (empty for no filter)
render_by_date() {
  local field="$1" since="${2:-}" mid
  mid="$(_ref_midnight)"

  jq -r --argjson mid "$mid" --arg field "$field" --arg since "$since" "
    $(bucket_jq_filter)
    def order: {\"Today\":0,\"Yesterday\":1,\"This week\":2,\"Last week\":3,\"Older\":4};
    [ .[]
      | . + {ts: (.[\$field] | tonumber), bucketName: bucket(.[\$field] | tonumber)}
      | select(\$since == \"\" or ((\$mid - (.ts/1000)) / 86400) < (\$since | tonumber))
    ]
    | group_by(.bucketName)
    | sort_by(order[.[0].bucketName])
    | map(
        \"## \" + .[0].bucketName + \"\n\"
        + ( group_by(.file)
            | map(\"  \" + .[0].file + \"\n\"
                  + (map(\"    [\" + .status + \"] \" + .text) | join(\"\n\")))
            | join(\"\n\") )
      )
    | join(\"\n\n\")
  "
}

# One TSV line per task: status, text, bucket, file, ref (ref last and hidden by fzf).
render_picker() {
  local field="$1" mid
  mid="$(_ref_midnight)"

  jq -r --argjson mid "$mid" --arg field "$field" "
    $(bucket_jq_filter)
    .[] | [\"[\" + .status + \"]\", .text, bucket(.[\$field] | tonumber), .file, .ref]
        | @tsv
  "
}
```

Append to `lib/fetch.sh`:

```bash
# $1 = 1 to include completed tasks, else 0
fetch_enriched() {
  local all="${1:-0}" tasks meta_file path

  if [[ "$all" == "1" ]]; then
    tasks="$(obs tasks format=json)"
  else
    tasks="$(obs tasks todo format=json)"
  fi

  # An empty vault yields no tasks; emit an empty array rather than failing.
  if [[ -z "$tasks" || "$(jq -r 'length' <<< "$tasks")" == "0" ]]; then
    printf '[]\n'
    return 0
  fi

  tasks="$(printf '%s' "$tasks" | normalize_tasks)"

  meta_file="$(mktemp)"
  trap 'rm -f "$meta_file"' RETURN

  {
    printf '['
    local first=1
    while IFS= read -r path; do
      [[ $first -eq 0 ]] && printf ','
      first=0
      obs file path="$path" | parse_file_meta
    done < <(jq -r '[.[].file] | unique | .[]' <<< "$tasks")
    printf ']'
  } > "$meta_file"

  printf '%s' "$tasks" | join_metadata "$meta_file"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/fetch.sh lib/render.sh tests/test_render.sh
git commit -m "feat: add fetch pipeline and date/picker renderers"
```

---

### Task 7: Dispatcher

**Files:**
- Create: `bin/obsidian-tasks`
- Create: `tests/test_cli.sh`

**Interfaces:**
- Consumes: `fetch_enriched`, `render_by_date`, `render_picker`, `obs_task_write`, `obs`.
- Produces: the executable `bin/obsidian-tasks` supporting `by-date`, `by-file`, `pick`, `toggle`, and `--help`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_cli.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_cli.sh`
Expected: FAIL — no such file `bin/obsidian-tasks`

- [ ] **Step 3: Write minimal implementation**

Create `bin/obsidian-tasks`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/obsidian.sh"
source "$ROOT/lib/render.sh"
source "$ROOT/lib/fetch.sh"

usage() {
  cat <<'EOF'
obsidian-tasks — manage Obsidian tasks from the terminal

Usage:
  obsidian-tasks by-date [--created] [--all] [--since <n>d]
  obsidian-tasks by-file [--all]
  obsidian-tasks pick    [--created] [--all]
  obsidian-tasks toggle <ref> [--done|--todo]

Options:
  --created      Group by file creation date instead of modification date
  --all          Include completed tasks (default: open tasks only)
  --since <n>d   Only files touched within the last n days

Environment:
  OBSIDIAN_TASKS_DRY_RUN=1   Print write commands instead of running them
  OBSIDIAN_TIMEOUT=<secs>    CLI timeout (default 25)

Targets whichever vault Obsidian currently has focused.
EOF
}

cmd="${1:-}"
[[ -n "$cmd" ]] || { usage >&2; exit 1; }
shift || true

case "$cmd" in
  -h|--help|help) usage; exit 0 ;;

  by-date|pick)
    field="modified"; all=0; since=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --created) field="created"; shift ;;
        --all)     all=1; shift ;;
        --since)   since="${2%d}"; shift 2 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
      esac
    done

    enriched="$(fetch_enriched "$all")"
    if [[ "$(jq -r 'length' <<< "$enriched")" == "0" ]]; then
      printf 'No tasks found.\n'; exit 0
    fi

    if [[ "$cmd" == "by-date" ]]; then
      printf '%s' "$enriched" | render_by_date "$field" "$since"
    else
      run_picker "$enriched" "$field"
    fi
    ;;

  by-file)
    all=0
    [[ "${1:-}" == "--all" ]] && all=1
    if [[ "$all" == "1" ]]; then obs tasks verbose; else obs tasks todo verbose; fi
    ;;

  toggle)
    ref="${1:-}"
    [[ -n "$ref" ]] || { printf 'toggle requires a ref (path:line)\n' >&2; exit 1; }
    shift
    verb="toggle"
    case "${1:-}" in
      --done) verb="done" ;;
      --todo) verb="todo" ;;
      "")     ;;
      *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
    obs_task_write "$ref" "$verb"
    ;;

  *) printf 'Unknown command: %s\n' "$cmd" >&2; usage >&2; exit 1 ;;
esac
```

Append `run_picker` to `lib/render.sh` (it belongs with rendering, and Task 7's dispatcher calls it):

```bash
# $1 = enriched JSON, $2 = date field. Selects tasks and toggles each one.
run_picker() {
  local enriched="$1" field="$2" lines ref

  lines="$(printf '%s' "$enriched" | render_picker "$field")"
  [[ -n "$lines" ]] || { printf 'No tasks found.\n'; return 0; }

  local selected
  if command -v fzf >/dev/null 2>&1; then
    # --with-nth=1..-2 hides the trailing ref from display and from matching.
    selected="$(printf '%s\n' "$lines" \
      | fzf --multi --delimiter=$'\t' --with-nth=1..-2 \
            --prompt='task> ' --header='TAB to select multiple, ENTER to toggle' \
      || true)"
  else
    printf 'fzf not found — falling back to a numbered list.\n' >&2
    printf '%s\n' "$lines" | awk -F'\t' '{printf "%3d  %s %s  (%s)\n", NR, $1, $2, $3}'
    printf 'Number to toggle (blank to cancel): '
    local n; read -r n
    [[ -n "$n" ]] || return 0
    selected="$(printf '%s\n' "$lines" | sed -n "${n}p")"
  fi

  [[ -n "$selected" ]] || return 0

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    ref="${line##*$'\t'}"
    obs_task_write "$ref" toggle || return 1
  done <<< "$selected"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `chmod +x bin/obsidian-tasks && bash tests/run.sh`
Expected: PASS — every suite ok

- [ ] **Step 5: Commit**

```bash
git add bin/obsidian-tasks lib/render.sh tests/test_cli.sh
git commit -m "feat: add dispatcher with by-date, by-file, pick, and toggle"
```

---

### Task 8: Live verification and README

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: everything above.
- Produces: user-facing docs and confirmation the tool works against the real vault.

**Consent gate:** Steps 2 and 3 write to the live vault. Do not run them without explicit user approval at that moment. Steps 1 and 4 are read-only and always safe.

- [ ] **Step 1: Verify read paths against the live vault**

```bash
bin/obsidian-tasks by-date | head -40
bin/obsidian-tasks by-date --created | head -20
bin/obsidian-tasks by-date --since 7d | head -20
bin/obsidian-tasks by-file | head -20
```

Expected: bucket headings in Today → Older order, tasks nested under their source files, `--since 7d` visibly shorter. No errors, no hangs.

- [ ] **Step 2: Verify the write path in dry-run (no changes made)**

Pick any real ref from Step 1's output:

```bash
OBSIDIAN_TASKS_DRY_RUN=1 bin/obsidian-tasks toggle "<ref from above>"
```

Expected: `DRY RUN: obsidian task ref=<ref> toggle`, and the vault is untouched.

- [ ] **Step 3: Live round-trip on a scratch note — ASK THE USER FIRST**

```bash
obsidian create name="obsidian-tasks-smoke-test" content="- [ ] scratch task\n"
bin/obsidian-tasks toggle "obsidian-tasks-smoke-test.md:1"
obsidian read file="obsidian-tasks-smoke-test"     # expect: - [x] scratch task
bin/obsidian-tasks toggle "obsidian-tasks-smoke-test.md:1" --todo
obsidian read file="obsidian-tasks-smoke-test"     # expect: - [ ] scratch task
obsidian delete file="obsidian-tasks-smoke-test"
```

Expected: the checkbox flips to `[x]`, back to `[ ]`, and the scratch note is removed. Never run this against a real note.

- [ ] **Step 4: Write the README**

Create `README.md`:

````markdown
# obsidian-tasks

Group and manage [Obsidian](https://obsidian.md) tasks from the terminal, built on
the [Obsidian CLI](https://obsidian.md/cli).

Tasks live in the notes where they were written — meetings, projects, daily notes.
This tool gathers them into one view without moving them.

## Requirements

- Obsidian, running, with the CLI enabled
- `jq`
- `fzf` (optional — `pick` falls back to a numbered prompt)

## Usage

```bash
obsidian-tasks by-date              # open tasks, grouped by when their note changed
obsidian-tasks by-date --created    # group by note creation date instead
obsidian-tasks by-date --since 7d   # only notes touched in the last week
obsidian-tasks by-date --all        # include completed tasks

obsidian-tasks by-file              # group by source file

obsidian-tasks pick                 # fuzzy-select tasks and toggle them
obsidian-tasks toggle "Notes/Standup.md:7"
obsidian-tasks toggle "Notes/Standup.md:7" --done
```

Date buckets are Today, Yesterday, This week (2–7 days), Last week (8–14 days),
and Older, measured from local midnight. Empty buckets are omitted.

## How it works

`obsidian tasks format=json` returns each task's `file` and `line`. Joined with a
colon, those form the `ref=<path:line>` that `obsidian task` accepts — so reading
and writing share one identifier, and no local index or state file exists.

Grouping by date needs one `obsidian file` call per distinct file to read
timestamps, which is why a date-grouped run takes a few seconds.

## Known limitations

- **Active vault only.** The CLI's `vault=` option is documented but has no effect;
  every command targets whichever vault Obsidian currently has focused.
- **Line numbers shift.** A ref is valid at the moment it is read. `pick` re-fetches
  immediately before toggling to keep that window small.
- **Obsidian must be running.** The CLI hangs rather than failing otherwise; calls
  time out after 25s (`OBSIDIAN_TIMEOUT` to change).

## Environment

| Variable | Effect |
|---|---|
| `OBSIDIAN_TASKS_DRY_RUN=1` | Print write commands instead of executing them |
| `OBSIDIAN_TIMEOUT` | CLI timeout in seconds (default 25) |
| `OBSIDIAN_BIN` | Path to the `obsidian` binary (default `obsidian`) |

## Tests

```bash
bash tests/run.sh
```

Tests run entirely against fixtures and never touch a vault.
````

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: add README with usage and known limitations"
```

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| `ref` = file + ":" + line | 3 (build), 5 (parse) |
| Strip `- [ ] ` prefix | 3 |
| Todo default, `--all` opts in | 6 (fetch), 7 (flag) |
| Date buckets, midnight-anchored | 2 |
| `--created` / `--modified` | 6, 7 |
| `--since <n>d` | 6, 7 |
| `by-date` grouping | 6 |
| `by-file` wrapper | 7 |
| `pick` with multi-select | 7 |
| fzf hides ref, filename visible | 6 (columns), 7 (`--with-nth`) |
| fzf fallback | 7 |
| `toggle` with `--done` / `--todo` | 7 |
| Dry-run on writes | 5, 7 |
| Timeout wrapper | 5 |
| Vault-mismatch detection | 5 |
| Stale-ref mitigation (re-fetch before toggle) | 7 — `pick` fetches, renders, and toggles in one pass |
| TSV metadata parsing | 4 |
| Smoke test, consent-gated | 8 |

No gaps.

**Placeholder scan:** none — every step carries runnable code.

**Type consistency:** `ref_file`/`ref_line` (Task 5) are named consistently; `bucket_jq_filter` (Task 2) is consumed by both renderers in Task 6 with the required `--argjson mid`; `parse_file_meta` output keys (`path`/`created`/`modified`) match the `INDEX(.path)` lookup and the `.created`/`.modified` reads in `join_metadata` (Task 4); `render_picker`'s 5-column order matches `run_picker`'s `${line##*$'\t'}` extraction and `--with-nth=1..-2`.

**One deviation from the spec, deliberate:** the spec placed `run_picker` conceptually in the dispatcher, but it is defined in `lib/render.sh` alongside `render_picker` — the two share the column contract, and splitting them across files would let that contract drift silently.
