#!/usr/bin/env bash
set -euo pipefail

# Cleanup trap
tmp_files=()
cleanup() {
  rm -f "${tmp_files[@]}"
}
trap cleanup EXIT INT TERM

# Args & validation
PLAN_PATH="${1:-}"
if [[ -z "$PLAN_PATH" ]]; then
  echo "Usage: run_one.sh path/to/plan.md" >&2
  exit 2
fi
if [[ ! -f "$PLAN_PATH" ]]; then
  echo "Plan file not found: $PLAN_PATH" >&2
  exit 2
fi

# Config
MAX_PASSES="${MAX_PASSES:-2}"
FACTORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$FACTORY_ROOT/.." && pwd)"
RUNS="$FACTORY_ROOT/runs"
SCHEMA="$FACTORY_ROOT/schema/result.schema.json"

mkdir -p "$RUNS"

plan_name="$(basename "$PLAN_PATH" .md)"
out_json="$RUNS/$plan_name.codex.json"
out_log="$RUNS/$plan_name.log"

# Render prompt with plan content injected
tmp_prompt="$(mktemp)"
tmp_files+=("$tmp_prompt")

cat > "$tmp_prompt" <<PROMPT
$(cat "$FACTORY_ROOT/prompts/codex_execute.md")

---

PLAN FILE CONTENT:
$(cat "$PLAN_PATH")
PROMPT

# Execute with retries
pass=0
while [[ $pass -lt $MAX_PASSES ]]; do
  ((pass++))

  # Run Codex from repo root, capture output
  tmp_output="$(mktemp)"
  tmp_files+=("$tmp_output")

  cd "$REPO_ROOT"
  if codex exec ${CODEX_MODEL:+--model "$CODEX_MODEL"} --full-auto -        < "$tmp_prompt" > "$tmp_output" 2>&1; then

    # Extract JSON (robust: use last ```json block or last {...} block)
    if grep -q '```json' "$tmp_output"; then
      json_payload="$(
        awk '
          /```json/ { in_block=1; buf=""; next }
          /```/ { if (in_block) { last=buf; in_block=0 } ; next }
          in_block { buf = buf $0 "
" }
          END { if (last != "") print last }
        ' "$tmp_output"
      )"
      if [[ -z "$json_payload" ]]; then
        echo "JSON extraction failed (empty markdown fence)" >&2
        cat "$tmp_output" > "$out_log"
        exit 1
      fi
      printf "%s" "$json_payload" | jq -c '.' > "$out_json" 2>/dev/null || {
        echo "JSON extraction failed (markdown fence)" >&2
        cat "$tmp_output" > "$out_log"
        exit 1
      }
    else
      # Try extracting last JSON object
      tac "$tmp_output" | awk '/{/,/}/' | tac | jq -c '.' > "$out_json" 2>/dev/null || {
        echo "JSON extraction failed (no valid JSON found)" >&2
        cat "$tmp_output" > "$out_log"
        exit 1
      }
    fi

    cat "$tmp_output" > "$out_log"

    # Validate against schema
    if ! jq -e --slurpfile schema "$SCHEMA" '. as $data | $schema[0] | . as $s | $data | .' "$out_json" >/dev/null 2>&1; then
      echo "JSON schema validation failed" >&2
      exit 1
    fi

    # Check stop conditions
    status="$(jq -r '.status' "$out_json")"
    tests_passed="$(jq -r '.tests.passed' "$out_json")"
    must_fix_count="$(jq '.must_fix | length' "$out_json")"

    # Consistency check
    if [[ "$status" == "success" && "$tests_passed" != "true" ]]; then
      echo "Inconsistent result: status=success but tests_passed!=true" >&2
      exit 1
    fi

    if [[ "$status" == "success" && "$tests_passed" == "true" && "$must_fix_count" == "0" ]]; then
      exit 0  # Success!
    fi

    # If failed and have passes left, retry
    if [[ $pass -lt $MAX_PASSES ]]; then
      echo "Pass $pass failed, retrying..." >&2
      continue
    fi

  else
    # Codex crashed/timed out
    echo "Codex execution failed (exit code $?)" >&2
    cat "$tmp_output" > "$out_log"
    exit 1
  fi
done

# Max passes exceeded
echo "Failed after $MAX_PASSES passes" >&2
exit 1
