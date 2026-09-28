# AGENTS.md

## What this is

A monorepo of composite GitHub Actions, one per directory, that run a `pre-commit` hook of the **calling** repository on a
pull request's diff range and report the result through [reviewdog](https://github.com/reviewdog/reviewdog) (review comments and
suggested fixes). `conventional-commits` is the exception: it runs the caller's `conventional-pre-commit` hook on every commit of
the range and fails with annotations, without reviewdog.

Callers pin `@<sha> # v1.x.y` or the moving `@v1`, and a single repo-wide tag covers every action. An action runs in the caller's
repository with the caller's token: a defect here ships to every caller at the next release.

## Common commands

```bash
make check               # pre-commit on all files (actionlint, yamllint, markdownlint, shellcheck, ruff, mypy, prettier, checkmake, …)
make check-stage         # pre-commit on the staged files only
make pre-commit-install  # installs the pre-commit and commit-msg hooks
make mk-common-update    # refresh the shared .mk snippets from leinardi/make-common@v1
```

## Layout

| Path | What lives there |
| --- | --- |
| `<tool>/action.yaml` | the composite action |
| `<tool>/README.md` | its contract: the pre-commit hook it needs in the caller, inputs, outputs, usage |
| `<tool>/lib/*.jq` | converters from the tool's output to reviewdog's RDJSON (mypy, sqlfluff, tofu-tflint, tofu-trivy) |
| `.github/workflows/ci.yaml` | self-lint: the local actions run on this repository's own code, plus a schema check of every action |

`README.md` "Adding a new action" lists every place a new action must be registered.

## Invariants

- **The caller's hook is the source of truth.** An action runs a manual-stage alias (`<hook>-rdjson`, `-json-output`, `-oneline`,
  `-parsable`, …) that the caller declares in its `.pre-commit-config.yaml`, so the CI result and the local hook always agree.
  Changing which alias an action runs is a breaking change: every caller's config must change with it.
- **Backward compatible within `v1`.** No input removed, renamed or made required; no output removed. A breaking change is `v2`.
- **Inputs reach shell through `env:` only**, never as `${{ inputs.* }}` inside a `run:` body.
- **Everything is pinned:** every `uses:` to a full commit SHA with a `# vX.Y.Z` comment; the reviewdog binary to an explicit
  version (bumped by hand, Dependabot does not track it).
- **Each action both reports and fails.** The reviewdog actions comment on the pull request and fail the job at their
  `-fail-level` (`info` for most, `error` for a few); `conventional-commits` checks every commit and exits non-zero if any of them
  fails. Whether a failing job blocks the merge is decided by the caller's required checks, not here.
- The pre-commit cache key is `pre-commit|<os>|hash(.pre-commit-config.yaml)`, the same key `gh-reusable-workflows`'
  `pre-commit-warmup.yaml` fills. Change both or neither.

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) with a mandatory scope, enforced by the
`conventional-pre-commit` `commit-msg` hook (`--force-scope`) and by the `conventional-commits` CI job, which runs this
repository's own action. The release version is derived from them: a change callers should receive is a `fix` or a `feat`; use
the action's directory as the scope. Examples: `fix(ruff): pass the refs through env`, `feat(sqlfluff): add a dialect input`.

## Project skills

- `.agents/skills/adversarial-review/` — how to review a change to this repository. `.claude/skills` is a symlink to
  `.agents/skills`.
