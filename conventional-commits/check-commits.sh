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
# Checks the message of every non-merge commit in FROM_REF..TO_REF with the caller's own
# conventional-pre-commit hook (`pre-commit run conventional-pre-commit --hook-stage commit-msg
# --commit-msg-filename <file>`), so CI and the local commit-msg hook always agree. Merge commits
# (more than one parent) are skipped. No reviewdog: a bad message is an ::error:: annotation.
#
# Environment:
#   FROM_REF, TO_REF   the range to check (e.g. the pull request's base and head SHA); each must
#                      resolve to a commit and must not start with "-"
#   WORKING_DIRECTORY  the caller repository, relative to GITHUB_WORKSPACE (default "."): no
#                      absolute path, no ".." component, a directory inside the workspace
#   GITHUB_WORKSPACE   the workspace root (default: the current directory)
#   RUNNER_TEMP        where the message files go (default TMPDIR, then /tmp)
#   GITHUB_OUTPUT      when set, exitcode=0 (every commit passed) or 1 is appended to it
#
# Exit status: 0 when every checked commit passed (or the range has none), 1 otherwise, including
# a bad input, a missing hook or a range git cannot list.

set -euo pipefail

FROM_REF="${FROM_REF:-}"
TO_REF="${TO_REF:-}"
WORKING_DIRECTORY="${WORKING_DIRECTORY-.}"

esc() {
	local s="$*"
	s="${s//'%'/%25}"
	s="${s//$'\r'/%0D}"
	s="${s//$'\n'/%0A}"
	printf '%s' "${s}"
}

# Prints the hook output with workflow commands stopped, so a line of it (or of a commit message
# the hook echoes) that looks like ::error:: or ::add-mask:: is only text.
print_raw() {
	[[ -n "$1" ]] || return 0
	local token
	token="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
	echo "::stop-commands::${token}"
	printf '%s\n' "$1"
	echo "::${token}::"
}

output() {
	[[ -z "${GITHUB_OUTPUT:-}" ]] || echo "exitcode=$1" >>"${GITHUB_OUTPUT}"
}

fail() {
	echo "::error::$(esc "$*")"
	output 1
	exit 1
}

WORKSPACE="${GITHUB_WORKSPACE:-${PWD}}"
[[ -n "${WORKING_DIRECTORY}" ]] || fail "working-directory is empty (use . for the workspace root)"
[[ "${WORKING_DIRECTORY}" != /* ]] || fail "working-directory '${WORKING_DIRECTORY}' is absolute; it must be relative to the workspace"
[[ "/${WORKING_DIRECTORY}/" != */../* ]] || fail "working-directory '${WORKING_DIRECTORY}' has a .. component"
WORKSPACE_REAL="$(cd "${WORKSPACE}" 2>/dev/null && pwd -P)" || fail "the workspace ${WORKSPACE} is not a directory"
ROOT="$(cd "${WORKSPACE_REAL}/${WORKING_DIRECTORY}" 2>/dev/null && pwd -P)" ||
	fail "working-directory '${WORKING_DIRECTORY}' is not a directory in ${WORKSPACE_REAL}"
[[ "${ROOT}" == "${WORKSPACE_REAL}" || "${ROOT}" == "${WORKSPACE_REAL}/"* ]] ||
	fail "working-directory '${WORKING_DIRECTORY}' resolves to ${ROOT}, outside the workspace ${WORKSPACE_REAL}"
cd "${ROOT}"

# The hook this action runs is the caller's own, so a caller without it would fail every commit
# with a misleading message. Say what is missing.
if ! grep -Eq '^[[:space:]]*-?[[:space:]]*id:[[:space:]]*["'\'']?conventional-pre-commit["'\'']?([[:space:]]|$)' .pre-commit-config.yaml 2>/dev/null; then
	fail ".pre-commit-config.yaml in '${WORKING_DIRECTORY}' has no conventional-pre-commit hook. Add it with stages: [commit-msg] (see the README of this action)."
fi
if [[ -z "${FROM_REF}" || -z "${TO_REF}" ]]; then
	fail "from-ref and to-ref are both required (got '${FROM_REF}'..'${TO_REF}'). Outside pull_request events, pass e.g. origin/main and HEAD."
fi
for ref in "${FROM_REF}" "${TO_REF}"; do
	[[ "${ref}" != -* ]] || fail "the ref '${ref}' starts with -"
	git rev-parse --verify --quiet "${ref}^{commit}" >/dev/null ||
		fail "'${ref}' is not a commit in ${ROOT}. Ensure 'fetch-depth: 0' is used on actions/checkout."
done
if ! commits="$(git log --format='%H %P' "${FROM_REF}..${TO_REF}" -- 2>&1)"; then
	fail "Failed to get the commit log for '${FROM_REF}..${TO_REF}': ${commits}"
fi

MSG_DIR="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/conventional-commits.XXXXXX")"

# The caller's index is left byte for byte as it was. GIT_OPTIONAL_LOCKS=0 stops the optional
# refresh that `git status` and friends write, but pre-commit's own `git diff` still rewrites the
# index when its stat data is stale, so the bytes are saved here and put back after every run,
# and once more on the way out (an interruption included). A copy that could not be put back is
# never deleted: it is moved to a recovery directory and the error says how to restore it.
export GIT_OPTIONAL_LOCKS=0
INDEX=""
INDEX_STATE=""
INDEX_ERROR=""
index_state() {
	if [[ -L "${INDEX}" ]]; then
		echo other
	elif [[ -f "${INDEX}" ]]; then
		echo "present $(stat --printf '%a' -- "${INDEX}")"
	elif [[ -e "${INDEX}" ]]; then
		echo other
	else
		echo absent
	fi
}
# Returns 1 with the reason in INDEX_ERROR when the index differs and could not be put back.
restore_index() {
	local tmp
	INDEX_ERROR=""
	[[ -n "${INDEX_STATE}" ]] || return 0
	if [[ "$(index_state)" == "${INDEX_STATE}" ]] &&
		{ [[ "${INDEX_STATE}" == absent ]] || cmp -s -- "${MSG_DIR}/index" "${INDEX}"; }; then
		return 0
	fi
	if [[ -e "${INDEX}.lock" || -L "${INDEX}.lock" ]]; then
		INDEX_ERROR="pre-commit left ${INDEX}.lock (git may still be writing the index)"
		return 1
	fi
	if [[ "${INDEX_STATE}" == absent ]]; then
		rm -f -- "${INDEX}" || { INDEX_ERROR="cannot remove the index ${INDEX} that pre-commit created"; return 1; }
		return 0
	fi
	if ! tmp="$(mktemp "${INDEX%/*}/.pcrd-index.XXXXXX")"; then
		INDEX_ERROR="cannot create a temporary file next to the index ${INDEX}"
		return 1
	fi
	if ! cat -- "${MSG_DIR}/index" >"${tmp}" || ! chmod "${INDEX_STATE#present }" -- "${tmp}" || ! mv -T -- "${tmp}" "${INDEX}"; then
		rm -f -- "${tmp}"
		INDEX_ERROR="cannot put the index ${INDEX} back"
		return 1
	fi
	cmp -s -- "${MSG_DIR}/index" "${INDEX}" || { INDEX_ERROR="the index ${INDEX} still differs after it was put back"; return 1; }
}
# Keeps the saved index out of the cleanup and prints how to restore it.
keep_index() {
	local keep
	if [[ "${INDEX_STATE}" == absent ]]; then
		echo "::error::$(esc "the index could not be restored: ${INDEX_ERROR}. There was no index before the run: once no git is running, remove ${INDEX} (and ${INDEX}.lock).")"
		return 0
	fi
	if keep="$(mktemp -d "${MSG_DIR%/*}/conventional-commits-index-recovery.XXXXXX")" && mv -T -- "${MSG_DIR}/index" "${keep}/index"; then
		echo "::error::$(esc "the index could not be restored: ${INDEX_ERROR}. The index from before the run is kept in ${keep}/index. Once no git is running, remove ${INDEX}.lock if it is still there and restore it with: cp -- ${keep}/index ${INDEX} && chmod ${INDEX_STATE#present } ${INDEX}")"
	else
		MSG_DIR_KEEP=1
		echo "::error::$(esc "the index could not be restored: ${INDEX_ERROR}. The index from before the run is kept in ${MSG_DIR}/index; restore it with: cp -- ${MSG_DIR}/index ${INDEX}")"
	fi
}
MSG_DIR_KEEP=0
INDEX_KEPT=0
# shellcheck disable=SC2329 # invoked from the traps
cleanup() {
	local rc=$?
	trap '' INT TERM
	if ((INDEX_KEPT == 0)) && ! restore_index; then
		keep_index
		INDEX_KEPT=1
		output 1
		rc=1
	fi
	((MSG_DIR_KEEP)) || rm -rf -- "${MSG_DIR}"
	exit "${rc}"
}
trap cleanup EXIT
trap 'echo "::error::interrupted (SIGINT)"; exit 130' INT
trap 'echo "::error::interrupted (SIGTERM)"; exit 143' TERM

INDEX="$(git rev-parse --path-format=absolute --git-path index)" || fail "cannot find the index file of ${ROOT}"
state="$(index_state)"
[[ "${state}" != other ]] || fail "the index ${INDEX} is not a regular file"
if [[ "${state}" != absent ]]; then
	cp -- "${INDEX}" "${MSG_DIR}/index" || fail "cannot copy the index ${INDEX}"
fi
INDEX_STATE="${state}"

failed=0
checked=0
while read -r sha parents; do
	[[ -n "${sha}" ]] || continue
	# A merge commit has more than one parent.
	read -ra parent_list <<<"${parents}"
	((${#parent_list[@]} <= 1)) || continue
	checked=$((checked + 1))
	msg_file="${MSG_DIR}/${sha}"
	git log -1 --format=%B "${sha}" >"${msg_file}"
	# --files keeps pre-commit from stashing the caller's unstaged changes (run.py: stash = not
	# all_files and not files); at the commit-msg stage the hook still gets only the message file
	# (_all_filenames returns commit_msg_filename before it looks at --files).
	rc=0
	out="$(pre-commit run conventional-pre-commit --hook-stage commit-msg \
		--commit-msg-filename "${msg_file}" --files "${msg_file}" --color=never 2>&1)" || rc=$?
	if ! restore_index; then
		keep_index
		INDEX_KEPT=1
		fail "the caller's index was left changed by pre-commit on commit $(git log -1 --format=%h "${sha}")"
	fi
	print_raw "${out}"
	if ((rc != 0)); then
		# shellcheck disable=SC2016 # the backticks are pre-commit's, literal
		if grep -qxF 'No hook with id `conventional-pre-commit` in stage `commit-msg`' <<<"${out}"; then
			fail "the conventional-pre-commit hook in '${WORKING_DIRECTORY}/.pre-commit-config.yaml' does not run at the commit-msg stage. Add stages: [commit-msg] to it (see the README of this action)."
		fi
		# Only a hook that ran and failed is a bad message: its status line ends in "Failed".
		if ! grep -qE '[.]{3,}Failed$' <<<"${out}"; then
			fail "pre-commit exited ${rc} without running the hook on commit $(git log -1 --format=%h "${sha}"); its output is above"
		fi
		echo "::error::Commit $(git log -1 --format=%h "${sha}") has a non-conventional message: $(esc "$(git log -1 --format=%s "${sha}")")"
		failed=1
	fi
done <<<"${commits}"

echo "Checked ${checked} non-merge commit(s) in ${FROM_REF}..${TO_REF}."
output "${failed}"
exit "${failed}"
