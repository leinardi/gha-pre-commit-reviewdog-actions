# Security policy

## Supported versions

Only the latest release gets security fixes, and it reaches callers through the moving `v1` tag or a Dependabot bump of their
pinned SHA. Released `vX.Y.Z` tags are immutable and are never re-pointed.

## Reporting a vulnerability

Report it privately through GitHub's
[private vulnerability reporting](https://github.com/leinardi/gha-pre-commit-reviewdog-actions/security/advisories/new), not in a public
issue or pull request. Include the action, the version or SHA, and how a caller would be affected.

This is a project maintained in spare time, so reports are handled on a best-effort basis. You will get an answer in the advisory,
and the fix, once released, is credited there unless you prefer otherwise.

## Scope

In scope: the composite actions in this repository and anything they execute. An action runs with the calling repository's token,
so a way to make it act outside its documented contract (injection through an input or a file name in the diff, posting where it
should not, running unpinned code) is a vulnerability. Vulnerabilities in the linters themselves are reported upstream.

## Security model

- Inputs reach shell and JavaScript through `env:` only, never through expression interpolation inside a script.
- Every third-party action is pinned to a full commit SHA, and the reviewdog binary to an explicit version.
- The actions need `contents: read` and, for the reviewdog reporters, `pull-requests: write`; nothing else.
