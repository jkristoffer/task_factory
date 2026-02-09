#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAN_DIR="$ROOT/plans"

shopt -s nullglob
plans=("$PLAN_DIR"/*.md)

if [[ ${#plans[@]} -eq 0 ]]; then
  echo "No plans found in $PLAN_DIR" >&2
  exit 0
fi

passed=0
failed_plans=()
start_time=$SECONDS

for i in "${!plans[@]}"; do
  p="${plans[$i]}"
  name="$(basename "$p")"
  printf "[%d/%d] %s... " $((i+1)) ${#plans[@]} "$name"

  plan_start=$SECONDS
  if "$ROOT/bin/run_one.sh" "$p" 2>/dev/null; then
    elapsed=$((SECONDS - plan_start))
    echo "OK (${elapsed}s)"
    ((passed++))
  else
    elapsed=$((SECONDS - plan_start))
    echo "FAIL (${elapsed}s)"
    failed_plans+=("$p")
  fi
done

total_time=$((SECONDS - start_time))
echo ""
echo "--------------------------"
echo "Summary: $passed/${#plans[@]} passed (${total_time}s total)"

if [[ ${#failed_plans[@]} -gt 0 ]]; then
  echo "Failed:"
  printf '  %s
' "${failed_plans[@]}"
  exit 1
fi
