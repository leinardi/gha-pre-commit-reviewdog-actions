# ruff

Runs the caller's `ruff-check-rdjson` and `ruff-format` [pre-commit](https://pre-commit.com/) hooks
([ruff](https://docs.astral.sh/ruff/)) on the files changed between two commits and posts the
remaining diagnostics, the fixes `--fix` made and the formatting changes through
[reviewdog](https://github.com/reviewdog/reviewdog).

## What it runs and posts

- **check**: `ruff-check-rdjson` at the `manual` stage. Posts:
  - `ruff`: the diagnostics the hook printed, converted to RDJSON by `ruff/rdjson.jq`, as review
    comments
  - `ruff (check fixes)`: the changes its hooks made to the files, as suggestions
- **format**: `ruff-format` at the `pre-commit` stage. Posts:
  - `ruff (format fixes)`: the changes its hooks made to the files, as suggestions

## Requirements

Declare these hooks in the caller's `.pre-commit-config.yaml` (the action runs your hook ids and
aliases, with your arguments, so CI and the local hooks agree):

```yaml
repos:
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.17.3
    hooks:
      - id: ruff-check
        args: ["--fix"]
      - id: ruff-format
      - id: ruff-check
        alias: ruff-check-rdjson
        args: ["--fix", "-q", "--output-format=rdjson"]
        stages: [manual]
```

## How it runs

The files are the ones changed between `from-ref` and `to-ref`, computed as `pre-commit run
--from-ref/--to-ref` would (`git diff FROM...TO`, deletions dropped), and passed with `--files`:
pre-commit never stashes your unstaged changes, and a hook's fixes are never rolled back. With no
changed file, nothing runs and `result` is `skipped`. Each pass starts from a snapshot of the
worktree, and the worktree is restored to it, and verified, before anything is posted. See the
[root README](../README.md#conventions) for what that guarantee covers.

The job fails when a hook fails (`result=failed`) or when something operational goes wrong
(`result=error`: a missing hook id, a report that cannot be read, a reviewdog failure, a restore
that cannot be verified, a setup step that failed); the log says which. reviewdog runs with
`-fail-level=none`, so it only posts. `findings` counts what was posted (diagnostics plus diff
hunks). No token reaches a hook: `github-token` goes to reviewdog only (and, in tofu-tflint, to
setup-tflint).

For debugging, `reports-dir` names an existing directory outside the caller repository (for
example `${{ runner.temp }}/reports`) that receives every report exactly as reviewdog got it, plus
`reports.json`; upload it as an artifact to see what would have been posted.

`ruff/rdjson.jq` reads ruff's RDJSON (several documents when pre-commit ran ruff more than once) and
removes its `suggestions`, which are made against the file before `--fix`: the fixes are posted from
the tree instead, as `ruff (check fixes)`.

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `from-ref` | yes | – | The base commit of the range, such as the pull request's base SHA |
| `to-ref` | yes | – | The head commit of the range, such as the pull request's head SHA |
| `github-token` | no | `""` | The token reviewdog posts with, usually secrets.GITHUB_TOKEN. Required unless reporter is local. |
| `working-directory` | no | `.` | The caller repository, relative to the workspace: a git work tree root, no absolute path, no `..` component. Its .pre-commit-config.yaml defines the hooks and the cache key. |
| `reporter` | no | `github-pr-review` | reviewdog's reporter: github-pr-review, github-check or local |
| `python-version` | no | `3.x` | The Python for setup-python, such as `3.x` or `3.13`. Its resolved version is part of the cache key, so keep it equal to the pre-commit warm-up's `python_version`. |
| `pre-commit-version` | no | `4.6.2` | The pre-commit release to install, X.Y.Z. Keep it equal to the version the warm-up and the rest of CI install. |
| `cache-key-prefix` | no | `pre-commit` | The first part of the pre-commit cache key, before `\|<runner.os>\|`. Keep it equal to the warm-up's `cache_key_prefix`. |
| `reports-dir` | no | `""` | For debugging and the self-tests: an absolute path to an existing, writable directory outside the caller repository that receives every report exactly as reviewdog gets it, plus reports.json. Empty: no copy is kept. |

## Outputs

| Name | Description |
| --- | --- |
| `exitcode` | pre-commit's first nonzero exit status across the passes, else 0; empty when a setup step failed |
| `result` | passed, failed (a hook found problems), skipped (no changed files or none matched) or error (an operational failure, including a setup step that failed before the hooks could run) |
| `ran` | true when at least one hook ran on files; false when none did or a setup step failed |
| `findings` | The number of findings posted: diagnostics plus diff hunks, across every report. Empty when a setup step failed before the hooks ran. |
| `check-exitcode` | pre-commit's exit status in the check pass (ruff-check-rdjson); empty when the pass did not run |
| `format-exitcode` | pre-commit's exit status in the format pass (ruff-format); empty when the pass did not run |

## Permissions

```yaml
permissions:
  contents: read
  pull-requests: write # reporter github-pr-review (the default)
  # checks: write      # reporter github-check instead
```

`reporter: local` prints the findings in the log and needs neither, nor a `github-token`.

## Usage

```yaml
on:
  pull_request:

jobs:
  ruff:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 0
          persist-credentials: false

      - uses: leinardi/gha-pre-commit-reviewdog-actions/ruff@<sha> # v2.0.0
        with:
          from-ref: ${{ github.event.pull_request.base.sha }}
          to-ref: ${{ github.event.pull_request.head.sha }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

Composite actions cannot set a timeout on their steps, so set `timeout-minutes` on the job. The
checkout must reach both commits (`fetch-depth: 0`). With `working-directory`, the caller
repository can be checked out to a subdirectory (`path:` on the checkout).
