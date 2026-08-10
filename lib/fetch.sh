#!/usr/bin/env bash

# stdin: `obsidian file path=<p>` TSV output
# stdout: {"path":..., "created":..., "modified":...}
parse_file_meta() {
  awk -F'\t' '
    { m[$1] = $2 }
    END {
      p = m["path"]
      gsub(/\\/, "\\\\", p)
      gsub(/"/, "\\\"", p)
      printf "{\"path\":\"%s\",\"created\":\"%s\",\"modified\":\"%s\"}\n",
        p, m["created"], m["modified"]
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
