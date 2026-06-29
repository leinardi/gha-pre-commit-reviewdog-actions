# Run Trivy (SARIF) for OpenTofu via pre-commit + reviewdog

This GitHub Action runs `tofu_trivy` from [`pre-commit-opentofu`](https://github.com/tofuutils/pre-commit-opentofu) in SARIF mode on a ref range and:

- Extracts and merges SARIF blobs from the Trivy output
- Converts the result to RDJSON via a jq script
- Reports diagnostics to pull requests using [reviewdog](https://github.com/reviewdog/reviewdog)

It can optionally use a GitHub App token to authenticate private module checkouts.

## Requirements

Add the Trivy hooks to your `.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/tofuutils/pre-commit-opentofu
    rev: v2.2.2
    hooks:
      - id: tofu_trivy
      - id: tofu_trivy
        alias: tofu_trivy-sarif-output
        name: tofu_trivy (sarif output)
        args: ["--args=--format sarif"]
        stages: [manual]
````

You also need:

- GitHub Actions enabled on the repository
- `secrets.GITHUB_TOKEN` available (default on GitHub-hosted runners)
- Trivy installed (this action uses `aquasecurity/setup-trivy`)
- `jq` available on the runner
- The jq filter file at `lib/trivy-sarif-to-rdjson.jq` in this action repository
- `actions/checkout` fetching enough history to include both `from-ref` and `to-ref`, for example:

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0
```

If you scan modules from private GitHub repositories, you may also provide a GitHub App token via `gh-module-token` to allow Trivy/OpenTofu to fetch
those modules.

## Inputs

| Name | Required | Description |
| --- | --- | --- |
| `from-ref` | ✅ | Base git ref (e.g. PR base SHA) |
| `to-ref` | ✅ | Head git ref (e.g. PR head SHA) |
| `github-token` | ✅ | GitHub token for reviewdog (`secrets.GITHUB_TOKEN`) |
| `gh-module-token` | ❌ | GitHub App token used to rewrite Git URLs for private module checkouts (HTTPS with token) |

## Outputs

| Name | Description |
| --- | --- |
| `exitcode` | Exit code returned by the `tofu_trivy-sarif-output` hook |

## Usage

Example workflow for pull requests:

```yaml
name: Scan OpenTofu with Trivy

on:
  pull_request:

jobs:
  tofu-trivy:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Run Trivy (SARIF) for OpenTofu via pre-commit + reviewdog
        uses: leinardi/gha-pre-commit-reviewdog-actions/tofu-trivy@v1
        with:
          from-ref: ${{ github.event.pull_request.base.sha }}
          to-ref: ${{ github.event.pull_request.head.sha }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
          # Optional, if you need private module access:
          # gh-module-token: ${{ secrets.GH_APP_MODULE_TOKEN }}
```

This will:

1. Run `tofu_trivy-sarif-output` on files changed between `from-ref` and `to-ref`.
2. Strip ANSI sequences and extract SARIF JSON objects from the Trivy output.
3. Merge all SARIF documents and convert them to RDJSON using `lib/trivy-sarif-to-rdjson.jq`.
4. Post Trivy findings as inline comments on the pull request via reviewdog.
5. Fail the job if vulnerabilities or misconfigurations are reported.

## Versioning

It’s recommended to pin to the major version:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/tofu-trivy@v1
```

For fully reproducible behavior, pin to an exact tag:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/tofu-trivy@v1.0.0
```
