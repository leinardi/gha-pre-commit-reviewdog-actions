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
# Tests for tree-manifest.sh with real git in a temporary repository: the manifest is stable, it
# changes for every kind of change the CI self-tests must catch (content, permission bits, a new
# or removed path, a symlink target, a file turned into a directory, the real index file), and it
# leaves out what it says it leaves out (DIR's own .git internals other than the index; with
# --exclude-ignored, ignored paths), while a nested repository is listed in full.
#
# Run: bash scripts/tree-manifest.test.sh

set -euo pipefail
umask 022

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${HERE}/tree-manifest.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

PASS=0
FAIL=0
ok() {
	PASS=$((PASS + 1))
	echo "ok - $1"
}
not_ok() {
	FAIL=$((FAIL + 1))
	echo "not ok - $1"
}

# A fresh repository with a little of everything.
setup() {
	REPO="${WORK}/repo"
	rm -rf -- "${REPO}"
	mkdir -p -- "${REPO}/dir"
	git -C "${REPO}" init -q -b main
	printf 'a\n' >"${REPO}/a.txt"
	printf 'run\n' >"${REPO}/run.sh"
	chmod +x "${REPO}/run.sh"
	printf 'spaced\n' >"${REPO}/dir/with space.txt"
	printf 'newline\n' >"${REPO}/dir/new"$'\n'"line.txt"
	ln -s a.txt "${REPO}/link"
	printf 'cache/\n' >"${REPO}/.gitignore"
	git -C "${REPO}" add -A
	git -C "${REPO}" commit -q -m base
	mkdir -p -- "${REPO}/cache" "${REPO}/nested"
	printf 'ignored\n' >"${REPO}/cache/blob"
	git -C "${REPO}/nested" init -q -b main
	printf 'nested\n' >"${REPO}/nested/n.txt"
	git -C "${REPO}/nested" add -A
	git -C "${REPO}/nested" commit -q -m nested
}

manifest() {
	"${MANIFEST}" "$@"
}

# Each case: a change, and whether the manifest (with --exclude-ignored) must differ.
check() {
	local name="$1" want="$2" change="$3" before after
	setup
	before="$(manifest --exclude-ignored "${REPO}")"
	(cd "${REPO}" && eval "${change}")
	after="$(manifest --exclude-ignored "${REPO}")"
	if [[ "${want}" == differs && "${before}" != "${after}" ]] ||
		[[ "${want}" == same && "${before}" == "${after}" ]]; then
		ok "${name}: ${want}"
	else
		not_ok "${name}: expected the manifest to be ${want}"
		diff <(echo "${before}") <(echo "${after}") || true
	fi
}

check "no change" same ":"
check "a git command that only reads" same "git log -1 >/dev/null; git ls-files -s >/dev/null"
check "content" differs "printf 'b\n' >a.txt"
check "permission bits" differs "chmod 600 a.txt"
check "the executable bit" differs "chmod -x run.sh"
check "a new untracked file" differs "printf 'x\n' >new.txt"
check "a removed file" differs "rm a.txt"
check "a new empty directory" differs "mkdir empty"
check "a symlink target" differs "ln -sfn run.sh link"
check "a file turned into a directory" differs "rm a.txt && mkdir a.txt"
check "a name with a newline" differs "printf 'changed\n' >\"dir/new\"\$'\n'\"line.txt\""
check "the real index" differs "git update-index --chmod=-x run.sh"
check "a staged change" differs "printf 'b\n' >a.txt && git add a.txt"
check "a nested repository's file" differs "printf 'changed\n' >nested/n.txt"
check "a nested repository's index" differs "git -C nested update-index --chmod=+x n.txt"
check "an ignored file, with --exclude-ignored" same "printf 'changed\n' >cache/blob && printf 'new\n' >cache/new"
check "a .git internal other than the index" same "git tag t1 && git config core.foo bar"

# Without --exclude-ignored, ignored paths are listed.
setup
before="$(manifest "${REPO}")"
printf 'changed\n' >"${REPO}/cache/blob"
after="$(manifest "${REPO}")"
if [[ "${before}" != "${after}" ]]; then
	ok "an ignored file, without --exclude-ignored: differs"
else
	not_ok "an ignored file, without --exclude-ignored: expected the manifest to differ"
fi

# The listing itself: the index by sha256, a symlink by target, quoted names, no .git internals.
setup
listing="$(manifest --exclude-ignored "${REPO}")"
index_sum="$(sha256sum <"${REPO}/.git/index")"
expect_line() {
	if grep -qxF -- "$2" <<<"${listing}"; then
		ok "lists $1"
	else
		not_ok "lists $1: no line '$2' in"$'\n'"${listing}"
	fi
}
expect_line "the index" ".git/index -rw-r--r-- ${index_sum%% *}"
expect_line "a symlink by target" "link lrwxrwxrwx -> a.txt"
expect_line "a name with a space, quoted" 'dir/with\ space.txt -rw-r--r-- '"$(sha256sum <"${REPO}/dir/with space.txt" | cut -d' ' -f1)"
expect_line "a directory" "dir drwxr-xr-x -"
if grep -q '^\.git/' <<<"${listing}" && [[ "$(grep -c '^\.git/' <<<"${listing}")" -eq 1 ]]; then
	ok "lists no .git internal but the index"
else
	not_ok "lists no .git internal but the index"
fi
if grep -q '^nested/\.git/HEAD ' <<<"${listing}"; then
	ok "lists a nested repository's .git in full"
else
	not_ok "lists a nested repository's .git in full"
fi
if ! grep -q '^cache' <<<"${listing}"; then
	ok "--exclude-ignored leaves out an ignored directory"
else
	not_ok "--exclude-ignored leaves out an ignored directory"
fi

# Refusals.
if ! manifest --exclude-ignored "${REPO}/dir" >/dev/null 2>&1; then
	ok "--exclude-ignored refuses a directory that is not a work tree root"
else
	not_ok "--exclude-ignored refuses a directory that is not a work tree root"
fi
if ! manifest "${WORK}/missing" >/dev/null 2>&1; then
	ok "refuses a missing directory"
else
	not_ok "refuses a missing directory"
fi

echo "${PASS} passed, ${FAIL} failed"
((FAIL == 0))
