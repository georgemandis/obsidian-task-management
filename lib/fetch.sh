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
  local all="${1:-0}" tasks meta_file path rc=0

  if [[ "$all" == "1" ]]; then
    tasks="$(obs tasks format=json)" || rc=$?
  else
    tasks="$(obs tasks todo format=json)" || rc=$?
  fi

  if [[ $rc -ne 0 ]]; then
    printf 'Failed to list tasks (obsidian exited %s). Is Obsidian running with a vault focused?\n' "$rc" >&2
    return 1
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
    local first=1 out file_rc
    while IFS= read -r path; do
      [[ $first -eq 0 ]] && printf ','
      first=0
      out="$(obs file path="$path")" && file_rc=0 || file_rc=$?
      if [[ $file_rc -ne 0 ]]; then
        printf '{"path":"","created":"","modified":""}'
        printf 'Warning: could not read metadata for %s\n' "$path" >&2
      else
        printf '%s' "$out" | parse_file_meta
      fi
    done < <(jq -r '[.[].file] | unique | .[]' <<< "$tasks")
    printf ']'
  } > "$meta_file"

  printf '%s' "$tasks" | join_metadata "$meta_file"
}
