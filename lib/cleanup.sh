#!/usr/bin/env bash

# Noise removal and an ignore list.
#
# Two kinds of checkbox are not tasks and only ever accumulate:
#   - an empty box left by a template ("- [ ]" with nothing after it);
#   - a past meeting on a daily note's agenda ("- [ ] 11:30 – 12:00 [[...]]").
# `clean-up` deletes the first and ticks the second, but only in notes whose
# filename carries a date older than a grace window, so the current week stays
# untouched. Notes with no date in their path are never touched.
#
# The ignore list keeps template folders and bulk imports out of every listing:
# `<vault>/.obsidian-tasks-ignore`, one path prefix per line, `#` for comments.
# Without that file the default is `_/Templates/`.

DEFAULT_IGNORE_PREFIXES='_/Templates/'

# Prints the focused vault's absolute path, or nothing if the CLI cannot say.
vault_path() {
  obs vault 2>/dev/null | awk -F'\t' '$1 == "path" { print $2; exit }'
}

# Prints one ignore prefix per line. OBSIDIAN_TASKS_IGNORE_FILE overrides the
# vault-root lookup (tests use it; so can a user who keeps the list elsewhere).
ignore_prefixes() {
  local f="${OBSIDIAN_TASKS_IGNORE_FILE:-}" root
  if [[ -z "$f" ]]; then
    root="$(vault_path)"
    [[ -n "$root" ]] && f="$root/.obsidian-tasks-ignore"
  fi
  if [[ -n "$f" && -r "$f" ]]; then
    # Strip comments and blank lines; trim trailing whitespace.
    sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' "$f" | grep -v '^$' || true
  else
    printf '%s\n' "$DEFAULT_IGNORE_PREFIXES"
  fi
}

# stdin: task JSON array; stdout: the same minus tasks under an ignored prefix.
filter_ignored() {
  local prefixes
  prefixes="$(ignore_prefixes | jq -R . | jq -s .)"
  jq --argjson ig "$prefixes" '
    [ .[] | . as $t | select( ($ig | map(. as $p | $t.file | startswith($p)) | any) | not ) ]'
}

# YYYY-MM-DD that is $1 days before today. OBSIDIAN_TASKS_TODAY pins "today"
# for tests. BSD date first (macOS), GNU date as the fallback.
cleanup_cutoff() {
  local days="$1" today="${OBSIDIAN_TASKS_TODAY:-}"
  if [[ -n "$today" ]]; then
    date -j -f '%Y-%m-%d' -v-"${days}"d "$today" '+%Y-%m-%d' 2>/dev/null \
      || date -d "$today -${days} days" '+%Y-%m-%d'
  else
    date -j -v-"${days}"d '+%Y-%m-%d' 2>/dev/null \
      || date -d "-${days} days" '+%Y-%m-%d'
  fi
}

# stdin: task JSON (raw CLI shape or normalized; needs .file/.line/.text|.raw)
# $1: cutoff date (YYYY-MM-DD); a note qualifies when the first date in its
#     path is strictly older than the cutoff.
# stdout: TSV of action, ref, raw line text. Actions: delete-empty, done-agenda.
cleanup_plan() {
  local cutoff="$1"
  jq -r --arg cutoff "$cutoff" '
    def raw_of: (.raw // .text);
    def note_date: (.file | capture("(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})") | .d) // null;
    def is_empty_box: raw_of | test("^\\s*-\\s*\\[ \\]\\s*$");
    def is_past_agenda:
      (.file | test("^Daily/")) and
      (raw_of | test("^\\s*-\\s*\\[ \\]\\s*[0-9]{1,2}:[0-9]{2}\\s*[–-]\\s*[0-9]{1,2}:[0-9]{2}\\s"));
    .[]
    | select(.status == " ")
    | select((note_date != null) and (note_date < $cutoff))
    | if is_empty_box then ["delete-empty", "\(.file):\(.line)", raw_of]
      elif is_past_agenda then ["done-agenda", "\(.file):\(.line)", raw_of]
      else empty end
    | @tsv'
}

# Deletes the given line numbers from a file, after re-checking that each one
# is still an empty checkbox (the plan may be minutes old and lines can shift).
# $1: absolute file path; remaining args: line numbers.
# Rewrites in place through a temp file; the inode is preserved so Obsidian's
# watcher sees an edit, not a replacement.
_delete_empty_lines() {
  local file="$1"; shift
  local tmp
  tmp="$(mktemp)"
  awk -v lines="$*" '
    BEGIN { n = split(lines, a, " "); for (i = 1; i <= n; i++) del[a[i]] = 1 }
    (NR in del) && ($0 ~ /^[[:space:]]*-[[:space:]]*\[ \][[:space:]]*$/) { next }
    { print }' "$file" > "$tmp" && cat "$tmp" > "$file"
  rm -f "$tmp"
}

# stdin: cleanup_plan TSV. Applies it: ticks agenda lines through the CLI,
# deletes empty boxes on disk. Honors OBSIDIAN_TASKS_DRY_RUN=1.
cleanup_apply() {
  local root="" action ref raw file line rc=0
  local -a delete_refs=()

  while IFS=$'\t' read -r action ref raw; do
    [[ -n "$action" ]] || continue
    case "$action" in
      done-agenda)
        obs_task_write "$ref" done || rc=1 ;;
      delete-empty)
        delete_refs+=("$ref") ;;
    esac
  done

  [[ ${#delete_refs[@]} -gt 0 ]] || return $rc

  if [[ "${OBSIDIAN_TASKS_DRY_RUN:-}" == "1" ]]; then
    for ref in "${delete_refs[@]}"; do printf 'DRY RUN: delete empty checkbox %s\n' "$ref"; done
    return $rc
  fi

  root="$(vault_path)"
  if [[ -z "$root" ]]; then
    printf 'Cannot resolve the vault path (obsidian vault); skipping deletions.\n' >&2
    return 1
  fi

  # Group refs by file, highest line first, so earlier deletions never shift
  # a later target. Sorted on the line number after the last colon.
  local prev="" lines=""
  while IFS= read -r ref; do
    file="$(ref_file "$ref")"; line="$(ref_line "$ref")"
    if [[ "$file" != "$prev" ]]; then
      if [[ -n "$prev" ]]; then
        _delete_empty_lines "$root/$prev" $lines
        printf 'Deleted empty checkbox(es) at line(s)%s in %s\n' "$lines" "$prev"
      fi
      prev="$file"; lines=""
    fi
    lines="$lines $line"
  done < <(printf '%s\n' "${delete_refs[@]}" \
            | awk -F: '{ print $0 "\t" $NF }' | sort -t$'\t' -k1,1 -k2,2nr | cut -f1)
  if [[ -n "$prev" ]]; then
    _delete_empty_lines "$root/$prev" $lines
    printf 'Deleted empty checkbox(es) at line(s)%s in %s\n' "$lines" "$prev"
  fi
  return $rc
}
