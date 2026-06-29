# Run mypy via pre-commit + reviewdog

This GitHub Action runs [`mypy`](https://mypy-lang.org/) via [`pre-commit`](https://pre-commit.com/) on a ref range and reports diagnostics to pull
requests using [reviewdog](https://github.com/reviewdog/reviewdog), using RDJSON as the intermediate format.

It uses the `mypy-json-output` hook to produce JSON lines, then converts them to RDJSON via a jq script.

## Requirements

Add the mypy hooks to your `.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/pre-commit/mirrors-mypy
    rev: v1.19.0
    hooks:
      - id: mypy
        additional_dependencies:
          # add stubs the project needs
          - types-requests
          - types-setuptools
      - id: mypy
        alias: mypy-json-output
        name: mypy (json output)
        args:
          [
            "--output",
            "json",
            "--hide-error-context",
            "--show-column-numbers",
            "--show-absolute-path",
            "--no-pretty",
            "--ignore-missing-imports",
            "--scripts-are-modules",
          ]
        additional_dependencies:
          # add stubs the project needs
          - types-requests
          - types-setuptools
        stages: [manual]
````

You also need:

* GitHub Actions enabled on the repository
* `secrets.GITHUB_TOKEN` available (default on GitHub-hosted runners)
* A runner with `jq` available
* The jq filter file at `lib/mypy-json-to-rdjson.jq` in this action repository
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
| `exitcode` | Exit code returned by the `mypy-json-output` hook |

## Usage

Example workflow for pull requests:

```yaml
name: Type-check with mypy

on:
  pull_request:

jobs:
  mypy:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Run mypy via pre-commit + reviewdog
        uses: leinardi/gha-pre-commit-reviewdog-actions/mypy@v1
        with:
          from-ref: ${{ github.event.pull_request.base.sha }}
          to-ref: ${{ github.event.pull_request.head.sha }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

This will:

1. Run `mypy-json-output` on the files changed between `from-ref` and `to-ref`.
2. Convert the JSONL output to RDJSON using the provided jq script.
3. Report diagnostics as inline comments on the pull request via reviewdog.
4. Fail the job if type errors are found.

## Versioning

It’s recommended to pin to the major version:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/mypy@v1
```

For fully reproducible behavior, pin to an exact tag:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/mypy@v1.0.0
```
