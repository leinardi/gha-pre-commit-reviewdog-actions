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
# Tests for snapshot.sh with real git in temporary repositories, no stubs. Every case starts from
# the same state, laid out as the CI self-tests are: a workspace with this action's checkout at
# self/ and the caller repository at caller/ (siblings, never nested), and in caller/ every kind
# of path at once: a staged change, an unstaged change on top of a staged one, an untracked and an
# ignored file, an unstaged and a staged deletion, an executable, a symlink, a CRLF file, a binary,
# a file under an LFS-style clean filter, names with spaces and newlines, a checked-out submodule,
# a gitlink whose directory is empty and a nested repository. A "hook" (a shell function) then
# changes the worktree, and the case checks that restore and verify bring back, byte for byte:
# every path's type, permission bits and content (ignored files, the submodule's files and the
# nested repository included), git status, the staged diff, the index entries, the sha256 of the
# real index file and of the submodule's, the repository's object store and config, and self/.
#
# The orchestration failure paths (a hook exiting nonzero, a converter or reviewdog failing, TERM
# mid-pass, and a failed restore stopping the next pass) are in run-passes.test.sh, which drives
# this library through the real run.
#
# Run: bash lib/snapshot.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${HERE}/snapshot.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

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

# Sources the library under test into the current (sub)shell.
load_lib() {
	# shellcheck source=SCRIPTDIR/snapshot.sh
	source "${LIB}"
}

git_q() { git -c init.defaultBranch=main -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false "$@"; }

NL=$'\n'
NEWLINE_NAME="new${NL}line.txt"

# A fresh workspace for one case. Sets WS, REPO, SELF, OUTSIDE, SNAPWORK.
N=0
fresh() {
	N=$((N + 1))
	WS="${WORK}/case-${N}/ws"
	REPO="${WS}/caller"
	SELF="${WS}/self"
	OUTSIDE="${WORK}/case-${N}/outside"
	SNAPWORK="${WORK}/case-${N}/snap"
	mkdir -p "${REPO}" "${SELF}" "${OUTSIDE}/sub" "${SNAPWORK}"
	printf 'outside\n' >"${OUTSIDE}/f"
	printf 'outside deep\n' >"${OUTSIDE}/sub/deep.txt"
	(
		cd "${SELF}"
		git_q init -q .
		printf 'the action\n' >action.yaml
		git_q add -A
		git_q commit -qm self
		printf 'the action, v2\n' >action.yaml
		git_q commit -qam 'self v2'
	)
	(
		cd "${REPO}"
		git_q init -q .
		git config filter.x.clean 'sed "s/^/CLEAN:/"'
		git config filter.x.smudge cat
		printf '*.log\nsub3\n' >.gitignore
		printf '*.lfs filter=x\ncrlf.txt -text\n' >.gitattributes
		printf 'a\n' >a.txt
		printf 'staged\n' >staged.txt
		printf 'both\n' >both.txt
		printf 'del unstaged\n' >del-unstaged.txt
		printf 'del staged\n' >del-staged.txt
		printf '#!/bin/sh\necho hi\n' >exec.sh
		chmod 755 exec.sh
		chmod 600 staged.txt
		ln -s a.txt link
		printf 'one\r\ntwo\r\n' >crlf.txt
		printf '\x00\x01\x02binary\xff\n' >bin.dat
		printf 'raw lfs content\n' >big.lfs
		printf 'space\n' >'sp ace.txt'
		printf 'newline\n' >"${NEWLINE_NAME}"
		mkdir -p dir/sub tofile sub2 sub3
		printf 'deep\n' >dir/sub/deep.txt
		printf 'inner\n' >tofile/inner.txt
		printf 'file\n' >filedir
		printf 'f2\n' >sub2/f
		printf 'f3\n' >sub3/f
		git_q add -A
		git_q add -f sub3/f
		git_q commit -qm base
		# A real submodule (a checkout of self/ over a file:// URL), and a gitlink whose checkout
		# directory is empty.
		git_q -c protocol.file.allow=always submodule --quiet add "file://${SELF}" sub >/dev/null 2>&1
		git_q commit -qm submodule
		git update-index --add --cacheinfo "160000,$(git -C "${SELF}" rev-parse HEAD),gl"
		mkdir gl
		printf 'staged change\n' >staged.txt
		git add staged.txt
		printf 'both staged\n' >both.txt
		git add both.txt
		printf 'both staged and unstaged\n' >>both.txt
		rm del-unstaged.txt
		git rm -q del-staged.txt
		printf 'untracked\n' >untracked.txt
		printf 'ignored\n' >ignored.log
		mkdir nested
		git_q -C nested init -q .
		printf 'nested\n' >nested/n.txt
		git_q -C nested add -A
		git_q -C nested commit -qm nested
	)
	[[ -z "${FRESH_EXTRA:-}" ]] || "${FRESH_EXTRA}"
}

# FRESH_EXTRA for the nested-submodule cases: a submodule inside the submodule sub/, staged there.
nested_submodule() {
	local src="${WORK}/case-${N}/inner-src"
	git_q init -q "${src}"
	printf 'inner\n' >"${src}/inner.txt"
	git_q -C "${src}" add -A
	git_q -C "${src}" commit -qm inner
	git_q -C "${REPO}/sub" -c protocol.file.allow=always submodule --quiet add "file://${src}" inner >/dev/null 2>&1
}

# Every path under $1 except its top .git: type, permission bits, content hash or link target.
tree_manifest() {
	(
		cd "$1"
		find . -path ./.git -prune -o -print0 | LC_ALL=C sort -z | while IFS= read -r -d '' p; do
			if [[ -L "${p}" ]]; then
				printf '%q L %s\n' "${p}" "$(readlink -- "${p}")"
			elif [[ -d "${p}" ]]; then
				printf '%q D %s\n' "${p}" "$(stat -c %a -- "${p}")"
			else
				printf '%q F %s %s\n' "${p}" "$(stat -c %a -- "${p}")" "$(sha256sum <"${p}" | cut -c1-64)"
			fi
		done
	)
}

# The full before/after record of a case.
manifest() {
	tree_manifest "${REPO}"
	echo "-- git"
	(
		cd "${REPO}"
		echo "index $(sha256sum <.git/index | cut -c1-64)"
		echo "config $(sha256sum <.git/config | cut -c1-64)"
		echo "objects $(find .git/objects -type f | LC_ALL=C sort | sha256sum | cut -c1-64)"
		echo "status $(GIT_OPTIONAL_LOCKS=0 git status --porcelain=v2 -z | sha256sum | cut -c1-64)"
		echo "cached $(GIT_OPTIONAL_LOCKS=0 git diff --cached --binary | sha256sum | cut -c1-64)"
		echo "stage $(git ls-files -s -z | sha256sum | cut -c1-64)"
		echo "submodule index $(sha256sum <.git/modules/sub/index | cut -c1-64)"
		if [[ -f .git/modules/sub/modules/inner/index ]]; then
			echo "inner submodule index $(sha256sum <.git/modules/sub/modules/inner/index | cut -c1-64)"
		fi
	)
	echo "-- self"
	tree_manifest "${SELF}"
	echo "self index $(sha256sum <"${SELF}/.git/index" | cut -c1-64)"
	echo "-- outside"
	tree_manifest "${OUTSIDE}"
}

# case NAME EXPECT HOOK: from a fresh workspace, takes T0, runs the hook function in caller/,
# takes T1, restores and verifies. EXPECT is "restored" (restore and verify succeed and the
# manifest is unchanged) or "stopped" (restore or verify fails, the outside directory and self/
# are untouched, and the failed paths are listed). Sets RESULT, ERR, FAILED, T0, T1.
run_case() {
	local title="$1" expect="$2" hookfn="$3" before after
	fresh
	before="$(manifest)"
	RESULT="$(
		cd "${REPO}"
		load_lib
		snap_init "${SNAPWORK}" "${REPO}" || { echo "init-failed ${SNAP_ERROR}"; exit 0; }
		snap_take t0 || { echo "t0-failed ${SNAP_ERROR}"; exit 0; }
		"${hookfn}"
		cd "${REPO}"
		snap_take t1 || { echo "t1-failed ${SNAP_ERROR}"; exit 0; }
		snap_restore t0 t1 || { echo "restore-failed ${SNAP_ERROR}"; exit 0; }
		if ! snap_same t0 t1; then
			snap_verify t0 || { echo "verify-failed ${SNAP_ERROR}"; exit 0; }
		fi
		echo restored
	)"
	after="$(manifest)"
	FAILED="$(cat "${SNAPWORK}/failed-paths" 2>/dev/null || true)"
	T0="$(cat "${SNAPWORK}/t0.tree" 2>/dev/null || true)"
	T1="$(cat "${SNAPWORK}/t1.tree" 2>/dev/null || true)"
	case "${expect}" in
	restored)
		if [[ "${RESULT}" == restored && "${after}" == "${before}" ]]; then
			ok "${title}: restored byte for byte"
		else
			not_ok "${title}: restored byte for byte" "result: ${RESULT}
$(diff <(echo "${before}") <(echo "${after}") || true)"
		fi
		;;
	stopped)
		local outside_before outside_after
		outside_before="$(sed -n '/^-- self$/,$p' <<<"${before}")"
		outside_after="$(sed -n '/^-- self$/,$p' <<<"${after}")"
		if [[ "${RESULT}" == restore-failed* && -n "${FAILED}" && "${outside_after}" == "${outside_before}" ]]; then
			ok "${title}: restore stops, lists the path, and nothing outside the root changed"
		else
			not_ok "${title}: restore stops, lists the path, and nothing outside the root changed" "result: ${RESULT}
failed: ${FAILED}
$(diff <(echo "${outside_before}") <(echo "${outside_after}") || true)"
		fi
		;;
	esac
}

snap_git_case() {
	(
		cd "${REPO}"
		load_lib
		SNAP_WORK="${SNAPWORK}"
		SNAP_ROOT="${REPO}"
		SNAP_REPO_OBJECTS="${REPO}/.git/objects"
		snap_git "$@"
	)
}

# --- hooks --------------------------------------------------------------------------------------

hook_none() { :; }
hook_modify() {
	printf 'A\n' >a.txt
	printf 'hook\n' >>both.txt
	printf 'staged change by hook\n' >staged.txt
	printf 'one\ntwo\n' >crlf.txt
	printf '\x00changed\n' >bin.dat
	printf 'changed lfs\n' >big.lfs
	printf 'changed\n' >'sp ace.txt'
	printf 'changed\n' >"${NEWLINE_NAME}"
	printf 'changed\n' >untracked.txt
}
hook_create() {
	printf 'new\n' >new.txt
	mkdir -p newdir/a/b 'new dir'
	printf 'c\n' >newdir/a/b/c.txt
	printf 'x\n' >'new dir/x y'
	printf 'nl\n' >"newdir/${NEWLINE_NAME}"
	ln -s a.txt newlink
	printf 'restored file\n' >del-unstaged.txt
}
hook_delete() {
	rm a.txt link untracked.txt "${NEWLINE_NAME}"
	rm -r dir
}
hook_chmod() {
	chmod 755 a.txt
	chmod 644 exec.sh
	chmod 640 staged.txt
}
hook_file_to_dir() {
	rm filedir
	mkdir filedir
	printf 'b\n' >filedir/b
}
hook_dir_to_file() {
	rm -r tofile
	printf 'now a file\n' >tofile
}
hook_symlink_out() {
	rm a.txt
	ln -s "${OUTSIDE}/f" a.txt
	rm link
	ln -s "${OUTSIDE}" link
}
hook_parent_link() {
	rm -r sub2
	ln -s "${OUTSIDE}" sub2
}
hook_ignored_parent_link() {
	rm -r sub3
	ln -s "${OUTSIDE}" sub3
}
hook_ignored_leftover() {
	mkdir made
	printf 'new\n' >made/new.txt
	printf 'junk\n' >made/junk.log
}
hook_nested() {
	printf 'changed in nested\n' >nested/n.txt
	printf 'ignored\n' >>ignored.log
}
hook_unignore() {
	printf 'sub3\n' >.gitignore
}
hook_unrepo_nested() {
	rm -rf nested/.git
}
hook_sub_remove() {
	rm -rf sub
}
hook_sub_checkout() {
	git -C sub checkout -q HEAD~1
}
hook_sub_to_file() {
	rm -rf sub
	printf 'not a submodule\n' >sub
}
hook_sub_content() {
	printf 'overwritten by the hook\n' >sub/action.yaml
	printf 'new\n' >sub/new.txt
	chmod 600 sub/.gitmodules 2>/dev/null || true
}
hook_inner_content() {
	printf 'overwritten\n' >sub/inner/inner.txt
	printf 'new\n' >sub/inner/new.txt
}
# Stale stat data, which pre-commit's own `git diff` refreshes: the index is rewritten even with
# GIT_OPTIONAL_LOCKS=0. The marker file proves the hook did rewrite it.
hook_stale_index() {
	local before
	before="$(sha256sum <.git/index)"
	touch -d '+1 hour' a.txt sub/action.yaml
	GIT_OPTIONAL_LOCKS=0 git diff --quiet --no-ext-diff -- a.txt || true
	GIT_OPTIONAL_LOCKS=0 git -C sub diff --quiet --no-ext-diff || true
	[[ "$(sha256sum <.git/index)" == "${before}" ]] || touch "${WORK}/index-rewritten"
}
# Staging that writes no object (the object store is in the manifest too).
hook_stage() {
	git rm -q --cached a.txt
	git update-index --chmod=+x staged.txt
}
hook_index_lock() {
	printf 'A\n' >a.txt
	: >.git/index.lock
}
hook_gitlink_dir_content() {
	printf 'not a checkout\n' >gl/f
}
hook_unicode() {
	printf 'new\n' >'caffè ü.txt'
	printf 'A\n' >a.txt
}
hook_everything() {
	hook_modify
	hook_create
	hook_chmod
	hook_file_to_dir
	hook_dir_to_file
	hook_symlink_out
	hook_parent_link
	rm exec.sh
}

# --- cases --------------------------------------------------------------------------------------

run_case "no change" restored hook_none
if [[ "${T0}" == "${T1}" ]]; then ok "no change: T1 equals T0"; else not_ok "no change: T1 equals T0" "${T0} ${T1}"; fi
tree0="$(snap_git_case ls-tree -r -z "${T0}" | tr '\0' '\n')"
want_absent() {
	local what="$1" path="$2"
	if ! grep -qF "	${path}" <<<"${tree0}"; then ok "the snapshot leaves out ${what}"; else not_ok "the snapshot leaves out ${what}" "${tree0}"; fi
}
want_present() {
	local what="$1" line="$2"
	if grep -qxF -- "${line}" <<<"${tree0}"; then ok "the snapshot records ${what}"; else not_ok "the snapshot records ${what}" "${tree0}"; fi
}
want_absent "the ignored file" ignored.log
want_absent "the unstaged deletion" del-unstaged.txt
want_absent "the staged deletion" del-staged.txt
want_absent "the nested repository" nested
want_present "the real submodule's gitlink" "160000 commit $(git -C "${SELF}" rev-parse HEAD)	sub"
want_present "the gitlink as the index has it" "160000 commit $(git -C "${SELF}" rev-parse HEAD)	gl"
want_present "the executable as 100755" "100755 blob $(git -C "${REPO}" hash-object --no-filters exec.sh)	exec.sh"
want_present "the symlink as 120000" "120000 blob $(printf 'a.txt' | git -C "${REPO}" hash-object --stdin)	link"
want_present "the untracked file" "100644 blob $(git -C "${REPO}" hash-object --no-filters untracked.txt)	untracked.txt"
want_present "the worktree side of a staged+unstaged file" "100644 blob $(git -C "${REPO}" hash-object --no-filters both.txt)	both.txt"
if [[ "$(snap_git_case cat-file blob "${T0}:big.lfs")" == "raw lfs content" ]]; then
	ok "the snapshot stores the bytes on disk, not the clean filter's output"
else
	not_ok "the snapshot stores the bytes on disk, not the clean filter's output" "$(snap_git_case cat-file blob "${T0}:big.lfs")"
fi
if [[ "$(snap_git_case cat-file blob "${T0}:crlf.txt" | od -An -c | tr -d ' \n')" == 'one\r\ntwo\r\n' ]]; then
	ok "the snapshot keeps CRLF line endings"
else
	not_ok "the snapshot keeps CRLF line endings"
fi
if [[ "$(tr '\0' '\n' <"${SNAPWORK}/t0.nested")" == nested ]]; then ok "the nested repository is listed for the notice"; else not_ok "the nested repository is listed for the notice"; fi
if [[ "$(tr '\0' '\n' <"${SNAPWORK}/t0.perms" | grep 'staged.txt$')" == "600	staged.txt" ]]; then
	ok "the permission bits are recorded"
else
	not_ok "the permission bits are recorded" "$(tr '\0' '\n' <"${SNAPWORK}/t0.perms")"
fi
if ! grep -q 'self' <<<"${tree0}"; then ok "the sibling self/ checkout is not in the caller's snapshot"; else not_ok "the sibling self/ checkout is not in the caller's snapshot"; fi

run_case "modify (staged, unstaged, CRLF, binary, LFS-filtered, spaces, newlines)" restored hook_modify
run_case "create (in new directories too, a symlink, an unstaged deletion undone)" restored hook_create
run_case "delete (files, a symlink, a directory tree, a newline name)" restored hook_delete
run_case "chmod (mode-only changes, and permission bits beyond the exec bit)" restored hook_chmod
run_case "file -> directory" restored hook_file_to_dir
if grep -q $'^:100644 000000 [0-9a-f]* 0\\{40\\} D$' <(tr '\0' '\n' <"${SNAPWORK}/plan") && tr '\0' '\n' <"${SNAPWORK}/plan" | grep -qx 'filedir/b'; then
	ok "file -> directory: the plan is D filedir, A filedir/b"
else
	not_ok "file -> directory: the plan is D filedir, A filedir/b" "$(tr '\0' '\n' <"${SNAPWORK}/plan")"
fi
run_case "directory -> file" restored hook_dir_to_file
run_case "a file and a symlink replaced by symlinks out of the root" restored hook_symlink_out
run_case "a parent directory replaced by a symlink out of the root (the link is the hook's: removed, never followed)" restored hook_parent_link
run_case "an ignored parent replaced by a symlink out of the root" stopped hook_ignored_parent_link
if grep -q '^sub3/f: its parent sub3 is a symlink$' <<<"${FAILED}"; then ok "the symlinked parent is named in the failed paths"; else not_ok "the symlinked parent is named in the failed paths" "${FAILED}"; fi
run_case "a hook-created directory left with ignored content" stopped hook_ignored_leftover
if grep -q '^made: a directory the hook created still holds' <<<"${FAILED}" && [[ -f "${REPO}/made/junk.log" ]]; then
	ok "the leftover directory is named and nothing in it is removed recursively"
else
	not_ok "the leftover directory is named and nothing in it is removed recursively" "${FAILED}"
fi
run_case "changes inside the nested repository and to ignored files are outside the snapshot" restored hook_none
fresh
before_nested="$(cd "${REPO}" && load_lib && snap_init "${SNAPWORK}" "${REPO}" && snap_take t0 && hook_nested && snap_take t1 && echo "$(<"${SNAPWORK}/t0.tree") $(<"${SNAPWORK}/t1.tree")")"
if [[ "${before_nested% *}" == "${before_nested#* }" ]]; then
	ok "a change inside the nested repository or to an ignored file leaves T1 equal to T0"
else
	not_ok "a change inside the nested repository or to an ignored file leaves T1 equal to T0" "${before_nested}"
fi
run_case "everything at once" restored hook_everything
run_case "a non-ASCII file name" restored hook_unicode
if snap_git_case diff --name-only "${T0}" "${T1}" | grep -qxF 'caffè ü.txt'; then
	ok "paths are printed raw (core.quotePath=false), not octal-quoted"
else
	not_ok "paths are printed raw (core.quotePath=false), not octal-quoted" "$(snap_git_case diff --name-only "${T0}" "${T1}")"
fi

run_case "a hook that un-ignores a pre-existing ignored file (by editing .gitignore)" stopped hook_unignore
if [[ -f "${REPO}/ignored.log" ]] && grep -q '^ignored.log: it existed before the pass' <<<"${FAILED}"; then
	ok "the un-ignored file is never unlinked as if the hook had added it"
else
	not_ok "the un-ignored file is never unlinked as if the hook had added it" "${FAILED}"
fi
run_case "a hook that removes a nested repository's .git" stopped hook_unrepo_nested
if [[ -f "${REPO}/nested/n.txt" ]] && grep -q '^nested/n.txt: it existed before the pass' <<<"${FAILED}"; then
	ok "the nested repository's files are never unlinked"
else
	not_ok "the nested repository's files are never unlinked" "${FAILED}"
fi
run_case "a hook that deletes a submodule checkout" stopped hook_sub_remove
if grep -q '^sub: the submodule changed on disk (was: checkout [0-9a-f]*; now: absent)' <<<"${FAILED}"; then ok "the deleted submodule is named"; else not_ok "the deleted submodule is named" "${FAILED}"; fi
run_case "a hook that moves a submodule to another commit" stopped hook_sub_checkout
run_case "a hook that replaces a submodule with a file" stopped hook_sub_to_file
if grep -q 'now: not-a-directory' <<<"${FAILED}"; then ok "the replaced submodule is named"; else not_ok "the replaced submodule is named" "${FAILED}"; fi
run_case "a hook that changes files inside a submodule checkout" restored hook_sub_content
if [[ "$(<"${SNAPWORK}/t0.subs" tr '\0' '\n')" == *$'\tsub' ]] && ! cmp -s "${SNAPWORK}/t0.subs" "${SNAPWORK}/t1.subs"; then
	ok "the submodule's content is part of the snapshot"
else
	not_ok "the submodule's content is part of the snapshot" "$(tr '\0' '\n' <"${SNAPWORK}/t0.subs")"
fi
FRESH_EXTRA=nested_submodule run_case "a hook that changes files inside a submodule of a submodule" restored hook_inner_content
sub_work="${SNAPWORK}/sub/$(printf sub | sha1sum | cut -c1-40)"
if [[ "$(tr '\0' '\n' <"${sub_work}/t0.subs")" == *$'\tinner' ]] && ! cmp -s "${sub_work}/t0.subs" "${sub_work}/t1.subs"; then
	ok "the submodule of the submodule has its own snapshot, and the hook changed it"
else
	not_ok "the submodule of the submodule has its own snapshot, and the hook changed it" "$(find "${SNAPWORK}/sub" -maxdepth 2 2>&1 | head -20)"
fi
diff_out="${WORK}/case-${N}/inner.diff"
result="$(cd "${REPO}" && load_lib && snap_init "${SNAPWORK}" "${REPO}" && { snap_diff t0 t1 "${diff_out}" && echo diffed || echo "${SNAP_ERROR}"; })"
if [[ "${result}" == diffed ]] && grep -qxF "diff --git a/sub/inner/inner.txt b/sub/inner/inner.txt" "${diff_out}" &&
	grep -qxF "+++ b/sub/inner/new.txt" "${diff_out}" && [[ "$(grep -c '^diff --git' "${diff_out}")" == 2 ]]; then
	ok "snap_diff includes a submodule's changes, recursively, under the submodule's path"
else
	not_ok "snap_diff includes a submodule's changes, recursively, under the submodule's path" "${result}${NL}$(cat "${diff_out}" 2>&1)"
fi
rm -f "${WORK}/index-rewritten"
run_case "stale stat data that a refresh rewrites in the index and a submodule's index" restored hook_stale_index
if [[ -f "${WORK}/index-rewritten" ]]; then ok "the refresh did rewrite the index (the case is not vacuous)"; else not_ok "the refresh did rewrite the index (the case is not vacuous)"; fi
run_case "a hook that stages and unstages" restored hook_stage
run_case "a hook that leaves index.lock" stopped hook_index_lock
if grep -q 'index.lock: the hooks left the index locked' <<<"${FAILED}" && [[ -f "${REPO}/.git/index.lock" ]]; then
	ok "the lock is named and left alone"
else
	not_ok "the lock is named and left alone" "${FAILED}"
fi
run_case "a hook that writes into a gitlink directory that is not a checkout" stopped hook_gitlink_dir_content
if grep -q '^gl: the submodule changed on disk (was: directory; now: directory with content' <<<"${FAILED}"; then
	ok "the gitlink directory is named"
else
	not_ok "the gitlink directory is named" "${FAILED}"
fi

# Fail closed before any hook: a tracked path replaced by a fifo.
fresh
rm "${REPO}/a.txt"
mkfifo "${REPO}/a.txt"
result="$(cd "${REPO}" && load_lib && snap_init "${SNAPWORK}" "${REPO}" && { snap_take t0 && echo taken || echo "${SNAP_ERROR}"; })"
if [[ "${result}" == *"a.txt is not a regular file, symlink or directory"* ]]; then
	ok "a fifo fails the snapshot closed"
else
	not_ok "a fifo fails the snapshot closed" "${result}"
fi

# A hook that leaves a fifo where a tracked file was: T1 cannot be taken, so the run must stop.
fresh
result="$(cd "${REPO}" && load_lib && snap_init "${SNAPWORK}" "${REPO}" && snap_take t0 && rm a.txt && mkfifo a.txt && { snap_take t1 && echo taken || echo "${SNAP_ERROR}"; })"
if [[ "${result}" == *"is not a regular file"* ]]; then ok "a fifo left by a hook fails the after-snapshot"; else not_ok "a fifo left by a hook fails the after-snapshot" "${result}"; fi

# Verify catches a restore that did not put the tree back.
fresh
result="$(
	cd "${REPO}" && load_lib && snap_init "${SNAPWORK}" "${REPO}" && snap_take t0
	printf 'drift\n' >a.txt
	if snap_verify t0; then echo verified; else echo "${SNAP_ERROR}"; fi
)"
if [[ "${result}" == "verify: the worktree after restore"* ]] && grep -q '^a.txt: differs' "${SNAPWORK}/failed-paths"; then
	ok "verify fails and names the path when the tree differs from T0"
else
	not_ok "verify fails and names the path when the tree differs from T0" "${result}"
fi

# recover.sh rebuilds T0 from the snapshot alone, a submodule's content (an unstaged change in it
# too) from the submodule's own snapshot.
fresh
printf 'changed in the submodule\n' >"${REPO}/sub/action.yaml"
(cd "${REPO}" && load_lib && snap_init "${SNAPWORK}" "${REPO}" && snap_take t0 >/dev/null)
result="$(bash "${HERE}/recover.sh" "${SNAPWORK}" "${WORK}/case-${N}/recovered" 2>&1)" || result="failed: ${result}"
if cmp -s "${REPO}/sub/action.yaml" "${WORK}/case-${N}/recovered/sub/action.yaml" &&
	cmp -s "${REPO}/a.txt" "${WORK}/case-${N}/recovered/a.txt" && [[ -d "${WORK}/case-${N}/recovered/gl" ]]; then
	ok "recover.sh recreates the files, and a submodule's from its own snapshot"
else
	not_ok "recover.sh recreates the files, and a submodule's from its own snapshot" "${result}"
fi

# recover.sh on a SHA-256 repository, and on a snapshot whose tree it cannot list.
sha256_case="${WORK}/sha256"
mkdir -p "${sha256_case}/snap"
git_q init -q --object-format=sha256 "${sha256_case}/repo"
printf 'sha256 content\n' >"${sha256_case}/repo/a.txt"
git_q -C "${sha256_case}/repo" add -A
git_q -C "${sha256_case}/repo" commit -qm base
printf 'untracked\n' >"${sha256_case}/repo/u.txt"
result="$(cd "${sha256_case}/repo" && load_lib && snap_init "${sha256_case}/snap" "${sha256_case}/repo" && snap_take t0 && echo taken || echo "${SNAP_ERROR}")"
rc=0
out="$(bash "${HERE}/recover.sh" "${sha256_case}/snap" "${sha256_case}/recovered" 2>&1)" || rc=$?
if [[ "${result}" == taken && ${rc} == 0 ]] && cmp -s "${sha256_case}/repo/a.txt" "${sha256_case}/recovered/a.txt" &&
	cmp -s "${sha256_case}/repo/u.txt" "${sha256_case}/recovered/u.txt" && [[ "${out}" == *"recreated 2 path(s)"* ]]; then
	ok "recover.sh recreates a SHA-256 repository's snapshot"
else
	not_ok "recover.sh recreates a SHA-256 repository's snapshot" "${result}${NL}${out}"
fi
printf '%s\n' "$(printf '0%.0s' $(seq 64))" >"${sha256_case}/snap/t0.tree"
rc=0
out="$(bash "${HERE}/recover.sh" "${sha256_case}/snap" "${sha256_case}/recovered-2" 2>&1)" || rc=$?
if [[ ${rc} != 0 && "${out}" == *"cannot list tree"* ]]; then
	ok "recover.sh fails when it cannot list the tree, never 'recreated 0 paths'"
else
	not_ok "recover.sh fails when it cannot list the tree, never 'recreated 0 paths'" "status ${rc}${NL}${out}"
fi

# The private store holds only what the repository lacks, and the repository's store is untouched.
fresh
objects_before="$(find "${REPO}/.git/objects" -type f | LC_ALL=C sort)"
(cd "${REPO}" && load_lib && snap_init "${SNAPWORK}" "${REPO}" && snap_take t0 && hook_modify && snap_take t1 >/dev/null)
if [[ "$(find "${REPO}/.git/objects" -type f | LC_ALL=C sort)" == "${objects_before}" && -n "$(find "${SNAPWORK}/objects" -type f)" ]]; then
	ok "snapshots write only to the private object store"
else
	not_ok "snapshots write only to the private object store"
fi

echo
echo "${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
