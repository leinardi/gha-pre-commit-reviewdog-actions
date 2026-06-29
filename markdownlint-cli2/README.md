# Run markdownlint-cli2 via pre-commit + reviewdog

This GitHub Action runs the [`markdownlint-cli2`](https://github.com/DavidAnson/markdownlint-cli2) [`pre-commit`](https://pre-commit.com/) hook on a
ref range and reports:

- Suggested fixes (as a diff review)
- Diagnostics (inline comments on the PR)

via [reviewdog](https://github.com/reviewdog/reviewdog).

## Requirements

Add the `markdownlint-cli2` hook to your `.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/DavidAnson/markdownlint-cli2
    rev: v0.19.1
    hooks:
      - id: markdownlint-cli2
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
| `exitcode` | Exit code returned by the `markdownlint-cli2` hook |

## Usage

Example workflow for pull requests:

```yaml
name: Lint Markdown with markdownlint-cli2

on:
  pull_request:

jobs:
  markdownlint:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Run markdownlint-cli2 via pre-commit + reviewdog
        uses: leinardi/gha-pre-commit-reviewdog-actions/markdownlint-cli2@v1
        with:
          from-ref: ${{ github.event.pull_request.base.sha }}
          to-ref: ${{ github.event.pull_request.head.sha }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

This will:

1. Run `markdownlint-cli2` on files changed between `from-ref` and `to-ref`.
2. Post a review with suggested fixes (based on the generated diff).
3. Post another review with inline diagnostics.
4. Fail the job if violations are found.

## Versioning

It’s recommended to pin to the major version:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/markdownlint-cli2@v1
```

For fully reproducible behavior, pin to an exact tag:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/markdownlint-cli2@v1.0.0
```
