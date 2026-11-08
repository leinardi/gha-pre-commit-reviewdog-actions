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
# Prints a manifest of a directory tree, one line per path, sorted, so two manifests of the same
# tree taken before and after something ran can be compared with diff:
#
#   <path, shell-quoted> <type and permission bits, as ls -l> <sha256 | -> link target | ->
#
# The CI self-tests use it to check that an action left the caller repository and its own
# checkout exactly as they were. Left out:
#   - the internals of DIR's own .git directory, except .git/index, whose sha256 is listed (an
#     action must never write the real index); a nested repository's .git is listed in full;
#   - with --exclude-ignored, when DIR is the root of a git work tree, every path git ignores
#     there (`git ls-files --others --ignored --exclude-standard --directory`): the caches a hook
#     leaves (.mypy_cache, .ruff_cache) are outside the actions' guarantee.
#
# Usage: scripts/tree-manifest.sh [--exclude-ignored] DIR

set -euo pipefail

usage() {
	echo "Usage: $0 [--exclude-ignored] DIR" >&2
	exit 2
}

exclude_ignored=0
if [[ "${1:-}" == --exclude-ignored ]]; then
	exclude_ignored=1
	shift
fi
[[ $# -eq 1 && -d "$1" ]] || usage
cd "$1"

declare -A ignored=()
if ((exclude_ignored)); then
	top="$(git rev-parse --show-toplevel 2>/dev/null)" || {
		echo "$0: $1 is not in a git work tree, so --exclude-ignored has nothing to read" >&2
		exit 2
	}
	[[ "$(cd "${top}" && pwd -P)" == "$(pwd -P)" ]] || {
		echo "$0: $1 is not the root of its git work tree (${top})" >&2
		exit 2
	}
	while IFS= read -r -d '' path; do
		ignored["${path%/}"]=1
	done < <(GIT_OPTIONAL_LOCKS=0 git ls-files -z --others --ignored --exclude-standard --directory)
fi

# Whether the path, or one of its parent directories, is ignored.
is_ignored() {
	local path="$1"
	while true; do
		[[ -z "${ignored[${path}]:-}" ]] || return 0
		[[ "${path}" == */* ]] || return 1
		path="${path%/*}"
	done
}

entry() {
	local path="$1" rel="${1#./}" mode sum
	if ((${#ignored[@]} > 0)) && is_ignored "${rel}"; then
		return 0
	fi
	mode="$(stat -c %A -- "${path}")"
	case "${mode}" in
	-*)
		sum="$(sha256sum <"${path}")"
		sum="${sum%% *}"
		;;
	l*) sum="-> $(readlink -n -- "${path}")" ;;
	*) sum="-" ;;
	esac
	printf '%q %s %s\n' "${rel}" "${mode}" "${sum}"
}

{
	while IFS= read -r -d '' path; do
		entry "${path}"
	done < <(find . -mindepth 1 -path ./.git -prune -o -print0)
	if [[ -d .git && ! -L .git && -f .git/index ]]; then
		entry ./.git/index
	fi
} | LC_ALL=C sort
