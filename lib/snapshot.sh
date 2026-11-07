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
# Worktree snapshot, restore and verify, sourced by run-passes.sh (and its tests). It lets a hook
# change the worktree freely and then puts every path git would report back exactly as it was,
# without git stash, reset, clean or checkout, and without ever writing the real index, the
# repository's object store or its config.
#
# Scope: tracked files (staged or unstaged), deletions and untracked files that are not ignored;
# the real index file, byte for byte (pre-commit's own `git diff` refreshes stale stat data in it,
# even with GIT_OPTIONAL_LOCKS=0); and the content of every checked-out submodule, snapshotted the
# same way, recursively, in WORK/sub/<sha1 of its path>. Ignored paths, empty directories and
# nested repositories (an untracked directory that `git ls-files --others` lists as `dir/`) are
# outside it.
#
# Functions (each returns non-zero on failure with the reason in SNAP_ERROR; none of them relies
# on `set -e`, every step is checked explicitly so they also work inside `if` and `||`):
#
#   snap_init WORK ROOT     WORK: an empty private directory; ROOT: the absolute worktree root.
#                           Creates WORK/objects, the private object store every snapshot writes
#                           into. The repository's own store is only read, as an alternate.
#   snap_take NAME          Snapshots the worktree as tree NAME: WORK/NAME.tree (the tree id, also
#                           in SNAP_TREE), WORK/NAME.index (its private index), WORK/NAME.perms
#                           (permission bits, "<octal>\t<path>\0" per file) and WORK/NAME.nested
#                           (the nested repositories left out, NUL-separated), WORK/NAME.ignored
#                           (the ignored paths, an ignored directory as one "dir/", from
#                           `git ls-files --others --ignored --exclude-standard --directory`) and
#                           WORK/NAME.gitlinks ("<state>\t<path>\0" per gitlink: absent, symlink,
#                           not-a-directory, directory, "directory with content <hash>", or
#                           "checkout <HEAD>"), WORK/NAME.subs ("<content hash>\t<path>\0" per
#                           checked-out submodule, whose own snapshot NAME is in WORK/sub/<id>),
#                           WORK/NAME.indexstate ("absent", or "present <permission bits>", plus
#                           " locked" while index.lock exists) and WORK/NAME.gitindex (the bytes of
#                           the real index). A fifo, socket or device fails it closed.
#   snap_restore T0 T1      Brings the worktree from snapshot T1 back to snapshot T0 (both names).
#                           The plan is WORK/plan (`git diff-tree -r -z --no-renames`). On a
#                           path-safety stop or any failed operation it stops at once, lists the
#                           paths in WORK/failed-paths (one "<path>: <reason>" per line, the path
#                           shell-quoted) and returns 1.
#   snap_verify T0          Takes snapshot "verify" and returns 0 only if it equals T0 (the same
#                           tree and permission bits); otherwise the paths that differ go to
#                           WORK/failed-paths.
#   snap_same A B           Whether snapshots A and B have the same tree and permission bits.
#   snap_diff A B OUT       Appends to file OUT (an absolute path) the binary diff from snapshot A
#                           to B, then that of every submodule whose content changed between them
#                           (present in both), its paths led by the submodule's path, recursively.
#   snap_git ARGS...        git in the private store, for the caller's own reads (diff, archive).
#
# Restore runs in two phases, and every filesystem operation is preceded by an lstat check of
# each ancestor of its target, from the root down: a symlink or a non-directory where a directory
# is needed stops the restore, so nothing is ever written through a link a hook created.
#   Before anything: a submodule whose on-disk state changed (deleted, replaced, another HEAD)
#   stops the restore, and so does an added path that existed before the pass (ignored then, the
#   hook having changed the ignore rules, or inside a nested repository whose .git it removed):
#   only what the hook created is ever unlinked.
#   A. Deepest path first: every path the hook added or turned into another type is unlinked
#      (`rm -f --`, which neither follows links nor recurses); then every directory above those
#      paths that is not a directory of T0 is removed with rmdir, deepest first. A directory that
#      still holds something (untracked or ignored content) stops the restore: never `rm -r`.
#   B. Shallowest path first: every path T0 has that was modified, retyped or deleted is
#      recreated: missing parents one mkdir at a time, the content in a temporary file in the
#      parent with T0's permission bits (a symlink made with `ln -s` under a temporary name),
#      then renamed into place with `mv -T --`.
#   C. Permission bits a hook changed without touching the content or the exec bit (invisible to
#      git, so not in the plan) are set back with chmod, on files regular in both snapshots.
#   D. Every submodule whose content changed is restored by its own snapshot, the same way.
#   E. The real index, if its bytes changed, is put back from T0's copy through a temporary file
#      and `mv -T`. An index.lock the hooks left stops the restore: git may still be writing.
#
# Needs bash 4.4+, git 2.34+ and GNU coreutils (stat --printf, mv -T, readlink -n).

SNAP_WORK=""
SNAP_ROOT=""
SNAP_REPO_OBJECTS=""
SNAP_INDEX=""
SNAP_TREE=""
SNAP_ERROR=""

# git as the caller sees it, but never through a private store or index the caller's environment
# might name, and without optional locks, so a read never refreshes and rewrites the real index.
_snap_git_real() {
	env -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
		GIT_OPTIONAL_LOCKS=0 git -C "${SNAP_ROOT}" -c core.fsmonitor=false -c core.quotePath=false "$@"
}

# git in the private store, with the private index $1. New objects land in WORK/objects; objects
# the repository already has are read from its store through the alternate and never copied.
_snap_git_index() {
	local index="$1"
	shift
	GIT_OBJECT_DIRECTORY="${SNAP_WORK}/objects" \
		GIT_ALTERNATE_OBJECT_DIRECTORIES="$(_snap_alternate_path "${SNAP_REPO_OBJECTS}")" \
		GIT_INDEX_FILE="${index}" GIT_OPTIONAL_LOCKS=0 \
		git -C "${SNAP_ROOT}" -c core.fsmonitor=false -c core.quotePath=false "$@"
}

snap_git() {
	_snap_git_index "${SNAP_WORK}/scratch.index" "$@"
}

# GIT_ALTERNATE_OBJECT_DIRECTORIES is a colon-separated list; a path holding a colon (or starting
# with a quote) must be written C-quoted, which git unquotes.
_snap_alternate_path() {
	local path="$1"
	if [[ "${path}" == *:* || "${path}" == \"* ]]; then
		path="${path//\\/\\\\}"
		path="${path//\"/\\\"}"
		path="\"${path}\""
	fi
	printf '%s' "${path}"
}

_snap_fail() {
	SNAP_ERROR="$*"
	return 1
}

# Records one failed path for the recovery report and the error message.
_snap_failed_path() {
	printf '%q: %s\n' "$1" "$2" >>"${SNAP_WORK}/failed-paths"
}

snap_init() {
	SNAP_WORK="$1"
	SNAP_ROOT="$2"
	SNAP_ERROR=""
	SNAP_TREE=""
	[[ -d "${SNAP_WORK}" && "${SNAP_ROOT}" == /* && -d "${SNAP_ROOT}" ]] ||
		_snap_fail "snapshot: bad work directory '${SNAP_WORK}' or root '${SNAP_ROOT}'" || return 1
	SNAP_REPO_OBJECTS="$(_snap_git_real rev-parse --path-format=absolute --git-path objects)" ||
		_snap_fail "snapshot: cannot find the object store of the repository at ${SNAP_ROOT}" || return 1
	[[ -d "${SNAP_REPO_OBJECTS}" ]] ||
		_snap_fail "snapshot: the object store ${SNAP_REPO_OBJECTS} is not a directory" || return 1
	SNAP_INDEX="$(_snap_git_real rev-parse --path-format=absolute --git-path index)" ||
		_snap_fail "snapshot: cannot find the index file of the repository at ${SNAP_ROOT}" || return 1
	mkdir -p "${SNAP_WORK}/objects" || _snap_fail "snapshot: cannot create ${SNAP_WORK}/objects" || return 1
	: >"${SNAP_WORK}/failed-paths" || return 1
	# recover.sh reads the store of the repository as an alternate, for this snapshot and for
	# every submodule's under WORK/sub.
	printf '%s\n' "${SNAP_REPO_OBJECTS}" >"${SNAP_WORK}/repo-objects" || return 1
	_snap_git_real rev-parse --show-object-format >"${SNAP_WORK}/object-format" ||
		_snap_fail "snapshot: cannot read the object format of the repository at ${SNAP_ROOT}" || return 1
}

# The directory of the snapshots of the submodule at path $1.
_snap_sub_work() {
	local id
	id="$(printf '%s' "$1" | sha1sum)" || return 1
	printf '%s/sub/%s' "${SNAP_WORK}" "${id%% *}"
}

# Runs snapshot function $2... for the submodule at path $1, in a subshell with its own globals.
# Its error goes to SNAP_ERROR, its failed paths to this snapshot's, led by the submodule path.
_snap_in_sub() {
	local path="$1" sub rc=0 line
	shift
	sub="$(_snap_sub_work "${path}")" || _snap_fail "snapshot: cannot name the work directory of submodule ${path}" || return 1
	mkdir -p -- "${sub}" || _snap_fail "snapshot: cannot create ${sub}" || return 1
	printf '%s' "${path}" >"${sub}/path" || return 1
	rm -f -- "${sub}/error"
	(
		# The submodule's git directory is found from its .git file, never from the environment.
		unset GIT_DIR GIT_WORK_TREE
		snap_init "${sub}" "${SNAP_ROOT}/${path}" && "$@" && exit 0
		printf '%s' "${SNAP_ERROR}" >"${sub}/error"
		exit 1
	) </dev/null || rc=$?
	if ((rc != 0)); then
		SNAP_ERROR="in submodule $(printf '%q' "${path}"): $(cat -- "${sub}/error" 2>/dev/null || echo "exit status ${rc}")"
		if [[ -s "${sub}/failed-paths" ]]; then
			while IFS= read -r line; do
				printf '%q (submodule): %s\n' "${path}" "${line}" >>"${SNAP_WORK}/failed-paths"
			done <"${sub}/failed-paths"
		fi
		return 1
	fi
	return 0
}

# Content hash of the snapshot NAME in work directory $1: tree, permission bits, submodule states
# and contents, and index bytes, all of which snap_same compares.
_snap_content_hash() {
	local work="$1" name="$2" hash
	hash="$(cat -- "${work}/${name}.tree" "${work}/${name}.perms" "${work}/${name}.gitlinks" \
		"${work}/${name}.subs" "${work}/${name}.indexstate" "${work}/${name}.gitindex" | sha256sum)" || return 1
	printf '%s' "${hash%% *}"
}

# A path as git prints it is relative and normalised; anything else (absolute, empty component,
# "." or "..") is refused rather than resolved, so no operation can be aimed outside the root.
_snap_valid_path() {
	local path="$1"
	[[ -n "${path}" && "${path}" != /* && "${path}" != */ && "${path}" != *//* ]] || return 1
	[[ "/${path}/" != */./* && "/${path}/" != */../* ]] || return 1
	return 0
}

# Whether every ancestor of $1 is a real directory (no symlink), as git itself requires before it
# treats a path as present: a tracked a/b behind a symlinked a is not in the worktree. Directory
# answers are cached in the associative array _snap_dir_ok for one snapshot.
_snap_ancestors_real() {
	local path="$1" dir="" rest="$1" component
	while [[ "${rest}" == */* ]]; do
		component="${rest%%/*}"
		rest="${rest#*/}"
		dir="${dir:+${dir}/}${component}"
		if [[ -z "${_snap_dir_ok["k${dir}"]+set}" ]]; then
			if [[ ! -L "${SNAP_ROOT}/${dir}" && -d "${SNAP_ROOT}/${dir}" ]]; then
				_snap_dir_ok["k${dir}"]=1
			else
				_snap_dir_ok["k${dir}"]=0
			fi
		fi
		[[ "${_snap_dir_ok["k${dir}"]}" == 1 ]] || return 1
	done
	return 0
}

# What is on disk at gitlink $1: absent, a symlink, a file, a plain directory, or a checkout and
# its HEAD commit. The index entry of a gitlink is copied into every snapshot unchanged, so this
# is what tells a hook that deleted, replaced or moved a submodule apart from one that did not.
_snap_gitlink_state() {
	local path="$1" abs="${SNAP_ROOT}/$1" head
	local -A _snap_dir_ok=()
	if ! _snap_ancestors_real "${path}"; then
		echo behind-a-link
	elif [[ -L "${abs}" ]]; then
		echo "symlink $(readlink -- "${abs}")"
	elif [[ ! -e "${abs}" ]]; then
		echo absent
	elif [[ ! -d "${abs}" ]]; then
		echo not-a-directory
	elif [[ -e "${abs}/.git" ]]; then
		head="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY \
			-u GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_OPTIONAL_LOCKS=0 \
			git -C "${abs}" rev-parse --verify --quiet HEAD 2>/dev/null)" || head=none
		echo "checkout ${head}"
	elif [[ -z "$(ls -A -- "${abs}")" ]]; then
		echo directory
	else
		# Not a checkout, but not empty either: what a hook writes there is no repository's, so
		# any change to it stops the restore.
		head="$(cd -- "${abs}" && find . -mindepth 1 -printf '%P\0%y %m %s %T@\0' | LC_ALL=C sort -z | sha256sum)"
		echo "directory with content ${head%% *}"
	fi
}

snap_take() {
	local name="$1"
	local list="${SNAP_WORK}/${name}.list" stage="${SNAP_WORK}/${name}.stage"
	local index="${SNAP_WORK}/${name}.index" info="${SNAP_WORK}/${name}.info"
	local perms="${SNAP_WORK}/${name}.perms" nested="${SNAP_WORK}/${name}.nested"
	local stats="${SNAP_WORK}/${name}.stat" hashes="${SNAP_WORK}/${name}.hashes"
	local ignored="${SNAP_WORK}/${name}.ignored" links="${SNAP_WORK}/${name}.gitlinks"
	local subs="${SNAP_WORK}/${name}.subs" istate="${SNAP_WORK}/${name}.indexstate"
	local icopy="${SNAP_WORK}/${name}.gitindex"
	local rec meta path mode sha i state
	SNAP_TREE=""
	SNAP_ERROR=""
	rm -f -- "${index}" "${info}" "${perms}" "${nested}" "${links}" "${subs}" "${istate}" "${icopy}" || return 1
	: >"${info}" && : >"${perms}" && : >"${nested}" && : >"${links}" && : >"${subs}" && : >"${icopy}" || return 1

	# The real index, byte for byte: pre-commit refreshes stale stat data in it (its `git diff`
	# rewrites the index even with GIT_OPTIONAL_LOCKS=0), and a hook may stage something.
	if [[ -L "${SNAP_INDEX}" || -e "${SNAP_INDEX}" ]]; then
		[[ ! -L "${SNAP_INDEX}" && -f "${SNAP_INDEX}" ]] ||
			_snap_fail "snapshot ${name}: the index ${SNAP_INDEX} is not a regular file" || return 1
		cp -- "${SNAP_INDEX}" "${icopy}" ||
			_snap_fail "snapshot ${name}: cannot copy the index ${SNAP_INDEX}" || return 1
		state="present $(stat --printf '%a' -- "${SNAP_INDEX}")" ||
			_snap_fail "snapshot ${name}: cannot stat the index ${SNAP_INDEX}" || return 1
	else
		state=absent
	fi
	[[ ! -e "${SNAP_INDEX}.lock" && ! -L "${SNAP_INDEX}.lock" ]] || state+=" locked"
	printf '%s\n' "${state}" >"${istate}" || return 1

	# The ignored paths, an ignored directory as one "dir/" entry: outside the snapshot, but the
	# restore must know they existed, so that a hook which un-ignores one (by editing .gitignore)
	# never gets it deleted as a path the hook "added".
	_snap_git_real ls-files -z --others --ignored --exclude-standard --directory >"${ignored}" ||
		_snap_fail "snapshot ${name}: git ls-files --ignored failed" || return 1

	# Candidates: every path in the real index plus every untracked path that is not ignored. The
	# real index is read here and never written.
	_snap_git_real ls-files -z --cached --others --exclude-standard >"${list}" ||
		_snap_fail "snapshot ${name}: git ls-files failed" || return 1
	_snap_git_real ls-files -z --stage >"${stage}" ||
		_snap_fail "snapshot ${name}: git ls-files --stage failed" || return 1

	# Gitlinks (submodules) are kept exactly as the real index has them: their content is another
	# repository, never part of this snapshot.
	local -A gitlinks=()
	while IFS= read -r -d '' rec; do
		meta="${rec%%$'\t'*}"
		path="${rec#*$'\t'}"
		mode="${meta%% *}"
		if [[ "${mode}" == 160000 && -z "${gitlinks["k${path}"]+set}" ]]; then
			sha="${meta#* }"
			gitlinks["k${path}"]="${sha%% *}"
			state="$(_snap_gitlink_state "${path}")"
			printf '%s\t%s\0' "${state}" "${path}" >>"${links}"
			if [[ "${state}" == "checkout "* ]]; then
				# A checkout is another repository: its own snapshot, recursively, in WORK/sub.
				_snap_in_sub "${path}" snap_take "${name}" || return 1
				sha="$(_snap_content_hash "$(_snap_sub_work "${path}")" "${name}")" ||
					_snap_fail "snapshot ${name}: cannot hash the snapshot of submodule ${path}" || return 1
				printf '%s\t%s\0' "${sha}" "${path}" >>"${subs}"
			fi
		fi
	done <"${stage}"

	local -A _snap_dir_ok=()
	local -a present=()
	local p
	while IFS= read -r -d '' p; do
		if [[ "${p}" == */ ]]; then
			# A nested repository: git shows it as one directory entry and never lists its files.
			printf '%s\0' "${p%/}" >>"${nested}"
			continue
		fi
		_snap_valid_path "${p}" ||
			_snap_fail "snapshot ${name}: git listed a path that is not a plain relative path: $(printf '%q' "${p}")" ||
			return 1
		if [[ -n "${gitlinks["k${p}"]+set}" ]]; then
			printf '160000 %s\t%s\0' "${gitlinks["k${p}"]}" "${p}" >>"${info}"
			continue
		fi
		# Behind a symlinked or replaced parent, or gone from disk: a deletion, left out.
		_snap_ancestors_real "${p}" || continue
		[[ -e "${SNAP_ROOT}/${p}" || -L "${SNAP_ROOT}/${p}" ]] || continue
		present+=("${p}")
	done < <(LC_ALL=C sort -zu "${list}")

	# One lstat per path, batched: the raw mode in hex and the permission bits in octal.
	: >"${stats}" || return 1
	if ((${#present[@]} > 0)); then
		if ! (cd "${SNAP_ROOT}" && printf '%s\0' "${present[@]}" | xargs -0 stat --printf '%f %a\0' --) >"${stats}"; then
			_snap_fail "snapshot ${name}: stat failed on the worktree (did a file vanish while it was read?)"
			return 1
		fi
	fi
	local -a modes=()
	mapfile -d '' -t modes <"${stats}"
	((${#modes[@]} == ${#present[@]})) ||
		_snap_fail "snapshot ${name}: stat returned ${#modes[@]} results for ${#present[@]} paths" || return 1

	# Regular files are hashed in one batch when their name survives git's --stdin-paths line
	# reading (no newline, no trailing CR, no leading quote, which git would unquote); the rest are
	# hashed one by one. --no-filters stores the bytes on disk, never a clean filter's output.
	local -a batch=() batch_mode=() single=() single_mode=()
	local raw type perm target
	for i in "${!present[@]}"; do
		p="${present[i]}"
		raw="${modes[i]%% *}"
		perm="${modes[i]#* }"
		type=$((16#${raw} & 0xF000))
		case "${type}" in
		$((0x8000)))
			if (((8#${perm}) & 8#100)); then mode=100755; else mode=100644; fi
			printf '%s\t%s\0' "${perm}" "${p}" >>"${perms}"
			if [[ "${p}" == *$'\n'* || "${p}" == *$'\r' || "${p}" == \"* ]]; then
				single+=("${p}")
				single_mode+=("${mode}")
			else
				batch+=("${p}")
				batch_mode+=("${mode}")
			fi
			;;
		$((0xA000)))
			# The blob of a symlink is its target, without a trailing newline.
			target="$(readlink -n -- "${SNAP_ROOT}/${p}" && printf x)" ||
				_snap_fail "snapshot ${name}: cannot read the symlink $(printf '%q' "${p}")" || return 1
			target="${target%x}"
			sha="$(printf '%s' "${target}" | _snap_git_index "${index}" hash-object -w --stdin)" ||
				_snap_fail "snapshot ${name}: cannot store the symlink $(printf '%q' "${p}")" || return 1
			printf '120000 %s\t%s\0' "${sha}" "${p}" >>"${info}"
			;;
		$((0x4000)))
			# A tracked path that is now a directory: the file is deleted, and whatever untracked
			# content the directory holds is listed by git on its own.
			;;
		*)
			_snap_fail "snapshot ${name}: $(printf '%q' "${p}") is not a regular file, symlink or directory (a fifo, socket or device); it cannot be snapshotted, so nothing was run"
			return 1
			;;
		esac
	done

	if ((${#batch[@]} > 0)); then
		printf '%s\n' "${batch[@]}" | _snap_git_index "${index}" hash-object -w --no-filters --stdin-paths >"${hashes}" ||
			_snap_fail "snapshot ${name}: git hash-object failed" || return 1
		local -a shas=()
		mapfile -t shas <"${hashes}"
		((${#shas[@]} == ${#batch[@]})) ||
			_snap_fail "snapshot ${name}: git hash-object returned ${#shas[@]} ids for ${#batch[@]} files" || return 1
		for i in "${!batch[@]}"; do
			printf '%s %s\t%s\0' "${batch_mode[i]}" "${shas[i]}" "${batch[i]}" >>"${info}"
		done
	fi
	for i in "${!single[@]}"; do
		sha="$(_snap_git_index "${index}" hash-object -w --no-filters -- "${single[i]}")" ||
			_snap_fail "snapshot ${name}: git hash-object failed on $(printf '%q' "${single[i]}")" || return 1
		printf '%s %s\t%s\0' "${single_mode[i]}" "${sha}" "${single[i]}" >>"${info}"
	done

	_snap_git_index "${index}" update-index -z --index-info <"${info}" ||
		_snap_fail "snapshot ${name}: git update-index on the private index failed" || return 1
	SNAP_TREE="$(_snap_git_index "${index}" write-tree)" ||
		_snap_fail "snapshot ${name}: git write-tree on the private index failed" || return 1
	[[ "${SNAP_TREE}" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] ||
		_snap_fail "snapshot ${name}: git write-tree printed '${SNAP_TREE}'" || return 1
	printf '%s\n' "${SNAP_TREE}" >"${SNAP_WORK}/${name}.tree" || return 1
	rm -f -- "${list}" "${stage}" "${stats}" "${hashes}"
	return 0
}

# Prints the NUL-separated paths of $1 sorted by depth: "asc" shallowest first, "desc" deepest
# first; ties in byte order, so a run is reproducible.
_snap_sort_depth() {
	local order="$1" p slashes
	shift
	local key=-k1,1n
	[[ "${order}" == asc ]] || key=-k1,1nr
	for p in "$@"; do
		slashes="${p//[^\/]/}"
		printf '%06d\t%s\0' "${#slashes}" "${p}"
	done | LC_ALL=C sort -z -t $'\t' "${key}" -k2 | while IFS= read -r -d '' p; do
		printf '%s\0' "${p#*$'\t'}"
	done
}

# The path-safety check: every ancestor of $1, from the root down, must be a real directory or
# missing (and then so is everything below it). Returns 1, with the reason in _snap_unsafe, on a
# symlink or a non-directory.
_snap_safe_ancestors() {
	local dir="" rest="$1" component
	_snap_unsafe=""
	while [[ "${rest}" == */* ]]; do
		component="${rest%%/*}"
		rest="${rest#*/}"
		dir="${dir:+${dir}/}${component}"
		if [[ -L "${SNAP_ROOT}/${dir}" ]]; then
			_snap_unsafe="its parent $(printf '%q' "${dir}") is a symlink"
			return 1
		elif [[ -d "${SNAP_ROOT}/${dir}" ]]; then
			continue
		elif [[ -e "${SNAP_ROOT}/${dir}" ]]; then
			_snap_unsafe="its parent $(printf '%q' "${dir}") is not a directory"
			return 1
		else
			return 0
		fi
	done
	return 0
}

# Creates the missing parents of $1 one component at a time, checking each existing one again.
_snap_make_parents() {
	local dir="" rest="$1" component
	_snap_unsafe=""
	while [[ "${rest}" == */* ]]; do
		component="${rest%%/*}"
		rest="${rest#*/}"
		dir="${dir:+${dir}/}${component}"
		if [[ -L "${SNAP_ROOT}/${dir}" ]]; then
			_snap_unsafe="its parent $(printf '%q' "${dir}") is a symlink"
			return 1
		elif [[ -d "${SNAP_ROOT}/${dir}" ]]; then
			continue
		elif [[ -e "${SNAP_ROOT}/${dir}" ]]; then
			_snap_unsafe="its parent $(printf '%q' "${dir}") is not a directory"
			return 1
		fi
		if ! mkdir -- "${SNAP_ROOT}/${dir}"; then
			_snap_unsafe="mkdir $(printf '%q' "${dir}") failed"
			return 1
		fi
		if [[ -L "${SNAP_ROOT}/${dir}" || ! -d "${SNAP_ROOT}/${dir}" ]]; then
			_snap_unsafe="$(printf '%q' "${dir}") is not a directory after mkdir"
			return 1
		fi
	done
	return 0
}

# Stops the restore on path $1 for reason $2.
_snap_stop() {
	_snap_failed_path "$1" "$2"
	SNAP_ERROR="restore stopped at $(printf '%q' "$1"): $2"
	return 1
}

snap_restore() {
	local t0name="$1" t1name="$2" t0 t1 p
	SNAP_ERROR=""
	: >"${SNAP_WORK}/failed-paths" || return 1
	t0="$(<"${SNAP_WORK}/${t0name}.tree")" && t1="$(<"${SNAP_WORK}/${t1name}.tree")" ||
		_snap_fail "restore: snapshot ${t0name} or ${t1name} is missing" || return 1
	: >"${SNAP_WORK}/plan" || return 1

	# A submodule the hook deleted, replaced or moved to another commit is another repository's
	# content: it is never rebuilt here, the restore stops.
	if ! cmp -s -- "${SNAP_WORK}/${t0name}.gitlinks" "${SNAP_WORK}/${t1name}.gitlinks"; then
		local -A link0=()
		local lrec
		while IFS= read -r -d '' lrec; do
			link0["k${lrec#*$'\t'}"]="${lrec%%$'\t'*}"
		done <"${SNAP_WORK}/${t0name}.gitlinks"
		while IFS= read -r -d '' lrec; do
			p="${lrec#*$'\t'}"
			if [[ "${link0["k${p}"]:-}" != "${lrec%%$'\t'*}" ]]; then
				_snap_stop "${p}" "the submodule changed on disk (was: ${link0["k${p}"]:-not a gitlink}; now: ${lrec%%$'\t'*})" || return 1
			fi
		done <"${SNAP_WORK}/${t1name}.gitlinks"
		_snap_stop "(gitlinks)" "the set of submodules changed" || return 1
	fi
	! snap_same "${t0name}" "${t1name}" || return 0

	if [[ "${t0}" != "${t1}" ]]; then
		snap_git diff-tree -r -z --no-renames "${t0}" "${t1}" >"${SNAP_WORK}/plan" ||
			_snap_fail "restore: git diff-tree ${t0} ${t1} failed" || return 1
	fi

	# T0's permission bits, to put back exactly what was there rather than a umask default.
	local -A perm0=()
	local rec
	while IFS= read -r -d '' rec; do
		perm0["k${rec#*$'\t'}"]="${rec%%$'\t'*}"
	done <"${SNAP_WORK}/${t0name}.perms"

	# D0: every directory of T0. Only a directory outside it can be one the hook made.
	local -A d0=()
	local p dir
	while IFS= read -r -d '' p; do
		dir="${p}"
		while [[ "${dir}" == */* ]]; do
			dir="${dir%/*}"
			[[ -z "${d0["k${dir}"]+set}" ]] || break
			d0["k${dir}"]=1
		done
	done < <(snap_git ls-tree -r -z --name-only "${t0}")

	local -a remove=() recreate=() added=()
	local -A old_mode=() old_sha=()
	local meta status m1 m2 s1
	while IFS= read -r -d '' meta && IFS= read -r -d '' p; do
		read -r m1 m2 s1 _ status <<<"${meta#:}"
		_snap_valid_path "${p}" || _snap_stop "${p}" "git diff-tree printed a path that is not plain" || return 1
		if [[ "${m1}" == 160000 || "${m2}" == 160000 ]]; then
			_snap_stop "${p}" "a gitlink (submodule) entry changed" || return 1
		fi
		case "${status}" in
		A)
			remove+=("${p}")
			added+=("${p}")
			;;
		T)
			remove+=("${p}")
			recreate+=("${p}")
			;;
		M | D) recreate+=("${p}") ;;
		*) _snap_stop "${p}" "unexpected git diff-tree status ${status}" || return 1 ;;
		esac
		old_mode["k${p}"]="${m1}"
		old_sha["k${p}"]="${s1}"
	done <"${SNAP_WORK}/plan"

	# A path the hook "added" may only be unlinked if it did not exist before the pass. One that was
	# ignored then (the hook changed the ignore rules) or inside a nested repository (the hook
	# removed its .git) is the user's file: the restore stops rather than delete it.
	local -A before=()
	while IFS= read -r -d '' p; do
		before["k${p%/}"]=1
	done < <(cat -- "${SNAP_WORK}/${t0name}.ignored" "${SNAP_WORK}/${t0name}.nested")
	for p in "${added[@]}"; do
		dir="${p}"
		while :; do
			if [[ -n "${before["k${dir}"]+set}" ]]; then
				_snap_stop "${p}" "it existed before the pass (ignored or in a nested repository then) and is not the hook's to remove" ||
					return 1
			fi
			[[ "${dir}" == */* ]] || break
			dir="${dir%/*}"
		done
	done

	# Phase A.1: unlink what the hook added or retyped, deepest first.
	local -A made_dirs=()
	while IFS= read -r -d '' p; do
		_snap_safe_ancestors "${p}" || _snap_stop "${p}" "${_snap_unsafe}" || return 1
		rm -f -- "${SNAP_ROOT}/${p}" || _snap_stop "${p}" "rm failed" || return 1
		dir="${p}"
		while [[ "${dir}" == */* ]]; do
			dir="${dir%/*}"
			[[ -z "${d0["k${dir}"]+set}" ]] || break
			made_dirs["k${dir}"]=1
		done
	done < <(_snap_sort_depth desc "${remove[@]}")

	# Phase A.2: remove the directories the hook made, deepest first, only if empty.
	local -a dirs=()
	for dir in "${!made_dirs[@]}"; do
		dirs+=("${dir#k}")
	done
	while IFS= read -r -d '' dir; do
		_snap_safe_ancestors "${dir}" || _snap_stop "${dir}" "${_snap_unsafe}" || return 1
		if [[ -L "${SNAP_ROOT}/${dir}" ]]; then
			_snap_stop "${dir}" "it is a symlink where the hook made a directory" || return 1
		elif [[ -d "${SNAP_ROOT}/${dir}" ]]; then
			rmdir -- "${SNAP_ROOT}/${dir}" 2>/dev/null ||
				_snap_stop "${dir}" "a directory the hook created still holds untracked or ignored content; it was not removed" ||
				return 1
		elif [[ -e "${SNAP_ROOT}/${dir}" ]]; then
			_snap_stop "${dir}" "it is not a directory" || return 1
		fi
	done < <(_snap_sort_depth desc "${dirs[@]}")

	# Phase B: recreate T0's version of every modified, retyped or deleted path, shallowest first.
	local parent tmp mode sha perm target
	while IFS= read -r -d '' p; do
		mode="${old_mode["k${p}"]}"
		sha="${old_sha["k${p}"]}"
		_snap_make_parents "${p}" || _snap_stop "${p}" "${_snap_unsafe}" || return 1
		parent="${SNAP_ROOT}"
		[[ "${p}" != */* ]] || parent="${SNAP_ROOT}/${p%/*}"
		tmp="$(mktemp "${parent}/.pcrd-restore.XXXXXX")" ||
			_snap_stop "${p}" "cannot create a temporary file next to it" || return 1
		case "${mode}" in
		100644 | 100755)
			perm="${perm0["k${p}"]:-}"
			if [[ -z "${perm}" ]]; then
				perm=644
				[[ "${mode}" == 100644 ]] || perm=755
			fi
			if ! snap_git cat-file blob "${sha}" >"${tmp}" || ! chmod "${perm}" -- "${tmp}"; then
				rm -f -- "${tmp}"
				_snap_stop "${p}" "cannot write its content" || return 1
			fi
			;;
		120000)
			if ! target="$(snap_git cat-file blob "${sha}" && printf x)"; then
				rm -f -- "${tmp}"
				_snap_stop "${p}" "cannot read its symlink target" || return 1
			fi
			target="${target%x}"
			if ! ln -sfT -- "${target}" "${tmp}"; then
				rm -f -- "${tmp}"
				_snap_stop "${p}" "ln -s failed" || return 1
			fi
			;;
		*)
			rm -f -- "${tmp}"
			_snap_stop "${p}" "unexpected mode ${mode}" || return 1
			;;
		esac
		# The parent was checked by _snap_make_parents and nothing ran since: rename into place.
		if ! mv -T -- "${tmp}" "${SNAP_ROOT}/${p}"; then
			rm -f -- "${tmp}"
			_snap_stop "${p}" "mv into place failed" || return 1
		fi
	done < <(_snap_sort_depth asc "${recreate[@]}")

	# Phase C: permission bits a hook changed without changing the content or the exec bit (git
	# does not see those, so they are not in the plan). Only files that are regular in both
	# snapshots and were not recreated above.
	local -A recreated=() perm1=()
	for p in "${recreate[@]}"; do
		recreated["k${p}"]=1
	done
	while IFS= read -r -d '' rec; do
		perm1["k${rec#*$'\t'}"]="${rec%%$'\t'*}"
	done <"${SNAP_WORK}/${t1name}.perms"
	local k
	for k in "${!perm0[@]}"; do
		[[ -n "${perm1[${k}]+set}" && "${perm1[${k}]}" != "${perm0[${k}]}" && -z "${recreated[${k}]+set}" ]] || continue
		p="${k#k}"
		_snap_safe_ancestors "${p}" || _snap_stop "${p}" "${_snap_unsafe}" || return 1
		if [[ -L "${SNAP_ROOT}/${p}" || ! -f "${SNAP_ROOT}/${p}" ]]; then
			_snap_stop "${p}" "it is no longer a regular file" || return 1
		fi
		chmod "${perm0[${k}]}" -- "${SNAP_ROOT}/${p}" || _snap_stop "${p}" "chmod failed" || return 1
	done

	# Phase D: every submodule whose content changed, by its own snapshots. The gitlink states
	# are the same (checked above), so each one is still the checkout it was.
	local -A sub1=()
	while IFS= read -r -d '' rec; do
		sub1["k${rec#*$'\t'}"]="${rec%%$'\t'*}"
	done <"${SNAP_WORK}/${t1name}.subs"
	while IFS= read -r -d '' rec; do
		p="${rec#*$'\t'}"
		[[ "${sub1["k${p}"]:-}" != "${rec%%$'\t'*}" ]] || continue
		if ! _snap_in_sub "${p}" snap_restore "${t0name}" "${t1name}"; then
			_snap_failed_path "${p}" "the submodule's content could not be restored"
			return 1
		fi
	done <"${SNAP_WORK}/${t0name}.subs"

	# Phase E: the real index, from T0's copy.
	_snap_restore_index "${t0name}" "${t1name}" || return 1
	return 0
}

# Puts the real index back as snapshot $1 had it, if snapshot $2 differs.
_snap_restore_index() {
	local s0 s1 perm tmp
	s0="$(<"${SNAP_WORK}/$1.indexstate")" && s1="$(<"${SNAP_WORK}/$2.indexstate")" ||
		_snap_fail "restore: the index state of snapshot $1 or $2 is missing" || return 1
	[[ "${s0}" != "${s1}" ]] || ! cmp -s -- "${SNAP_WORK}/$1.gitindex" "${SNAP_WORK}/$2.gitindex" || return 0
	if [[ "${s0}" == *" locked" ]]; then
		_snap_stop "${SNAP_INDEX}.lock" "it existed before the pass, so the index cannot be restored" || return 1
	elif [[ "${s1}" == *" locked" ]]; then
		_snap_stop "${SNAP_INDEX}.lock" "the hooks left the index locked (git may still be writing it); it was not removed" || return 1
	elif [[ "${s0}" == absent ]]; then
		rm -f -- "${SNAP_INDEX}" || _snap_stop "${SNAP_INDEX}" "cannot remove the index the hooks created" || return 1
		return 0
	fi
	perm="${s0#present }"
	if ! tmp="$(mktemp "${SNAP_INDEX%/*}/.pcrd-index.XXXXXX")"; then
		_snap_stop "${SNAP_INDEX}" "cannot create a temporary file next to the index" || return 1
	fi
	if ! cat -- "${SNAP_WORK}/$1.gitindex" >"${tmp}" || ! chmod "${perm}" -- "${tmp}" || ! mv -T -- "${tmp}" "${SNAP_INDEX}"; then
		rm -f -- "${tmp}"
		_snap_stop "${SNAP_INDEX}" "cannot put the index back" || return 1
	fi
	return 0
}

# Whether snapshots $1 and $2 are the same: the same tree, permission bits, submodule states and
# contents, and index bytes.
snap_same() {
	[[ "$(<"${SNAP_WORK}/$1.tree")" == "$(<"${SNAP_WORK}/$2.tree")" ]] &&
		cmp -s -- "${SNAP_WORK}/$1.perms" "${SNAP_WORK}/$2.perms" &&
		cmp -s -- "${SNAP_WORK}/$1.gitlinks" "${SNAP_WORK}/$2.gitlinks" &&
		cmp -s -- "${SNAP_WORK}/$1.subs" "${SNAP_WORK}/$2.subs" &&
		cmp -s -- "${SNAP_WORK}/$1.indexstate" "${SNAP_WORK}/$2.indexstate" &&
		cmp -s -- "${SNAP_WORK}/$1.gitindex" "${SNAP_WORK}/$2.gitindex"
}

snap_diff() {
	local t0name="$1" t1name="$2" out="$3" prefix="${4:-}" t0 t1 rec p
	t0="$(<"${SNAP_WORK}/${t0name}.tree")" && t1="$(<"${SNAP_WORK}/${t1name}.tree")" ||
		_snap_fail "diff: snapshot ${t0name} or ${t1name} is missing" || return 1
	if [[ "${t0}" != "${t1}" ]]; then
		snap_git diff --binary --no-ext-diff --no-textconv --no-renames --no-color --no-relative \
			--src-prefix="a/${prefix}" --dst-prefix="b/${prefix}" "${t0}" "${t1}" >>"${out}" ||
			_snap_fail "diff: git diff ${t0} ${t1} failed${prefix:+ in submodule ${prefix%/}}" || return 1
	fi
	local -A sub1=()
	while IFS= read -r -d '' rec; do
		sub1["k${rec#*$'\t'}"]="${rec%%$'\t'*}"
	done <"${SNAP_WORK}/${t1name}.subs"
	while IFS= read -r -d '' rec; do
		p="${rec#*$'\t'}"
		[[ -n "${sub1["k${p}"]+set}" && "${sub1["k${p}"]}" != "${rec%%$'\t'*}" ]] || continue
		_snap_in_sub "${p}" snap_diff "${t0name}" "${t1name}" "${out}" "${prefix}${p}/" || return 1
	done <"${SNAP_WORK}/${t0name}.subs"
	return 0
}

snap_verify() {
	local t0name="$1" t0 t2
	t0="$(<"${SNAP_WORK}/${t0name}.tree")" || _snap_fail "verify: snapshot ${t0name} is missing" || return 1
	if ! snap_take verify; then
		SNAP_ERROR="verify: ${SNAP_ERROR}"
		return 1
	fi
	t2="${SNAP_TREE}"
	! snap_same "${t0name}" verify || return 0
	local p
	while IFS= read -r -d '' p; do
		_snap_failed_path "${p}" "differs from the snapshot taken before the pass"
	done < <(snap_git diff-tree -r -z --no-renames --name-only "${t0}" "${t2}")
	if [[ "${t2}" == "${t0}" ]] && ! cmp -s -- "${SNAP_WORK}/${t0name}.perms" "${SNAP_WORK}/verify.perms"; then
		_snap_failed_path "(permission bits)" "a file's permission bits differ from the snapshot taken before the pass"
	fi
	if ! cmp -s -- "${SNAP_WORK}/${t0name}.gitlinks" "${SNAP_WORK}/verify.gitlinks" ||
		! cmp -s -- "${SNAP_WORK}/${t0name}.subs" "${SNAP_WORK}/verify.subs"; then
		_snap_failed_path "(submodules)" "a submodule's state or content differs from the snapshot taken before the pass"
	fi
	if ! cmp -s -- "${SNAP_WORK}/${t0name}.indexstate" "${SNAP_WORK}/verify.indexstate" ||
		! cmp -s -- "${SNAP_WORK}/${t0name}.gitindex" "${SNAP_WORK}/verify.gitindex"; then
		_snap_failed_path "${SNAP_INDEX}" "the index differs from the one before the pass"
	fi
	SNAP_ERROR="verify: the worktree after restore (tree ${t2}) is not the one before the pass (tree ${t0})"
	return 1
}
