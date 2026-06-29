# Run ansible-lint via pre-commit + reviewdog

This GitHub Action runs the [`ansible-lint-parseable`](https://ansible-lint.readthedocs.io/) [`pre-commit`](https://pre-commit.com/) hook on a ref
range and reports diagnostics to pull requests using [reviewdog](https://github.com/reviewdog/reviewdog).

Typical use case:

- Run `ansible-lint` on changed Ansible/YAML files
- Get one-line, parseable output
- Annotate problems directly on the PR diff
- Fail the job if violations are found

## Requirements

Add the `ansible-lint` hooks to your `.pre-commit-config.yaml`, including the `ansible-lint-parseable` alias with the `manual` stage:

```yaml
repos:
  - repo: https://github.com/ansible/ansible-lint
    rev: v25.5.0
    hooks:
      - id: ansible-lint
        alias: ansible-lint-fix
        name: ansible-lint-fix
        always_run: false
        files: \.(yml|yaml)$
        exclude: ^\.github/.*
        args: [--fix]
      - id: ansible-lint
        name: ansible-lint
        always_run: false
        files: \.(yml|yaml)$
        exclude: ^\.github/.*
      - id: ansible-lint
        alias: ansible-lint-parseable
        name: "ansible-lint (parseable output)"
        args: ["-p"]
        stages: [manual]
````

You also need:

- GitHub Actions enabled on the repository
- `secrets.GITHUB_TOKEN` available (default on GitHub-hosted runners)
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
| `exitcode` | Exit code returned by the `ansible-lint-parseable` hook |

## Usage

Example workflow for pull requests:

```yaml
name: Lint Ansible with ansible-lint

on:
  pull_request:

jobs:
  ansible-lint:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Run ansible-lint via pre-commit + reviewdog
        uses: leinardi/gha-pre-commit-reviewdog-actions/ansible-lint@v1
        with:
          from-ref: ${{ github.event.pull_request.base.sha }}
          to-ref: ${{ github.event.pull_request.head.sha }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

## Versioning

It’s recommended to pin to the major version:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/ansible-lint@v1
```

For fully reproducible behavior, pin to an exact tag:

```yaml
uses: leinardi/gha-pre-commit-reviewdog-actions/ansible-lint@v1.0.0
```
