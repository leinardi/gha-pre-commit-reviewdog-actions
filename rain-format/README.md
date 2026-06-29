# Run rain format via pre-commit + reviewdog

This GitHub Action runs the `rain-format` hook from [`rain`](https://github.com/aws-cloudformation/rain) via [`pre-commit`](https://pre-commit.com/)
on a ref range and posts formatting suggestions to pull requests as a diff review using [reviewdog](https://github.com/reviewdog/reviewdog).

It is intended to keep your CloudFormation YAML consistently formatted in CI, mirroring your local `pre-commit` setup.

## Requirements

Add the `rain` hooks to your `.pre-commit-config.yaml`, for example:

```yaml
repos:
  - repo: https://github.com/aws-cloudformation/rain
    rev: v1.24.1
    hooks:
      - id: rain-format
        files: ^(stacks|modules)/.*\.(yml|yaml)$
        args: ["fmt", "-w", "--node-style", "strict-booleans"]
        require_serial: true
      - id: rain-verify
        args: ["fmt", "-v", "--node-style", "strict-booleans"]
        require_serial: true
        stages: [manual]
````

> **Note:** This action uses only the `rain-format` hook. You can still run `rain-verify` locally or in a separate job if you want verification
> without writes.

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
| `exitcode` | Exit code returned by the `rain-format` hook |

## Usage

Example workflow for pull requests:

```yaml
name: Format CloudFormation with rain

on:
  pull_request:

jobs:
  rain-format:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Run rain format via pre-commit + reviewdog
        uses: leinardi/gha-pre-commit-reviewdog-actions/rain-format@v1
        with:
          from-ref: ${{ github.event.pull_request.base.sha }}
          to-ref: ${{ github.event.pull_request.head.sha }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

This will:

1. Run `rain-format` on CloudFormation templates changed between `from-ref` and `to-ref`.
2. Capture any formatting changes as a diff.
3. Post a review with suggested changes (`rain`) via reviewdog.
4. Fail the job if formatting changes are required.

## Versioning

It’s recommended to pin to the major version:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/rain-format@v1
```

For fully reproducible behavior, pin to an exact tag:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/rain-format@v1.0.0
```
