# gha-pre-commit-reviewdog-actions

Composite GitHub Actions that run the **calling repository's own** [pre-commit](https://pre-commit.com/)
hooks on the files a pull request changed and post what they find, and the fixes they make, as
review comments and suggestions through [reviewdog](https://github.com/reviewdog/reviewdog). The
hooks come from the caller's `.pre-commit-config.yaml`, so CI and the local hooks always agree.
`conventional-commits` is the exception: it checks commit messages and fails with annotations,
without reviewdog.

## Actions

| Action | What it runs | Posts |
| --- | --- | --- |
| [`actionlint`](actionlint/README.md) | `actionlint-oneline` ([actionlint](https://github.com/rhysd/actionlint)) | diagnostics |
| [`ansible-lint`](ansible-lint/README.md) | `ansible-lint-parseable` ([ansible-lint](https://ansible-lint.readthedocs.io/)) | diagnostics, fixes |
| [`conventional-commits`](conventional-commits/README.md) | `conventional-pre-commit` on every commit message of the range | annotations only |
| [`markdownlint-cli2`](markdownlint-cli2/README.md) | `markdownlint-cli2` ([markdownlint-cli2](https://github.com/DavidAnson/markdownlint-cli2)) | diagnostics, fixes |
| [`mypy`](mypy/README.md) | `mypy-json-output` ([mypy](https://mypy-lang.org/)) | diagnostics |
| [`pre-commit-hooks`](pre-commit-hooks/README.md) | a list of hooks, by default the core [pre-commit-hooks](https://github.com/pre-commit/pre-commit-hooks) | fixes |
| [`ruff`](ruff/README.md) | `ruff-check-rdjson`, then `ruff-format` ([ruff](https://docs.astral.sh/ruff/)) | diagnostics, fixes |
| [`shellcheck`](shellcheck/README.md) | `shellcheck-json-output`, then `shellcheck-diff-output` ([ShellCheck](https://www.shellcheck.net/)) | diagnostics, suggestions |
| [`sqlfluff`](sqlfluff/README.md) | `sqlfluff-lint-json-output`, then `sqlfluff-fix` unless `run-fix` is `false` ([sqlfluff](https://www.sqlfluff.com/)) | diagnostics, fixes |
| [`tofu-docs`](tofu-docs/README.md) | `tofu_docs` ([terraform-docs](https://terraform-docs.io/), installed checksum-verified) | fixes |
| [`tofu-fmt`](tofu-fmt/README.md) | `tofu_fmt` (`tofu fmt`) | fixes |
| [`tofu-tflint`](tofu-tflint/README.md) | `tofu_tflint-json-output` ([TFLint](https://github.com/terraform-linters/tflint)) | diagnostics, fixes |
| [`tofu-trivy`](tofu-trivy/README.md) | `tofu_trivy-sarif-output` ([Trivy](https://github.com/aquasecurity/trivy)) | diagnostics |
| [`yamllint`](yamllint/README.md) | `yamllint-parsable` ([yamllint](https://github.com/adrienverge/yamllint)) | diagnostics |

The `tofu-*` hooks come from [pre-commit-opentofu](https://github.com/tofuutils/pre-commit-opentofu).
Each action's README lists the hook definitions it needs, its inputs and outputs.

## Usage

Pin every action by full commit SHA, with the release in a trailing comment:

```yaml
jobs:
  ruff:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 0
          persist-credentials: false

      - uses: leinardi/gha-pre-commit-reviewdog-actions/ruff@<sha> # v2.0.0
        with:
          from-ref: ${{ github.event.pull_request.base.sha }}
          to-ref: ${{ github.event.pull_request.head.sha }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

Every pre-commit action takes the same common inputs, in this order:

| Input | Default | Description |
| --- | --- | --- |
| `from-ref`, `to-ref` | required | The range: the files changed between these commits are checked |
| `github-token` | `""` | The token reviewdog posts with; required unless `reporter` is `local` |
| `working-directory` | `.` | The caller repository, relative to the workspace (a git work tree root) |
| `reporter` | `github-pr-review` | `github-pr-review` (needs `pull-requests: write`), `github-check` (needs `checks: write`) or `local` (the log only) |
| `python-version` | `3.x` | Python for `setup-python`; its resolved version is part of the cache key |
| `pre-commit-version` | `4.6.2` | The pre-commit release to install, `X.Y.Z` |
| `cache-key-prefix` | `pre-commit` | The first part of the pre-commit cache key |
| `reports-dir` | `""` | For debugging and the self-tests: an existing directory outside the caller repository that receives every report exactly as reviewdog got it, plus `reports.json` |

And the same outputs: `exitcode` (pre-commit's first nonzero exit status), `result` (`passed`,
`failed`, `skipped` or `error`), `ran` (`true` when a hook ran on files), `findings` (the number of
diagnostics and diff hunks posted) and one `<pass>-exitcode` per pass. When a setup step fails
before the hooks run (a bad `pre-commit-version`, a failed download), `result` is still `error`
and `ran` `false`, so a `continue-on-error` caller can tell; `exitcode`, `findings` and the
per-pass outputs are then empty.

Composite actions cannot set a timeout on their steps: set `timeout-minutes` on the job.

## Conventions

- **The caller's hook is the source of truth.** An action runs the hook ids and aliases the
  caller declares (usually manual-stage aliases such as `ruff-check-rdjson` or
  `mypy-json-output`), with the caller's arguments.
- **Only the changed files.** The files are the ones changed between `from-ref` and `to-ref`, as
  `pre-commit run --from-ref/--to-ref` computes them (`git diff FROM...TO`, or `FROM..TO` without a
  merge base, deletions dropped), passed with `--files`. pre-commit therefore never stashes
  unstaged changes and never rolls a hook's fixes back. With no changed file, pre-commit is not
  called and `result` is `skipped`.
- **Passes.** An action runs one or more passes. A pass snapshots the worktree, runs its hooks,
  builds its reports (the hooks' output, and the diff of what they changed), restores the
  worktree, verifies it, and only then posts. Report names: `<action>` for diagnostics,
  `<action> (<pass> fixes)` for the changes the hooks made, `<action> (<pass> suggestions)` for a
  diff a hook printed.
- **Fail closed.** The hooks decide the verdict: a failing hook is `result=failed`. Anything
  operational is `result=error`, with an `::error::` that says what: a hook id missing from the
  caller's config, a hook report that cannot be parsed, a converter failure, reviewdog failing (it
  runs with `-fail-level=none`, so a nonzero exit is a reporting failure, not a finding), bad
  inputs or refs. A converter never silently drops what it cannot read. Both fail the job.
- **The worktree is left as found.** After every pass the worktree is restored byte for byte, and
  verified, before the next pass runs: tracked files (staged or not), deletions and untracked files
  that are not ignored, including modes and symlinks; the content of every checked-out submodule,
  recursively; and the real index file, byte for byte (pre-commit's own `git diff` refreshes stale
  stat data in it, so its bytes are put back after every pass). There is no `git stash`, `reset`,
  `clean` or `checkout`, and every git runs with `GIT_OPTIONAL_LOCKS=0`. A hook that deletes,
  replaces or checks out another commit in a submodule, or leaves `index.lock` behind, stops the
  restore (see Recovery). Outside that guarantee: **ignored paths** (a hook's
  `__pycache__` stays), **empty directories**, and **nested repositories** (an untracked
  directory git lists as `dir/`), which are left out of the snapshot with a `::notice::` and never
  passed to a hook.
- **Recovery.** If a restore or its verification fails, no further hook runs, the action fails
  with `result=error`, and the snapshot is kept in
  `$RUNNER_TEMP/pre-commit-reviewdog-recovery-<action>-<suffix>` (objects, the original tree id,
  the restore plan, the paths that failed, the original index as `t0.gitindex`, and one such
  snapshot per submodule under `sub/`). The error prints the command that recovers the original
  files: `bash <dir>/recover.sh <dir> <dest>` rebuilds the exact bytes, modes and symlinks of the
  original tree in `<dest>`, submodules included, without applying `.gitattributes` (no
  `export-ignore`, `export-subst` or filters, unlike `git archive`).
- **Inputs reach shell only through `env:`**, and are validated before anything runs. Every
  `uses:` is pinned to a full commit SHA; reviewdog and terraform-docs are downloaded over HTTPS
  only, checked against pinned SHA-256s and installed under `RUNNER_TEMP`. System tools (`jq`,
  `shellcheck`) are installed with apt only when they are missing. Input values printed in an
  `::error::` are escaped, so they cannot start a workflow command of their own.
- **No token reaches a hook.** `github-token` is passed only to reviewdog (and, in tofu-tflint, to
  setup-tflint for its API calls); the hooks run without it. tofu-trivy's `gh-module-token` goes
  to git for the run step only, as environment variables, and is never written to a git config.

## Pre-commit cache

Every pre-commit action sets up Python, installs a pinned pre-commit and **restores** the
pre-commit cache; none of them saves it. The entry is written on the default branch by
[`gh-reusable-workflows`' `pre-commit-warmup.yaml`](https://github.com/leinardi/gh-reusable-workflows/blob/main/.github/workflows/pre-commit-warmup.md),
under `<cache-key-prefix>|<os>|<resolved Python>|hash(<working-directory>/.pre-commit-config.yaml)`,
with a fallback to the newest entry for the same OS and Python. Keep `python-version`,
`pre-commit-version` and `cache-key-prefix` equal to the warm-up's; the defaults already are. The
action's Python stays set up for the rest of the job.

## Versioning

The repository uses **repository-wide tags**: one release (`v2.0.0`) covers every action, and the
`v2` tag moves to the newest `v2.x.y`. Pin the SHA (Dependabot's `github-actions` ecosystem keeps
it current). `v1` (v1.1.0) stays available, unchanged, for callers that have not moved yet.

## Migrating from v1 to v2

- **rain-format is removed.**
- **pre-commit-hooks fails when a hook fails.** v1 never failed (its exit status was lost in a
  subshell).
- **`--files` instead of `--from-ref/--to-ref`.** The same files are checked, but pre-commit no
  longer stashes unstaged changes, so the hooks see the worktree as it is.
- **sqlfluff:** `run_fix` is now `run-fix`; the outputs `lint_exitcode` and `fix_exitcode` are now
  `lint-exitcode` and `fix-exitcode`.
- **Outputs are per pass:** every action has `exitcode`, `result`, `ran` and `<pass>-exitcode`
  (ruff: `check-exitcode`, `format-exitcode`; shellcheck: `lint-exitcode`, `diff-exitcode`; see
  each README).
- **reviewdog runs with `-fail-level=none`.** The hooks decide the verdict, and a reviewdog failure
  (input, API, token) now fails the action as an error instead of being ignored.
- **No report files in the workspace**, and the worktree is restored after every pass: a later
  step no longer sees the fixes an action made.
- **New inputs** `reporter`, `working-directory` and `reports-dir`, and the output `findings`;
  `github-token` is optional with `reporter: local`.
- **Every pass posts its tree changes**, so fixes made by a lint hook (ruff's `--fix`,
  markdownlint-cli2's and tflint's fixes) are now posted. Report names changed to the scheme
  above (`ruff (fixes)` is now `ruff (check fixes)` and `ruff (format fixes)`;
  `opentofu fmt` is `tofu-fmt (fmt fixes)`; `trivy` is `tofu-trivy`).
- **shellcheck** posts its diff suggestions on every run, maps `style` to info (it was an unknown
  severity), and no longer apt-installs shellcheck and jq when they are already there.
- **mypy** columns are now 1-based (v1 posted mypy's 0-based columns); **sqlfluff** paths are
  relative to the repository.
- **tofu-docs** installs terraform-docs v0.24.0 by default, verified against a pinned SHA-256
  (v0.22.0 and v0.23.0 are pinned too), on Linux X64 and ARM64.
- **No token reaches a hook.** The token is passed only to reviewdog (and to setup-tflint): v1's
  tofu-tflint exported `github-token` to its hooks as `GITHUB_TOKEN`, and v2 does not.
  **tofu-trivy** passes `gh-module-token` to git for the run step only, never in the global git
  config.
- **conventional-commits** no longer stashes unstaged changes for every commit it checks, and a
  hook without `stages: [commit-msg]` is reported as such instead of failing every message.

The "Migrating from standalone repos" section is gone from this README; v1's README still has it.

## Adding a new action

1. Create `<action>/action.yaml` with the common inputs and steps (copy an existing action), and
   one run step, `id: run`, that calls `"$GITHUB_ACTION_PATH/../lib/run-passes.sh"` with its
   `PASSES` as a static JSON literal in `env:`. `lib/run-passes.sh` documents the shape of
   `PASSES`.
2. A converter from the tool's output to RDJSON goes in `<action>/rdjson.jq` with
   `<action>/rdjson.test.sh`; any other logic in `<action>/<name>.sh` with
   `<action>/<name>.test.sh`. Every script and jq file starts with the MIT license header.
3. Write `<action>/README.md`: the hooks the caller declares, inputs and outputs matching
   `action.yaml`, permissions, usage.
4. Add the directory to `.github/dependabot.yml`, a self-test in `tests/self-test/<action>.sh`, and
   the matrix entries in `.github/workflows/ci.yaml`.
5. Add a row to the table above. `make test` checks the new `action.yaml` against the shared
   conventions and its `PASSES` against `lib/run-passes.sh`.

## Development

```bash
make check               # every pre-commit hook on every file
make test                # the script and converter tests (stub pre-commit and reviewdog, real git)
make pre-commit-install  # installs the pre-commit and commit-msg hooks
```

See [AGENTS.md](AGENTS.md) for the layout and the rules a change follows,
[CONTRIBUTING.md](CONTRIBUTING.md) for commits and releases, and [SECURITY.md](SECURITY.md) for
reporting a vulnerability.

## License

[MIT](LICENSE)
