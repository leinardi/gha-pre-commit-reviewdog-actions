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
# Tests for run-passes.sh: real git in temporary repositories, stub pre-commit and reviewdog
# first on PATH, no network. The script under test is a copy of lib/ inside a temporary "action
# repository", so test converters can live inside it (converters must resolve inside the action's
# repository) without writing into this checkout.
#
# The pre-commit stub prints exactly what pre-commit 4.6.2 prints for one hook (status line padded
# with dots to 79 columns, `- hook id:`, `- exit code:`, `- files were modified by this hook`, a
# blank line, the stripped output, a blank line), with the hook's behaviour taken from
# $STUB_DIR/hooks/<id> (an executable run on the files; missing: "No hook with id"). A file
# $STUB_DIR/hooks/<id>.raw is printed verbatim instead (exit status in <id>.rc), for transcripts
# recorded from the real pre-commit 4.6.2. Every call is logged to $STUB_DIR/calls.
#
# Run: bash lib/run-passes.test.sh

# Each check's condition is a single-quoted string that check evaluates after the run, so the
# variables it reads are set by then (SC2016), and some are read only there (SC2034).
# shellcheck disable=SC2016,SC2034

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# The action repository copy.
ACTION="${WORK}/action"
mkdir -p "${ACTION}/lib" "${ACTION}/conv"
cp "${HERE}/run-passes.sh" "${HERE}/snapshot.sh" "${HERE}/recover.sh" "${HERE}/rdjson.jq" "${ACTION}/lib/"
SCRIPT="${ACTION}/lib/run-passes.sh"
cat >"${ACTION}/conv/lines.jq" <<'EOF'
include "rdjson";
# path:line: message lines to RDJSON.
{diagnostics: [split("\n")[] | strip_ansi | select(length > 0)
  | capture("^(?<p>[^:]+):(?<l>[0-9]+): (?<m>.*)$")
  | {message: .m, location: {path: .p, range: {start: {line: (.l | tonumber)}}}}]}
EOF
cat >"${ACTION}/conv/fail.jq" <<'EOF'
error("converter refuses")
EOF
ln -s /etc/hostname "${ACTION}/conv/outside.jq"

BIN="${WORK}/bin"
mkdir -p "${BIN}"
cat >"${BIN}/pre-commit" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
{
	printf 'CALL'
	printf ' %q' "$@"
	printf '\n'
} >>"${STUB_DIR}/calls"
[[ "$1" == run ]] || exit 99
printf 'ENV GIT_OPTIONAL_LOCKS=%s\n' "${GIT_OPTIONAL_LOCKS-unset}" >>"${STUB_DIR}/calls"
# As pre-commit 4.6.2, which runs this twice per hook: the worktree-vs-index diff refreshes stale
# stat data in the real index, and rewrites it even with GIT_OPTIONAL_LOCKS=0.
git diff --quiet --no-ext-diff --no-textconv --ignore-submodules >/dev/null 2>&1 || true
hook="$2"
shift 2
stage="" from="" to=""
files=()
while (($#)); do
	case "$1" in
	--hook-stage) stage="$2"; shift 2 ;;
	--color=never) shift ;;
	--from-ref) from="$2"; shift 2 ;;
	--to-ref) to="$2"; shift 2 ;;
	--files) shift; files=("$@"); break ;;
	*) echo "stub pre-commit: unexpected argument $1" >&2; exit 99 ;;
	esac
done
# As pre-commit 4.6.2: the refs choose the files (run.py:262), a non-empty --files only turns
# the stash off (run.py:344), and names that do not exist are dropped (run.py:75).
((${#files[@]} > 0)) || { echo "stub pre-commit: no --files, pre-commit would stash" >&2; exit 98; }
if [[ -n "${from}" && -n "${to}" ]]; then
	listed="$(mktemp)"
	git diff --name-only --no-ext-diff -z "${from}...${to}" >"${listed}" 2>/dev/null ||
		git diff --name-only --no-ext-diff -z "${from}..${to}" >"${listed}"
	files=()
	while IFS= read -r -d '' f; do
		[[ -e "${f}" || -L "${f}" ]] && files+=("${f}")
	done <"${listed}"
	rm -f "${listed}"
fi
export PRE_COMMIT_ORIGIN="${from}" PRE_COMMIT_SOURCE="${to}" PRE_COMMIT_FROM_REF="${from}" PRE_COMMIT_TO_REF="${to}"
{
	printf 'FILES %s' "${#files[@]}"
	((${#files[@]} > 100)) || printf ' %q' "${files[@]}"
	printf '\n'
} >>"${STUB_DIR}/calls"
behaviour="${STUB_DIR}/hooks/${hook}"
if [[ -f "${behaviour}.raw" ]]; then
	cat "${behaviour}.raw"
	exit "$(cat "${behaviour}.rc" 2>/dev/null || echo 0)"
fi
if [[ ! -x "${behaviour}" ]]; then
	echo "No hook with id \`${hook}\` in stage \`${stage}\`"
	exit 1
fi
status_line() {
	local dots=$((79 - ${#hook} - ${#2} - ${#1}))
	printf '%s%s%s%s\n' "${hook}" "$(printf '.%.0s' $(seq 1 "${dots}"))" "$2" "$1"
}
if [[ -f "${behaviour}.nofiles" ]]; then
	status_line Skipped "(no files to check)"
	exit 0
fi
manifest() { find . -path ./.git -prune -o -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum; }
before="$(manifest)"
rc=0
# Like pre-commit's xargs, a long list is split over several runs of the hook.
if ((${#files[@]} > 1000)); then
	out="$(printf '%s\0' "${files[@]}" | xargs -0 "${behaviour}" 2>&1)" || rc=1
else
	out="$("${behaviour}" "${files[@]}" 2>&1)" || rc=$?
fi
after="$(manifest)"
modified=0
[[ "${before}" == "${after}" ]] || modified=1
verbose=0
[[ ! -f "${behaviour}.verbose" ]] || verbose=1
if ((rc || modified)); then status_line Failed ""; else status_line Passed ""; fi
if ((verbose || rc || modified)); then
	echo "- hook id: ${hook}"
	((verbose == 0)) || echo "- duration: 0.01s"
	((rc == 0)) || echo "- exit code: ${rc}"
	((modified == 0)) || echo "- files were modified by this hook"
	if [[ -n "${out//[[:space:]]/}" ]]; then
		echo
		printf '%s\n' "${out}" | sed -e '/./,$!d'
		echo
	fi
fi
((rc || modified)) && exit 1
exit 0
STUB
cat >"${BIN}/reviewdog" <<'STUB'
#!/usr/bin/env bash
n=$(($(cat "${STUB_DIR}/reviewdog-count" 2>/dev/null || echo 0) + 1))
echo "${n}" >"${STUB_DIR}/reviewdog-count"
printf '%s\n' "$@" >"${STUB_DIR}/reviewdog-${n}.args"
env >"${STUB_DIR}/reviewdog-${n}.env"
cat >"${STUB_DIR}/reviewdog-${n}.in"
echo "stub reviewdog ${n}"
exit "$(cat "${STUB_DIR}/reviewdog.rc" 2>/dev/null || echo 0)"
STUB
chmod +x "${BIN}/pre-commit" "${BIN}/reviewdog"

NL=$'\n'
PASS=0
FAIL=0
ok() {
	PASS=$((PASS + 1))
	echo "ok - $1"
}
not_ok() {
	FAIL=$((FAIL + 1))
	echo "not ok - $1"
	if [[ -n "${2:-}" ]]; then
		while IFS= read -r line; do printf '       %s\n' "${line}"; done <<<"$2"
	fi
}
check() {
	local name="$1"
	shift
	if "$@"; then ok "${name}"; else not_ok "${name}" "status ${STATUS}
${LOG}
OUTPUT:
${OUTPUT}"; fi
}

git_q() { git -c init.defaultBranch=main -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false "$@"; }

# A fresh case: a workspace with repository "repo", a base commit with a.txt and b.txt, and a head
# commit that changes a.txt and adds "c d.txt". Sets CASE, REPO, STUB_DIR, BASE_SHA, HEAD_SHA.
N=0
new_case() {
	N=$((N + 1))
	CASE="${WORK}/case-${N}"
	REPO="${CASE}/ws/repo"
	export STUB_DIR="${CASE}/stub"
	mkdir -p "${REPO}" "${STUB_DIR}/hooks" "${CASE}/tmp"
	(
		cd "${REPO}"
		git_q init -q .
		printf 'one\n' >a.txt
		printf 'bee\n' >b.txt
		printf 'gone\n' >gone.txt
		git_q add -A
		git_q commit -qm base
		printf 'one changed\n' >a.txt
		printf 'see\n' >'c d.txt'
		git_q rm -q gone.txt
		git_q add -A
		git_q commit -qm head
	)
	BASE_SHA="$(git -C "${REPO}" rev-parse HEAD~1)"
	HEAD_SHA="$(git -C "${REPO}" rev-parse HEAD)"
}

# hook ID BODY: a stub hook behaviour (a bash script body; "$@" are the files).
hook() {
	printf '#!/usr/bin/env bash\n%s\n' "$2" >"${STUB_DIR}/hooks/$1"
	chmod +x "${STUB_DIR}/hooks/$1"
}

# A manifest of the worktree (every path but .git: type, mode, sha256 or link target) plus the
# real index's sha256 and git's own view, to compare before and after.
manifest() {
	(
		cd "${REPO}"
		find . -path ./.git -prune -o -print0 | LC_ALL=C sort -z | while IFS= read -r -d '' p; do
			if [[ -L "${p}" ]]; then
				printf '%q L %s\n' "${p}" "$(readlink -- "${p}")"
			elif [[ -d "${p}" ]]; then
				printf '%q D %s\n' "${p}" "$(stat -c %a -- "${p}")"
			else
				printf '%q F %s %s\n' "${p}" "$(stat -c %a -- "${p}")" "$(sha256sum <"${p}" | cut -c1-64)"
			fi
		done
		echo "index $(sha256sum <.git/index | cut -c1-64)"
		echo "status $(GIT_OPTIONAL_LOCKS=0 git status --porcelain=v2 -z | sha256sum | cut -c1-64)"
		echo "cached $(GIT_OPTIONAL_LOCKS=0 git diff --cached --binary | sha256sum | cut -c1-64)"
		echo "stage $(git ls-files -s -z | sha256sum | cut -c1-64)"
	)
}

# run PASSES [ENV=VALUE...]: runs the script. Sets STATUS, LOG, OUTPUT.
run() {
	local passes="$1"
	shift
	: >"${CASE}/output"
	STATUS=0
	LOG="$(cd "${CASE}" && env -u GITHUB_ACTIONS PATH="${BIN}:${PATH}" ACTION_NAME=test PASSES="${passes}" \
		FROM_REF="${BASE_SHA}" TO_REF="${HEAD_SHA}" GITHUB_WORKSPACE="${CASE}/ws" WORKING_DIRECTORY=repo \
		REPORTER=local RUNNER_TEMP="${CASE}/tmp" GITHUB_OUTPUT="${CASE}/output" "$@" \
		bash "${SCRIPT}" 2>&1)" || STATUS=$?
	OUTPUT="$(cat "${CASE}/output")"
}
out() { sed -n "s/^$1=//p" <<<"${OUTPUT}"; }
calls() { grep -c '^CALL' "${STUB_DIR}/calls" 2>/dev/null || true; }
rd_count() { cat "${STUB_DIR}/reviewdog-count" 2>/dev/null || echo 0; }
tmp_empty() { [[ -z "$(ls -A "${CASE}/tmp")" ]]; }

TREE='{"source": "tree", "format": "diff", "name": "test (fixes)"}'
one_pass() { # ID HOOK [REPORT...]: a one-pass PASSES with the tree report and the extra reports
	local id="$1" h="$2" reports="${TREE/fixes/${1} fixes}"
	shift 2
	local r
	for r in "$@"; do reports+=", ${r}"; done
	printf '{"id": "%s", "hooks": ["%s"], "stage": "manual", "reports": [%s]}' "${id}" "${h}" "${reports}"
}

# --- a clean run ---------------------------------------------------------------------------
new_case
hook clean 'exit 0'
before="$(manifest)"
run "[$(one_pass check clean)]"
check "a clean run passes, with ran=true and nothing posted" \
	eval '[[ ${STATUS} == 0 && $(out result) == passed && $(out ran) == true && $(out exitcode) == 0 && $(out check-exitcode) == 0 && $(rd_count) == 0 ]]'
check "a clean run leaves the worktree, index and git status as they were" eval '[[ "$(manifest)" == "${before}" ]]'
check "a clean run deletes its work directory" tmp_empty
check "pre-commit gets the hook, stage, --color=never and the changed files that exist, NUL-safe" \
	grep -qxF "CALL run clean --hook-stage manual --color=never --from-ref ${BASE_SHA} --to-ref ${HEAD_SHA} --files /dev/null/pre-commit-reviewdog-unused" "${STUB_DIR}/calls"
check "pre-commit computes the changed files itself, the existing ones only" \
	grep -qxF "FILES 2 a.txt c\\ d.txt" "${STUB_DIR}/calls"

# --- stale stat data in the index ------------------------------------------------------------
# pre-commit's own `git diff` (the stub's too) refreshes it and rewrites .git/index, even with
# GIT_OPTIONAL_LOCKS=0; the run must put the index bytes back.
new_case
hook clean 'exit 0'
touch -d '+1 hour' "${REPO}/a.txt" "${REPO}/b.txt"
before="$(manifest)"
index_before="$(sha256sum <"${REPO}/.git/index")"
run "[$(one_pass check clean)]"
check "a clean run on stale stat data passes and leaves .git/index byte for byte" \
	eval '[[ ${STATUS} == 0 && $(out result) == passed && "$(sha256sum <"${REPO}/.git/index")" == "${index_before}" && "$(manifest)" == "${before}" ]]'
check "pre-commit and the hooks run with GIT_OPTIONAL_LOCKS=0" grep -qxF "ENV GIT_OPTIONAL_LOCKS=0" "${STUB_DIR}/calls"
(cd "${REPO}" && GIT_OPTIONAL_LOCKS=0 git diff --quiet --no-ext-diff --no-textconv --ignore-submodules) || true
check "the case is not vacuous: the same git diff does rewrite the index" \
	eval '[[ "$(sha256sum <"${REPO}/.git/index")" != "${index_before}" ]]'

# --- files inside a submodule checkout --------------------------------------------------------
new_case
(
	cd "${CASE}"
	git_q init -q sub-src
	printf 'sub\n' >sub-src/file.txt
	git_q -C sub-src add -A
	git_q -C sub-src commit -qm sub
	cd "${REPO}"
	git_q -c protocol.file.allow=always submodule --quiet add "file://${CASE}/sub-src" sub >/dev/null 2>&1
	git_q commit -qm submodule
)
HEAD_SHA="$(git -C "${REPO}" rev-parse HEAD)"
hook subwrite 'printf "overwritten\n" >sub/file.txt; printf "new\n" >sub/new.txt; exit 0'
before="$(manifest)"
run "[$(one_pass check subwrite)]"
# The stub sees every file it changed (real pre-commit, whose diff ignores submodules, says Passed:
# see the real pre-commit case below), so the hook "failed"; what matters is the restore.
check "a hook that writes inside a submodule: its files are restored" \
	eval '[[ $(out result) == failed && "$(cat "${REPO}/sub/file.txt")" == sub && ! -e "${REPO}/sub/new.txt" && "$(manifest)" == "${before}" ]]'
check "the submodule restore is reported" grep -q "pass check: the worktree was restored and verified" <<<"${LOG}"
check "the hook's fixes inside the submodule are posted, under the submodule's path" \
	eval '[[ $(rd_count) == 1 ]] && grep -qxF "diff --git a/sub/file.txt b/sub/file.txt" "${STUB_DIR}/reviewdog-1.in" && grep -qxF "+++ b/sub/new.txt" "${STUB_DIR}/reviewdog-1.in" && grep -qxF -- "-f=diff" "${STUB_DIR}/reviewdog-1.args"'

# --- a finding: rdjson through a converter, reviewdog exit 0 ----------------------------------
new_case
hook lint 'echo "'"${REPO}"'/a.txt:1: bad"; exit 1'
run "[$(one_pass check lint '{"source": "stdout", "format": "rdjson", "converter": "conv/lines.jq", "required": true, "name": "test"}')]"
check "a finding with reviewdog exit 0 is a lint failure (result=failed, exit 1)" \
	eval '[[ ${STATUS} == 1 && $(out result) == failed && $(out exitcode) == 1 && $(out check-exitcode) == 1 && $(out ran) == true ]]'
check "reviewdog runs with -fail-level=none, nofilter, the reporter and the name" \
	eval '[[ "$(cat "${STUB_DIR}/reviewdog-1.args")" == "-name=test${NL}-reporter=local${NL}-filter-mode=nofilter${NL}-fail-level=none${NL}-f=rdjson" ]]'
check "the converted report has a workspace-relative path" \
	eval '[[ "$(jq -r ".diagnostics[0].location.path" "${STUB_DIR}/reviewdog-1.in")" == a.txt ]]'
check "the failed hook's raw output is grouped in the log with workflow commands stopped" \
	eval 'grep -q "^::group::test: lint output (pre-commit exit 1)" <<<"${LOG}" && grep -q "^::stop-commands::" <<<"${LOG}"'
check "a failed run says hooks found problems, not an operational error" \
	eval 'grep -q "::error::test: hooks found problems in pass(es) check" <<<"${LOG}" && ! grep -q "operational error" <<<"${LOG}"'

# --- hook passes, reviewdog fails --------------------------------------------------------------
new_case
hook warn 'echo "{\"diagnostics\": [{\"message\": \"w\", \"location\": {\"path\": \"a.txt\"}}]}"'
touch "${STUB_DIR}/hooks/warn.verbose"
echo 1 >"${STUB_DIR}/reviewdog.rc"
run "[$(one_pass check warn '{"source": "stdout", "format": "rdjson", "name": "test"}')]"
check "a passing hook whose report reviewdog fails to post is an error (exit 2)" \
	eval '[[ ${STATUS} == 2 && $(out result) == error && $(out exitcode) == 0 && $(rd_count) == 1 ]] && grep -q "reviewdog exited 1 while reporting test" <<<"${LOG}"'

# --- a failed rdjson hook without its report ----------------------------------------------------
for variant in empty garbage; do
	new_case
	if [[ "${variant}" == empty ]]; then hook lint 'exit 1'; else hook lint 'echo "Traceback: not json"; exit 1'; fi
	run "[$(one_pass check lint '{"source": "stdout", "format": "rdjson", "required": true, "name": "test"}')]"
	check "a failed rdjson hook with an ${variant} report is an error" \
		eval '[[ ${STATUS} == 2 && $(out result) == error && $(rd_count) == 0 ]] && grep -q "the hook failed without the JSON report it prints" <<<"${LOG}"'
done
new_case
hook lint 'echo "{\"diagnostics\": []}"; exit 1'
run "[$(one_pass check lint '{"source": "stdout", "format": "rdjson", "required": true, "name": "test"}')]"
check "a failed rdjson hook with zero diagnostics is a lint failure and posts nothing" \
	eval '[[ ${STATUS} == 1 && $(out result) == failed && $(rd_count) == 0 ]]'
new_case
hook lint 'echo "x"; sed -i "s/one/ONE/" a.txt; exit 1'
before="$(manifest)"
run "[$(one_pass check lint '{"source": "stdout", "format": "rdjson", "converter": "conv/fail.jq", "name": "test"}')]"
check "a converter failure still leaves the worktree restored and posts the tree diff" \
	eval '[[ "$(manifest)" == "${before}" && $(rd_count) == 1 ]]'
check "a converter failing on non-empty output is an error" \
	eval '[[ ${STATUS} == 2 && $(out result) == error ]] && grep -q "the converter conv/fail.jq failed" <<<"${LOG}"'
new_case
hook lint 'echo "{\"diagnostics\": [{\"message\": \"m\"}]}"; echo "{\"diagnostics\": []}"; exit 1'
run "[$(one_pass check lint '{"source": "stdout", "format": "rdjson", "name": "test"}')]"
check "two JSON documents where one RDJSON report is expected is an error" \
	eval '[[ ${STATUS} == 2 && $(out result) == error ]]'

# --- validator-only and diff-suggestion failures with nothing to post ---------------------------
new_case
hook validate 'echo "a.txt: invalid"; exit 1'
run "[$(one_pass check validate)]"
check "a failed validator-only hook with an empty tree diff is a lint failure, not an error" \
	eval '[[ ${STATUS} == 1 && $(out result) == failed && $(rd_count) == 0 ]]'
new_case
hook sc 'exit 1'
run "[$(one_pass diff sc '{"source": "stdout", "format": "diff", "name": "test (diff suggestions)"}')]"
check "a failed shellcheck with no suggestion is a lint failure" \
	eval '[[ ${STATUS} == 1 && $(out result) == failed && $(rd_count) == 0 ]]'
new_case
hook lint 'exit 1'
run "[$(one_pass check lint '{"source": "stdout", "format": "efm", "efm": ["%f:%l: %m"], "name": "test"}')]"
check "a failed efm hook that printed nothing warns that no line could be annotated" \
	eval '[[ ${STATUS} == 1 && $(out result) == failed ]] && grep -q "::warning::test: .*no line could be annotated" <<<"${LOG}"'
# Recorded from ansible-lint on GitHub Actions: its pep8 line is coloured under --color=never,
# with an OSC 8 hyperlink elsewhere in the output.
new_case
hook lint 'printf "\\e]8;;https://example.com/\\e\\\\docs\\e]8;;\\e\\\\\n\\e[35ma.txt\\e[0m\\e[2m:1:\\e[0m \\e[31m\\e[1mname[missing][/]: All tasks should be named.\\e[0m\\e[0m\n"; exit 1'
run "[$(one_pass check lint '{"source": "stdout", "format": "efm", "efm": ["%f:%l:%c: %m", "%f:%l: %m"], "name": "test"}')]"
check "a coloured efm line is matched and posted without its escape sequences" \
	eval '[[ ${STATUS} == 1 && $(out findings) == 1 ]] && [[ "$(cat "${STUB_DIR}/reviewdog-1.in")" == "docs${NL}a.txt:1: name[missing][/]: All tasks should be named." ]]'

new_case
hook lint 'echo "a.txt:1: bad"; exit 1'
run "[$(one_pass check lint '{"source": "stdout", "format": "efm", "efm": ["%f:%l: %m", "%-G%.%#"], "name": "test", "level": "warning"}')]"
check "an efm report passes each pattern and the level to reviewdog, with the stripped output" \
	eval '[[ ${STATUS} == 1 ]] && grep -qxF -- "-efm=%f:%l: %m" "${STUB_DIR}/reviewdog-1.args" && grep -qxF -- "-efm=%-G%.%#" "${STUB_DIR}/reviewdog-1.args" && grep -qxF -- "-level=warning" "${STUB_DIR}/reviewdog-1.args" && [[ "$(cat "${STUB_DIR}/reviewdog-1.in")" == "a.txt:1: bad" ]]'

# --- the tree report and the restore --------------------------------------------------------------
new_case
printf 'unstaged\n' >>"${REPO}/b.txt"
printf 'untracked\n' >"${REPO}/new.txt"
hook fix 'cat b.txt >"'"${STUB_DIR}"'/seen-b"; sed -i "s/one/ONE/" a.txt; sed -i "s/unstaged/UNSTAGED/" b.txt; mkdir -p made/deep; echo x >made/deep/f; exit 0'
before="$(manifest)"
run "[$(one_pass format fix)]"
check "a hook that only fixes files is a lint failure whose diff is posted" \
	eval '[[ ${STATUS} == 1 && $(out result) == failed && $(rd_count) == 1 ]] && grep -qxF -- "-f=diff" "${STUB_DIR}/reviewdog-1.args" && grep -qxF -- "-f.diff.strip=1" "${STUB_DIR}/reviewdog-1.args"'
check "the tree diff has a/ b/ prefixes and the hook's changes only" \
	eval 'grep -qxF -- "--- a/a.txt" "${STUB_DIR}/reviewdog-1.in" && grep -qxF -- "+ONE changed" "${STUB_DIR}/reviewdog-1.in" && grep -qxF -- "+++ b/made/deep/f" "${STUB_DIR}/reviewdog-1.in" && grep -qx -- "+UNSTAGED" "${STUB_DIR}/reviewdog-1.in" && ! grep -qx -- "+unstaged" "${STUB_DIR}/reviewdog-1.in"'
check "the hook saw the unstaged change (no stash with --files)" eval '[[ "$(cat "${STUB_DIR}/seen-b")" == "bee${NL}unstaged" ]]'
check "after the pass the worktree, index and status are as they were" eval '[[ "$(manifest)" == "${before}" ]]'

# --- continuation ---------------------------------------------------------------------------------
new_case
hook fix 'sed -i "s/one/ONE/" a.txt; exit 1'
hook look 'cat a.txt >"'"${STUB_DIR}"'/seen-a"'
echo 1 >"${STUB_DIR}/reviewdog.rc"
before="$(manifest)"
run "[$(one_pass first fix), $(one_pass second look)]"
check "a reviewdog failure still leaves the worktree restored" eval '[[ "$(manifest)" == "${before}" ]]'
check "a reporting error in pass 1 with a clean restore still runs pass 2, from the original tree" \
	eval '[[ ${STATUS} == 2 && $(out result) == error && $(calls) == 2 && "$(cat "${STUB_DIR}/seen-a")" == "one changed" ]]'
check "per-pass exit codes are reported" eval '[[ $(out first-exitcode) == 1 && $(out second-exitcode) == 0 && $(out exitcode) == 1 ]]'
new_case
hook fail 'exit 1'
hook pass 'exit 0'
run "[$(one_pass first fail), $(one_pass second pass)]"
check "a hook failure in pass 1 still runs pass 2; the verdict is failed" \
	eval '[[ ${STATUS} == 1 && $(out result) == failed && $(calls) == 2 && $(out second-exitcode) == 0 ]]'

# --- a restore failure -------------------------------------------------------------------------------
new_case
printf '*.log\n' >"${REPO}/.gitignore"
# What git archive would not give back byte for byte: an export-ignore'd file, eol conversion,
# permission bits beyond the exec bit, and a symlink.
printf 'a.txt export-ignore\n*.txt eol=crlf\n' >"${REPO}/.gitattributes"
printf '#!/bin/sh\n' >"${REPO}/run.sh"
chmod 750 "${REPO}/run.sh"
ln -s a.txt "${REPO}/lnk"
hook mess 'mkdir made; echo x >made/f; echo junk >made/ignored.log; sed -i "s/one/ONE/" a.txt'
hook pass 'exit 0'
before_a="$(cat "${REPO}/a.txt")"
before_b="$(sha256sum <"${REPO}/b.txt")"
run "[$(one_pass first mess), $(one_pass second pass)]"
recovery="$(find "${CASE}/tmp" -maxdepth 1 -name 'pre-commit-reviewdog-recovery-test-*' | head -n1)"
check "a restore failure in pass 1 runs no pass 2 and gives result=error" \
	eval '[[ ${STATUS} == 2 && $(out result) == error && $(calls) == 1 && -z "$(out second-exitcode)" ]]'
check "the recovery directory keeps the objects, the T0 tree, the plan and the failed paths" \
	eval '[[ -n "${recovery}" && -d "${recovery}/objects" && -s "${recovery}/t0.tree" && -s "${recovery}/plan" && -s "${recovery}/RECOVERY.txt" ]] && grep -q "^made: " "${recovery}/failed-paths"'
check "the error names the path and prints the recover.sh command kept next to the snapshot" \
	eval 'grep -q "could not be restored after pass first" <<<"${LOG}" && grep -qF "recover the original files with: bash ${recovery}/recover.sh ${recovery} <dest>" <<<"${LOG}" && grep -q "^test: failed path: made: " <<<"${LOG}" && [[ -x "${recovery}/recover.sh" || -f "${recovery}/recover.sh" ]]'
cmd="$(sed -n 's/^recover: //p' "${recovery:-/nonexistent}/RECOVERY.txt" 2>/dev/null || true)"
(eval "${cmd/<dest>/${CASE}/recovered}") >/dev/null 2>&1 || true
check "the printed recovery command recreates the original files" \
	eval '[[ "$(cat "${CASE}/recovered/a.txt" 2>/dev/null)" == "${before_a}" && -f "${CASE}/recovered/.gitignore" ]]'
check "recover.sh ignores export-ignore and eol attributes and keeps permission bits and symlinks" \
	eval '[[ "$(sha256sum <"${CASE}/recovered/b.txt")" == "${before_b}" && "$(stat -c %a "${CASE}/recovered/run.sh")" == 750 && "$(readlink "${CASE}/recovered/lnk")" == a.txt ]]'
check "the summary lists the remaining pass as not-run" eval 'grep -q "pass second: not-run" <<<"${LOG}"'

# --- missing hook, no changed files, pre-commit's own failures -------------------------------------------
new_case
run "[$(one_pass check nosuchhook)]"
check "a missing hook id is an error that says what to add to .pre-commit-config.yaml" \
	eval '[[ ${STATUS} == 2 && $(out result) == error && $(out ran) == false ]] && grep -q "no hook with id or alias nosuchhook in stage manual. Add it to the caller.s .pre-commit-config.yaml" <<<"${LOG}"'
new_case
hook clean 'exit 0'
run "[$(one_pass check clean)]" TO_REF="${BASE_SHA}"
check "no changed files: skipped, ran=false, pre-commit never invoked" \
	eval '[[ ${STATUS} == 0 && $(out result) == skipped && $(out ran) == false && $(out check-exitcode) == 0 && ! -e "${STUB_DIR}/calls" ]]'
check "no changed files leaves no work directory" tmp_empty
new_case
git -C "${REPO}" rm -q 'c d.txt'
git_q -C "${REPO}" commit -qm 'drop c d'
hook clean 'exit 0'
run "[$(one_pass check clean)]" FROM_REF="${HEAD_SHA}" TO_REF=HEAD
check "only deleted files changed: pre-commit is not called with an empty --files" \
	eval '[[ ${STATUS} == 0 && $(out result) == skipped && ! -e "${STUB_DIR}/calls" ]]'
new_case
hook nofiles 'exit 0'
touch "${STUB_DIR}/hooks/nofiles.nofiles"
run "[$(one_pass check nofiles)]"
check "(no files to check)Skipped is recorded as skipped" \
	eval '[[ ${STATUS} == 0 && $(out result) == skipped && $(out ran) == false && $(calls) == 1 ]] && grep -q "nofiles skipped" <<<"${LOG}"'
new_case
printf 'An unexpected error has occurred: CalledProcessError\n' >"${STUB_DIR}/hooks/boom.raw"
echo 3 >"${STUB_DIR}/hooks/boom.rc"
run "[$(one_pass check boom)]"
check "pre-commit exiting 3 is an error" eval '[[ ${STATUS} == 2 && $(out result) == error ]] && grep -q "exited 3" <<<"${LOG}"'

# --- no merge base -------------------------------------------------------------------------------------
new_case
(
	cd "${REPO}"
	git_q checkout -q --orphan other
	git_q rm -q -rf .
	printf 'other\n' >z.txt
	git_q add z.txt
	git_q commit -qm other
)
hook clean 'exit 0'
run "[$(one_pass check clean)]" FROM_REF="${HEAD_SHA}" TO_REF=other
check "without a merge base the two-dot diff gives the files (as pre-commit falls back)" \
	grep -qxF "FILES 1 z.txt" "${STUB_DIR}/calls"

# --- stripping pre-commit's own lines from a real pre-commit 4.6.2 transcript ------------------------------
new_case
# Recorded from pre-commit 4.6.2: a local hook that prints, modifies a file and exits 3, preceded by
# the environment set-up lines pre-commit prints on a cold cache.
{
	printf '[INFO] Initializing environment for local.\n'
	printf 'fail and modify..........................................................Failed\n'
	printf -- '- hook id: fail-mod\n- exit code: 3\n- files were modified by this hook\n\n'
	printf 'a.txt:1:1: bad thing\n\nsecond para\n\n'
} >"${STUB_DIR}/hooks/fail-mod.raw"
echo 1 >"${STUB_DIR}/hooks/fail-mod.rc"
run "[$(one_pass check fail-mod '{"source": "stdout", "format": "efm", "efm": ["%f:%l:%c: %m"], "name": "test"}')]"
check "the status, meta and blank lines are stripped and the output's own blank line kept" \
	eval '[[ ${STATUS} == 1 && "$(cat "${STUB_DIR}/reviewdog-1.in")" == "a.txt:1:1: bad thing${NL}${NL}second para" ]]'
new_case
{
	printf 'fail and modify..........................................................Failed\n'
	printf -- '- hook id: fail-mod\n- exit code: 3\n\n'
	printf 'first\n\n\nafter two blank lines\n  indented\n\n'
} >"${STUB_DIR}/hooks/fail-mod.raw"
echo 1 >"${STUB_DIR}/hooks/fail-mod.rc"
run "[$(one_pass check fail-mod '{"source": "stdout", "format": "efm", "efm": ["%m"], "name": "test"}')]"
check "consecutive blank lines and indentation inside the hook output are kept" \
	eval '[[ ${STATUS} == 1 && "$(cat "${STUB_DIR}/reviewdog-1.in")" == "first${NL}${NL}${NL}after two blank lines${NL}  indented" ]]'
new_case
{
	printf 'verbose hook.............................................................Passed\n'
	printf -- '- hook id: verbose-hook\n- duration: 0s\n\nverbose out\n\n'
} >"${STUB_DIR}/hooks/verbose-hook.raw"
run "[$(one_pass check verbose-hook '{"source": "stdout", "format": "efm", "efm": ["%m"], "name": "test"}')]"
check "a verbose passing hook (with - duration:) keeps only its output" \
	eval '[[ ${STATUS} == 0 && $(out result) == passed && "$(cat "${STUB_DIR}/reviewdog-1.in")" == "verbose out" ]]'
new_case
{
	printf 'dup one..................................................................Passed\n'
	printf 'dup two..................................................................Failed\n'
	printf -- '- hook id: dup\n- exit code: 3\n- files were modified by this hook\n\n'
	printf 'a.txt:1:1: bad thing\n\nsecond para\n\n'
} >"${STUB_DIR}/hooks/dup.raw"
echo 1 >"${STUB_DIR}/hooks/dup.rc"
run "[$(one_pass check dup '{"source": "stdout", "format": "efm", "efm": ["%f:%l:%c: %m"], "name": "test"}')]"
check "an id matching two hooks is parsed as two blocks (one passed, one failed)" \
	eval '[[ ${STATUS} == 1 && $(out result) == failed && "$(cat "${STUB_DIR}/reviewdog-1.in")" == "a.txt:1:1: bad thing${NL}${NL}second para" ]] && grep -q "matched 2 hooks" <<<"${LOG}"'
new_case
printf 'modify only..............................................................Failed\n- hook id: mod-only\n- files were modified by this hook\n' >"${STUB_DIR}/hooks/mod-only.raw"
echo 1 >"${STUB_DIR}/hooks/mod-only.rc"
run "[$(one_pass check mod-only '{"source": "stdout", "format": "diff", "name": "test (suggestions)"}')]"
check "a failed hook that printed nothing leaves an empty stdout report" \
	eval '[[ ${STATUS} == 1 && $(out result) == failed && $(rd_count) == 0 ]]'
new_case
{
	printf 'An error has occurred: InvalidConfigError: \n==> File .pre-commit-config.yaml\n'
	printf '=====> mapping values are not allowed in this context\n'
	printf 'Check the log at /home/u/.cache/pre-commit/pre-commit.log\n'
} >"${STUB_DIR}/hooks/cfg.raw"
echo 1 >"${STUB_DIR}/hooks/cfg.rc"
run "[$(one_pass check cfg)]"
check "pre-commit's fatal error (exit 1, no status line) is an error, not a lint failure" \
	eval '[[ ${STATUS} == 2 && $(out result) == error ]] && grep -q "printed no hook status line" <<<"${LOG}"'
new_case
hook inject 'echo "::error::injected"; exit 1'
run "[$(one_pass check inject)]"
token="$(sed -n 's/^::stop-commands::\(.*\)$/\1/p' <<<"${LOG}")"
check "hook output is printed between ::stop-commands:: and its token" \
	eval '[[ -n "${token}" ]] && sed -n "/^::stop-commands::/,/^::${token}::\$/p" <<<"${LOG}" | grep -qxF "::error::injected"'


# --- tokens never reach a hook ------------------------------------------------------------------
new_case
hook dump 'env >"'"${STUB_DIR}"'/hook-env"; sed -i "s/one/ONE/" a.txt'
run "[$(one_pass check dump)]" REPORTER=github-pr-review REVIEWDOG_GITHUB_API_TOKEN=rd-secret GITHUB_TOKEN=gh-secret \
	GH_TOKEN=gh2-secret GH_MODULE_TOKEN=mod-secret ACTIONS_RUNTIME_TOKEN=rt-secret INPUT_GITHUB_TOKEN=in-secret

check "no token reaches a hook (REVIEWDOG_GITHUB_API_TOKEN, GITHUB_TOKEN, GH_TOKEN, GH_MODULE_TOKEN, ACTIONS_RUNTIME_TOKEN, INPUT_*)" \
	eval '[[ -s "${STUB_DIR}/hook-env" ]] && ! grep -q "secret" "${STUB_DIR}/hook-env" && ! grep -qE "^(REVIEWDOG_GITHUB_API_TOKEN|GITHUB_TOKEN|GH_TOKEN|GH_MODULE_TOKEN|ACTIONS_RUNTIME_TOKEN|INPUT_GITHUB_TOKEN)=" "${STUB_DIR}/hook-env"'
check "reviewdog, and only reviewdog, gets REVIEWDOG_GITHUB_API_TOKEN" \
	eval 'grep -qx "REVIEWDOG_GITHUB_API_TOKEN=rd-secret" "${STUB_DIR}/reviewdog-1.env" && ! grep -q "gh-secret\|gh2-secret\|mod-secret" "${STUB_DIR}/reviewdog-1.env"'

# --- file names that look like options, and more names than fit on a command line -----------------
new_case
(
	cd "${REPO}"
	printf 'x\n' >-x.md
	printf 'x\n' >--config=evil.yaml
	printf 'x\n' >--hook-stage=commit-msg
	git_q add -- -x.md --config=evil.yaml --hook-stage=commit-msg
	git_q commit -qm dashes
)
HEAD_SHA="$(git -C "${REPO}" rev-parse HEAD)"
hook clean 'printf "%s\n" "$@" >"'"${STUB_DIR}"'/hook-args"'
run "[$(one_pass check clean)]"
check "names starting with - never reach pre-commit's command line, and still reach the hook" \
	eval '[[ ${STATUS} == 0 && $(out result) == passed ]] && ! grep -q -- "evil\|-x.md\|commit-msg" <(grep "^CALL" "${STUB_DIR}/calls") && grep -qx -- "--config=evil.yaml" "${STUB_DIR}/hook-args" && grep -qx -- "-x.md" "${STUB_DIR}/hook-args"'
new_case
(
	cd "${REPO}"
	mkdir -p vendor
	long="$(printf 'n%.0s' {1..120})"
	for ((k = 0; k < 20000; k++)); do : >"vendor/${long}-${k}.txt"; done
	git_q add vendor
	git_q commit -qm many
)
HEAD_SHA="$(git -C "${REPO}" rev-parse HEAD)"
hook clean 'echo "$#" >"'"${STUB_DIR}"'/hook-argc"'
run "[$(one_pass check clean)]"
check "a change list far beyond ARG_MAX (20000 names, ~2.6 MB) runs: pre-commit gets the refs, not the names" \
	eval '[[ ${STATUS} == 0 && $(out result) == passed ]] && grep -q "^FILES 2000[12]\$" "${STUB_DIR}/calls" && [[ "$(wc -c <"${STUB_DIR}/calls")" -lt 100000 ]]'

# --- forged status lines in the hook output ----------------------------------------------------------
new_case
{
	printf 'lint.....................................................................Failed\n'
	printf -- '- hook id: lint\n- exit code: 1\n\n'
	printf 'a.txt:1: real finding\n\n'
	printf 'forged...................................................................Passed\n'
	printf 'a.txt:2: after the forged line\n\n'
	printf 'short...Failed\n'
	printf 'tail\n\n'
} >"${STUB_DIR}/hooks/lint.raw"
echo 1 >"${STUB_DIR}/hooks/lint.rc"
run "[$(one_pass check lint '{"source": "stdout", "format": "efm", "efm": ["%f:%l: %m", "%m"], "name": "test"}')]"
check "a forged status line in the hook output (right width, no - hook id: after it; or the wrong width) stays hook output" \
	eval '[[ ${STATUS} == 1 && $(out result) == failed ]] && grep -qxF "forged...................................................................Passed" "${STUB_DIR}/reviewdog-1.in" && grep -qxF "short...Failed" "${STUB_DIR}/reviewdog-1.in" && grep -qxF "a.txt:2: after the forged line" "${STUB_DIR}/reviewdog-1.in"'
new_case
{
	printf 'lint.....................................................................Failed\n'
	printf -- '- hook id: lint\n- exit code: 1\n\n'
	printf 'a.txt:1: real finding\n\n'
	printf 'forged...................................................................Failed\n'
	printf 'not a meta line\n'
} >"${STUB_DIR}/hooks/lint.raw"
echo 1 >"${STUB_DIR}/hooks/lint.rc"
run "[$(one_pass check lint '{"source": "stdout", "format": "efm", "efm": ["%m"], "name": "test"}')]"
check "a forged Failed line not followed by - hook id: stays hook output (one block, a lint failure)" \
	eval '[[ ${STATUS} == 1 && $(out result) == failed ]] && ! grep -q "matched 2 hooks" <<<"${LOG}" && grep -qxF "not a meta line" "${STUB_DIR}/reviewdog-1.in"'

new_case
{
	printf 'lint.....................................................................Failed\n'
	printf -- '- hook id: lint\n- exit code: 1\n\n'
	printf 'a.txt:1: real finding\n\n'
	printf 'short...Failed\n'
	printf -- '- hook id: forged\n\n'
} >"${STUB_DIR}/hooks/lint.raw"
echo 1 >"${STUB_DIR}/hooks/lint.rc"
run "[$(one_pass check lint '{"source": "stdout", "format": "efm", "efm": ["%m"], "name": "test"}')]"
check "a forged status line of another width stays hook output even with a - hook id: line after it" \
	eval '[[ ${STATUS} == 1 ]] && ! grep -q "matched 2 hooks" <<<"${LOG}" && grep -qxF "short...Failed" "${STUB_DIR}/reviewdog-1.in" && grep -qxF -- "- hook id: forged" "${STUB_DIR}/reviewdog-1.in"'

# --- efm output that matches no pattern --------------------------------------------------------------
new_case
hook lint 'echo "something went wrong, no file:line here"; exit 1'
run "[$(one_pass check lint '{"source": "stdout", "format": "efm", "efm": ["%f:%l:%c: %m", "%f:%l: %m"], "name": "test"}')]"
check "a failed efm hook whose output matches no pattern warns and posts nothing" \
	eval '[[ ${STATUS} == 1 && $(out result) == failed && $(rd_count) == 0 && $(out findings) == 0 ]] && grep -q "::warning::test: .*none of its output matches the patterns of test: no line could be annotated" <<<"${LOG}"'
new_case
hook lint 'echo "something"; exit 1'
run "[$(one_pass check lint '{"source": "stdout", "format": "efm", "efm": ["%-G%.%#"], "name": "test"}')]"
check "an efm pattern the count cannot read (%-G) is posted, counted as unknown" \
	eval '[[ ${STATUS} == 1 && $(rd_count) == 1 && $(out findings) == 0 ]] && ! grep -q "no line could be annotated" <<<"${LOG}"'

# --- findings, REPORTS_DIR and non-ASCII paths in the tree diff ---------------------------------------
new_case
mkdir -p "${CASE}/reports"
hook lint 'echo "a.txt:1: one"; echo "noise"; echo "c d.txt:2: two"; sed -i "s/one/ONE/" a.txt; printf "x\n" >"caffè.txt"; exit 1'
hook json 'echo "{\"diagnostics\": [{\"message\": \"m1\", \"location\": {\"path\": \"a.txt\"}}, {\"message\": \"m2\", \"location\": {\"path\": \"a.txt\"}}]}"; exit 1'
run "[$(one_pass check lint '{"source": "stdout", "format": "efm", "efm": ["%f:%l: %m"], "name": "test"}'), $(one_pass rd json '{"source": "stdout", "format": "rdjson", "name": "test rd"}')]" \
	REPORTS_DIR="${CASE}/reports"
check "findings counts efm matches, diff hunks and rdjson diagnostics (1 efm line, 2 tree hunks, 2 diagnostics; the name c d.txt has a space, which %f does not match)" \
	eval '[[ $(out findings) == 5 ]]'
check "REPORTS_DIR holds each posted report byte for byte, named <pass>--<index>.<format>" \
	eval 'cmp -s "${CASE}/reports/check--0.diff" "${STUB_DIR}/reviewdog-1.in" && cmp -s "${CASE}/reports/check--1.efm" "${STUB_DIR}/reviewdog-2.in" && cmp -s "${CASE}/reports/rd--1.rdjson" "${STUB_DIR}/reviewdog-3.in"'
check "reports.json indexes them with pass, name, source, format, file and count" \
	eval '[[ "$(jq -c "sort_by(.file) | map([.pass, .name, .source, .format, .file, .count])" "${CASE}/reports/reports.json")" == "[[\"check\",\"test (check fixes)\",\"tree\",\"diff\",\"check--0.diff\",2],[\"check\",\"test\",\"stdout\",\"efm\",\"check--1.efm\",1],[\"rd\",\"test rd\",\"stdout\",\"rdjson\",\"rd--1.rdjson\",2]]" ]]'
check "the tree diff names a non-ASCII path in raw UTF-8 (core.quotePath=false)" \
	eval 'grep -qxF "+++ b/caffè.txt" "${CASE}/reports/check--0.diff"'
new_case
hook clean 'exit 0'
run "[$(one_pass check clean)]" REPORTS_DIR="${CASE}/tmp"
check "REPORTS_DIR with nothing posted gets an empty reports.json" eval '[[ "$(cat "${CASE}/tmp/reports.json")" == "[]" && $(out findings) == 0 ]]'

# --- SIGTERM mid-pass ---------------------------------------------------------------------------------
new_case
hook slow 'sed -i "s/one/ONE/" a.txt; touch "'"${STUB_DIR}"'/started"; sleep 30'
hook pass 'exit 0'
before="$(manifest)"
: >"${CASE}/output"
(cd "${CASE}" && exec env PATH="${BIN}:${PATH}" ACTION_NAME=test PASSES="[$(one_pass first slow), $(one_pass second pass)]" \
	FROM_REF="${BASE_SHA}" TO_REF="${HEAD_SHA}" GITHUB_WORKSPACE="${CASE}/ws" WORKING_DIRECTORY=repo \
	REPORTER=local RUNNER_TEMP="${CASE}/tmp" GITHUB_OUTPUT="${CASE}/output" bash "${SCRIPT}" >"${CASE}/log" 2>&1) &
pid=$!
for ((t = 0; t < 100; t++)); do
	[[ ! -e "${STUB_DIR}/started" ]] || break
	sleep 0.1
done
kill -TERM "${pid}"
STATUS=0
wait "${pid}" || STATUS=$?
LOG="$(cat "${CASE}/log")"
OUTPUT="$(cat "${CASE}/output")"
check "TERM mid-pass restores the worktree, exits 143 with result=error and runs no further pass" \
	eval '[[ ${STATUS} == 143 && $(out result) == error && $(calls) == 1 && "$(manifest)" == "${before}" ]] && grep -q "received SIGTERM during pass first" <<<"${LOG}"'
check "TERM mid-pass, restored, leaves no work directory" tmp_empty

# --- input validation ------------------------------------------------------------------------------------
new_case
hook clean 'exit 0'
GOOD="[$(one_pass check clean)]"
bad_input() { # NAME PATTERN PASSES [ENV...]
	local name="$1" pattern="$2" passes="$3"
	shift 3
	run "${passes}" "$@"
	if [[ ${STATUS} == 2 && $(out result) == error && ! -e "${STUB_DIR}/calls" ]] && grep -q -- "${pattern}" <<<"${LOG}"; then
		ok "${name}"
	else
		not_ok "${name} (want exit 2, result=error, no pre-commit call, a message matching '${pattern}')" "status ${STATUS}
${LOG}"
	fi
}
bad_input "PASSES that is not JSON is refused" "PASSES is not valid JSON" '[{'
bad_input "an empty PASSES array is refused" "not a non-empty JSON array" '[]'
bad_input "a pass id with capitals is refused" "id is not" '[{"id": "Check", "hooks": ["clean"], "stage": "manual", "reports": ['"${TREE}"']}]'
bad_input "a hook id with a space is refused" "hooks is not" '[{"id": "c", "hooks": ["a b"], "stage": "manual", "reports": ['"${TREE}"']}]'
bad_input "a hook id that is an option is still a plain id" "hooks is not" '[{"id": "c", "hooks": [], "stage": "manual", "reports": ['"${TREE}"']}]'
bad_input "a stage outside the allow-list is refused" "stage is not" '[{"id": "c", "hooks": ["clean"], "stage": "commit-msg", "reports": ['"${TREE}"']}]'
bad_input "a pass without a tree report is refused" "exactly one tree report" '[{"id": "c", "hooks": ["clean"], "stage": "manual", "reports": []}]'
bad_input "a tree report in rdjson is refused" "is a tree report but" '[{"id": "c", "hooks": ["clean"], "stage": "manual", "reports": [{"source": "tree", "format": "rdjson", "name": "x"}]}]'
bad_input "an unknown format is refused" "format is not" "[$(one_pass c clean '{"source": "stdout", "format": "sarif", "name": "s"}')]"
bad_input "an efm report without patterns is refused" "efm is not" "[$(one_pass c clean '{"source": "stdout", "format": "efm", "name": "s"}')]"
bad_input "an efm pattern with a newline is refused (it would start a log line of its own)" "efm is not" "[$(one_pass c clean '{"source": "stdout", "format": "efm", "efm": ["%m\n::warning::x"], "name": "s"}')]"
bad_input "an empty report name is refused" "name is empty" "[$(one_pass c clean '{"source": "stdout", "format": "diff", "name": ""}')]"
bad_input "duplicate report names are refused" "report name test (c fixes) is used more than once" "[$(one_pass c clean '{"source": "stdout", "format": "diff", "name": "test (c fixes)"}')]"
bad_input "duplicate pass ids are refused" "pass id c is used more than once" "[$(one_pass c clean), {\"id\": \"c\", \"hooks\": [\"clean\"], \"stage\": \"manual\", \"reports\": [{\"source\": \"tree\", \"format\": \"diff\", \"name\": \"other\"}]}]"
bad_input "an unknown key is refused" "unknown keys: typo" "[$(one_pass c clean '{"source": "stdout", "format": "diff", "name": "s", "typo": 1}')]"
bad_input "a converter with .. is refused" "converter is not a relative" "[$(one_pass c clean '{"source": "stdout", "format": "rdjson", "name": "s", "converter": "../x.jq"}')]"
bad_input "a converter that is a symlink out of the action repository is refused" "outside" "[$(one_pass c clean '{"source": "stdout", "format": "rdjson", "name": "s", "converter": "conv/outside.jq"}')]"
bad_input "a missing converter is refused" "does not exist" "[$(one_pass c clean '{"source": "stdout", "format": "rdjson", "name": "s", "converter": "conv/none.jq"}')]"
bad_input "a converter on an efm report is refused" "has a converter but" "[$(one_pass c clean '{"source": "stdout", "format": "efm", "efm": ["%m"], "name": "s", "converter": "conv/lines.jq"}')]"
bad_input "an unknown reporter is refused" "reporter 'github-pr-check' is not" "${GOOD}" REPORTER=github-pr-check
bad_input "a GitHub reporter without a token is refused" "REVIEWDOG_GITHUB_API_TOKEN is empty" "${GOOD}" REPORTER=github-pr-review REVIEWDOG_GITHUB_API_TOKEN=
bad_input "a ref that starts with - is refused" "starts with -" "${GOOD}" FROM_REF=--output=/tmp/x
bad_input "a ref that is not a commit is refused" "is not a commit" "${GOOD}" TO_REF=nosuchref
bad_input "an empty ref is refused" "TO_REF is empty" "${GOOD}" TO_REF=
bad_input "an absolute working-directory is refused" "is absolute" "${GOOD}" WORKING_DIRECTORY=/tmp
bad_input "a working-directory with .. is refused" "has a .. component" "${GOOD}" WORKING_DIRECTORY=repo/../repo
bad_input "an empty working-directory is refused" "working-directory is empty" "${GOOD}" WORKING_DIRECTORY=
mkdir -p "${REPO}/sub"
bad_input "a working-directory that is not a work tree root is refused" "is not the root of its work tree" "${GOOD}" WORKING_DIRECTORY=repo/sub
ln -s "${WORK}" "${CASE}/ws/escape"
bad_input "a working-directory that resolves outside the workspace is refused" "outside the workspace" "${GOOD}" WORKING_DIRECTORY=escape
bad_input "a bad ACTION_NAME is refused" "ACTION_NAME" "${GOOD}" ACTION_NAME='a b'
bad_input "a relative REPORTS_DIR is refused" "REPORTS_DIR 'rel' is not an absolute path" "${GOOD}" REPORTS_DIR=rel
bad_input "a missing REPORTS_DIR is refused" "is not an existing directory" "${GOOD}" REPORTS_DIR=/nonexistent/dir
bad_input "a REPORTS_DIR inside the caller's work tree is refused" "inside the caller's work tree" "${GOOD}" REPORTS_DIR="${REPO}/sub"
# git never lists an untracked fifo, but a tracked path replaced by one is in its scope.
rm -f "${REPO}/b.txt"
mkfifo "${REPO}/b.txt"
bad_input "a tracked file replaced by a fifo fails the preflight snapshot before any hook" "not a regular file, symlink or directory" "${GOOD}"
rm -f "${REPO}/b.txt"

bad_input "a hook id that starts with - is refused, so it can never reach pre-commit as an option" "hooks is not" '[{"id": "c", "hooks": ["--all-files"], "stage": "manual", "reports": ['"${TREE}"']}]'
bad_input "a VALIDATE_ONLY that is not true or false is refused" "VALIDATE_ONLY 'yes' is not true or false" "${GOOD}" VALIDATE_ONLY=yes

# --- VALIDATE_ONLY ---------------------------------------------------------------------------
new_case
run "${GOOD}" VALIDATE_ONLY=true FROM_REF= TO_REF= WORKING_DIRECTORY=nowhere REPORTER=github-pr-review REVIEWDOG_GITHUB_API_TOKEN=
check "VALIDATE_ONLY=true accepts good PASSES without refs, a work tree, a token or a pre-commit call" \
	eval '[[ ${STATUS} == 0 && -z "${OUTPUT}" && ! -e "${STUB_DIR}/calls" ]] && grep -q "PASSES is valid: 1 pass(es) (check)" <<<"${LOG}"'
check "VALIDATE_ONLY=true leaves no work directory" tmp_empty
run "[$(one_pass c clean '{"source": "stdout", "format": "rdjson", "name": "s", "converter": "conv/lines.jq"}')]" VALIDATE_ONLY=true
check "VALIDATE_ONLY=true accepts a converter that resolves inside the action repository" eval '[[ ${STATUS} == 0 ]]'
run "[$(one_pass c clean '{"source": "stdout", "format": "rdjson", "name": "s", "converter": "conv/none.jq"}')]" VALIDATE_ONLY=true
check "VALIDATE_ONLY=true still refuses a missing converter" \
	eval '[[ ${STATUS} == 2 && $(out result) == error ]] && grep -q "does not exist" <<<"${LOG}"'
run '[{"id": "c", "hooks": ["--all-files"], "stage": "manual", "reports": ['"${TREE}"']}]' VALIDATE_ONLY=true
check "VALIDATE_ONLY=true still refuses malformed PASSES" eval '[[ ${STATUS} == 2 && $(out result) == error ]] && grep -q "hooks is not" <<<"${LOG}"'

# --- the real pre-commit 4.6.2, when it is installed: a local system hook, no download ---------
# The reviewer's reproductions: a hook that overwrites a file inside a submodule (real pre-commit
# says Passed, its diff ignores submodules), on a worktree with stale stat data in the index
# (pre-commit's own git diff rewrites the index).
if command -v pre-commit >/dev/null && [[ "$(command pre-commit --version)" == "pre-commit 4."* ]]; then
	REAL_BIN="${WORK}/real-bin"
	mkdir -p "${REAL_BIN}"
	cp "${BIN}/reviewdog" "${REAL_BIN}/"
	new_case
	(
		cd "${CASE}"
		git_q init -q sub-src
		printf 'sub\n' >sub-src/file.txt
		git_q -C sub-src add -A
		git_q -C sub-src commit -qm sub
		cd "${REPO}"
		git_q -c protocol.file.allow=always submodule --quiet add "file://${CASE}/sub-src" sub >/dev/null 2>&1
		cat >.pre-commit-config.yaml <<'EOF'
repos:
  - repo: local
    hooks:
      - id: subwrite
        name: subwrite
        entry: bash -c 'printf "overwritten\n" >sub/file.txt'
        language: system
        pass_filenames: false
        always_run: true
        stages: [manual]
EOF
		git_q add -A
		git_q commit -qm 'submodule and config'
	)
	HEAD_SHA="$(git -C "${REPO}" rev-parse HEAD)"
	touch -d '+1 hour' "${REPO}/a.txt" "${REPO}/.pre-commit-config.yaml"
	before="$(manifest)"
	index_before="$(sha256sum <"${REPO}/.git/index")"
	sub_before="$(sha256sum <"${REPO}/sub/file.txt")"
	STATUS=0
	LOG="$(cd "${CASE}" && env -u GITHUB_ACTIONS PATH="${REAL_BIN}:${PATH}" PRE_COMMIT_HOME="${CASE}/pre-commit-home" \
		ACTION_NAME=test PASSES="[$(one_pass check subwrite)]" FROM_REF="${BASE_SHA}" TO_REF="${HEAD_SHA}" \
		GITHUB_WORKSPACE="${CASE}/ws" WORKING_DIRECTORY=repo REPORTER=local RUNNER_TEMP="${CASE}/tmp" \
		GITHUB_OUTPUT="${CASE}/output" bash "${SCRIPT}" 2>&1)" || STATUS=$?
	OUTPUT="$(cat "${CASE}/output")"
	check "real pre-commit: the hook ran and passed (pre-commit ignores submodule changes)" \
		eval '[[ ${STATUS} == 0 && $(out result) == passed && $(out ran) == true ]]'
	check "real pre-commit: the file the hook overwrote inside the submodule is restored" \
		eval '[[ "$(sha256sum <"${REPO}/sub/file.txt")" == "${sub_before}" ]] && grep -q "the worktree was restored and verified" <<<"${LOG}"'
	check "real pre-commit: the fix inside the submodule is posted as a suggestion under sub/" \
		eval '[[ $(rd_count) == 1 ]] && grep -qxF "+++ b/sub/file.txt" "${STUB_DIR}/reviewdog-1.in"'
	check "real pre-commit: .git/index is unchanged byte for byte despite the stale stat data" \
		eval '[[ "$(sha256sum <"${REPO}/.git/index")" == "${index_before}" && "$(manifest)" == "${before}" ]]'
else
	echo "# skipped the real pre-commit cases: pre-commit 4 is not installed"
fi

echo
echo "${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
