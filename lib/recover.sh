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
# Recreates the worktree a pass started from, byte for byte, out of a recovery directory that
# run-passes.sh left behind when a restore failed. run-passes.sh copies this script into the
# recovery directory, so it works after the action's checkout is gone.
#
# Usage: recover.sh RECOVERY_DIR DEST
#   RECOVERY_DIR  holds objects/ (the private object store), t0.tree (the tree id), t0.perms (the
#                 permission bits) and repo-objects (the path of the repository's own object
#                 store, used as an alternate for the objects the repository already had), and
#                 object-format (sha1 or sha256; without it, the tree id's length decides)
#   DEST          a directory that does not exist yet, or an empty one
#
# Unlike `git archive`, nothing in .gitattributes applies: no export-ignore, no export-subst, no
# eol conversion, no smudge filter. Every regular file gets the exact bytes and permission bits of
# the snapshot, every symlink its exact target. A gitlink (submodule) becomes a directory, filled
# from the submodule's own snapshot in RECOVERY_DIR/sub/<sha1 of its path> when the run took one
# (a checked-out submodule), recursively; otherwise it stays empty. The index is not rewritten:
# RECOVERY_DIR/t0.gitindex is a byte copy of it, for the user to put back.
# A private bare repository in a temporary directory is the git directory, so the caller's
# repository is only read, through the alternate.

set -euo pipefail

die() {
	echo "recover.sh: $*" >&2
	exit 1
}

[[ $# -eq 2 ]] || die "usage: recover.sh RECOVERY_DIR DEST"
dir="$(cd "$1" && pwd -P)" || die "recovery directory $1 does not exist"
dest="$2"
[[ -d "${dir}/objects" && -s "${dir}/t0.tree" && -f "${dir}/t0.perms" && -s "${dir}/repo-objects" ]] ||
	die "${dir} is not a recovery directory (objects/, t0.tree, t0.perms and repo-objects are needed)"
if [[ -e "${dest}" || -L "${dest}" ]]; then
	[[ -d "${dest}" && ! -L "${dest}" && -z "$(ls -A -- "${dest}")" ]] || die "${dest} exists and is not an empty directory"
else
	mkdir -p -- "${dest}"
fi
dest="$(cd "${dest}" && pwd -P)"

tree="$(<"${dir}/t0.tree")"
[[ "${tree}" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || die "t0.tree holds '${tree}', not a tree id"
gitdir="$(mktemp -d)"
trap 'rm -rf "${gitdir}"' EXIT
# The private repository must use the snapshot's object format (sha1 or sha256), or no object
# is found. snapshot.sh records it; a tree id's length says the same.
if [[ -s "${dir}/object-format" ]]; then
	format="$(<"${dir}/object-format")"
elif ((${#tree} == 64)); then
	format=sha256
else
	format=sha1
fi
[[ "${format}" == sha1 || "${format}" == sha256 ]] || die "object-format holds '${format}', not sha1 or sha256"
git init -q --bare --object-format="${format}" "${gitdir}"
alternate="$(<"${dir}/repo-objects")"
if [[ "${alternate}" == *:* || "${alternate}" == \"* ]]; then
	alternate="${alternate//\\/\\\\}"
	alternate="\"${alternate//\"/\\\"}\""
fi
g() {
	GIT_DIR="${gitdir}" GIT_OBJECT_DIRECTORY="${dir}/objects" GIT_ALTERNATE_OBJECT_DIRECTORIES="${alternate}" \
		git -c core.quotePath=false "$@"
}

# The tree is listed into a file first: a failed ls-tree must stop the recovery, never look like
# an empty tree.
g ls-tree -r -z "${tree}" >"${gitdir}/paths" || die "cannot list tree ${tree} from ${dir}/objects"

declare -A perm=()
while IFS= read -r -d '' rec; do
	perm["k${rec#*$'\t'}"]="${rec%%$'\t'*}"
done <"${dir}/t0.perms"

count=0
while IFS= read -r -d '' rec; do
	meta="${rec%%$'\t'*}"
	path="${rec#*$'\t'}"
	read -r mode _ sha <<<"${meta}"
	[[ "/${path}/" != */../* && "/${path}/" != */./* && "${path}" != /* ]] || die "the tree holds a path that is not plain: ${path}"
	target="${dest}/${path}"
	mkdir -p -- "$(dirname -- "${target}")"
	case "${mode}" in
	100644 | 100755)
		g cat-file blob "${sha}" >"${target}"
		p="${perm["k${path}"]:-}"
		[[ -n "${p}" ]] || { p=644; [[ "${mode}" == 100644 ]] || p=755; }
		chmod "${p}" -- "${target}"
		;;
	120000)
		link="$(g cat-file blob "${sha}" && printf x)"
		ln -s -- "${link%x}" "${target}"
		;;
	160000)
		mkdir -p -- "${target}"
		sub="$(printf '%s' "${path}" | sha1sum)"
		sub="${dir}/sub/${sub%% *}"
		if [[ -s "${sub}/t0.tree" ]]; then
			bash "${BASH_SOURCE[0]}" "${sub}" "${target}"
		fi
		;;
	*) die "unexpected mode ${mode} for ${path}" ;;
	esac
	count=$((count + 1))
done <"${gitdir}/paths"
echo "recover.sh: recreated ${count} path(s) of tree ${tree} in ${dest}"
