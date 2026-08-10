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

run_tests
