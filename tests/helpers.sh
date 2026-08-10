#!/usr/bin/env bash

fail() {
  printf '  FAIL: %s\n' "$1" >&2
  return 1
}

assert_eq() {
  local actual="$1" expected="$2" msg="${3:-}"
  if [[ "$actual" != "$expected" ]]; then
    printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$msg" "$expected" "$actual" >&2
    return 1
  fi
  return 0
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '  FAIL: %s\n    expected to contain: %s\n    actual: %s\n' "$msg" "$needle" "$haystack" >&2
    return 1
  fi
  return 0
}

# Runs every function in the sourcing file whose name starts with test_.
run_tests() {
  local failed=0 name
  for name in $(declare -F | awk '{print $3}' | grep '^test_' || true); do
    if "$name"; then
      printf '  ok  %s\n' "$name"
    else
      printf '  ERR %s\n' "$name"
      failed=1
    fi
  done
  return $failed
}
