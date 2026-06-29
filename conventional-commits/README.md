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

Add the `conventional-pre-commit` hook to your `.pre-commit-config.yaml` with `stages: [commit-msg]`:

```yaml
repos:
  - repo: https://github.com/compilerla/conventional-pre-commit
    rev: v3.6.0
    hooks:
      - id: conventional-pre-commit
        stages: [commit-msg]
        args: []  # optional: list of allowed types, e.g. [feat, fix, chore]
```

You also need `actions/checkout` fetching enough history to include both `from-ref` and `to-ref`:

```yaml
- uses: actions/checkout@v4
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
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Validate commit messages
        uses: leinardi/gha-pre-commit-reviewdog-actions/conventional-commits@v1
        with:
          from-ref: ${{ github.event.pull_request.base.sha }}
          to-ref: ${{ github.event.pull_request.head.sha }}
```

## Versioning

Pin to the major version for automatic patch/minor updates:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/conventional-commits@v1
```

For fully reproducible behavior, pin to an exact tag:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/conventional-commits@v1.0.0
```
