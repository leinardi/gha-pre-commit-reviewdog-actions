# conventional-commits

Checks the message of every non-merge commit between two commits with the caller's own
`conventional-pre-commit` [pre-commit](https://pre-commit.com/) hook, so the CI check and the local
`commit-msg` hook always agree. Each message that does not follow [Conventional
Commits](https://www.conventionalcommits.org/) gets an `::error::` annotation with the commit's
short SHA and subject, and the step fails. No reviewdog, no token.

## Requirements

Add the `conventional-pre-commit` hook to your `.pre-commit-config.yaml` with `stages:
[commit-msg]`, and install the `commit-msg` hook type by default, so `pre-commit install` checks
messages locally too:

```yaml
default_install_hook_types: [pre-commit, commit-msg]

repos:
  - repo: https://github.com/compilerla/conventional-pre-commit
    rev: v4.4.0
    hooks:
      - id: conventional-pre-commit
        stages: [commit-msg]
        args: ["--force-scope"] # require a scope: type(scope): subject
```

The action runs **your** hook, with your arguments. Each message is checked with `pre-commit run
conventional-pre-commit --hook-stage commit-msg --commit-msg-filename <file> --files <file>`: the
`--files` keeps pre-commit from stashing your unstaged changes, and the hook still gets only the
message file. Your index is left byte for byte as it was: pre-commit's own `git diff` rewrites
it when its stat data is stale, so it is saved before and put back after every run (and on an
interruption); if that fails (a hook left `index.lock`), the action fails, keeps the saved copy
under `$RUNNER_TEMP` and prints the command that restores it. It fails with a clear error when the
hook is missing from `.pre-commit-config.yaml`,
when it does not run at the `commit-msg` stage (no `stages: [commit-msg]`), when pre-commit fails
without running it (an invalid config), when a ref is empty or not a commit (fetch the history with
`fetch-depth: 0`), or when `working-directory` is not a directory inside the workspace. Merge
commits are skipped; an empty range checks nothing and passes. The logic lives in
`check-commits.sh`, tested by `check-commits.test.sh`.

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `from-ref` | yes | – | The base commit of the range, such as the pull request's base SHA |
| `to-ref` | yes | – | The head commit of the range, such as the pull request's head SHA |
| `working-directory` | no | `.` | The caller repository, relative to the workspace: no absolute path, no `..` component. Its .pre-commit-config.yaml defines the hook and the cache key. |
| `python-version` | no | `3.x` | The Python for setup-python, such as `3.x` or `3.13`. Its resolved version is part of the cache key, so keep it equal to the pre-commit warm-up's `python_version`. |
| `pre-commit-version` | no | `4.6.2` | The pre-commit release to install, X.Y.Z. Keep it equal to the version the warm-up and the rest of CI install. |
| `cache-key-prefix` | no | `pre-commit` | The first part of the pre-commit cache key, before `\|<runner.os>\|`. Keep it equal to the warm-up's `cache_key_prefix`. |

## Outputs

| Name | Description |
| --- | --- |
| `exitcode` | Exit code of the conventional-pre-commit validation (0 = all commits pass) |

## Permissions

`contents: read` only: nothing is posted.

## Usage

```yaml
on:
  pull_request:

jobs:
  conventional-commits:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 0
          persist-credentials: false

      - uses: leinardi/gha-pre-commit-reviewdog-actions/conventional-commits@<sha> # v2.0.0
        with:
          from-ref: ${{ github.event.pull_request.base.sha }}
          to-ref: ${{ github.event.pull_request.head.sha }}
```

Composite actions cannot set a timeout on their steps, so set `timeout-minutes` on the job. The
checkout must reach both commits (`fetch-depth: 0`). With `working-directory`, the caller
repository can be checked out to a subdirectory (`path:` on the checkout).
