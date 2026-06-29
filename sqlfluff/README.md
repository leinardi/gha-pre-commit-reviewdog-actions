# Run sqlfluff lint/fix via pre-commit + reviewdog

This GitHub Action runs [`sqlfluff`](https://www.sqlfluff.com/) via [`pre-commit`](https://pre-commit.com/) on a ref range and reports:

- **Lint diagnostics** (JSON → RDJSON) as inline comments
- **Optional fix suggestions** (diff of `sqlfluff-fix`) as a review

using [reviewdog](https://github.com/reviewdog/reviewdog).

It uses:

- `sqlfluff-lint-json-output` for parseable JSON output
- `sqlfluff-fix` for autofixes (optional, controlled by `run_fix` input)

## Requirements

Add the sqlfluff hooks to your `.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/sqlfluff/sqlfluff
    rev: 3.5.0
    hooks:
      - id: sqlfluff-lint
        alias: sqlfluff-lint-only
        stages: [manual]
      - id: sqlfluff-lint
        alias: sqlfluff-lint-json-output
        name: sqlfluff-lint (json output)
        args: ["--format", "json"]
        stages: [manual]
      - id: sqlfluff-fix
````

You also need:

- GitHub Actions enabled on the repository
- `secrets.GITHUB_TOKEN` available (default on GitHub-hosted runners)
- A runner with `jq` available
  – on `ubuntu-latest`, this action installs `jq` via `apt`
- The jq filter file at `lib/sqlfluff-json-to-rdjson.jq` in this action repository
- `actions/checkout` fetching enough history to include both `from-ref` and `to-ref`, for example:

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
| `run_fix` | ❌ | `true` | Whether to also run `sqlfluff-fix` and comment the resulting diff (`true`/`false`) |

## Outputs

| Name | Description |
| --- | --- |
| `lint_exitcode` | Exit code from the `sqlfluff-lint-json-output` hook |
| `fix_exitcode` | Exit code from `sqlfluff-fix` (if `run_fix` is `true`) |

## Usage

Example workflow for pull requests:

```yaml
name: Lint SQL with sqlfluff

on:
  pull_request:

jobs:
  sqlfluff:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Run sqlfluff lint/fix via pre-commit + reviewdog
        uses: leinardi/gha-pre-commit-reviewdog-actions/sqlfluff@v1
        with:
          from-ref: ${{ github.event.pull_request.base.sha }}
          to-ref: ${{ github.event.pull_request.head.sha }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
          # Optional:
          # run_fix: "false"
```

This will:

1. Run `sqlfluff-lint-json-output` on SQL files changed between `from-ref` and `to-ref`.
2. Convert the JSON output to RDJSON via the jq script and report diagnostics via reviewdog.
3. If `run_fix` is `true`, run `sqlfluff-fix` on the same range and post the resulting diff as a review (`sqlfluff-fix`).
4. Fail the job if either lint or fix reports issues.

## Versioning

It’s recommended to pin to the major version:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/sqlfluff@v1
```

For fully reproducible behavior, pin to an exact tag:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/sqlfluff@v1.0.0
```
