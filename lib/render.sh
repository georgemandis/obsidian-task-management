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
