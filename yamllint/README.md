# Run yamllint via pre-commit + reviewdog

This GitHub Action runs [`yamllint`](https://github.com/adrienverge/yamllint) via [`pre-commit`](https://pre-commit.com/) on a ref range and reports
diagnostics to pull requests using [reviewdog](https://github.com/reviewdog/reviewdog).

It uses the `yamllint-parsable` hook to produce parseable output suitable for reviewdog.

## Requirements

Add the `yamllint` hooks to your `.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/adrienverge/yamllint
    rev: v1.37.1
    hooks:
      - id: yamllint
      - id: yamllint
        alias: yamllint-parsable
        name: "yamllint (parsable output)"
        args: ["--format", "parsable"]
        stages: [manual]
````

You also need:

* GitHub Actions enabled on the repository
* `secrets.GITHUB_TOKEN` available (default on GitHub-hosted runners)
* `actions/checkout` fetching enough history to include both `from-ref` and `to-ref`, for example:

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
| `exitcode` | Exit code from the `yamllint-parsable` pre-commit hook |

## Usage

Example workflow for pull requests:

```yaml
name: Lint YAML with yamllint

on:
  pull_request:

jobs:
  yamllint:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Run yamllint via pre-commit + reviewdog
        uses: leinardi/gha-pre-commit-reviewdog-actions/yamllint@v1
        with:
          from-ref: ${{ github.event.pull_request.base.sha }}
          to-ref: ${{ github.event.pull_request.head.sha }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

This will:

1. Run `yamllint-parsable` on YAML files changed between `from-ref` and `to-ref`.
2. Pass the parsable output to reviewdog, which annotates the pull request.
3. Fail the job if violations are found.

## Versioning

It’s recommended to pin to the major version:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/yamllint@v1
```

For fully reproducible behavior, pin to an exact tag:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/yamllint@v1.0.0
```
