# Run actionlint via pre-commit + reviewdog

This GitHub Action runs the [`actionlint-oneline`](https://github.com/rhysd/actionlint) [`pre-commit`](https://pre-commit.com/) hook on a diff range
and reports results to pull requests using [reviewdog](https://github.com/reviewdog/reviewdog).

Typical use case:

- Run `actionlint-oneline` on changed workflow files
- Annotate problems directly on the PR diff
- Fail the job if violations are found

## Requirements

Add the `actionlint` hooks to your `.pre-commit-config.yaml`, including the `actionlint-oneline` alias with the `manual` stage:

```yaml
repos:
  - repo: https://github.com/rhysd/actionlint
    rev: v1.7.8
    hooks:
      - id: actionlint
        name: actionlint
        files: ^\.github/workflows/.*\.(yml|yaml)$
        args: ["-shellcheck"]
      - id: actionlint
        alias: actionlint-oneline
        name: actionlint (one line per one error)
        files: ^\.github/workflows/.*\.(yml|yaml)$
        args: ["-oneline", "-shellcheck"]
        stages: [manual]
````

You also need:

- GitHub Actions enabled on the repository
- `secrets.GITHUB_TOKEN` available (default on GitHub-hosted runners)
- `actions/checkout` fetching enough history to include both `from-ref` and `to-ref`, for example:

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0
```

## Inputs

| Name | Required | Description |
| --- | --- | --- |
| `from-ref` | ✅ | Base git ref (e.g. PR base SHA) |
| `to-ref` | ✅ | Head git ref (e.g. PR head SHA) |
| `github-token` | ✅ | GitHub token for reviewdog (`secrets.GITHUB_TOKEN`) |

## Outputs

| Name | Description |
| --- | --- |
| `exitcode` | Exit code of the `actionlint-oneline` hook |

## Usage

Example workflow for pull requests:

```yaml
name: Lint workflows with actionlint

on:
  pull_request:

jobs:
  actionlint:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Run actionlint via pre-commit + reviewdog
        uses: leinardi/gha-pre-commit-reviewdog-actions/actionlint@v1
        with:
          from-ref: ${{ github.event.pull_request.base.sha }}
          to-ref: ${{ github.event.pull_request.head.sha }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

## Versioning

It’s recommended to pin to the major version:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/actionlint@v1
```

For fully reproducible behavior, pin to an exact tag:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/actionlint@v1.0.0
```
