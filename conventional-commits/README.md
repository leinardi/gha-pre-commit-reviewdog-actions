# Validate commit messages via conventional-pre-commit

This GitHub Action checks every non-merge commit in a PR diff range against the
[Conventional Commits](https://www.conventionalcommits.org/) spec using the
[`conventional-pre-commit`](https://github.com/compilerla/conventional-pre-commit)
[`pre-commit`](https://pre-commit.com/) hook.

Typical use case:

- Enforce Conventional Commits format on all PR commits
- Fail the job with `::error::` annotations identifying each offending commit SHA and subject
- Skip merge commits automatically

Unlike the other actions in this monorepo, this action does **not** use reviewdog — there are no
file-level annotations because commit messages are not tied to a specific file or line.

## Requirements

Add the `conventional-pre-commit` hook to your `.pre-commit-config.yaml` with `stages: [commit-msg]`, and install the
`commit-msg` hook type by default, so `pre-commit install` checks messages locally too:

```yaml
default_install_hook_types: [pre-commit, commit-msg]

repos:
  - repo: https://github.com/compilerla/conventional-pre-commit
    rev: v4.4.0
    hooks:
      - id: conventional-pre-commit
        stages: [commit-msg]
        args: ["--force-scope"]  # require a scope: type(scope): subject
```

The action runs **your** hook, with your arguments, so the CI check and the local `commit-msg` hook always agree. It fails with a
clear error if the hook is missing from `.pre-commit-config.yaml`.

You also need `actions/checkout` fetching enough history to include both `from-ref` and `to-ref`:

```yaml
- uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
  with:
    fetch-depth: 0
```

## Inputs

| Name | Required | Description |
| --- | --- | --- |
| `from-ref` | ✅ | Base git ref (e.g., PR base SHA) |
| `to-ref` | ✅ | Head git ref (e.g., PR head SHA) |

## Outputs

| Name | Description |
| --- | --- |
| `exitcode` | Exit code of the validation (0 = all commits pass, 1 = violations found) |

## Usage

Example workflow for pull requests:

```yaml
name: Validate commit messages

on:
  pull_request:

jobs:
  conventional-commits:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 0

      - name: Validate commit messages
        uses: leinardi/gha-pre-commit-reviewdog-actions/conventional-commits@<sha> # v1.x.y
        with:
          from-ref: ${{ github.event.pull_request.base.sha }}
          to-ref: ${{ github.event.pull_request.head.sha }}
```

Merge commits are skipped. Only commits are checked, not the pull-request title: if squash merging is enabled, the title becomes the
commit on the default branch and needs its own check.

Outside `pull_request` events (for example a CI run dispatched on a release branch opened with `GITHUB_TOKEN`, which does not
trigger `pull_request`), pass a branch range instead:

```yaml
      - name: Validate commit messages
        uses: leinardi/gha-pre-commit-reviewdog-actions/conventional-commits@<sha> # v1.x.y
        with:
          from-ref: ${{ github.event.pull_request.base.sha || format('origin/{0}', github.event.repository.default_branch) }}
          to-ref: ${{ github.event.pull_request.head.sha || github.sha }}
```

## Versioning

Pin to a commit SHA with the version in a trailing comment (Dependabot keeps it current), or to the major version for
automatic patch/minor updates:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/conventional-commits@v1
```

For fully reproducible behavior, pin to an exact tag:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/conventional-commits@v1.0.0
```
