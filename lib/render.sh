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
  (($mid - (ms/1000)) / 86400) as $d
  | if   $d <= 0  then "Today"
    elif $d <= 1  then "Yesterday"
    elif $d <= 7  then "This week"
    elif $d <= 14 then "Last week"
    else "Older" end;
JQ
}

# stdin: raw `obsidian tasks format=json`
# stdout: same records plus `ref`, with the checkbox prefix stripped from `text`.
normalize_tasks() {
  jq '[ .[] | . + {
        ref: "\(.file):\(.line)",
        raw: .text,
        text: (.text | sub("^\\s*-\\s*\\[.\\]\\s*"; ""))
      } ]'
}

# stdin: normalized tasks; stdout: the `obsidian tasks verbose` layout —
# a file path, then one "line<TAB>raw line" per task, then a blank line.
render_by_file() {
  jq -r 'group_by(.file) | .[] | .[0].file, (.[] | "\(.line)\t\(.raw)"), ""'
}

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
    def ts_of(v): (if (v == null or v == \"\") then \"0\" else v end) | tonumber;
    def known_of(v): (v != null and v != \"\");
    def order: {\"Today\":0,\"Yesterday\":1,\"This week\":2,\"Last week\":3,\"Older\":4};
    [ .[]
      | . + {ts: ts_of(.[\$field]), ts_known: known_of(.[\$field]), bucketName: bucket(ts_of(.[\$field]))}
      | select(\$since == \"\" or (.ts_known | not) or ((\$mid - (.ts/1000)) / 86400) <= (\$since | tonumber))
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

# $1 = modified|created, $2 = since-days (empty for no filter)
# One TSV line per task: status, text, bucket, file, ref (ref last and hidden by fzf).
render_picker() {
  local field="$1" since="${2:-}" mid
  mid="$(_ref_midnight)"

  jq -r --argjson mid "$mid" --arg field "$field" --arg since "$since" "
    $(bucket_jq_filter)
    def ts_of(v): (if (v == null or v == \"\") then \"0\" else v end) | tonumber;
    def known_of(v): (v != null and v != \"\");
    [ .[] | . + {ts: ts_of(.[\$field]), ts_known: known_of(.[\$field])}
          | select(\$since == \"\" or (.ts_known | not) or ((\$mid - (.ts/1000)) / 86400) <= (\$since | tonumber))
    ]
    | .[] | [\"[\" + .status + \"]\", .text, bucket(.ts), .file, .ref]
        | @tsv
  "
}

# $1 = enriched JSON, $2 = date field, $3 = all-flag (1 to include completed),
# $4 = since-days (empty for no filter).
# Selects tasks and toggles each one. Re-fetches immediately before writing to
# narrow the window in which a captured ref (path:line) could go stale —
# editing a note above a task shifts its line number.
#
# `since` narrows only what is displayed/selectable here; the re-fetch below
# always uses `all_flag` (not `since`) because reconciliation must be able to
# find a selected task regardless of how it re-buckets after being edited.
run_picker() {
  local enriched="$1" field="$2" all_flag="${3:-0}" since="${4:-}" lines ref

  lines="$(printf '%s' "$enriched" | render_picker "$field" "$since")"
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
    if [[ ! "$n" =~ ^[0-9]+$ ]]; then
      printf 'Invalid selection: %s\n' "$n" >&2
      return 1
    fi
    selected="$(printf '%s\n' "$lines" | sed -n "${n}p")"
    if [[ -z "$selected" ]]; then
      printf 'No task numbered %s\n' "$n" >&2
      return 1
    fi
  fi

  [[ -n "$selected" ]] || return 0

  # Line numbers shift when a note is edited above a task, so a ref captured
  # before the user browsed can be stale. Re-fetch and confirm before writing.
  local fresh
  fresh="$(fetch_enriched "$all_flag")" || return 1

  local want have
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    ref="${line##*$'\t'}"
    # Compare both sides through jq's raw .text, never the @tsv-rendered line:
    # @tsv escapes backslash/tab/newline as two-character sequences, so a
    # comparison against a cut -f2 field would false-mismatch on any task
    # text containing those characters (e.g. a literal backslash in a regex).
    want="$(printf '%s' "$enriched" | jq -r --arg r "$ref" '.[] | select(.ref == $r) | .text' | head -1)"
    have="$(printf '%s' "$fresh"    | jq -r --arg r "$ref" '.[] | select(.ref == $r) | .text' | head -1)"
    if [[ -z "$have" ]]; then
      printf 'Skipped %s — task no longer exists (file changed?)\n' "$ref" >&2
      continue
    fi
    if [[ "$have" != "$want" ]]; then
      printf 'Skipped %s — line moved; it now reads: %s\n' "$ref" "$have" >&2
      continue
    fi
    obs_task_write "$ref" toggle || return 1
  done <<< "$selected"
}
