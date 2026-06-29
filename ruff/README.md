# Run ruff via pre-commit + reviewdog

This GitHub Action runs [`ruff`](https://docs.astral.sh/ruff/) via [`pre-commit`](https://pre-commit.com/) on a ref range and reports:

- **Diagnostics** (RDJSON) as inline comments
- **Suggested fixes** (formatting / autofixes) as a diff review

using [reviewdog](https://github.com/reviewdog/reviewdog).

It combines:

- `ruff-check-rdjson` (manual, RDJSON output, `--fix`)
- `ruff-format` (formatting)

## Requirements

Add the `ruff-pre-commit` hooks to your `.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.14.7
    hooks:
      - id: ruff-check
        args: ["--fix"]
      - id: ruff-format
      - id: ruff-check
        alias: ruff-check-rdjson
        args: ["--fix", "-q", "--output-format=rdjson"]
        stages: [manual]
````

You also need:

- GitHub Actions enabled on the repository
- `secrets.GITHUB_TOKEN` available (default on GitHub-hosted runners)
- `jq` installed on the runner (already present on `ubuntu-latest`)
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
| `exitcode` | Combined exit code of `ruff-check-rdjson` and `ruff-format` |

## Usage

Example workflow for pull requests:

```yaml
name: Lint Python with ruff

on:
  pull_request:

jobs:
  ruff:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Run ruff via pre-commit + reviewdog
        uses: leinardi/gha-pre-commit-reviewdog-actions/ruff@v1
        with:
          from-ref: ${{ github.event.pull_request.base.sha }}
          to-ref: ${{ github.event.pull_request.head.sha }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

This will:

1. Run `ruff-check-rdjson` on files changed between `from-ref` and `to-ref`, capture RDJSON, normalize paths, strip suggestions, and report
   diagnostics via reviewdog.
2. Run `ruff-format` on the same range.
3. Generate a diff of fixes and post it as a review (`ruff (fixes)`).
4. Fail the job if either step reports issues.

## Versioning

It’s recommended to pin to the major version:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/ruff@v1
```

For fully reproducible behavior, pin to an exact tag:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/ruff@v1.0.0
```
