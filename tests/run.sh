#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

failed=0
for f in test_*.sh; do
  printf '%s\n' "$f"
  bash "$f" || failed=1
done

if [[ $failed -ne 0 ]]; then
  printf '\nFAILED\n' >&2
  exit 1
fi
printf '\nAll tests passed\n'
