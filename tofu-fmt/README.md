# Run OpenTofu fmt via pre-commit + reviewdog

This GitHub Action runs the `tofu_fmt` hook from [`pre-commit-opentofu`](https://github.com/tofuutils/pre-commit-opentofu) on a ref range and posts
formatting suggestions to pull requests as a diff review using [reviewdog](https://github.com/reviewdog/reviewdog).

It is meant to keep your OpenTofu configuration consistently formatted in CI, mirroring your local `pre-commit` setup.

## Requirements

Add the `tofu_fmt` hook to your `.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/tofuutils/pre-commit-opentofu
    rev: v2.2.2
    hooks:
      - id: tofu_fmt
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
| `exitcode` | Exit code returned by the `tofu_fmt` pre-commit hook |

## Usage

Example workflow for pull requests:

```yaml
name: Format OpenTofu with tofu fmt

on:
  pull_request:

jobs:
  tofu-fmt:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Run OpenTofu fmt via pre-commit + reviewdog
        uses: leinardi/gha-pre-commit-reviewdog-actions/tofu-fmt@v1
        with:
          from-ref: ${{ github.event.pull_request.base.sha }}
          to-ref: ${{ github.event.pull_request.head.sha }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

This will:

1. Run `tofu_fmt` on OpenTofu files changed between `from-ref` and `to-ref`.
2. Capture any formatting changes as a diff.
3. Post a review with suggested changes (`opentofu fmt`) via reviewdog.
4. Fail the job if formatting changes are required.

## Versioning

It’s recommended to pin to the major version:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/tofu-fmt@v1
```

For fully reproducible behavior, pin to an exact tag:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/tofu-fmt@v1.0.0
```
