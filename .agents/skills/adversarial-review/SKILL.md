---
name: adversarial-review
description: >
  Adversarial code review of a set of changes to gha-pre-commit-reviewdog-actions — working
  tree, staged diff, a branch vs main, a commit range, or a PR. Hunts for breaking changes to
  `v2` callers, a caller worktree that is not left as found, a hook failure or operational error
  that passes, shell injection through inputs or file names, unpinned actions or tools, a wrong
  hook alias or stage, reviewdog output that is dropped or misattributed, and README drift, then
  reports ranked findings. Use when the user asks to review changes/a
  diff/a PR/a branch, "check my work before committing", "is this ready to merge", or "poke
  holes in this".
---

# Adversarial Review — gha-pre-commit-reviewdog-actions

You are a hostile reviewer. Assume the change is **wrong until proven right**. Each action runs
in other repositories, on their worktree, with their token, at the next release: a defect ships
to every caller. Find the input, diff or repository layout where it breaks. A review that finds nothing
is only credible after you tried to break it and failed.

Copy this checklist and tick items as you go:

```text
Review progress:
- [ ] 1. Diff and intent established (default scope if none given)
- [ ] 2. AGENTS.md and the contracts it names read
- [ ] 3. Repository invariants checked
- [ ] 4. Adversarial passes run
- [ ] 5. Findings confirmed or dropped; gates run
- [ ] 6. Report written
```

## 1. Establish the diff

With no scope given, review the uncommitted work; if the tree is clean, review the branch
against `main`.

| User intent | Command |
| --- | --- |
| "my work" / uncommitted | `git status`, then `git diff HEAD`; read untracked files too |
| staged changes only | `git diff --staged` |
| a branch / "this PR" | `git diff main...HEAD` |
| a commit range | `git diff <base>..<head>` |
| a GitHub PR number | `gh pr diff <n>` and `gh pr view <n>` |

Read every changed `action.yaml` in full, its `README.md`, its converter (`<action>/rdjson.jq`)
and scripts, and the parts of `lib/` they rely on (`run-passes.sh`'s header is the contract).

Also read `git log --oneline` for the range and any linked issue or pull request body: the stated
**intent** is what you check the change against. A change that works but does something other
than what it claims is a finding.

## 2. Load project authority

Read `AGENTS.md` first. Each action's `README.md` is its public contract (hook alias the caller
must declare, inputs, outputs): behaviour and README must agree.

## 3. Repository invariants — check on every review

### Callers of `v2`

- An input removed, renamed or made required, an output or pass removed, or a different hook id,
  alias or stage in `PASSES` is a breaking change: **critical** inside `v2`.
- A new way for the job to fail, or a changed verdict (`failed` vs `error`), changes what callers'
  required checks enforce. Call it out even when intended.

### The caller's worktree

- Every pass is snapshot, hooks, reports, restore, verify, then reviewdog; the next pass runs only
  after a verified restore. Anything that leaves the real index or a submodule's content changed
  (pre-commit's own `git diff` rewrites a stale index: test with stale stat data), stashes,
  resets, cleans, checks out, or runs pre-commit without the placeholder `--files` or with an
  empty one is **critical**.
- Path handling in the restore: symlinked parents, file↔directory transitions, names with
  newlines or leading dashes. A restore failure must keep the recovery directory and run no
  further pass.

### Fail closed

- A converter (`<action>/rdjson.jq`) must error on input it does not understand, never drop it:
  look for `select(...)`, `// empty`, `try ... catch empty`, `|| true` that turn a parse failure
  into a smaller report. Every severity is mapped explicitly; an unknown one is an error.
- A `required` rdjson report must fail on empty or unparsable output from a failed hook.
- reviewdog runs with `-fail-level=none`; its nonzero exit is an error, not ignored.
- Outputs (`exitcode`, `result`, `ran`, `<pass>-exitcode`) are written on every exit path, the
  early refusals of the action scripts included.

### Shell and injection

- `${{ inputs.* }}` or `${{ github.* }}` inside a `run:` body is injection; it goes through `env:`.
  Every `run:` starts with `set -euo pipefail`.
- File names come from the caller's diff: NUL-safe arrays, never word splitting; quoting, `jq`
  arguments and workflow-command messages (`%`, CR, LF escaped) must survive spaces, quotes,
  newlines and leading dashes. A hook id or ref that starts with `-` is refused.
- Hook output is untrusted: it is printed inside `::stop-commands::`, and never evaluated.

### Pinning, tokens and cache

- Every `uses:` is a full SHA with a `# vX.Y.Z` comment; reviewdog and terraform-docs downloads
  have a pinned version and SHA-256 per platform, `--proto '=https' --retry 3`, under
  `RUNNER_TEMP`, with a version check.
- `github-token` reaches reviewdog (and setup-tflint) only; tofu-trivy's module token is masked
  and passed as step-scoped `GIT_CONFIG_*` env, never written to a git config.
- System tools (`jq`, `shellcheck`) are installed with apt only when missing.
- The pre-commit cache is restore-only (`actions/cache/restore`), under
  `<cache-key-prefix>|<os>|<resolved Python>|hash(<working-directory>/.pre-commit-config.yaml)`:
  the key `gh-reusable-workflows`' warm-up saves. The `python-version`, `pre-commit-version` and
  `cache-key-prefix` defaults stay equal to the warm-up's.

### `conventional-commits`

- Every non-merge commit in `from..to` is checked with the caller's own hook, merges are skipped,
  an empty or invalid range or `working-directory` fails loudly, and a missing hook is reported
  as such.

## 4. Adversarial passes

- **Correctness:** wrong alias, `--from-ref`/`--to-ref` swapped, a step output never written on
  an early exit.
- **Empty:** no changed files, no findings, a tool that prints nothing, a repository without the
  hook the action runs.
- **Contract drift:** root `README.md` table, action `README.md` (inputs and outputs tables equal
  to `action.yaml`), `dependabot.yml` directories, the self-test in `tests/self-test/` and the CI
  matrices all list a new or renamed action.
- **Commit type:** each commit's type must match whether the change ships (`AGENTS.md`, Commit
  messages). The Release workflow derives the version with `svu` from the commits since the last
  tag, and every caller's Dependabot proposes it. A change to what a caller runs (an
  `action.yaml`, `lib/`, a converter or an action script) typed `chore`, `ci`, `docs` or
  `refactor` never ships; a repository-only change typed `fix` or `feat` cuts a release callers did
  not need; a stray `!` or `BREAKING CHANGE:` footer cuts a major. Pull requests land as merge
  commits, so every commit counts, not only the title.
- **A check that can no longer fail:** a hook, script or CI job is only worth its green if it
  still fails on what it exists to stop. Make the guarded thing go wrong (drop a license header,
  dirty a file in `pre-commit-all`, fail a job `ci-result` needs) and see whether it still
  notices. A check that passes because its file list is empty, its hook never ran, its job was
  skipped or a `|| true` swallowed the exit status is a false pass.

For each candidate finding, reproduce it or trace the failing input end to end. If that confirms
it, report it; if not, dig once more, then drop it. No named input and wrong result, no finding.

## 5. Verify

| Diff touched | Run |
| --- | --- |
| anything | `make check` and `make test` |
| `lib/`, a converter, an action script | break the change on purpose and see a test case fail; a converter case uses output recorded from the real tool |
| any `action.yaml` | `make test` (`lib/action-passes.test.sh` validates its structure and `PASSES`); its self-test in `tests/self-test/` runs it on a real runner in CI |
| `scripts/check-license-headers.sh` | `scripts/check-license-headers.sh`, then again with a header removed from one governed file: it must fail and name it |
| `.github/workflows/ci.yaml` | `pre-commit run actionlint --all-files`; `ci-result` still needs every job |

What only a real runner shows (a real reviewdog post, the real tool's output on a hosted image)
is covered by the CI self-tests: say so when the change depends on it.

## 6. Report

Rank worst first:

```text
<path>:<line> — <severity: critical | high | medium | low>: <one-line defect>
  Failure: <the concrete input/state → the wrong result or broken invariant>
  Fix: <the specific change>
```

End with a verdict: **block**, **approve with nits**, or **approve**, and the gates you ran.
