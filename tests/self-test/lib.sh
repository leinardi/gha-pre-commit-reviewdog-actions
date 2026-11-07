#!/usr/bin/env bash
#
# MIT License
#
# Copyright (c) 2026 Roberto Leinardi
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# Helpers for the self-test caller generators (tests/self-test/<action>.sh), sourced by each.
# A generator builds a throwaway caller repository the CI self-test runs an action on:
#
#   st_init "$@"            parses MODE [DIR], creates DIR as an empty git repository on main
#   st_write PATH           writes stdin to PATH in the caller (parents created)
#   st_rev URL              the rev this repository's own .pre-commit-config.yaml pins URL to,
#                           so a caller hook is always the release this repository runs itself
#   st_commit MSG           stages everything and commits it
#   st_commit_base MSG      the same, and records the commit as the from-ref
#   st_finish EXPECTED HOOK STAGE
#                           adds the nested checkout (mode nested), settles the index and writes
#                           the outputs
#
# MODE is one of:
#   bad     the head commit adds a change the action's hooks must fail on
#   clean   the head commit adds a change the hooks run on and pass
#   none    the head commit changes nothing the hooks look at: the action must report skipped
#   nested  clean, plus an untracked nested checkout inside the caller (holding files the hooks
#           would fail on) that the action must leave out with a notice, not fail on
#
# DIR defaults to $CALLER_DIR, else $GITHUB_WORKSPACE/caller, else ./caller. It must not exist or
# be empty.
#
# Outputs (appended to $GITHUB_OUTPUT when set, always printed): from-ref, to-ref, mode,
# expected-finding (mode bad only: text the posted reports must carry, as an RDJSON diagnostic's
# message or rule code or as text in an efm or diff report; the hook's own output or fixes carry
# it too),
# check-hook and check-stage (the hook and stage that produce that finding).
#
# Bad content lives only in the generators' heredocs and printf calls: nothing malformed is ever
# committed to this repository.

set -euo pipefail

ST_SELF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
ST_MODE=""
ST_DIR=""
ST_FROM=""

# Deterministic git for the generated repositories: no system or global config (a developer's
# hooksPath, signing, autocrlf or templates), a fixed identity.
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME="Self Test" GIT_AUTHOR_EMAIL="self-test@example.invalid"
export GIT_COMMITTER_NAME="Self Test" GIT_COMMITTER_EMAIL="self-test@example.invalid"

st_die() {
	echo "::error::self-test generator $(basename "$0"): $*" >&2
	exit 1
}

st_init() {
	[[ $# -ge 1 && $# -le 2 ]] || st_die "usage: $(basename "$0") bad|clean|none|nested [DIR]"
	ST_MODE="$1"
	case "${ST_MODE}" in
	bad | clean | none | nested) ;;
	*) st_die "mode '${ST_MODE}' is not bad, clean, none or nested" ;;
	esac
	ST_DIR="${2:-${CALLER_DIR:-${GITHUB_WORKSPACE:-${PWD}}/caller}}"
	if [[ -e "${ST_DIR}" ]]; then
		[[ -d "${ST_DIR}" && -z "$(ls -A -- "${ST_DIR}")" ]] || st_die "${ST_DIR} exists and is not an empty directory"
	fi
	mkdir -p -- "${ST_DIR}"
	ST_DIR="$(cd "${ST_DIR}" && pwd -P)"
	git -C "${ST_DIR}" init -q -b main
	# The caches some hooks leave in the caller are ignored, as a real repository ignores them:
	# the action's guarantee covers what git reports, and ignored paths are outside it.
	st_write .gitignore <<'EOF'
.ansible/
.mypy_cache/
.ruff_cache/
.terraform/
__pycache__/
EOF
}

st_write() {
	local path="$1"
	[[ "${path}" != /* && "/${path}/" != */../* ]] || st_die "st_write: ${path} is not inside the caller"
	mkdir -p -- "$(dirname -- "${ST_DIR}/${path}")"
	cat >"${ST_DIR}/${path}"
}

st_rev() {
	local url="$1" rev
	rev="$(awk -v url="${url}" '
		$1 == "-" && $2 == "repo:" { found = ($3 == url); next }
		found && $1 == "rev:" { print $2; exit }
	' "${ST_SELF_ROOT}/.pre-commit-config.yaml")"
	[[ -n "${rev}" ]] || st_die "${url} is not pinned in ${ST_SELF_ROOT}/.pre-commit-config.yaml"
	printf '%s' "${rev}"
}

st_commit() {
	git -C "${ST_DIR}" add -A
	git -C "${ST_DIR}" commit -q --no-verify --allow-empty -m "$1"
}

st_commit_base() {
	st_commit "$1"
	ST_FROM="$(git -C "${ST_DIR}" rev-parse HEAD)"
}

# An untracked checkout of another repository inside the caller, which git lists as one
# directory entry (vendor/nested-checkout/). Its files would fail most hooks (trailing whitespace,
# no final newline), so a hook that was given one would change it, and the manifest would show it.
st_nested() {
	local nested="${ST_DIR}/vendor/nested-checkout"
	mkdir -p -- "${nested}"
	git -C "${nested}" init -q -b main
	printf 'committed with trailing whitespace   \nand no final newline' >"${nested}/notes.txt"
	git -C "${nested}" add -A
	git -C "${nested}" commit -q --no-verify -m "chore(nested): add a file"
	printf 'an uncommitted change   \n' >>"${nested}/notes.txt"
}

st_output() {
	local key="$1" value="$2"
	[[ "${value}" != *$'\n'* ]] || st_die "output ${key} has a newline"
	echo "${key}=${value}"
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		echo "${key}=${value}" >>"${GITHUB_OUTPUT}"
	fi
}

st_finish() {
	local expected="$1" hook="$2" stage="$3" to
	[[ -n "${ST_FROM}" ]] || st_die "st_commit_base was never called"
	[[ "${ST_MODE}" != nested ]] || st_nested
	# Racy-git: an index written in the same second as the files it lists marks them for a
	# content re-check, and the next git command that refreshes the index rewrites it. One second
	# later the refresh below leaves nothing for any later command to rewrite, so the self-test can
	# compare the index file's sha256 before and after the action.
	# SELF_TEST_SETTLE_SECONDS=0 skips the wait, for the generator tests, which never compare it.
	sleep "${SELF_TEST_SETTLE_SECONDS:-1}"
	git -C "${ST_DIR}" update-index -q --refresh || true
	to="$(git -C "${ST_DIR}" rev-parse HEAD)"
	st_output mode "${ST_MODE}"
	st_output from-ref "${ST_FROM}"
	st_output to-ref "${to}"
	st_output check-hook "${hook}"
	st_output check-stage "${stage}"
	if [[ "${ST_MODE}" == bad ]]; then
		st_output expected-finding "${expected}"
	else
		st_output expected-finding ""
	fi
}
