# AGENTS.md

## What this is

A monorepo of composite GitHub Actions, one per directory, that run a `pre-commit` hook of
the **calling** repository on a pull request's diff range and report the result through
[reviewdog](https://github.com/reviewdog/reviewdog) (review comments and suggested fixes).
`conventional-commits` is the exception: it runs the caller's `conventional-pre-commit` hook on
every commit of the range and fails with annotations, without reviewdog.

Callers pin `@<sha> # v1.x.y` or the moving `@v1`, and a single repo-wide tag covers every action.
An action runs in the caller's repository with the caller's token: a defect here ships to every
caller at the next release.

## Common commands

```bash
make check               # pre-commit on all files (actionlint, yamllint, markdownlint, shellcheck, ruff, mypy, prettier, checkmake, license headers, …)
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
| `.github/workflows/ci.yaml` | `pre-commit-all` (every hook on every file), self-lint (the local actions run on this repository's own code on a pull request), a schema check of every action, and `ci-result`, the one required check, which needs every job |
| `scripts/check-license-headers.sh` | the license-header check (below) |

`README.md` "Adding a new action" lists every place a new action must be registered; a new CI job
is also added to `ci-result`'s `needs`.

### Generated or vendored: never hand-edit

- `.mk/help.mk`, `.mk/pre-commit.mk`, `.mk/password.mk` (the Makefile's `MK_COMMON_FILES`) and
  `scripts/bootstrap-mk-common.sh`: fetched from `leinardi/make-common`; refresh them with
  `make mk-common-update`, and port a change upstream.

## Validation matrix

Run before considering an edit done. `make check` applies to every row; CI's `pre-commit-all`
runs the same hooks on every file.

| You edited | Run |
| --- | --- |
| `<tool>/action.yaml` | `make check`; the action's self-lint job in `ci.yaml` runs it from the branch on the pull request (an action without one is only schema-checked by `validate-actions`) |
| `<tool>/lib/*.jq` | `make check`; feed the filter a sample of the tool's output with `jq -s -f` (or `jq -r -f` for sqlfluff) and compare the RDJSON |
| `conventional-commits/` | also run its step script against a throwaway repository with good, bad and merge commits |
| `.github/workflows/**` | `pre-commit run actionlint --all-files`; a new job is added to `ci-result`'s `needs` |
| `.pre-commit-config.yaml`, `Makefile`, `.mk/**` | `make check`, `make help` |
| `scripts/check-license-headers.sh` | `scripts/check-license-headers.sh`, then once with a header removed from a governed file: it must fail and name it |
| `**/*.md`, `.agents/skills/**` | `make check` (markdownlint: prose wraps at 100 columns; tables, code and headings may run longer) |

## License headers

Every shell, Python and jq source, the Makefile and the repo-local `.mk` fragments start with the
MIT header (see any `lib/*.jq`), with the year of the file's first commit.
`scripts/check-license-headers.sh`, run by the `check-license-headers` pre-commit hook on every
commit and by CI's `pre-commit-all`, fails on a tracked file that lacks it. YAML, JSON and
Markdown are never governed; the make-common files above are exempt.

## Invariants

- **The caller's hook is the source of truth.** An action runs a manual-stage alias
  (`<hook>-rdjson`, `-json-output`, `-oneline`, `-parsable`, …) that the caller declares in its
  `.pre-commit-config.yaml`, so the CI result and the local hook always agree. Changing which alias
  an action runs is a breaking change: every caller's config must change with it.
- **Backward compatible within `v1`.** No input removed, renamed or made required; no output
  removed. A breaking change is `v2`.
- **Inputs reach shell through `env:` only**, never as `${{ inputs.* }}` inside a `run:` body.
- **Everything is pinned:** every `uses:` to a full commit SHA with a `# vX.Y.Z` comment; the
  reviewdog binary to an explicit version (bumped by hand, Dependabot does not track it).
- **Each action both reports and fails.** The reviewdog actions comment on the pull request and fail
  the job at their `-fail-level` (`info` for most, `error` for a few); `conventional-commits` checks
  every commit and exits non-zero if any of them fails. Whether a failing job blocks the merge is
  decided by the caller's required checks, not here.
- The pre-commit cache key is `pre-commit|<os>|hash(.pre-commit-config.yaml)`, the same key
  `gh-reusable-workflows`' `pre-commit-warmup.yaml` fills. Change both or neither.

## Commit messages

All commits are [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/)
**with a scope**: `<type>(<scope>)[!]: <description>`, optional blank-line body and footers.
Enforced by the `conventional-pre-commit` `commit-msg` hook (`--force-scope`) and by the
`conventional-commits` CI job, which runs this repository's own action. Types: `feat`, `fix`,
`docs`, `test`, `refactor`, `perf`, `build`, `ci`, `chore`, `style`, `revert`. Breaking changes use
`!` before `:` or a `BREAKING CHANGE:` footer. Use the action's directory as the scope for a change
to an action. Examples: `fix(ruff): pass the refs through env`,
`feat(sqlfluff): add a dialect input`, `ci(ci): pin the checkout action`.

Release versions are derived by `svu` from the commits since the last tag, so a wrong type ships a
wrong version:

| Release | Commit | Example |
| --- | --- | --- |
| major | any type with `!` before the colon, or a `BREAKING CHANGE:` footer | `feat(mypy)!: run the mypy-rdjson alias` |
| minor | `feat` | `feat(sqlfluff): add a dialect input` |
| patch | `fix` | `fix(ruff): quote the ref range` |
| none | everything else: `perf`, `refactor`, `build`, `ci`, `chore`, `docs`, `style`, `test`, `revert` | `docs(readme): fix a link` |

The highest bump among the commits wins; with only "none" commits since the last tag, a release
with no version fails with "nothing to bump".

**Pick the type by whether the change should ship, not by what kind of change it is.** Anything
that changes what a caller runs (an `action.yaml`, a `lib/*.jq` filter) and that callers should
receive is `fix` (or `feat`), even when it is a performance improvement, a refactor or a revert.
Use `perf`, `refactor`, `style` and `revert` only when the commit is deliberately not meant to
trigger a release on its own. A `revert` of a shipped `feat` or `fix` is itself a `fix`. `svu`
matches `feat`/`fix` anywhere in the subject (e.g. `prefix:` counts as `fix:`), so avoid a word
ending in `feat` or `fix` directly before a colon in other subjects. A breaking change is a new
`v2`, never a change inside `v1`. PRs land as merge commits, so every commit counts, not just the
PR title. See [CONTRIBUTING.md](CONTRIBUTING.md#releasing).

## Project skills

- `.agents/skills/adversarial-review/` — how to review a change to this repository. `.claude/skills`
  is a symlink to `.agents/skills`.
