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
