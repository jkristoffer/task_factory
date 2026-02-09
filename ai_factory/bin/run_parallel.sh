#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# run_parallel.sh — Execute plans concurrently using git worktrees
#
# Usage:
#   ./ai_factory/bin/run_parallel.sh [plan1.md plan2.md ...]
#   MAX_JOBS=5 ./ai_factory/bin/run_parallel.sh
#
# Env vars:
#   MAX_JOBS     — max concurrent plan executions (default: 3)
#   MAX_PASSES   — forwarded to run_one.sh
#   CODEX_MODEL  — forwarded to run_one.sh
#   WORKTREE_DIR — base directory for worktrees (default: sibling dir)
#
# Flags:
#   --no-merge   — skip merge-back phase
# ---------------------------------------------------------------------------

FACTORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$FACTORY_ROOT/.." && pwd)"
RUNS="$FACTORY_ROOT/runs"
PLAN_DIR="$FACTORY_ROOT/plans"

MAX_JOBS="${MAX_JOBS:-3}"
RUN_ID="$$-$(date +%s)"
WORKTREE_DIR="${WORKTREE_DIR:-$(dirname "$REPO_ROOT")/.task_factory_worktrees}"

NO_MERGE=false

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
args=()
for arg in "$@"; do
  if [[ "$arg" == "--no-merge" ]]; then
    NO_MERGE=true
  else
    args+=("$arg")
  fi
done
set -- ${args+"${args[@]}"}

# ---------------------------------------------------------------------------
# Tracking state — parallel indexed arrays (bash 3.2 compatible)
#
# Active jobs:
#   active_pids[i]  — PID of running job
#   active_names[i] — plan_name for that job
#
# All plans launched:
#   all_names[i]     — plan_name
#   all_worktrees[i] — worktree path
#   all_branches[i]  — branch name
#   all_results[i]   — "ok" | "fail" | "" (pending)
# ---------------------------------------------------------------------------
state_dir="$(mktemp -d)"
worktree_list_file="$state_dir/worktrees"
touch "$worktree_list_file"

active_pids=()
active_names=()

all_names=()
all_worktrees=()
all_branches=()
all_results=()

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
kill_children() {
  local pid
  for pid in ${active_pids+"${active_pids[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in ${active_pids+"${active_pids[@]}"}; do
    wait "$pid" 2>/dev/null || true
  done
}

cleanup_worktrees() {
  if [[ -f "$worktree_list_file" ]]; then
    while IFS= read -r wt_path; do
      if [[ -n "$wt_path" && -d "$wt_path" ]]; then
        git -C "$REPO_ROOT" worktree remove --force "$wt_path" 2>/dev/null || true
      fi
    done < "$worktree_list_file"
  fi
  git -C "$REPO_ROOT" worktree prune 2>/dev/null || true

  # Delete temporary branches scoped to this run
  local i
  for (( i=0; i<${#all_branches[@]}; i++ )); do
    git -C "$REPO_ROOT" branch -D "${all_branches[$i]}" 2>/dev/null || true
  done

  rm -rf "$state_dir"
}

cleanup() {
  kill_children
  cleanup_worktrees
}

trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------------------
# Prune stale worktrees from previous interrupted runs
# ---------------------------------------------------------------------------
git -C "$REPO_ROOT" worktree prune 2>/dev/null || true

# ---------------------------------------------------------------------------
# Collect plans
# ---------------------------------------------------------------------------
if [[ $# -gt 0 ]]; then
  plans=("$@")
else
  shopt -s nullglob
  plans=("$PLAN_DIR"/*.md)
  shopt -u nullglob
fi

if [[ ${#plans[@]} -eq 0 ]]; then
  echo "No plans found" >&2
  exit 0
fi

echo "=== Parallel plan execution ==="
echo "Plans: ${#plans[@]}, Max concurrent: $MAX_JOBS"
echo ""

mkdir -p "$RUNS"

# ---------------------------------------------------------------------------
# Helpers: find index in all_names by plan_name
# ---------------------------------------------------------------------------
find_all_index() {
  local name="$1" i
  for (( i=0; i<${#all_names[@]}; i++ )); do
    if [[ "${all_names[$i]}" == "$name" ]]; then
      echo "$i"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Launch a single plan in a worktree
# ---------------------------------------------------------------------------
launch_plan() {
  local plan_path="$1"
  local plan_name
  plan_name="$(basename "$plan_path" .md)"

  local branch="worktree/${plan_name}-${RUN_ID}"
  local wt_path="$WORKTREE_DIR/${plan_name}-${RUN_ID}"

  # Record for cleanup and tracking
  echo "$wt_path" >> "$worktree_list_file"
  all_names+=("$plan_name")
  all_worktrees+=("$wt_path")
  all_branches+=("$branch")
  all_results+=("")

  # Create worktree on a new branch from current HEAD
  git -C "$REPO_ROOT" worktree add -b "$branch" "$wt_path" HEAD 2>/dev/null

  # Compute plan path relative to REPO_ROOT to find it in the worktree
  local abs_plan_path
  abs_plan_path="$(cd "$(dirname "$plan_path")" && pwd)/$(basename "$plan_path")"
  local rel_plan_path="${abs_plan_path#$REPO_ROOT/}"
  local wt_plan_path="$wt_path/$rel_plan_path"

  # Run the worktree's copy of run_one.sh
  local wt_run_one="$wt_path/ai_factory/bin/run_one.sh"

  (
    export MAX_PASSES="${MAX_PASSES:-}"
    export CODEX_MODEL="${CODEX_MODEL:-}"
    "$wt_run_one" "$wt_plan_path"
  ) &

  local pid=$!
  active_pids+=("$pid")
  active_names+=("$plan_name")
  echo "  Started: $plan_name (pid $pid)"
}

# ---------------------------------------------------------------------------
# Remove an active job by index
# ---------------------------------------------------------------------------
remove_active() {
  local idx="$1"
  local last=$(( ${#active_pids[@]} - 1 ))
  if [[ $idx -ne $last ]]; then
    active_pids[$idx]="${active_pids[$last]}"
    active_names[$idx]="${active_names[$last]}"
  fi
  unset "active_pids[$last]"
  unset "active_names[$last]"
  # Re-index to avoid sparse array
  if [[ ${#active_pids[@]} -gt 0 ]]; then
    active_pids=("${active_pids[@]}")
    active_names=("${active_names[@]}")
  else
    active_pids=()
    active_names=()
  fi
}

# ---------------------------------------------------------------------------
# Wait for any one active job to finish
# Sets: finished_name, finished_exit
# ---------------------------------------------------------------------------
wait_for_any_job() {
  while true; do
    local i pid
    for (( i=0; i<${#active_pids[@]}; i++ )); do
      pid="${active_pids[$i]}"
      if ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid" 2>/dev/null && finished_exit=0 || finished_exit=$?
        finished_name="${active_names[$i]}"
        remove_active "$i"
        return 0
      fi
    done
    sleep 0.5
  done
}

# ---------------------------------------------------------------------------
# Main execution loop
# ---------------------------------------------------------------------------
plan_idx=0
start_time=$SECONDS

# Launch initial batch
while [[ $plan_idx -lt ${#plans[@]} && ${#active_pids[@]} -lt $MAX_JOBS ]]; do
  launch_plan "${plans[$plan_idx]}"
  plan_idx=$((plan_idx + 1))
done

# Process completions and launch remaining
while [[ ${#active_pids[@]} -gt 0 ]]; do
  finished_name=""
  finished_exit=0
  wait_for_any_job

  all_idx="$(find_all_index "$finished_name")"

  if [[ $finished_exit -eq 0 ]]; then
    all_results[$all_idx]="ok"
    echo "  Finished: $finished_name — OK"
  else
    all_results[$all_idx]="fail"
    echo "  Finished: $finished_name — FAIL (exit $finished_exit)"
  fi

  # Copy results back from worktree runs/ to main runs/
  wt_runs="${all_worktrees[$all_idx]}/ai_factory/runs"
  if [[ -d "$wt_runs" ]]; then
    for f in "$wt_runs"/"$finished_name".*; do
      [[ -f "$f" ]] && cp "$f" "$RUNS/"
    done
  fi

  # Launch next plan if available
  if [[ $plan_idx -lt ${#plans[@]} && ${#active_pids[@]} -lt $MAX_JOBS ]]; then
    launch_plan "${plans[$plan_idx]}"
    plan_idx=$((plan_idx + 1))
  fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
total_time=$((SECONDS - start_time))
echo ""
echo "--------------------------"

passed=0
failed_names=()
succeeded_names=()

# Sort plan names alphabetically for deterministic merge ordering
sorted_plan_names=()
for p in "${plans[@]}"; do
  sorted_plan_names+=("$(basename "$p" .md)")
done
IFS=$'\n' sorted_plan_names=($(printf '%s\n' "${sorted_plan_names[@]}" | sort)); unset IFS

for plan_name in "${sorted_plan_names[@]}"; do
  idx="$(find_all_index "$plan_name")"
  if [[ "${all_results[$idx]}" == "ok" ]]; then
    passed=$((passed + 1))
    succeeded_names+=("$plan_name")
  else
    failed_names+=("$plan_name")
  fi
done

echo "Summary: $passed/${#plans[@]} passed (${total_time}s total)"

if [[ ${#failed_names[@]} -gt 0 ]]; then
  echo "Failed:"
  printf '  %s\n' "${failed_names[@]}"
fi

# ---------------------------------------------------------------------------
# Merge-back phase
# ---------------------------------------------------------------------------
if [[ "$NO_MERGE" == true ]]; then
  echo ""
  echo "Merge-back skipped (--no-merge)"
elif [[ ${#succeeded_names[@]} -eq 0 ]]; then
  echo ""
  echo "No successful plans to merge."
else
  echo ""
  echo "=== Merge-back phase ==="
  merged=0
  for plan_name in "${succeeded_names[@]}"; do
    all_idx="$(find_all_index "$plan_name")"
    branch="${all_branches[$all_idx]}"
    echo "  Merging: $plan_name ($branch)"
    if ! git -C "$REPO_ROOT" merge --no-ff -m "Merge plan: $plan_name" "$branch" 2>&1; then
      echo ""
      echo "MERGE CONFLICT on plan: $plan_name"
      git -C "$REPO_ROOT" merge --abort 2>/dev/null || true

      # Report remaining unmerged plans
      remaining=()
      found=false
      for s in "${succeeded_names[@]}"; do
        if [[ "$s" == "$plan_name" ]]; then
          found=true
          remaining+=("$s (conflicted)")
          continue
        fi
        if $found; then
          remaining+=("$s")
        fi
      done
      echo "Unmerged plans:"
      printf '  %s\n' "${remaining[@]}"
      exit 1
    fi
    merged=$((merged + 1))
  done
  echo "Merged $merged plan(s) successfully."
fi

# ---------------------------------------------------------------------------
# Exit
# ---------------------------------------------------------------------------
if [[ ${#failed_names[@]} -gt 0 ]]; then
  exit 1
fi
exit 0
