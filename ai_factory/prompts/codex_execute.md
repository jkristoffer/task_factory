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
