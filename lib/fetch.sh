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
