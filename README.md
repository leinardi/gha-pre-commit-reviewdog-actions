# gha-pre-commit-reviewdog-actions

A monorepo of GitHub Actions that run [`pre-commit`](https://pre-commit.com/) hooks on a pull-request diff range and report results as inline PR
comments using [reviewdog](https://github.com/reviewdog/reviewdog).

Each action is independently usable from any GitHub Actions workflow:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/<tool>@v1
```

---

## Available actions

| Action directory | Old standalone repo | Purpose |
| --- | --- | --- |
| [`conventional-commits`](conventional-commits/) | *(new)* | Validate PR commit messages against the [Conventional Commits](https://www.conventionalcommits.org/) spec |
| [`actionlint`](actionlint/) | `gha-pre-commit-actionlint-reviewdog` | Lint GitHub Actions workflow files with [`actionlint`](https://github.com/rhysd/actionlint) |
| [`ansible-lint`](ansible-lint/) | `gha-pre-commit-ansible-lint-reviewdog` | Lint Ansible playbooks with [`ansible-lint`](https://ansible-lint.readthedocs.io/) |
| [`pre-commit-hooks`](pre-commit-hooks/) | `gha-pre-commit-hooks-reviewdog` | Run generic [`pre-commit-hooks`](https://github.com/pre-commit/pre-commit-hooks) (whitespace, YAML, JSON, …) and post diffs |
| [`markdownlint-cli2`](markdownlint-cli2/) | `gha-pre-commit-markdownlint-cli2-reviewdog` | Lint Markdown with [`markdownlint-cli2`](https://github.com/DavidAnson/markdownlint-cli2); posts diagnostics and fix diffs |
| [`mypy`](mypy/) | `gha-pre-commit-mypy-reviewdog` | Type-check Python with [`mypy`](https://mypy-lang.org/) via RDJSON |
| [`rain-format`](rain-format/) | `gha-pre-commit-rain-format-reviewdog` | Format CloudFormation templates with [`rain`](https://github.com/aws-cloudformation/rain) |
| [`ruff`](ruff/) | `gha-pre-commit-ruff-reviewdog` | Lint & format Python with [`ruff`](https://docs.astral.sh/ruff/); posts RDJSON diagnostics and fix diffs |
| [`shellcheck`](shellcheck/) | `gha-pre-commit-shellcheck-reviewdog` | Lint shell scripts with [`shellcheck`](https://www.shellcheck.net/); posts diagnostics and fix diffs |
| [`sqlfluff`](sqlfluff/) | `gha-pre-commit-sqlfluff-reviewdog` | Lint (and optionally fix) SQL with [`sqlfluff`](https://www.sqlfluff.com/) via RDJSON |
| [`tofu-docs`](tofu-docs/) | `gha-pre-commit-tofu-docs-reviewdog` | Keep OpenTofu module docs in sync with [`terraform-docs`](https://terraform-docs.io/) |
| [`tofu-fmt`](tofu-fmt/) | `gha-pre-commit-tofu-fmt-reviewdog` | Format OpenTofu configuration with `tofu fmt` |
| [`tofu-tflint`](tofu-tflint/) | `gha-pre-commit-tofu-tflint-reviewdog` | Lint OpenTofu stacks with [`tflint`](https://github.com/terraform-linters/tflint) via RDJSON |
| [`tofu-trivy`](tofu-trivy/) | `gha-pre-commit-tofu-trivy-reviewdog` | Scan OpenTofu stacks for vulnerabilities with [`trivy`](https://github.com/aquasecurity/trivy) via RDJSON |
| [`yamllint`](yamllint/) | `gha-pre-commit-yamllint-reviewdog` | Lint YAML with [`yamllint`](https://github.com/adrienverge/yamllint) |

---

## Versioning

This monorepo uses **shared repo-wide tags**. A single tag (`v1`, `v1.2.3`, `latest`) covers all
actions simultaneously. When any action changes, a new version tag is cut that applies to all of
them.

Pin to the major version for automatic patch/minor updates:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/ruff@v1
```

Pin to an exact version for fully reproducible behavior:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/ruff@v1.2.3
```

---

## Quick-start usage

Every action requires the same three inputs:

| Input | Required | Description |
| --- | --- | --- |
| `from-ref` | ✅ | PR base SHA (`${{ github.event.pull_request.base.sha }}`) |
| `to-ref` | ✅ | PR head SHA (`${{ github.event.pull_request.head.sha }}`) |
| `github-token` | ✅ | `${{ secrets.GITHUB_TOKEN }}` |

Some actions have additional optional inputs — see their per-action README for details.

Example workflow running `ruff` on every pull request:

```yaml
name: Lint Python

on:
  pull_request:

jobs:
  ruff:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - uses: leinardi/gha-pre-commit-reviewdog-actions/ruff@v1
        with:
          from-ref: ${{ github.event.pull_request.base.sha }}
          to-ref: ${{ github.event.pull_request.head.sha }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

---

## Migrating from standalone repos

If you were using the old standalone repositories, replace `uses:` like this:

| Old | New |
| --- | --- |
| `leinardi/gha-pre-commit-actionlint-reviewdog@v1` | `leinardi/gha-pre-commit-reviewdog-actions/actionlint@v1` |
| `leinardi/gha-pre-commit-ansible-lint-reviewdog@v1` | `leinardi/gha-pre-commit-reviewdog-actions/ansible-lint@v1` |
| `leinardi/gha-pre-commit-hooks-reviewdog@v1` | `leinardi/gha-pre-commit-reviewdog-actions/pre-commit-hooks@v1` |
| `leinardi/gha-pre-commit-markdownlint-cli2-reviewdog@v1` | `leinardi/gha-pre-commit-reviewdog-actions/markdownlint-cli2@v1` |
| `leinardi/gha-pre-commit-mypy-reviewdog@v1` | `leinardi/gha-pre-commit-reviewdog-actions/mypy@v1` |
| `leinardi/gha-pre-commit-rain-format-reviewdog@v1` | `leinardi/gha-pre-commit-reviewdog-actions/rain-format@v1` |
| `leinardi/gha-pre-commit-ruff-reviewdog@v1` | `leinardi/gha-pre-commit-reviewdog-actions/ruff@v1` |
| `leinardi/gha-pre-commit-shellcheck-reviewdog@v1` | `leinardi/gha-pre-commit-reviewdog-actions/shellcheck@v1` |
| `leinardi/gha-pre-commit-sqlfluff-reviewdog@v1` | `leinardi/gha-pre-commit-reviewdog-actions/sqlfluff@v1` |
| `leinardi/gha-pre-commit-tofu-docs-reviewdog@v1` | `leinardi/gha-pre-commit-reviewdog-actions/tofu-docs@v1` |
| `leinardi/gha-pre-commit-tofu-fmt-reviewdog@v1` | `leinardi/gha-pre-commit-reviewdog-actions/tofu-fmt@v1` |
| `leinardi/gha-pre-commit-tofu-tflint-reviewdog@v1` | `leinardi/gha-pre-commit-reviewdog-actions/tofu-tflint@v1` |
| `leinardi/gha-pre-commit-tofu-trivy-reviewdog@v1` | `leinardi/gha-pre-commit-reviewdog-actions/tofu-trivy@v1` |
| `leinardi/gha-pre-commit-yamllint-reviewdog@v1` | `leinardi/gha-pre-commit-reviewdog-actions/yamllint@v1` |

> **Note:** There is no automatic redirect from the old repositories. Update your workflows
> manually. Inputs, outputs, and behavior are preserved; only the `uses:` path changes.

---

## Adding a new action

Each action follows this pattern:

```
<tool>/
├── action.yaml          # composite action
├── README.md            # inputs, outputs, pre-commit requirements, usage example
└── lib/                 # optional jq converters (e.g. <tool>-json-to-rdjson.jq)
```

1. Create `<tool>/action.yaml` as a `using: "composite"` action with `from-ref`, `to-ref`, and
   `github-token` inputs (plus any tool-specific inputs).
2. Reference `$GITHUB_ACTION_PATH/lib/...` for any jq scripts.
3. Add a `<tool>/README.md` documenting requirements, inputs/outputs, and usage.
4. Add the tool directory to the `directories` list in `.github/dependabot.yml`.
5. Add a `validate-actions` matrix entry in `.github/workflows/ci.yaml`.
6. If it's a generic linter suited for linting this repo's own code, add a self-lint job to CI.
7. Update this root README table.

---

## Repository layout

```
.
├── .github/
│   ├── dependabot.yml
│   ├── CODEOWNERS
│   ├── ISSUE_TEMPLATE/
│   ├── PULL_REQUEST_TEMPLATE.md
│   └── workflows/
│       ├── ci.yaml               # self-lint + action schema validation
│       ├── release.yaml          # manual dispatch → shared repo-wide tag
│       └── pre-commit-warmup.yaml
├── .pre-commit-config.yaml       # hooks used to lint this repo itself
├── Makefile                      # check / pre-commit-install / etc.
├── <tool>/
│   ├── action.yaml
│   ├── README.md
│   └── lib/                      # (mypy, sqlfluff, tofu-tflint, tofu-trivy only)
└── ...
```
