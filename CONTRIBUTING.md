# Contributing

## Setup

Install [`pre-commit`](https://pre-commit.com/) and [`shellcheck`](https://www.shellcheck.net/),
then install the hooks once with `make pre-commit-install`. It installs both the `pre-commit` and
the `commit-msg` hooks, so commit messages are checked when you commit.

`make check` runs the full pre-commit suite on every file, `make check-stage` on the staged files
only, and `make test` the script and converter tests (`*/*.test.sh`: stub pre-commit and
reviewdog, real git in temporary repositories, no network). Both must pass.

To add an action, follow "Adding a new action" in the [README](README.md). An action runs in other
repositories, on their worktree, with their token: read [AGENTS.md](AGENTS.md) for the invariants a
change must keep (the worktree is left as found, fail closed, inputs through `env:`, everything
pinned), and update the action's `README.md` in the same pull request. A script or converter change
comes with a test case that fails without it. CI runs every action the way a caller does, on a
generated caller repository (`tests/self-test/`), and the generic ones on this repository's own
code, from the branch, so a pull request exercises its own changes.

## Commit messages

All commits must follow [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/)
with a scope: `<type>(<scope>)[!]: <description>`. Use the action's directory as the scope. The
`conventional-pre-commit` hook enforces this on `commit-msg`, and the `conventional-commits` CI job
checks it again on every pull request.

```text
fix(ruff): pass the refs to the hook through env
feat(sqlfluff): add a dialect input
ci(deps): bump the checkout action
```

The release version is derived from these types, since the last release:

| Release | Commit | Example |
| --- | --- | --- |
| major | any type with `!` before the colon, or a `BREAKING CHANGE:` footer | `feat(mypy)!: run the mypy-rdjson alias` |
| minor | `feat` | `feat(sqlfluff): add a dialect input` |
| patch | `fix` | `fix(ruff): quote the ref range` |
| none | everything else: `build`, `chore`, `ci`, `docs`, `perf`, `refactor`, `style`, `test`, `revert` | `docs(readme): fix a link` |

Pick the type by whether callers should receive the change, not by what kind of change it is:
anything that changes what a caller runs (an `action.yaml`, `lib/`, a converter or an action
script) is a `fix` (or `feat`). A breaking change is a new major version, never a change inside
`v2`.

Pull requests are merged with merge commits; squash and rebase merging are disabled. Every commit
therefore lands on `main` as it is, so each one needs a correct type, not just the pull request as a
whole.

## Releasing

Dispatch the **Release** workflow from `main`. Leave the version empty to derive it from the
commits, or pass one; tick *dry run* first to see what it would do. It calls
[`simple-tag-and-release`](https://github.com/leinardi/gh-reusable-workflows/blob/main/.github/workflows/simple-tag-and-release.md)
from `gh-reusable-workflows`, which creates the release and moves the major tag (`v2`) and
`latest`. Callers pin a SHA, so Dependabot proposes the release to them; `v1` stays where it is.

Merging a Dependabot pull request that bumps a shipped pin (`fix(deps)`) releases the next patch on
its own, through the same workflow, when nothing else is unreleased, the change only moves existing
action pins and CI passes on the merge. With other work unreleased, it leaves a notice and the
release to you. See
[`dependabot-release`](https://github.com/leinardi/gh-reusable-workflows/blob/main/.github/workflows/dependabot-release.md).
