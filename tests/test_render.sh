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
