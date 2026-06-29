# Run shellcheck via pre-commit + reviewdog

This GitHub Action runs `shellcheck` via [`pre-commit`](https://pre-commit.com/) on a ref range and reports:

- **Diagnostics** (JSON-based) as inline comments
- **Suggested fixes** as a diff review

using [reviewdog](https://github.com/reviewdog/reviewdog).

It combines:

- `shellcheck-json-output` (JSON output; diagnostics)
- `shellcheck-diff-output` (diff output; suggestions)

## Requirements

Add the shellcheck hooks to your `.pre-commit-config.yaml` (using a local repo), for example:

```yaml
repos:
  - repo: local
    hooks:
      - id: shellcheck
        name: shellcheck
        entry: shellcheck
        language: system
        types: [shell]
        args: ["-x"]
      - id: shellcheck
        alias: shellcheck-diff-output
        name: shellcheck (diff output)
        entry: shellcheck
        language: system
        types: [shell]
        args: ["-f", "diff", "-x"]
        stages: [manual]
      - id: shellcheck
        alias: shellcheck-json-output
        name: shellcheck (json output)
        entry: shellcheck
        language: system
        types: [shell]
        args: ["-f", "json", "-x"]
        stages: [manual]
````

You also need:

- GitHub Actions enabled on the repository
- `secrets.GITHUB_TOKEN` available (default on GitHub-hosted runners)
- A runner where `shellcheck` is available
  – on `ubuntu-latest`, this action installs `shellcheck` and `jq` via `apt`
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
| `exitcode` | Exit code of the `shellcheck-json-output` hook |

## Usage

Example workflow for pull requests:

```yaml
name: Lint shell scripts with shellcheck

on:
  pull_request:

jobs:
  shellcheck:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Run shellcheck via pre-commit + reviewdog
        uses: leinardi/gha-pre-commit-reviewdog-actions/shellcheck@v1
        with:
          from-ref: ${{ github.event.pull_request.base.sha }}
          to-ref: ${{ github.event.pull_request.head.sha }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

This will:

1. Run `shellcheck-json-output` on shell files changed between `from-ref` and `to-ref` and report diagnostics with links to the corresponding
   ShellCheck wiki pages.
2. Run `shellcheck-diff-output` to generate a diff of suggested fixes and post it as a review (`shellcheck (suggestion)`).
3. Fail the job if issues are found.

## Versioning

It’s recommended to pin to the major version:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/shellcheck@v1
```

For fully reproducible behavior, pin to an exact tag:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/shellcheck@v1.0.0
```
