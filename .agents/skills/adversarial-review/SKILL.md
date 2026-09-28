---
name: adversarial-review
description: >
  Adversarial code review of a set of changes to gha-pre-commit-reviewdog-actions — working
  tree, staged diff, a branch vs main, a commit range, or a PR. Hunts for breaking changes to
  `v1` callers, shell injection through inputs or file names, unpinned actions or tools,
  wrong pre-commit alias or ref range, reviewdog output that is dropped or misattributed, and
  README drift, then reports ranked findings. Use whenever the user asks to review
  changes/a diff/a PR/a branch, "check my work before committing", "is this ready to merge",
  or "poke holes in this".
---

# Adversarial Review — gha-pre-commit-reviewdog-actions

You are a hostile reviewer. Assume the change is **wrong until proven right**. Each action runs
in other repositories, with their token, the next time `v1` moves: a defect ships to every
caller. Find the input, diff or repository layout where it breaks. A review that finds nothing
is only credible after you tried to break it and failed.

## 1. Establish the diff

| User intent | Command |
| --- | --- |
| "my work" / uncommitted | `git status`, then `git diff HEAD` |
| a branch / "this PR" | `git diff main...HEAD` |
| a commit range | `git diff <base>..<head>` |
| a GitHub PR number | `gh pr diff <n>` and `gh pr view <n>` |

Read every changed `action.yaml` in full, its `README.md`, and any `lib/*.jq` it uses.

## 2. Load project authority

Read `AGENTS.md` first. Each action's `README.md` is its public contract (hook alias the caller
must declare, inputs, outputs): behaviour and README must agree.

## 3. Repository invariants — check on every review

### Callers of `v1`

- An input removed, renamed or made required, an output removed, or a different pre-commit
  alias run is a breaking change: **critical** inside `v1`.
- A changed `-fail-level`, or a new way for the job to fail, changes what callers' required
  checks enforce. Call it out even when intended.

### Shell and injection

- `${{ inputs.* }}` or `${{ github.* }}` inside a `run:` body is injection; it goes through `env:`.
- File names come from the caller's diff: quoting, `xargs`, `for f in $(...)` and `jq` filters
  must survive spaces, quotes, newlines and leading dashes.
- `set -e`/`pipefail` state per step: a `tee >(...)` or `$(...)` that hides a failure, or an
  `exitcode` output computed from the wrong command in a pipeline.

### Pinning and cache

- Every `uses:` is a full SHA with a `# vX.Y.Z` comment; the reviewdog binary version is explicit.
- The cache key must stay `pre-commit|<os>|hash(.pre-commit-config.yaml)`, shared with
  `gh-reusable-workflows`' warm-up.

### Reporting

- RDJSON conversion (`lib/*.jq`): absolute paths made relative to the workspace, empty output
  handled, severities mapped, nothing silently dropped.
- Diff-based suggestions: computed against the right range, and the working tree left as the
  caller expects.

### `conventional-commits`

- Every non-merge commit in `from..to` is checked with the caller's own hook, merges are skipped,
  an empty or invalid range fails loudly, and a missing hook is reported as such.

## 4. Adversarial passes

- **Correctness:** wrong alias, `--from-ref`/`--to-ref` swapped, a condition inverted, a step
  output never written on an early exit.
- **Empty:** no changed files, no findings, a tool that prints nothing, a repository without the
  hook the action runs.
- **Contract drift:** root `README.md` table, action `README.md`, `dependabot.yml` directories
  and the CI `validate-actions` matrix all list a new or renamed action.

Prefer one reproducible defect over ten "consider"s. No named input and wrong result, no finding.

## 5. Verify

| Diff touched | Run |
| --- | --- |
| any `action.yaml` | `make check`; the CI self-lint job for that action runs it on this repository from the branch |
| `conventional-commits/` | also run its step script against a throwaway repository with good, bad and merge commits |
| anything else | `make check` |

An action that CI does not self-lint (ansible-lint, sqlfluff, tofu-*, rain-format) is only
schema-checked here: say that its behaviour is unverified.

## 6. Report

Rank worst first:

```text
<path>:<line> — <severity: critical | high | medium | low>: <one-line defect>
  Failure: <the concrete input/state → the wrong result or broken invariant>
  Fix: <the specific change>
```

End with a verdict: **block**, **approve with nits**, or **approve**, and the gates you ran.
