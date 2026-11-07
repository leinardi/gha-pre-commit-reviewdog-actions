# AGENTS.md

## What this is

A monorepo of composite GitHub Actions, one per directory, that run the **calling** repository's
own `pre-commit` hooks on the files a pull request changed and report the result through
[reviewdog](https://github.com/reviewdog/reviewdog) (review comments and suggested fixes).
`conventional-commits` is the exception: it runs the caller's `conventional-pre-commit` hook on
every commit message of the range and fails with annotations, without reviewdog.

Callers pin `@<sha> # v2.x.y`; one repository-wide tag covers every action, and `v1` stays
available. An action runs in the caller's repository, on the caller's worktree, with the caller's
token: a defect here ships to every caller at the next release, and the worst one is an action
that changes or loses a caller's files, or passes when a hook failed.

## Common commands

```bash
make check               # pre-commit on all files (actionlint, yamllint, markdownlint, shellcheck, ruff, mypy, prettier, checkmake, license headers, …)
make test                # every */*.test.sh: lib/, the converters and the action scripts (stub pre-commit and reviewdog, real git, no network)
make check-stage         # pre-commit on the staged files only
make pre-commit-install  # installs the pre-commit and commit-msg hooks
make mk-common-update    # refresh the shared .mk snippets from leinardi/make-common@v1
```

Before calling a change done, run `make check` and `make test`. Project targets live in the local
`.mk/*.mk` files listed in the Makefile's `MK_LOCAL_FILES` (`test.mk`), never as recipes in the
Makefile.

## Layout

| Path | What lives there |
| --- | --- |
| `lib/run-passes.sh` | the pass runner every pre-commit action calls: changed files, snapshot, hooks, reports, restore and verify, reviewdog, verdict. Its header is the contract (env, `PASSES`, converters, outputs, exit status), including `VALIDATE_ONLY=true` |
| `lib/snapshot.sh` | the worktree snapshot / restore / verify library (private object store; the real index and submodule contents restored byte for byte) |
| `lib/setup-reviewdog.sh` | installs the pinned reviewdog, SHA-256-verified, under `RUNNER_TEMP` |
| `lib/rdjson.jq` | shared jq helpers for converters: `strip_ansi`, `rel_path`, `rdjson_normalize`, `json_documents`, `json_values` |
| `lib/*.test.sh` | their tests; `lib/action-passes.test.sh` checks every `action.yaml` against the shared conventions and its `PASSES` against `run-passes.sh` |
| `<action>/action.yaml` | the composite action: setup steps, then one run step (`id: run`) with a static `PASSES` literal in `env:` |
| `<action>/rdjson.jq` (+ `rdjson.test.sh`) | the converter from the hook's raw output to RDJSON (actionlint, mypy, ruff, shellcheck, sqlfluff, tofu-tflint, tofu-trivy) |
| `<action>/<name>.sh` (+ `.test.sh`) | an action's own logic: `pre-commit-hooks.sh` (builds `PASSES` from `hooks`), `sqlfluff.sh` (`run-fix`), `tofu-trivy.sh` (module token), `tofu-docs/setup-terraform-docs.sh`, `conventional-commits/check-commits.sh` |
| `<action>/README.md` | its contract: the hooks the caller declares, inputs, outputs, permissions, usage |
| `tests/self-test/` | the CI self-tests: each script generates a caller repository the action runs on |
| `scripts/run-tests.sh` | `make test`: runs every `*/*.test.sh` |
| `.github/workflows/ci.yaml` | `pre-commit-all`, the self-lint jobs (the actions on this repository's own code), `script-tests`, `validate-actions`, `self-test`, and `ci-result`, the one required check |
| `scripts/check-license-headers.sh` | the license-header check (below) |
| `.agents/skills/` | project skills; `.claude/skills` is a symlink to it |

### Generated or vendored: never hand-edit

- `.mk/help.mk`, `.mk/pre-commit.mk`, `.mk/password.mk` (the Makefile's `MK_COMMON_FILES`) and
  `scripts/bootstrap-mk-common.sh`: fetched from `leinardi/make-common`; refresh them with
  `make mk-common-update`, and port a change upstream.

## Validation matrix

Run before considering an edit done. `make check` applies to every row.

| You edited | Run |
| --- | --- |
| `lib/*.sh`, `lib/rdjson.jq` | `make test`; break the change on purpose and see a case fail. A change to `run-passes.sh`'s contract updates its header and every caller of it |
| `<action>/action.yaml` | `make test` (`lib/action-passes.test.sh` validates it); the README's inputs and outputs tables match it; the action's self-test in `ci.yaml` runs it on a real runner |
| `<action>/rdjson.jq` | `make test`; add a case with output recorded from the real tool through pre-commit |
| `<action>/*.sh` | `make test`; break the change on purpose and see a case fail |
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

- **The caller's hook is the source of truth.** An action runs the hook ids and aliases (and
  stages) its `PASSES` names, which the caller declares in `.pre-commit-config.yaml`. Changing
  a hook id, alias or stage is a breaking change: every caller's config must change with it.
- **The worktree is left as found.** Every pass is snapshot, hooks, reports, restore, verify, and
  only then reviewdog; the next pass runs only from a verified restore. Never `git stash`,
  `reset`, `clean` or `checkout`. The real index and every checked-out submodule are part of the
  snapshot: pre-commit's own `git diff` rewrites a stale index even with `GIT_OPTIONAL_LOCKS=0`
  (which every git still gets). pre-commit always gets the placeholder `--files` next to
  `--from-ref/--to-ref`: without it pre-commit stashes, and an empty `--files` falls back to the
  staged files.
- **Fail closed.** The hook status decides the lint verdict (`result=failed`); every operational
  problem (a missing hook, a report that cannot be parsed, a converter or reviewdog failure, a
  restore that cannot be verified, a bad input) is `result=error` with an `::error::` that says
  what. No `|| true` on a converter, no silent fallback, no partial report: a converter that meets
  a line it does not understand errors. reviewdog always runs with `-fail-level=none`.
- **Every pass has exactly one tree report**, and report names follow `<action>`,
  `<action> (<pass> fixes)`, `<action> (<pass> suggestions)`.
- **Backward compatible within `v2`.** No input removed, renamed or made required; no output or
  pass removed. A breaking change is `v3`.
- **Inputs reach shell through `env:` only**, never as `${{ }}` inside a `run:` body. Every `run:`
  starts with `set -euo pipefail`. `PASSES` is a static literal (pre-commit-hooks builds it from
  its validated `hooks` input).
- **Everything is pinned:** every `uses:` to a full commit SHA with a `# vX.Y.Z` comment; the
  reviewdog and terraform-docs downloads to a version and a SHA-256 per platform (bumped by hand,
  Dependabot does not track them), `--proto '=https' --retry 3`, under `RUNNER_TEMP`.
- **No token reaches a hook.** `github-token` is passed only to reviewdog (and to setup-tflint
  in tofu-tflint); `run-passes.sh` runs the hooks without it. tofu-trivy's module token goes to git
  only as step-scoped `GIT_CONFIG_*` env, masked, never into a git config file.
- **Escape what you print.** An input or hook-controlled value in a workflow command
  (`::error::...`) has `%`, CR and LF escaped (`esc` in the scripts); hook output is printed
  inside `::stop-commands::`.
- **Outputs on every path.** `result` and `ran` fall back to `error` and `false` in
  `action.yaml` when the run step never ran; the action scripts write `result=error` themselves
  when they refuse an input.
- **System tools only when missing.** `jq` (and `shellcheck` for shellcheck) are installed with
  apt only when `command -v` does not find them.
- **The pre-commit cache is restore-only.** Every action sets up Python (`python-version`),
  installs a pinned pre-commit (`pre-commit-version`) and restores
  `<cache-key-prefix>|<os>|<resolved Python>|hash(<working-directory>/.pre-commit-config.yaml)`
  with `actions/cache/restore`, falling back to the newest entry for the same OS and Python. That
  is the key `gh-reusable-workflows`' `pre-commit-warmup.yaml` saves on the default branch, its
  only writer. Change both or neither, and keep the defaults equal to the warm-up's.

## Commit messages

All commits are [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/)
**with a scope**: `<type>(<scope>)[!]: <description>`, optional blank-line body and footers.
Enforced by the `conventional-pre-commit` `commit-msg` hook (`--force-scope`) and by the
`conventional-commits` CI job, which runs this repository's own action. Types: `feat`, `fix`,
`docs`, `test`, `refactor`, `perf`, `build`, `ci`, `chore`, `style`, `revert`. Breaking changes use
`!` before `:` or a `BREAKING CHANGE:` footer. Use the action's directory as the scope for a change
to an action, `lib` for the shared library. Examples: `fix(ruff): pass the refs through env`,
`feat(sqlfluff): add a dialect input`, `fix(lib): refuse a hook id that starts with -`.

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
that changes what a caller runs (an `action.yaml`, anything under `lib/`, a converter or an action
script) and that callers should receive is `fix` (or `feat`), even when it is a performance
improvement, a refactor or a revert. Use `perf`, `refactor`, `style` and `revert` only when the
commit is deliberately not meant to trigger a release on its own. A `revert` of a shipped `feat` or
`fix` is itself a `fix`. `svu` matches `feat`/`fix` anywhere in the subject (e.g. `prefix:` counts
as `fix:`), so avoid a word ending in `feat` or `fix` directly before a colon in other subjects. A
breaking change is a new major, never a change inside `v2`. PRs land as merge commits, so every
commit counts, not just the PR title. See [CONTRIBUTING.md](CONTRIBUTING.md#releasing).

## Project skills

- `.agents/skills/adversarial-review/` — how to review a change to this repository. `.claude/skills`
  is a symlink to `.agents/skills`.
