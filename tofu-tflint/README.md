# Run OpenTofu tflint (JSON) via pre-commit + reviewdog

This GitHub Action runs `tofu_tflint` from [`pre-commit-opentofu`](https://github.com/tofuutils/pre-commit-opentofu) in JSON mode on a ref range and:

- Converts the TFLint JSON output to RDJSON via a jq script
- Posts diagnostics as inline comments
- Posts autofix diffs as a separate review

using [reviewdog](https://github.com/reviewdog/reviewdog).

It is intended to lint your OpenTofu stacks with TFLint in CI, reusing your local `pre-commit` configuration.

## Requirements

Add the `tofu_tflint-json-output` hook to your `.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/tofuutils/pre-commit-opentofu
    rev: v2.2.2
    hooks:
      - id: tofu_tflint
        alias: tofu_tflint-json-output
        name: tofu_tflint (json output)
        args: ["--args=--format=json", "--args=--fix"]
        stages: [manual]
````

You also need:

- GitHub Actions enabled on the repository
- `secrets.GITHUB_TOKEN` available (default on GitHub-hosted runners)
- A runner where `jq` is available
- The jq filter file at `lib/tflint-json-to-rdjson.jq` in this action repository
- Network access to download and install TFLint via `terraform-linters/setup-tflint`
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
| `exitcode` | Exit code returned by the `tofu_tflint-json-output` hook |

## Usage

Example workflow for pull requests:

```yaml
name: Lint OpenTofu stacks with tflint

on:
  pull_request:

jobs:
  tofu-tflint:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Run OpenTofu tflint (JSON) via pre-commit + reviewdog
        uses: leinardi/gha-pre-commit-reviewdog-actions/tofu-tflint@v1
        with:
          from-ref: ${{ github.event.pull_request.base.sha }}
          to-ref: ${{ github.event.pull_request.head.sha }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

This will:

1. Run `tofu_tflint-json-output` on OpenTofu stacks changed between `from-ref` and `to-ref`.
2. Strip ANSI sequences and reconstruct per-stack JSON lines.
3. Convert the JSONL output to RDJSON via `lib/tflint-json-to-rdjson.jq`.
4. Post diagnostics (`opentofu tflint`) as inline comments via reviewdog.
5. Post autofix diffs (`opentofu tflint (fixes)`) as a review based on `git diff`.
6. Fail the job if TFLint reports issues.

## Versioning

It’s recommended to pin to the major version:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/tofu-tflint@v1
```

For fully reproducible behavior, pin to an exact tag:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/tofu-tflint@v1.0.0
```
