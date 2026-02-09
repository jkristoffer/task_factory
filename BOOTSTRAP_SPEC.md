# AI Factory Bootstrap v2 (Reference Spec)

This file mirrors the expected bootstrap specification. Use it only when the repo does NOT include a BOOTSTRAP.md. If BOOTSTRAP.md exists in the repo root, prefer it.

## Architecture

Layer A (Generator): This bootstrap (runs once)
Layer B (Runner): Iterates plans/*.md and executes them consistently

Critical constraint: No nested orchestration. Runner is pure iteration + gating.

## File Structure to Generate

ai_factory/
- plans/ (user implementation plans)
- runs/ (execution outputs)
- bin/
  - run_all.sh (iterate all plans/*.md sequentially)
  - run_one.sh (execute single plan)
  - run_parallel.sh (execute plans concurrently via git worktrees)
- prompts/
  - codex_execute.md (stable executor prompt)
- schema/
  - result.schema.json (machine-checkable output format)

## Plan File Format Specification

Plans must be markdown files in plans/*.md with these sections:

# [Plan Title]

## Objective
One-sentence description of what to implement.

## Changes
- Specific files to create/modify
- Code/config changes required

## Test Command
```bash
npm test
# or pytest, or cargo test, etc.
```

## Success Criteria
- All tests pass
- No lint errors
- [Any other verification]

Runner behavior: If a plan lacks a test command, Codex must infer one (e.g., syntax check for the changed language).

## Working Directory Contract

All operations execute in the repository root (parent of ai_factory/).
When run_one.sh calls Codex, the working directory is the repo root.
Plans use relative paths from there.

Example: Plan says "create src/utils.py" -> file lands at <repo-root>/src/utils.py.

## File Specifications

### bin/run_all.sh

Requirements:
- Bash with set -euo pipefail
- Iterate plans/*.md alphabetically
- Track timing and pass/fail counts
- Call bin/run_one.sh for each plan
- Continue on failure (do not exit early)
- Print summary at end

Output format:
[1/3] plans/001-setup.md... OK (2.3s)
[2/3] plans/002-tests.md... FAIL (5.1s)
[3/3] plans/003-docs.md... OK (1.0s)

--------------------------
Summary: 2/3 passed (8.4s total)
Failed: plans/002-tests.md

Implementation:
```bash
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
  printf '  %s\n' "${failed_plans[@]}"
  exit 1
fi
```

### bin/run_parallel.sh

Usage: ./bin/run_parallel.sh [plan1.md plan2.md ...]

Environment variables (optional):
- MAX_JOBS - Max concurrent plan executions (default: 3)
- MAX_PASSES - Forwarded to run_one.sh
- CODEX_MODEL - Forwarded to run_one.sh
- WORKTREE_DIR - Base directory for worktrees (default: sibling directory `../.task_factory_worktrees/`)

Flags:
- --no-merge - Skip the merge-back phase

Requirements:
- Bash 3.2+ compatible (no associative arrays)
- set -euo pipefail
- Collect plans from args or plans/*.md
- For each plan, create a git worktree on a temporary branch (`worktree/<plan_name>-<run_id>`)
- Run the worktree's copy of run_one.sh against the worktree's copy of the plan
- Copy results (.codex.json, .log) back to the main ai_factory/runs/
- Poll-based concurrency: track active PIDs, poll with `kill -0`, sleep 0.5s between polls
- EXIT trap cleans up all worktrees (`git worktree remove --force`) and temporary branches
- INT/TERM trap kills child processes, then cleanup runs via EXIT
- Prune stale worktrees from previous interrupted runs on startup
- Dependencies: git (with worktree support), jq, codex CLI

Execution flow:
1. Parse --no-merge flag, collect plan paths
2. Launch up to MAX_JOBS plans concurrently, each in its own worktree
3. As jobs finish, launch remaining plans to fill slots
4. Print summary with pass/fail counts

Merge-back phase (after all plans finish):
1. Sort successful plans alphabetically (same order as run_all.sh)
2. For each, run `git merge --no-ff worktree/<branch>` into current branch
3. On merge conflict: abort merge, report conflicting and remaining unmerged plans, exit 1
4. Failed plans are skipped (not merged) and reported in summary
5. --no-merge flag skips this phase entirely

Output format:
```
=== Parallel plan execution ===
Plans: 3, Max concurrent: 3

  Started: 001-setup (pid 12345)
  Started: 002-tests (pid 12346)
  Started: 003-docs (pid 12347)
  Finished: 001-setup — OK
  Finished: 003-docs — OK
  Finished: 002-tests — FAIL (exit 1)

--------------------------
Summary: 2/3 passed (15s total)
Failed:
  002-tests

=== Merge-back phase ===
  Merging: 001-setup (worktree/001-setup-12345-1700000000)
  Merging: 003-docs (worktree/003-docs-12345-1700000000)
Merged 2 plan(s) successfully.
```

Key design decisions:
- Uses run_one.sh unmodified: run_one.sh resolves REPO_ROOT from BASH_SOURCE, so when invoked from a worktree it naturally operates against that worktree's root
- Parallel indexed arrays instead of associative arrays for bash 3.2 compatibility
- Empty array guards (`${arr+"${arr[@]}"}`) for set -u compatibility
- Worktree cleanup is file-based (paths written to temp file) for reliability during signal handling
- Branch names scoped to RUN_ID (pid + timestamp) to avoid collisions between concurrent runs

### bin/run_one.sh

Usage: ./bin/run_one.sh plans/my-plan.md

Environment variables (optional):
- CODEX_MODEL - Model to use (default: from Codex CLI config)
- MAX_PASSES - Retry limit (default: 2)

Requirements:
- Accept single plan file path as argument
- Validate plan file exists
- Execute from repository root (not ai_factory/)
- Robust JSON extraction with fallback
- Cleanup temp files on exit/interrupt
- Dependencies: jq, codex CLI

Stop conditions (exit 0):
- status == "success" AND tests.passed == true AND must_fix is empty array

Fail conditions (exit 1):
- Plan file doesn't exist
- MAX_PASSES exceeded
- status == "failed"
- tests.passed == false
- must_fix is non-empty
- JSON parse error
- Codex timeout/crash (no output)

Implementation:
```bash
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
  if codex exec ${CODEX_MODEL:+--model "$CODEX_MODEL"} --full-auto - \
       < "$tmp_prompt" > "$tmp_output" 2>&1; then

    # Extract JSON (robust: use last ```json block or last {...} block)
    if grep -q '```json' "$tmp_output"; then
      json_payload="$(
        awk '
          /```json/ { in_block=1; buf=""; next }
          /```/ { if (in_block) { last=buf; in_block=0 } ; next }
          in_block { buf = buf $0 "\n" }
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
```

### prompts/codex_execute.md

```markdown
You are implementing a plan in a git repository.

## Working Directory
You are executing from the repository root. All file paths in the plan are relative to this root.

## Output Format (CRITICAL)

You MUST output valid JSON wrapped in markdown fences:

```json
{
  "status": "success" | "failed",
  "tests": {
    "passed": true | false,
    "command": "command that was run",
    "output_snippet": "first 500 chars of output"
  },
  "must_fix": ["issue 1", "issue 2"],
  "summary": "1-sentence description",
  "files_changed": ["path/to/file1", "path/to/file2"]
}
```

Do not include any text outside the fenced JSON block.

## Rules

1. Read the plan completely (provided below)
2. Implement all changes described
3. Run the test command from the plan
   - If no test command specified, infer appropriate verification (syntax check, import test, etc.)
   - If tests fail, attempt one fix and re-run
4. Populate JSON accurately:
   - status: "success" only if tests passed AND no critical issues
   - tests.passed: true only if test command exited 0
   - must_fix: [] if no blocking issues (suggestions do not count)
   - files_changed: [...] must list all files you created/modified

## Consistency Requirements

- If status == "failed", then tests.passed must be false OR must_fix must be non-empty
- If tests.passed == false, then status must be "failed"
- If must_fix is non-empty, then status must be "failed"

## Stop Condition

Output the JSON fence and stop. The runner decides retry logic.
```

### schema/result.schema.json

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["status", "tests", "must_fix", "summary", "files_changed"],
  "properties": {
    "status": {
      "type": "string",
      "enum": ["success", "failed"]
    },
    "tests": {
      "type": "object",
      "required": ["passed", "command", "output_snippet"],
      "properties": {
        "passed": { "type": "boolean" },
        "command": { "type": "string" },
        "output_snippet": { "type": "string" }
      },
      "additionalProperties": false
    },
    "must_fix": {
      "type": "array",
      "items": { "type": "string" }
    },
    "summary": {
      "type": "string",
      "minLength": 1
    },
    "files_changed": {
      "type": "array",
      "items": { "type": "string" }
    }
  },
  "additionalProperties": false
}
```

## Generation Checklist

1. Create ai_factory/ directory structure
2. Generate bin/run_one.sh with executable permissions
3. Generate bin/run_all.sh with executable permissions
4. Generate prompts/codex_execute.md
5. Generate schema/result.schema.json
6. Create empty plans/ directory with .gitkeep
7. Create empty runs/ directory with .gitkeep
8. Validate all scripts with shellcheck (if available)

Final output: "OK AI Factory generated. Add plans to plans/*.md and run bin/run_all.sh"

## Design Constraints (enforced)

- No nested orchestration: runner is iteration only
- No agent memory: each Codex call is stateless
- Hard limit: MAX_PASSES prevents infinite loops
- Machine-readable: all control flow based on JSON schema
- Stable process: prompts/schema versioned separately from plans
- Repo-centric: all operations relative to repo root, not ai_factory/
