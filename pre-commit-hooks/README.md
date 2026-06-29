# Run pre-commit hooks + reviewdog diff

This GitHub Action runs one or more [`pre-commit`](https://pre-commit.com/) hooks on a ref range and, if any of them fail or modify files, posts the
resulting diff to the pull request as a review using [reviewdog](https://github.com/reviewdog/reviewdog).

It’s designed as a lightweight “core hygiene” action for things like whitespace, merge conflicts, config checks, and large file detection.

## Default hooks

By default, this action expects the following hooks to be configured in your `.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v6.0.0
    hooks:
      - id: check-merge-conflict
      - id: end-of-file-fixer
      - id: trailing-whitespace
      - id: check-yaml
      - id: check-json
      - id: check-toml
      - id: check-added-large-files
````

If you don’t override the `hooks` input, these hook IDs will be used.

## Requirements

You need:

* GitHub Actions enabled on the repository
* `secrets.GITHUB_TOKEN` available (default on GitHub-hosted runners)
* `actions/checkout` fetching enough history to include both `from-ref` and `to-ref`, for example:

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0
```

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `from-ref` | ✅ | – | Base git ref (e.g. PR base SHA) |
| `to-ref` | ✅ | – | Head git ref (e.g. PR head SHA) |
| `github-token` | ✅ | – | GitHub token for reviewdog (`secrets.GITHUB_TOKEN`) |
| `hooks` | ❌ | The default list of core hooks shown above (newline-separated hook IDs) | Newline-separated list of pre-commit hook IDs to run. Empty lines and `#` comments are ignored. |

### Customizing the hooks

You can override the default list and provide your own set of hooks:

```yaml
      - name: Run pre-commit hooks + reviewdog diff
        uses: leinardi/gha-pre-commit-reviewdog-actions/pre-commit-hooks@v1
        with:
          from-ref: ${{ github.event.pull_request.base.sha }}
          to-ref: ${{ github.event.pull_request.head.sha }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
          hooks: |
            check-merge-conflict
            end-of-file-fixer
            trailing-whitespace
            check-yaml
            check-json
            # Custom extra hook:
            detect-private-key
```

The action will:

* Run each listed hook ID via `pre-commit run <hook>` on the diff between `from-ref` and `to-ref`.

## Outputs

| Name | Description |
| --- | --- |
| `exitcode` | `1` if any hook failed or modified files, `0` otherwise |

## Usage

Basic example for pull requests using the **default** hook list:

```yaml
name: pre-commit hooks

on:
  pull_request:

jobs:
  pre-commit-hooks:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Run pre-commit hooks + reviewdog diff
        uses: leinardi/gha-pre-commit-reviewdog-actions/pre-commit-hooks@v1
        with:
          from-ref: ${{ github.event.pull_request.base.sha }}
          to-ref: ${{ github.event.pull_request.head.sha }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

This will:

1. Run all configured hooks on files changed between `from-ref` and `to-ref`.
2. If any hook fails or fixes files, capture the resulting `git diff`.
3. Post the diff as a review (`pre-commit (fixes)`) via reviewdog.
4. Fail the job if any hooks reported issues or made changes.

## Versioning

It’s recommended to pin to the major version:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/pre-commit-hooks@v1
```

For fully reproducible behavior, pin to an exact tag:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/pre-commit-hooks@v1.0.0
```
