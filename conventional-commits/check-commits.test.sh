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
# Tests check-commits.sh with real git in temporary repositories and a stub pre-commit that
# checks the message file the way conventional-pre-commit --force-scope does (a type, a scope in
# parentheses, an optional !, a colon and a subject). No network.
#
# Run: bash conventional-commits/check-commits.test.sh

# Each check's condition is a single-quoted string that check evaluates after the run, so the
# variables it reads are set by then (SC2016), and some are read only there (SC2034).
# shellcheck disable=SC2016,SC2034

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/check-commits.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
NL=$'\n'

mkdir -p "${WORK}/bin"
cat >"${WORK}/bin/pre-commit" <<'STUB'
#!/usr/bin/env bash
printf 'CALL %s\n' "$*" >>"${STUB_CALLS}"
printf 'ENV GIT_OPTIONAL_LOCKS=%s\n' "${GIT_OPTIONAL_LOCKS-unset}" >>"${STUB_CALLS}"
[[ "$1 $2" == "run conventional-pre-commit" ]] || exit 99
# As pre-commit 4.6.2: its worktree-vs-index diff refreshes stale stat data in the real index and
# rewrites it, even with GIT_OPTIONAL_LOCKS=0.
git diff --quiet --no-ext-diff --no-textconv --ignore-submodules >/dev/null 2>&1 || true
# A misbehaving hook: stages a file, then leaves the index locked.
if [[ -n "${STUB_STAGE_LOCK:-}" ]]; then
	printf 'by the hook\n' >staged-by-hook.txt
	git add staged-by-hook.txt
	: >"$(git rev-parse --git-path index).lock"
fi
# A slow hook that stages a file first: the run is interrupted while it sleeps.
if [[ -n "${STUB_SLEEP:-}" ]]; then
	printf 'by the hook\n' >staged-by-hook.txt
	git add staged-by-hook.txt
	touch "${STUB_SLEEP}"
	sleep 20
fi
shift 2
stage="" msg="" files=""
while (($#)); do
	case "$1" in
	--hook-stage) stage="$2"; shift 2 ;;
	--commit-msg-filename) msg="$2"; shift 2 ;;
	--files) files="$2"; shift 2 ;;
	--color=never) shift ;;
	*) exit 99 ;;
	esac
done
[[ "${stage}" == commit-msg && -n "${msg}" ]] || exit 99
# Without --files pre-commit stashes the unstaged changes: the stub refuses to run like that.
[[ "${files}" == "${msg}" ]] || { echo "[WARNING] Unstaged files detected."; echo "[INFO] Stashing unstaged files to x."; exit 98; }
if [[ -n "${STUB_CRASH:-}" ]]; then
	echo "An error has occurred: InvalidConfigError:"
	exit 1
fi
if [[ -n "${STUB_NOHOOK:-}" ]]; then
	echo 'No hook with id `conventional-pre-commit` in stage `commit-msg`'
	exit 1
fi
head -1 "${msg}" >>"${STUB_CALLS}"
if head -1 "${msg}" | grep -qE '^[a-z]+\([a-z0-9-]+\)!?: .+'; then
	echo "Conventional Commit......................................................Passed"
else
	echo "Conventional Commit......................................................Failed"
	echo "::error::injected by the hook output"
	exit 1
fi
STUB
chmod +x "${WORK}/bin/pre-commit"

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
	if "$@"; then ok "${name}"; else not_ok "${name}" "status ${STATUS}${NL}${LOG}${NL}OUTPUT: ${OUTPUT}"; fi
}

git_q() { git -c init.defaultBranch=main -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false "$@"; }
commit() { git_q -C "${REPO}" commit -q --allow-empty -m "$1"; }

# A workspace with the caller repository "caller": a base commit with the hook configured, then
# the commits each case adds. Sets REPO and BASE.
N=0
new_repo() {
	N=$((N + 1))
	CASE="${WORK}/case-${N}"
	REPO="${CASE}/ws/caller"
	mkdir -p "${REPO}" "${CASE}/tmp"
	git_q -C "${REPO}" init -q
	printf 'repos:\n  - repo: https://github.com/compilerla/conventional-pre-commit\n    rev: v4.4.0\n    hooks:\n      - id: conventional-pre-commit\n        stages: [commit-msg]\n' >"${REPO}/.pre-commit-config.yaml"
	git_q -C "${REPO}" add -A
	git_q -C "${REPO}" commit -qm "chore(repo): base"
	BASE="$(git -C "${REPO}" rev-parse HEAD)"
}
# run [ENV=VALUE...]: runs the script from the workspace. Sets STATUS, LOG, OUTPUT, CALLS.
run() {
	: >"${CASE}/output"
	: >"${CASE}/calls"
	STATUS=0
	LOG="$(cd "${CASE}/ws" && env PATH="${WORK}/bin:${PATH}" STUB_CALLS="${CASE}/calls" GITHUB_WORKSPACE="${CASE}/ws" \
		WORKING_DIRECTORY=caller RUNNER_TEMP="${CASE}/tmp" GITHUB_OUTPUT="${CASE}/output" FROM_REF="${BASE}" TO_REF=HEAD "$@" \
		bash "${SCRIPT}" 2>&1)" || STATUS=$?
	OUTPUT="$(cat "${CASE}/output")"
	CALLS="$(cat "${CASE}/calls")"
}

new_repo
commit "feat(api): add a thing"
commit "fix(api)!: drop the old thing"
run
check "good commits pass with exitcode=0" eval '[[ ${STATUS} == 0 && "${OUTPUT}" == exitcode=0 ]] && grep -q "Checked 2 non-merge commit(s)" <<<"${LOG}"'
check "each commit's message goes to the caller's hook at the commit-msg stage" eval '[[ $(grep -c "^CALL run conventional-pre-commit --hook-stage commit-msg --commit-msg-filename " <<<"${CALLS}") == 2 ]] && grep -qx "feat(api): add a thing" <<<"${CALLS}"'
check "the message files are removed" eval '[[ -z "$(ls -A "${CASE}/tmp")" ]]'
check "pre-commit runs with GIT_OPTIONAL_LOCKS=0" eval 'grep -qxF "ENV GIT_OPTIONAL_LOCKS=0" <<<"${CALLS}"'

# Stale stat data: pre-commit's git diff rewrites the index; the run puts its bytes back.
new_repo
commit "feat(api): add a thing"
touch -d '+1 hour' "${REPO}/.pre-commit-config.yaml"
index_before="$(sha256sum <"${REPO}/.git/index")"
run
check "stale stat data in the index: the index is left byte for byte" \
	eval '[[ ${STATUS} == 0 && "$(sha256sum <"${REPO}/.git/index")" == "${index_before}" ]]'
(cd "${REPO}" && git diff --quiet --no-ext-diff --no-textconv --ignore-submodules) || true
check "the case is not vacuous: the same git diff does rewrite the stale index" \
	eval '[[ "$(sha256sum <"${REPO}/.git/index")" != "${index_before}" ]]'

# A hook that stages a file and leaves index.lock: the index cannot be put back, so its copy is
# kept, and the printed command restores it.
new_repo
commit "feat(api): add a thing"
index_before="$(sha256sum <"${REPO}/.git/index")"
run STUB_STAGE_LOCK=1
recovery="$(find "${CASE}/tmp" -maxdepth 2 -path '*conventional-commits-index-recovery.*/index' | head -n1)"
check "an index left locked fails the run and keeps the index copy outside the cleaned-up directory" \
	eval '[[ ${STATUS} == 1 && "${OUTPUT}" == *exitcode=1 && -n "${recovery}" ]] && [[ "$(sha256sum <"${recovery}")" == "${index_before}" ]] && grep -q "index.lock (git may still be writing the index)" <<<"${LOG}"'
cmd="$(sed -n 's/.*restore it with: \(cp -- .*\)$/\1/p' <<<"${LOG}" | head -n1)"
rm -f "${REPO}/.git/index.lock"
(eval "${cmd}") || true
check "the printed command puts the index back byte for byte" \
	eval '[[ -n "${cmd}" && "$(sha256sum <"${REPO}/.git/index")" == "${index_before}" ]] && ! git -C "${REPO}" ls-files --error-unmatch staged-by-hook.txt >/dev/null 2>&1'

# Interrupted while a hook runs after it staged a file: the exit trap puts the index back.
new_repo
commit "feat(api): add a thing"
index_before="$(sha256sum <"${REPO}/.git/index")"
: >"${CASE}/output"
: >"${CASE}/calls"
(cd "${CASE}/ws" && exec setsid env PATH="${WORK}/bin:${PATH}" STUB_CALLS="${CASE}/calls" GITHUB_WORKSPACE="${CASE}/ws" \
	WORKING_DIRECTORY=caller RUNNER_TEMP="${CASE}/tmp" GITHUB_OUTPUT="${CASE}/output" FROM_REF="${BASE}" TO_REF=HEAD \
	STUB_SLEEP="${CASE}/started" bash "${SCRIPT}" >"${CASE}/log" 2>&1) &
pid=$!
for _ in $(seq 100); do [[ -e "${CASE}/started" ]] && break; sleep 0.1; done
kill -TERM -- "-${pid}" 2>/dev/null || true
STATUS=0
wait "${pid}" || STATUS=$?
LOG="$(cat "${CASE}/log")"
OUTPUT="$(cat "${CASE}/output")"
check "an interrupted run puts the index back and removes its temporary directory" \
	eval '[[ -e "${CASE}/started" && ${STATUS} != 0 && "$(sha256sum <"${REPO}/.git/index")" == "${index_before}" && -z "$(ls -A "${CASE}/tmp")" ]]'

new_repo
commit "feat(api): fine"
commit "added stuff"
commit "Also bad: 100% %0A"
run
check "a bad commit fails with exitcode=1" eval '[[ ${STATUS} == 1 && "${OUTPUT}" == exitcode=1 ]] && grep -q "Checked 3 non-merge commit(s)" <<<"${LOG}"'
check "each bad commit gets an annotation with its short SHA and subject, escaped" \
	eval 'grep -qE "^::error::Commit [0-9a-f]+ has a non-conventional message: added stuff$" <<<"${LOG}" && grep -qF "non-conventional message: Also bad: 100%25 %250A" <<<"${LOG}"'

check "the message file is also passed as --files, so pre-commit never stashes" \
	eval '! grep -q "Stashing" <<<"${LOG}" && [[ ${STATUS} == 1 ]]'
check "a workflow command in the hook output is printed inside ::stop-commands::" \
	eval 'awk "/^::stop-commands::/{s=1} /^::error::injected/{exit !s} END{}" <<<"${LOG}" && grep -q "^::stop-commands::[0-9a-f]\{32\}$" <<<"${LOG}"'

new_repo
git_q -C "${REPO}" checkout -qb topic
commit "feat(api): on the topic"
git_q -C "${REPO}" checkout -q main
commit "fix(api): on main"
git_q -C "${REPO}" merge -q --no-ff -m "Merge branch topic" topic
run
check "merge commits are skipped" eval '[[ ${STATUS} == 0 ]] && grep -q "Checked 2 non-merge commit(s)" <<<"${LOG}" && ! grep -q "^Merge" <<<"${CALLS}"'

new_repo
run
check "an empty range checks nothing and passes" eval '[[ ${STATUS} == 0 && "${OUTPUT}" == exitcode=0 ]] && grep -q "Checked 0 non-merge commit(s)" <<<"${LOG}"'

new_repo
commit "feat(api): fine"
run STUB_NOHOOK=1
check "a hook that does not run at the commit-msg stage is an operational error with the fix, not a bad message" \
	eval '[[ ${STATUS} == 1 && "${OUTPUT}" == exitcode=1 ]] && grep -q "does not run at the commit-msg stage. Add stages: \[commit-msg\]" <<<"${LOG}" && ! grep -q "non-conventional message" <<<"${LOG}"'

new_repo
commit "feat(api): fine"
run STUB_CRASH=1
check "pre-commit failing without running the hook (a bad config) is an operational error, not a bad message" \
	eval '[[ ${STATUS} == 1 && "${OUTPUT}" == exitcode=1 ]] && grep -q "pre-commit exited 1 without running the hook" <<<"${LOG}" && ! grep -q "non-conventional message" <<<"${LOG}"'

refused() { # NAME PATTERN [ENV...]
	local name="$1" pattern="$2"
	shift 2
	run "$@"
	if [[ ${STATUS} == 1 && "${OUTPUT}" == exitcode=1 && -z "${CALLS}" ]] && grep -q -- "${pattern}" <<<"${LOG}"; then
		ok "${name}"
	else
		not_ok "${name} (want exit 1, exitcode=1, no hook call, a message matching '${pattern}')" "status ${STATUS}${NL}${LOG}"
	fi
}
new_repo
commit "feat(api): x"
refused "an empty from-ref is refused" "from-ref and to-ref are both required" FROM_REF=
refused "a ref that starts with - is refused" "starts with -" TO_REF=--output=x
refused "a ref that is not a commit is refused, with the fetch-depth hint" "fetch-depth: 0" FROM_REF=nosuchref
refused "an absolute working-directory is refused" "is absolute" WORKING_DIRECTORY=/tmp
refused "a working-directory with .. is refused" "has a .. component" WORKING_DIRECTORY=caller/../caller
refused "a working-directory that does not exist is refused" "is not a directory" WORKING_DIRECTORY=nowhere
refused "an empty working-directory is refused" "working-directory is empty" WORKING_DIRECTORY=
ln -s "${WORK}" "${CASE}/ws/escape"
refused "a working-directory outside the workspace is refused" "outside the workspace" WORKING_DIRECTORY=escape
printf 'repos: []\n' >"${REPO}/.pre-commit-config.yaml"
refused "a caller without the hook is told what to add" "has no conventional-pre-commit hook. Add it with stages: \[commit-msg\]"

# --- the real pre-commit 4.6.2, when it is installed: a local system hook, no download ---------
if command -v pre-commit >/dev/null && [[ "$(command pre-commit --version)" == "pre-commit 4."* ]]; then
	printf '#!/usr/bin/env bash\nhead -1 "$1" | grep -qE "^[a-z]+\\([a-z0-9-]+\\)!?: "\n' >"${WORK}/msgcheck.sh"
	chmod +x "${WORK}/msgcheck.sh"
	real_repo() { # STAGES_LINE
		new_repo
		cat >"${REPO}/.pre-commit-config.yaml" <<EOF2
repos:
  - repo: local
    hooks:
      - id: conventional-pre-commit
        name: Conventional Commit
        language: system
        entry: ${WORK}/msgcheck.sh
$1
EOF2
		git_q -C "${REPO}" add -A
		git_q -C "${REPO}" commit -qm "chore(repo): config"
		BASE="$(git -C "${REPO}" rev-parse HEAD)"
		commit "feat(api): good"
		commit "bad message"
		printf 'tracked\n' >"${REPO}/tracked.txt"
		git_q -C "${REPO}" add tracked.txt
		git_q -C "${REPO}" commit -qm "chore(repo): track a file"
		printf 'unstaged change\n' >"${REPO}/tracked.txt"
	}
	real_run() {
		: >"${CASE}/output"
		STATUS=0
		LOG="$(cd "${CASE}/ws" && env GITHUB_WORKSPACE="${CASE}/ws" WORKING_DIRECTORY=caller RUNNER_TEMP="${CASE}/tmp" \
			GITHUB_OUTPUT="${CASE}/output" FROM_REF="${BASE}" TO_REF=HEAD PRE_COMMIT_HOME="${WORK}/pre-commit-home" \
			bash "${SCRIPT}" 2>&1)" || STATUS=$?
		OUTPUT="$(cat "${CASE}/output")"
	}
	real_repo "        stages: [commit-msg]"
	touch -d '+1 hour' "${REPO}/.pre-commit-config.yaml"
	index_before="$(sha256sum <"${REPO}/.git/index")"
	real_run
	check "real pre-commit: stale stat data in the index, and the index is left byte for byte" \
		eval '[[ "$(sha256sum <"${REPO}/.git/index")" == "${index_before}" ]]'
	check "real pre-commit: a bad message fails and a good one passes" \
		eval '[[ ${STATUS} == 1 ]] && grep -q "non-conventional message: bad message" <<<"${LOG}" && [[ $(grep -c "non-conventional" <<<"${LOG}") == 1 ]]'
	check "real pre-commit: nothing is stashed and the unstaged change is still there" \
		eval '! grep -qi "stash" <<<"${LOG}" && [[ "$(cat "${REPO}/tracked.txt")" == "unstaged change" ]] && [[ -z "$(git -C "${REPO}" stash list)" ]]'
	real_repo "        stages: [pre-commit]"
	real_run
	check "real pre-commit: a hook without stages: [commit-msg] is reported as such" \
		eval '[[ ${STATUS} == 1 ]] && grep -q "does not run at the commit-msg stage" <<<"${LOG}" && ! grep -q "non-conventional" <<<"${LOG}"'
else
	echo "ok - # skip: the real pre-commit 4.x is not installed"
fi

echo
echo "${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
