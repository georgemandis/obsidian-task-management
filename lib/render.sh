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
        text: (.text | sub("^\\s*-\\s*\\[.\\]\\s*"; ""))
      } ]'
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
    def order: {\"Today\":0,\"Yesterday\":1,\"This week\":2,\"Last week\":3,\"Older\":4};
    [ .[]
      | . + {ts: ts_of(.[\$field]), bucketName: bucket(ts_of(.[\$field]))}
      | select(\$since == \"\" or ((\$mid - (.ts/1000)) / 86400) <= (\$since | tonumber))
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
    def ts_of(v): (if (v == null or v == \"\") then \"0\" else v end) | tonumber;
    .[] | [\"[\" + .status + \"]\", .text, bucket(ts_of(.[\$field])), .file, .ref]
        | @tsv
  "
}

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
