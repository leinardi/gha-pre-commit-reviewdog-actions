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
# The pass runner every pre-commit + reviewdog action calls: it runs the action's pre-commit hooks
# on the files changed between two commits, reports what they found through reviewdog, puts the
# worktree back exactly as it was after every pass, and decides the verdict.
#
# Environment (required unless a default is given; a default applies only when the variable is
# unset, an empty value is refused):
#   ACTION_NAME        the action's name, ^[a-z0-9-]+$, used in messages and the work directory
#   PASSES             the action's passes, a JSON array (shape below)
#   FROM_REF, TO_REF   the commits to diff (e.g. the pull request's base and head SHA); each must
#                      resolve to a commit and must not start with "-"
#   WORKING_DIRECTORY  the caller repository, relative to GITHUB_WORKSPACE (default "."): no
#                      absolute path, no ".." component, inside the workspace, a work tree root
#   REPORTER           reviewdog's reporter: github-pr-review (default), github-check or local
#   REVIEWDOG_GITHUB_API_TOKEN  the token reviewdog posts with; required unless REPORTER=local.
#                      It is moved into an unexported shell variable at start-up and handed to
#                      reviewdog alone: no hook, converter or git ever sees it. GITHUB_TOKEN,
#                      GH_TOKEN, GH_ENTERPRISE_TOKEN, GITHUB_ENTERPRISE_TOKEN, GH_MODULE_TOKEN,
#                      REVIEWDOG_TOKEN, ACTIONS_RUNTIME_TOKEN, ACTIONS_ID_TOKEN_REQUEST_TOKEN,
#                      ACTIONS_ID_TOKEN_REQUEST_URL and every INPUT_* variable are removed from the
#                      environment too (a composite step exports no INPUT_*, but a caller's job
#                      env might), so a hook cannot read them.
#   REPORTS_DIR        optional; empty or unset: off. Otherwise an absolute, existing, writable
#                      directory outside the caller's work tree: every report handed to reviewdog
#                      is copied there byte for byte as <pass id>--<report index>.<rdjson|efm|diff>,
#                      and reports.json lists them as
#                      [{"pass", "name", "source", "format", "file", "count"}] (file: the base
#                      name; count: as for the findings output, null when unknown). Written at
#                      the end of the run, also on error ([] when nothing was posted).
#   GITHUB_WORKSPACE   the workspace root (default: the current directory, for local runs)
#   RUNNER_TEMP        where the private work directory goes (default TMPDIR, then /tmp)
#   GITHUB_OUTPUT      when set, the outputs below are appended to it
#   VALIDATE_ONLY      true: check ACTION_NAME, PASSES and its converters, then exit 0 without
#                      running anything (no refs, pre-commit, reviewdog or work tree needed);
#                      false or unset: the normal run. It lets a test check every action's PASSES.
#
# PASSES: [{"id": "check", "hooks": ["ruff-check-rdjson"], "stage": "manual", "reports": [...]}]
#   id       ^[a-z0-9-]+$, unique; names the <id>-exitcode output
#   hooks    non-empty list of hook ids or aliases, ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ (never an option),
#            run in order on one snapshot
#   stage    pre-commit, pre-merge-commit, pre-push or manual (passed as --hook-stage)
#   reports  each {"source": "stdout"|"tree", "format": "efm"|"rdjson"|"diff", "name": "...", ...}:
#            name      reviewdog's -name, non-empty, unique within the action
#            efm       list of errorformat patterns (format efm only, required there)
#            converter a jq file inside this action's repository, relative to its root (format
#                      rdjson only). It reads the hook output as one raw string (jq -R -s) with
#                      `--arg workspace <repository root>` and `-L <this lib>`, and prints an
#                      RDJSON object. Without one, the output must itself be one RDJSON object.
#            required  true: a failed hook must leave a valid report (format rdjson only)
#            level     reviewdog's -level: info, warning or error (optional)
#            strip     reviewdog's -f.diff.strip (format diff only, default 1)
#            Every pass has exactly one {"source": "tree", "format": "diff"} report: the changes
#            its hooks made in place. A tree report takes only name, level and strip.
#
# A pass is: a snapshot of the worktree (T0), each hook as
#   pre-commit run <hook> --hook-stage <stage> --color=never \
#     --from-ref FROM --to-ref TO --files /dev/null/pre-commit-reviewdog-unused
# a snapshot after the hooks (T1), the reports built from the hooks' output and from
# `git diff T0 T1`, then the restore of T0 and its verification, and only then reviewdog.
#
# Why both the refs and --files, from pre-commit 4.6.2's source (identical to the v4.6.2 tag):
#   - commands/run.py:262-265, _all_filenames: `elif args.from_ref and args.to_ref:` comes before
#     `elif args.files:`, so the files are git.get_changed_files(FROM, TO) (git.py:158, the
#     three-dot diff with the two-dot fallback) and the --files value is never used;
#   - commands/run.py:344, `stash = not args.all_files and not args.files`: a non-empty --files
#     turns the stash off, so unstaged changes stay in place and fixes are never rolled back;
#   - main.py:67-75: --files is mutually exclusive with --all-files only, not with the refs;
#   - commands/run.py:388-392 sets PRE_COMMIT_ORIGIN/SOURCE/FROM_REF/TO_REF from the refs;
#   - commands/run.py:75, Classifier: names that do not exist (os.path.lexists) are dropped, so
#     deletions never reach a hook, and neither would the --files placeholder, which can never
#     exist (/dev/null is not a directory), should a future pre-commit prefer --files.
# No file name ever reaches pre-commit's command line: a name starting with "-" cannot be taken
# for an option, and no list of changed files can exceed ARG_MAX (pre-commit itself splits the
# list it passes to each hook, honouring require_serial and pass_filenames: false).
#
# The runner still computes the same list (the same git diff, then only the paths that exist)
# for one purpose: an empty list never reaches pre-commit, where an always_run hook would still
# run. Every pass is then skipped.
#
# Every pass leaves the worktree as it found it (lib/snapshot.sh): tracked and untracked files,
# the real index file byte for byte, and the content of every checked-out submodule.
#
# After a hook failure or a reporting error the next pass still runs, from the restored original
# tree. When restore or verify fails, no further hook runs: the private snapshot is kept in
# RUNNER_TEMP/pre-commit-reviewdog-recovery-<id> and the error prints the command that recovers
# the original files.
#
# Outputs: exitcode (pre-commit's first nonzero exit status, else 0), <id>-exitcode per pass
# (empty for a pass that did not run), ran (true when at least one hook ran on files), result
# (passed, failed, skipped or error), findings (below).
#
# findings: the sum, over every report handed to reviewdog, of its count:
#   rdjson  the number of diagnostics (after the converter and normalisation);
#   diff    the number of hunks: lines starting with "@@ ", plus one per "GIT binary patch" or
#           "Binary files ... differ" line;
#   efm     the number of report lines that match at least one of the report's patterns, each
#           pattern read as errorformat does (anchored at both ends, %f a file name without
#           unescaped spaces, %l and %c digits, %m any text, %t one character, %% a percent).
#           A pattern with any other specifier (%A, %C, %Z, %E, %W, %-G, %r, %s, %p, ...) makes the
#           count unknown: the report is posted, counted as nothing, and its count is null.
# A report with a known count of 0 is not posted. An efm report from a failed hook that matches
# no line gets the warning "no line could be annotated" (its raw output is in the log). Exit status: 0 for passed or skipped, 1 for failed (a hook
# found something), 2 for error (an operational failure: bad input, missing hook, capture,
# converter, reviewdog, restore), 128+n on signal n.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ACTION_ROOT="$(cd "${LIB_DIR}/.." && pwd -P)"
# shellcheck source=SCRIPTDIR/snapshot.sh
source "${LIB_DIR}/snapshot.sh"

ACTION_NAME="${ACTION_NAME:-}"
NAME="pre-commit-reviewdog"
[[ ! "${ACTION_NAME}" =~ ^[a-z0-9-]+$ ]] || NAME="${ACTION_NAME}"

# Workflow-command data must have %, CR and LF escaped, or a message could end early.
esc() {
	local s="$*"
	s="${s//'%'/%25}"
	s="${s//$'\r'/%0D}"
	s="${s//$'\n'/%0A}"
	printf '%s' "${s}"
}

# The reviewdog token, kept in a shell variable that is never exported, and every other token a
# job may carry, removed from the environment before anything else runs: a hook is code from the
# caller's repository (or a third party's) and must not be able to read them.
RD_TOKEN="${REVIEWDOG_GITHUB_API_TOKEN:-}"
for var in REVIEWDOG_GITHUB_API_TOKEN REVIEWDOG_TOKEN GITHUB_TOKEN GH_TOKEN GH_ENTERPRISE_TOKEN \
	GITHUB_ENTERPRISE_TOKEN GH_MODULE_TOKEN ACTIONS_RUNTIME_TOKEN ACTIONS_ID_TOKEN_REQUEST_TOKEN \
	ACTIONS_ID_TOKEN_REQUEST_URL $(compgen -e | grep '^INPUT_' || true); do
	unset "${var}" 2>/dev/null || true
done
# A name with a character bash cannot unset (INPUT_GITHUB-TOKEN) is still in the environment
# block; env -u removes those when pre-commit starts.
UNSET_ARGS=()
while IFS= read -r -d '' entry; do
	[[ "${entry}" == INPUT_* ]] && UNSET_ARGS+=(-u "${entry%%=*}")
done < <(env -0)

ERRORS=0
error() {
	ERRORS=$((ERRORS + 1))
	echo "::error::${NAME}: $(esc "$*")"
}
warning() {
	echo "::warning::${NAME}: $(esc "$*")"
}
notice() {
	echo "::notice::${NAME}: $(esc "$*")"
}

# State that the outputs and the verdict are built from.
declare -a PASS_IDS=()
declare -A PASS_STATUS=() PASS_EXIT=()
FIRST_EXIT=0
RAN=false
FINDINGS=0
REPORTS_DIR="${REPORTS_DIR:-}"
WORK=""
STATE=idle # idle | in-pass | recovery
CURRENT_PASS=""
CHILD=""
FINISHED=0
RECOVERY_DIR=""
RECOVERY_PASS=""
RECOVERY_ERROR=""

write_outputs() {
	local result="$1" id
	[[ -n "${GITHUB_OUTPUT:-}" ]] || return 0
	{
		echo "exitcode=${FIRST_EXIT}"
		for id in "${PASS_IDS[@]}"; do
			echo "${id}-exitcode=${PASS_EXIT[${id}]:-}"
		done
		echo "ran=${RAN}"
		echo "result=${result}"
		echo "findings=${FINDINGS}"
	} >>"${GITHUB_OUTPUT}"
}

# Moves the work directory to the recovery location and tells the user how to get the files back.
keep_for_recovery() {
	local base="${WORK%/*}" suffix="${WORK##*.}" t0
	RECOVERY_DIR="${base}/pre-commit-reviewdog-recovery-${NAME}-${suffix}"
	if ! mv -T -- "${WORK}" "${RECOVERY_DIR}"; then
		RECOVERY_DIR="${WORK}"
	fi
	WORK=""
	t0="$(cat "${RECOVERY_DIR}/t0.tree" 2>/dev/null || echo unknown)"
	# recover.sh rebuilds the exact bytes, modes and symlinks of T0 (git archive would apply
	# export-ignore, export-subst and eol or smudge filters). It is copied next to the snapshot, so
	# it outlives the action's checkout.
	cp -- "${LIB_DIR}/recover.sh" "${RECOVERY_DIR}/recover.sh" 2>/dev/null || true
	printf '%s\n' "${SNAP_REPO_OBJECTS}" >"${RECOVERY_DIR}/repo-objects" 2>/dev/null || true
	local command
	command="bash $(printf '%q' "${RECOVERY_DIR}/recover.sh") $(printf '%q' "${RECOVERY_DIR}") <dest>"
	{
		echo "pass: ${RECOVERY_PASS}"
		echo "error: ${RECOVERY_ERROR}"
		echo "t0 tree: ${t0}"
		echo "plan: plan (git diff-tree -r -z --no-renames T0 T1)"
		echo "failed paths: failed-paths"
		echo "index: t0.gitindex holds the bytes of ${SNAP_INDEX} before the pass (absent if t0.indexstate says so)"
		echo "submodules: recover.sh recreates each one from sub/<id> (its path in sub/<id>/path)"
		echo "recover: ${command}"
	} >"${RECOVERY_DIR}/RECOVERY.txt" 2>/dev/null || true
	error "the worktree could not be restored after pass ${RECOVERY_PASS}: ${RECOVERY_ERROR}. No further hook ran. The snapshot from before the pass (tree ${t0}) is kept in ${RECOVERY_DIR}; recover the original files with: ${command}"
	# One line per path, each led by the action name: a path is untrusted text, and a line that
	# starts with it (even after spaces, which the runner trims) could be read as a workflow
	# command.
	local line
	if [[ -s "${RECOVERY_DIR}/failed-paths" ]]; then
		while IFS= read -r line; do
			echo "${NAME}: failed path: ${line}"
		done <"${RECOVERY_DIR}/failed-paths"
	fi
}

# REPORTS_DIR/reports.json, from the entries post_reports collected.
write_reports_index() {
	[[ -n "${REPORTS_DIR_REAL:-}" ]] || return 0
	if [[ -n "${WORK}" && -s "${WORK}/reports.jsonl" ]]; then
		jq -s . "${WORK}/reports.jsonl" >"${REPORTS_DIR_REAL}/reports.json" ||
			error "cannot write ${REPORTS_DIR_REAL}/reports.json"
	else
		echo '[]' >"${REPORTS_DIR_REAL}/reports.json" || error "cannot write ${REPORTS_DIR_REAL}/reports.json"
	fi
}

# Writes the outputs, prints the summary, keeps or deletes the work directory and exits.
finish() {
	local result id status
	FINISHED=1
	trap - EXIT INT TERM
	for id in "${PASS_IDS[@]}"; do
		[[ -n "${PASS_STATUS[${id}]:-}" ]] || PASS_STATUS[${id}]=not-run
	done
	write_reports_index
	# The recovery message is an operational error of its own, so it comes before the verdict.
	if [[ "${STATE}" == recovery ]]; then
		keep_for_recovery
	elif [[ -n "${WORK}" ]]; then
		rm -rf -- "${WORK}"
		WORK=""
	fi

	local failed=0 ran_any=0
	for id in "${PASS_IDS[@]}"; do
		status="${PASS_STATUS[${id}]}"
		[[ "${status}" != failed ]] || failed=1
		[[ "${status}" == skipped || "${status}" == not-run ]] || ran_any=1
	done
	if ((ERRORS > 0)); then
		result=error
	elif ((failed)); then
		result=failed
	elif [[ "${RAN}" == true ]] || ((ran_any)); then
		result=passed
	else
		result=skipped
	fi

	echo "${NAME}: summary"
	for id in "${PASS_IDS[@]}"; do
		echo "  pass ${id}: ${PASS_STATUS[${id}]} (exitcode ${PASS_EXIT[${id}]:-none})"
	done
	echo "  result: ${result}, ran: ${RAN}, exitcode: ${FIRST_EXIT}"
	write_outputs "${result}"

	case "${result}" in
	error)
		echo "::error::${NAME}: failed with ${ERRORS} operational error(s), see the messages above; the hooks' verdict alone is not trusted"
		exit "${1:-2}"
		;;
	failed)
		local failed_ids=()
		for id in "${PASS_IDS[@]}"; do
			[[ "${PASS_STATUS[${id}]}" != failed ]] || failed_ids+=("${id}")
		done
		echo "::error::${NAME}: hooks found problems in pass(es) ${failed_ids[*]}; see the review comments and the hook output above"
		exit 1
		;;
	*) exit 0 ;;
	esac
}

# Stops the running pre-commit (its whole process group when it has one) and waits for it.
# shellcheck disable=SC2329 # invoked from the traps
stop_child() {
	[[ -n "${CHILD}" ]] || return 0
	kill -TERM -- "-${CHILD}" 2>/dev/null || kill -TERM -- "${CHILD}" 2>/dev/null || true
	# Up to 10 seconds for pre-commit to exit (a zombie, not yet waited for, has exited), then
	# KILL for whatever is left of the group: a hook process that ignored TERM included.
	local i state
	for ((i = 0; i < 50; i++)); do
		state="$(awk '/^State:/ { print $2 }' "/proc/${CHILD}/status" 2>/dev/null)" || break
		[[ -n "${state}" && "${state}" != Z ]] || break
		sleep 0.2
	done
	kill -KILL -- "-${CHILD}" 2>/dev/null || kill -KILL -- "${CHILD}" 2>/dev/null || true
	wait "${CHILD}" 2>/dev/null || true
	CHILD=""
}

# Restores T0 after the current pass was interrupted. On failure the run enters recovery.
# shellcheck disable=SC2329 # invoked from the traps
emergency_restore() {
	[[ "${STATE}" == in-pass ]] || return 0
	PASS_STATUS[${CURRENT_PASS}]=error
	if snap_take t1 && snap_restore t0 t1 && snap_verify t0; then
		STATE=idle
		echo "${NAME}: the worktree was restored after the interruption of pass ${CURRENT_PASS}"
	else
		STATE=recovery
		RECOVERY_PASS="${CURRENT_PASS}"
		RECOVERY_ERROR="${SNAP_ERROR}"
	fi
}

# shellcheck disable=SC2329 # invoked from the traps
on_signal() {
	local sig="$1" code="$2"
	trap '' INT TERM
	stop_child
	error "received SIG${sig} during ${CURRENT_PASS:+pass ${CURRENT_PASS}}${CURRENT_PASS:-the run}; stopping"
	emergency_restore
	finish "${code}"
}

# shellcheck disable=SC2329 # invoked from the traps
on_exit() {
	local rc=$?
	((FINISHED == 0)) || exit "${rc}"
	trap '' INT TERM
	stop_child
	error "stopped unexpectedly (exit status ${rc})${CURRENT_PASS:+ during pass ${CURRENT_PASS}}"
	emergency_restore
	finish 2
}

# Before anything is validated: a bad input still gets result=error in the outputs.
fail_input() {
	error "$*; nothing was run"
	finish 2
}

# ---------------------------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------------------------

[[ "${ACTION_NAME}" =~ ^[a-z0-9-]+$ ]] || fail_input "ACTION_NAME '${ACTION_NAME}' is not ^[a-z0-9-]+$"
PASSES="${PASSES:-}"
FROM_REF="${FROM_REF:-}"
TO_REF="${TO_REF:-}"
WORKING_DIRECTORY="${WORKING_DIRECTORY-.}"
REPORTER="${REPORTER-github-pr-review}"

VALIDATE_ONLY="${VALIDATE_ONLY-false}"
case "${VALIDATE_ONLY}" in
true | false) ;;
*) fail_input "VALIDATE_ONLY '${VALIDATE_ONLY}' is not true or false" ;;
esac

command -v jq >/dev/null || fail_input "jq is not on PATH"

# The shape of PASSES, checked as a whole before anything runs. Prints the problems, one a line.
# shellcheck disable=SC2016 # a jq program, not shell
PASSES_CHECK='
def str: type == "string";
def nonempty_str: str and length > 0 and (test("[\u0000-\u001f]") | not);
def one_of($xs): . as $v | any($xs[]; . == $v);
def report_errors($w):
  if type != "object" then ["\($w) is not an object"] else
  . as $r
  | [ (keys - ["source","format","name","converter","required","efm","level","strip"]
       | select(length > 0) | "\($w) has unknown keys: \(join(", "))"),
      (if ($r.source | one_of(["stdout","tree"])) then empty else "\($w) source is not stdout or tree" end),
      (if ($r.format | one_of(["efm","rdjson","diff"])) then empty else "\($w) format is not efm, rdjson or diff" end),
      (if ($r.name | nonempty_str) then empty else "\($w) name is empty, not a string or has control characters" end),
      (if $r.source == "tree" and $r.format != "diff" then "\($w) is a tree report but its format is not diff" else empty end),
      (if has("converter") and ($r.format != "rdjson" or $r.source != "stdout") then "\($w) has a converter but is not a stdout rdjson report" else empty end),
      (if has("converter") and (($r.converter | str and test("^[A-Za-z0-9_][A-Za-z0-9_./-]*[.]jq$") and (test("(^|/)[.][.]?(/|$)") | not)) | not)
       then "\($w) converter is not a relative .jq path inside the action repository" else empty end),
      (if has("required") and ($r.format != "rdjson" or ($r.required | type) != "boolean") then "\($w) required is allowed only as a boolean on an rdjson report" else empty end),
      (if $r.format == "efm" then
         (if ($r.efm | type) == "array" and ($r.efm | length) > 0 and all($r.efm[]; nonempty_str) then empty
          else "\($w) efm is not a non-empty list of errorformat patterns without control characters" end)
       elif has("efm") then "\($w) has efm but its format is not efm" else empty end),
      (if has("level") and (($r.level | one_of(["info","warning","error"])) | not) then "\($w) level is not info, warning or error" else empty end),
      (if has("strip") and ($r.format != "diff" or (($r.strip | type) != "number") or $r.strip < 0 or ($r.strip | floor) != $r.strip)
       then "\($w) strip is allowed only as a whole number >= 0 on a diff report" else empty end)
    ]
  end;
def pass_errors($w):
  if type != "object" then ["\($w) is not an object"] else
  . as $p
  | [ (keys - ["id","hooks","stage","reports"] | select(length > 0) | "\($w) has unknown keys: \(join(", "))"),
      (if ($p.id | str and test("^[a-z0-9-]+$")) then empty else "\($w) id is not ^[a-z0-9-]+$" end),
      (if ($p.hooks | type) == "array" and ($p.hooks | length) > 0 and all($p.hooks[]; str and test("^[A-Za-z0-9_][A-Za-z0-9_.-]*$")) then empty
       else "\($w) hooks is not a non-empty list of hook ids matching ^[A-Za-z0-9_][A-Za-z0-9_.-]*$" end),
      (if ($p.stage | one_of(["pre-commit","pre-merge-commit","pre-push","manual"])) then empty
       else "\($w) stage is not pre-commit, pre-merge-commit, pre-push or manual" end),
      (if ($p.reports | type) != "array" then "\($w) reports is not a list"
       else
         ($p.reports | to_entries[] | .value | report_errors("\($w) report \(.key)") | .[]),
         (if ([$p.reports[] | select(type == "object" and .source == "tree")] | length) != 1
          then "\($w) does not have exactly one tree report" else empty end)
       end)
    ]
  end;
if type != "array" or length == 0 then ["PASSES is not a non-empty JSON array"]
else
  [ (to_entries[] | .key as $i | .value | pass_errors("pass \($i)") | .[]),
    ([.[] | objects | .id] | group_by(.) | map(select(length > 1) | .[0]) | .[] | "pass id \(.) is used more than once"),
    ([.[] | objects | .reports | arrays | .[] | objects | .name] | group_by(.) | map(select(length > 1) | .[0]) | .[]
     | "report name \(.) is used more than once") ]
end
| .[]
'
[[ -n "${PASSES}" ]] || fail_input "PASSES is empty"
if ! passes_errors="$(jq -r "${PASSES_CHECK}" <<<"${PASSES}" 2>&1)"; then
	fail_input "PASSES is not valid JSON: ${passes_errors}"
fi
[[ -z "${passes_errors}" ]] || fail_input "PASSES is malformed: ${passes_errors//$'\n'/; }"
mapfile -t PASS_IDS < <(jq -r '.[].id' <<<"${PASSES}")

# Converters resolve inside this action's repository, so a pass can never run a jq file from the
# caller's checkout.
declare -A CONVERTER=()
while IFS=$'\t' read -r key path; do
	resolved="$(cd "${ACTION_ROOT}" && realpath -e -- "${path}" 2>/dev/null)" ||
		fail_input "converter ${path} does not exist in ${ACTION_ROOT}"
	[[ "${resolved}" == "${ACTION_ROOT}/"* && -f "${resolved}" ]] ||
		fail_input "converter ${path} resolves to ${resolved}, outside ${ACTION_ROOT} or not a file"
	CONVERTER[${key}]="${resolved}"
done < <(jq -r 'to_entries[] | .key as $p | .value.reports | to_entries[] | select(.value.converter) | "\($p)/\(.key)\t\(.value.converter)"' <<<"${PASSES}")

if [[ "${VALIDATE_ONLY}" == true ]]; then
	echo "${NAME}: PASSES is valid: ${#PASS_IDS[@]} pass(es) (${PASS_IDS[*]}), every converter resolves inside ${ACTION_ROOT}"
	exit 0
fi

command -v git >/dev/null || fail_input "git is not on PATH"
# Every git that runs from here, pre-commit's and the hooks' included, skips the optional index
# refresh that `git status` and friends write. pre-commit's own `git diff` rewrites the index all
# the same, so the snapshot also restores the index file byte for byte.
export GIT_OPTIONAL_LOCKS=0
command -v pre-commit >/dev/null || fail_input "pre-commit is not on PATH"
command -v reviewdog >/dev/null || fail_input "reviewdog is not on PATH"

case "${REPORTER}" in
github-pr-review | github-check | local) ;;
*) fail_input "reporter '${REPORTER}' is not github-pr-review, github-check or local" ;;
esac
if [[ "${REPORTER}" != local && -z "${RD_TOKEN}" ]]; then
	fail_input "REVIEWDOG_GITHUB_API_TOKEN is empty, and reporter ${REPORTER} posts to GitHub with it"
fi

# The caller repository: a relative path inside the workspace that is a work tree root.
WORKSPACE="${GITHUB_WORKSPACE:-${PWD}}"
[[ -n "${WORKING_DIRECTORY}" ]] || fail_input "working-directory is empty (use . for the workspace root)"
[[ "${WORKING_DIRECTORY}" != /* ]] || fail_input "working-directory '${WORKING_DIRECTORY}' is absolute; it must be relative to the workspace"
[[ "/${WORKING_DIRECTORY}/" != */../* ]] || fail_input "working-directory '${WORKING_DIRECTORY}' has a .. component"
WORKSPACE_REAL="$(cd "${WORKSPACE}" 2>/dev/null && pwd -P)" || fail_input "the workspace ${WORKSPACE} is not a directory"
ROOT="$(cd "${WORKSPACE_REAL}/${WORKING_DIRECTORY}" 2>/dev/null && pwd -P)" ||
	fail_input "working-directory '${WORKING_DIRECTORY}' is not a directory in ${WORKSPACE_REAL}"
[[ "${ROOT}" == "${WORKSPACE_REAL}" || "${ROOT}" == "${WORKSPACE_REAL}/"* ]] ||
	fail_input "working-directory '${WORKING_DIRECTORY}' resolves to ${ROOT}, outside the workspace ${WORKSPACE_REAL}"
toplevel="$(git -C "${ROOT}" rev-parse --show-toplevel 2>/dev/null)" ||
	fail_input "working-directory '${WORKING_DIRECTORY}' (${ROOT}) is not inside a git work tree"
toplevel="$(cd "${toplevel}" && pwd -P)"
[[ "${toplevel}" == "${ROOT}" ]] ||
	fail_input "working-directory '${WORKING_DIRECTORY}' (${ROOT}) is not the root of its work tree (${toplevel})"
cd "${ROOT}"

REPORTS_DIR_REAL=""
if [[ -n "${REPORTS_DIR}" ]]; then
	[[ "${REPORTS_DIR}" == /* ]] || fail_input "REPORTS_DIR '${REPORTS_DIR}' is not an absolute path"
	REPORTS_DIR_REAL="$(cd "${REPORTS_DIR}" 2>/dev/null && pwd -P)" ||
		fail_input "REPORTS_DIR '${REPORTS_DIR}' is not an existing directory"
	[[ -w "${REPORTS_DIR_REAL}" ]] || fail_input "REPORTS_DIR '${REPORTS_DIR}' is not writable"
	if [[ "${REPORTS_DIR_REAL}" == "${ROOT}" || "${REPORTS_DIR_REAL}" == "${ROOT}/"* ]]; then
		bad="${REPORTS_DIR_REAL}"
		REPORTS_DIR_REAL=""
		fail_input "REPORTS_DIR '${REPORTS_DIR}' resolves to ${bad}, inside the caller's work tree ${ROOT}; the copies would change the tree the hooks see"
	fi
fi

# The refs: commits, never options.
for ref_name in FROM_REF TO_REF; do
	ref="${!ref_name}"
	[[ -n "${ref}" ]] || fail_input "${ref_name} is empty"
	[[ "${ref}" != -* ]] || fail_input "${ref_name} '${ref}' starts with -"
	git rev-parse --verify --quiet "${ref}^{commit}" >/dev/null ||
		fail_input "${ref_name} '${ref}' is not a commit in ${ROOT} (is the checkout deep enough?)"
done

# ---------------------------------------------------------------------------------------------
# The private work directory and the cleanup trap, both before the first hook
# ---------------------------------------------------------------------------------------------

BASE="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
WORK="$(mktemp -d "${BASE}/pre-commit-reviewdog-${NAME}.XXXXXX")" ||
	fail_input "cannot create a work directory in ${BASE}"
trap on_exit EXIT
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM

# ---------------------------------------------------------------------------------------------
# The changed files, as pre-commit computes them for --from-ref/--to-ref (git.py
# get_changed_files): the three-dot diff, or the two-dot one when there is no merge base
# ---------------------------------------------------------------------------------------------

if ! GIT_OPTIONAL_LOCKS=0 git diff --name-only --no-ext-diff -z "${FROM_REF}...${TO_REF}" >"${WORK}/changed" 2>/dev/null; then
	GIT_OPTIONAL_LOCKS=0 git diff --name-only --no-ext-diff -z "${FROM_REF}..${TO_REF}" >"${WORK}/changed" ||
		fail_input "git diff ${FROM_REF}..${TO_REF} failed"
fi
FILES=()
while IFS= read -r -d '' f; do
	# pre-commit drops the paths that do not exist (os.path.lexists): the deletions.
	if [[ -e "${f}" || -L "${f}" ]]; then
		FILES+=("${f}")
	fi
done <"${WORK}/changed"

if ((${#FILES[@]} == 0)); then
	# `pre-commit run --files` with no names would fall back to the staged files and stash the
	# unstaged ones, so pre-commit is not called at all.
	notice "no files changed between ${FROM_REF} and ${TO_REF}; every pass is skipped (no changed files) and pre-commit was not run"
	for id in "${PASS_IDS[@]}"; do
		PASS_STATUS[${id}]=skipped
		PASS_EXIT[${id}]=0
	done
	finish
fi
echo "${NAME}: ${#FILES[@]} changed file(s) between ${FROM_REF} and ${TO_REF}"
NO_FILE=/dev/null/pre-commit-reviewdog-unused

# ---------------------------------------------------------------------------------------------
# Running one hook
# ---------------------------------------------------------------------------------------------

# Runs a command in the background, in its own process group when setsid exists, and waits for
# it. Waiting with `wait` rather than in the foreground lets INT and TERM reach the trap at once,
# and the process group lets the trap stop every process the hook started.
run_child() {
	local out="$1" err="$2" rc=0
	shift 2
	if command -v setsid >/dev/null; then
		setsid "$@" >"${out}" 2>"${err}" </dev/null &
	else
		"$@" >"${out}" 2>"${err}" </dev/null &
	fi
	CHILD=$!
	wait "${CHILD}" || rc=$?
	CHILD=""
	return "${rc}"
}

# Prints a file into the log inside a ::group::, with workflow commands stopped, so a line of hook
# output that looks like a workflow command (::error::, ::add-mask::) is only text.
print_raw() {
	local title="$1" token
	shift
	token="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
	echo "::group::${title}"
	echo "::stop-commands::${token}"
	local file
	for file in "$@"; do
		[[ ! -s "${file}" ]] || cat -- "${file}"
	done
	echo "::${token}::"
	echo "::endgroup::"
}

# Splits pre-commit's output into its own lines and the hook output. pre-commit 4.6.2 prints, per
# hook: optional [INFO]/[WARNING] lines (environment set-up), the status line
# `<name>...(Passed|Failed|Skipped)` (`...(no files to check)Skipped` when no file matched), then,
# for a failed or verbose hook, `- hook id: ...`, `- duration: ...`, `- exit code: N` and
# `- files were modified by this hook`, and when the hook printed something a blank line, its
# output (stripped) and a blank line. The hook output goes to the file `body`; a summary line
# "blocks passed failed skipped nohook unexpected" goes to stdout.
#
# Every status line of one run has the same width: commands/run.py:41-57 (_start_msg, _full_msg)
# pad the name with dots to cols - 1 characters, cols being one value per run (_compute_cols). The
# first status line comes before any hook output, so it fixes that width. A later one is
# recognised only where pre-commit can print one (right after the meta lines, or after the blank
# line that ends a hook's output), only at that exact width, and, after hook output, only when
# the next line confirms it: `- hook id: ` (which a Failed status always has), or for a Passed or
# Skipped status the end of the output or another such status line. Anything else stays hook
# output. (Widths are counted in bytes: an id matched by several hooks with non-ASCII names can
# still be misread; that is reported as an error, never as a pass.)
# shellcheck disable=SC2016 # an awk program, not shell
HOOK_PARSE='
function is_status(l) {
	return l ~ /[.][.][.](\(no files to check\))?(Passed|Failed|Skipped)$/ && (width == 0 || length(l) == width)
}
function start_block(l) {
	blank = 0
	blocks++
	if (l ~ /Passed$/) passed++
	else if (l ~ /Failed$/) failed++
	else skipped++
	state = 1
}
function body_line(l) {
	if (l == "") {
		if (blank) print "" > body
		blank = 1
		return
	}
	if (blank) print "" > body
	blank = 0
	print l > body
}
BEGIN { state = 0; blank = 0; width = 0; pend = ""; haspend = 0; blocks = 0; passed = 0; failed = 0; skipped = 0; nohook = 0; unexpected = 0 }
{
	line = $0
	if (haspend) {
		haspend = 0
		if (line ~ /^- hook id: / || (pend !~ /Failed$/ && is_status(line))) start_block(pend)
		else body_line(pend)
	}
	if (state == 0) {
		if (line ~ /[.][.][.](\(no files to check\))?(Passed|Failed|Skipped)$/) {
			width = length(line)
			start_block(line)
		} else if (line ~ /^No hook with id `.*` in stage `.*`$/) nohook = 1
		else if (line !~ /^\[(INFO|WARNING)\] /) unexpected++
		next
	}
	if (state == 1) {
		if (is_status(line)) { start_block(line); next }
		if (line ~ /^- hook id: / || line ~ /^- duration: / || line ~ /^- exit code: -?[0-9]+$/ || line == "- files were modified by this hook") next
		state = 2
		if (line == "") next
		unexpected++
	}
	if (blank && is_status(line)) {
		pend = line
		haspend = 1
		next
	}
	body_line(line)
}
END {
	if (haspend) {
		if (pend !~ /Failed$/) start_block(pend)
		else body_line(pend)
	}
	printf "%d %d %d %d %d %d\n", blocks, passed, failed, skipped, nohook, unexpected
}
'

# Runs hook $3 (the pass's hook number $5) of pass $1 in stage $2, with its files in pass
# directory $4. Appends the hook's
# output to $4/stdout and sets HOOK_RESULT (passed, failed, skipped or error) and HOOK_RC
# (pre-commit's exit status). An operational problem is reported here, with error.
run_hook() {
	local pass="$1" stage="$2" hook="$3" dir="$4" n="$5"
	local out="${dir}/${n}-${hook}.out" err="${dir}/${n}-${hook}.err" body="${dir}/${n}-${hook}.body"
	local rc=0 summary blocks passed failed nohook unexpected
	HOOK_RESULT=error
	HOOK_RC=0
	: >"${body}"
	echo "${NAME}: pass ${pass}: pre-commit run ${hook} --hook-stage ${stage} --from-ref <from> --to-ref <to> (${#FILES[@]} changed file(s))"
	# See the header: the refs choose the files, the placeholder --files only turns the stash off.
	run_child "${out}" "${err}" env "${UNSET_ARGS[@]}" \
		pre-commit run "${hook}" --hook-stage "${stage}" --color=never \
		--from-ref "${FROM_REF}" --to-ref "${TO_REF}" --files "${NO_FILE}" || rc=$?
	HOOK_RC="${rc}"

	if ! summary="$(awk -v body="${body}" "${HOOK_PARSE}" "${out}")"; then
		error "pass ${pass}: the output of hook ${hook} could not be read"
		print_raw "${NAME}: ${hook} output (pre-commit exit ${rc})" "${out}" "${err}"
		return 0
	fi
	read -r blocks passed failed _ nohook unexpected <<<"${summary}"

	if ((nohook)); then
		error "pass ${pass}: there is no hook with id or alias ${hook} in stage ${stage}. Add it to the caller's .pre-commit-config.yaml (with stages: [${stage}] if it is meant for this action only)"
	elif ((rc != 0 && rc != 1)); then
		error "pass ${pass}: pre-commit run ${hook} exited ${rc}, which is pre-commit's own failure, not a hook result"
	elif ((blocks == 0)); then
		error "pass ${pass}: pre-commit run ${hook} printed no hook status line (exit ${rc}); it failed before running the hook"
	elif ((unexpected > 0)); then
		error "pass ${pass}: pre-commit run ${hook} printed ${unexpected} line(s) outside its known format; the hook output cannot be separated from pre-commit's"
	elif ((rc == 0 && failed > 0)) || ((rc == 1 && failed == 0)); then
		error "pass ${pass}: pre-commit run ${hook} exited ${rc} but reported ${failed} failed hook(s)"
	elif ((failed > 0)); then
		HOOK_RESULT=failed
	elif ((passed > 0)); then
		HOOK_RESULT=passed
	else
		HOOK_RESULT=skipped
	fi
	((blocks <= 1)) || notice "pass ${pass}: ${hook} matched ${blocks} hooks in stage ${stage}; their output is reported together"

	case "${HOOK_RESULT}" in
	passed) echo "${NAME}: pass ${pass}: ${hook} passed" ;;
	skipped) echo "${NAME}: pass ${pass}: ${hook} skipped (no files to check)" ;;
	*) print_raw "${NAME}: ${hook} output (pre-commit exit ${rc})" "${out}" "${err}" ;;
	esac
	if [[ -s "${body}" ]]; then
		cat -- "${body}" >>"${dir}/stdout"
	fi
	return 0
}

# ---------------------------------------------------------------------------------------------
# Building one report
# ---------------------------------------------------------------------------------------------

# Prints errorformat pattern $1 as an anchored POSIX ERE, the way errorformat reads it (see the
# header for the specifiers it supports); returns 1 for any other specifier, whose meaning (a
# multi-line pattern, an ignore pattern, ...) a line-by-line match cannot reproduce.
efm_to_ere() {
	local pattern="$1" ere="^" c i
	[[ "${pattern}" != *$'\n'* ]] || return 1
	for ((i = 0; i < ${#pattern}; i++)); do
		c="${pattern:i:1}"
		if [[ "${c}" == % ]]; then
			i=$((i + 1))
			case "${pattern:i:1}" in
			f) ere+='([A-Za-z]:)?(\\ |[^ ])+' ;;
			l | c) ere+='[0-9]+' ;;
			m) ere+='.+' ;;
			t) ere+='.' ;;
			%) ere+='%' ;;
			*) return 1 ;;
			esac
		else
			case "${c}" in
			'.' | '[' | ']' | '(' | ')' | '*' | '+' | '?' | '{' | '}' | '|' | '^' | '$' | \\ | '/') ere+="\\${c}" ;;
			*) ere+="${c}" ;;
			esac
		fi
	done
	printf '%s$\n' "${ere}"
}

# Prints the number of lines of file $1 that match at least one errorformat pattern of the
# NUL-separated file $2, or "unknown" when a pattern cannot be read line by line.
efm_count() {
	local report="$1" patterns="$2" pattern res="${2}.ere"
	: >"${res}"
	while IFS= read -r -d '' pattern; do
		efm_to_ere "${pattern}" >>"${res}" || {
			echo unknown
			return 0
		}
	done <"${patterns}"
	awk 'NR == FNR { re[++n] = $0; next } { for (i = 1; i <= n; i++) if ($0 ~ re[i]) { c++; break } } END { print c + 0 }' "${res}" "${report}"
}

# Prints the number of hunks in diff $1 (see the header).
diff_count() {
	awk '/^@@ / || /^GIT binary patch$/ || /^Binary files .* differ$/ { c++ } END { print c + 0 }' "$1"
}

# Builds report $3 of pass index $2 (id $1) into $4/report-$3, with reviewdog's arguments in
# $4/report-$3.args (NUL-separated). $5 is 1 when a hook of the pass failed. Leaves no report file
# when there is nothing to post; returns 1 after reporting an operational error.
build_report() {
	local id="$1" i="$2" j="$3" dir="$4" hook_failed="$5"
	local report="${dir}/report-${j}" args="${dir}/report-${j}.args"
	rm -f -- "${report}.count"
	local r source format name level strip required key conv
	r="$(jq -c ".[${i}].reports[${j}]" <<<"${PASSES}")"
	source="$(jq -r '.source' <<<"${r}")"
	format="$(jq -r '.format' <<<"${r}")"
	name="$(jq -r '.name' <<<"${r}")"
	level="$(jq -r '.level // ""' <<<"${r}")"
	strip="$(jq -r '.strip // 1' <<<"${r}")"
	required="$(jq -r '.required // false' <<<"${r}")"
	key="${i}/${j}"
	conv="${CONVERTER[${key}]:-}"
	rm -f -- "${report}" "${args}"

	local -a flags=("-name=${name}" "-reporter=${REPORTER}" "-filter-mode=nofilter" "-fail-level=none")
	[[ -z "${level}" ]] || flags+=("-level=${level}")

	if [[ "${source}" == tree ]]; then
		# The superproject's changes, then each changed submodule's, under its path.
		: >"${report}" || return 1
		if ! snap_diff t0 t1 "${report}"; then
			rm -f -- "${report}"
			error "pass ${id}: the diff of the changes its hooks made could not be built (capture failed): ${SNAP_ERROR}"
			return 1
		fi
		if [[ ! -s "${report}" ]]; then
			rm -f -- "${report}"
			return 0
		fi
		flags+=("-f=diff" "-f.diff.strip=${strip}")
		printf '%s\0' "${flags[@]}" >"${args}"
		diff_count "${report}" >"${report}.count"
		return 0
	fi

	# A stdout report: the hooks' output without pre-commit's own lines.
	local out="${dir}/stdout"
	if ! LC_ALL=C grep -q '[^[:space:]]' "${out}"; then
		if ((hook_failed)); then
			case "${format}" in
			efm)
				warning "pass ${id}: a hook failed but printed nothing for ${name}: no line could be annotated; its raw output is in the log"
				;;
			rdjson)
				if [[ "${required}" == true ]]; then
					error "pass ${id}: the hook failed without the JSON report it prints (${name} is empty)"
					return 1
				fi
				;;
			esac
		fi
		return 0
	fi

	local count
	case "${format}" in
	efm)
		# Some tools colour their lines even under --color=never (ansible-lint does on GitHub
		# Actions), and a coloured line matches no pattern: escape sequences are removed first.
		if ! jq -R -r -L "${LIB_DIR}" 'include "rdjson"; strip_ansi' <"${out}" >"${report}"; then
			rm -f -- "${report}"
			error "pass ${id}: the hook output for ${name} could not be read (capture failed)"
			return 1
		fi
		local pattern
		jq -j '.efm[] | . + "\u0000"' <<<"${r}" >"${report}.patterns"
		while IFS= read -r -d '' pattern; do
			flags+=("-efm=${pattern}")
		done <"${report}.patterns"
		count="$(efm_count "${report}" "${report}.patterns")"
		if [[ "${count}" == 0 ]]; then
			rm -f -- "${report}"
			((hook_failed == 0)) ||
				warning "pass ${id}: a hook failed but none of its output matches the patterns of ${name}: no line could be annotated; its raw output is in the log"
			return 0
		fi
		echo "${count}" >"${report}.count"
		;;
	diff)
		cp -- "${out}" "${report}"
		flags+=("-f=diff" "-f.diff.strip=${strip}")
		count="$(diff_count "${report}")"
		if [[ "${count}" == 0 ]]; then
			rm -f -- "${report}"
			return 0
		fi
		echo "${count}" >"${report}.count"
		;;
	rdjson)
		local converted="${dir}/report-${j}.converted" cerr="${dir}/report-${j}.err" what
		if [[ -n "${conv}" ]]; then
			what="the converter ${conv#"${ACTION_ROOT}/"}"
			jq -R -s -L "${LIB_DIR}" --arg workspace "${ROOT}" -f "${conv}" <"${out}" >"${converted}" 2>"${cerr}"
		else
			what="the RDJSON parser"
			jq -R -s 'fromjson' <"${out}" >"${converted}" 2>"${cerr}"
		fi || {
			error "pass ${id}: ${what} failed on the hook output for ${name}$([[ "${required}" != true || "${hook_failed}" != 1 ]] || echo ' (the hook failed without the JSON report it prints)'): $(head -c 1000 "${cerr}")"
			return 1
		}
		if ! jq -s -L "${LIB_DIR}" --arg workspace "${ROOT}" \
			'include "rdjson"; if length != 1 then error("the report is \(length) JSON values, not one") else .[0] | rdjson_normalize($workspace) end' \
			<"${converted}" >"${report}" 2>"${cerr}"; then
			rm -f -- "${report}"
			error "pass ${id}: the report ${name} is not valid RDJSON: $(head -c 1000 "${cerr}")"
			return 1
		fi
		count="$(jq '.diagnostics | length' <"${report}")"
		if [[ "${count}" == 0 ]]; then
			rm -f -- "${report}"
			return 0
		fi
		echo "${count}" >"${report}.count"
		flags+=("-f=rdjson")
		;;
	esac
	printf '%s\0' "${flags[@]}" >"${args}"
	return 0
}

# Posts every report a pass built (pass index $4), after its restore was verified, adds its count
# to FINDINGS and copies it to REPORTS_DIR. Returns 1 if reviewdog failed.
post_reports() {
	local id="$1" dir="$2" count="$3" i="$4" j rc status=0 n file format
	for ((j = 0; j < count; j++)); do
		[[ -f "${dir}/report-${j}" ]] || continue
		local -a args=()
		mapfile -d '' -t args <"${dir}/report-${j}.args"
		n="$(cat "${dir}/report-${j}.count" 2>/dev/null || echo unknown)"
		[[ "${n}" == unknown ]] || FINDINGS=$((FINDINGS + n))
		if [[ -n "${REPORTS_DIR_REAL}" ]]; then
			format="$(jq -r ".[${i}].reports[${j}].format" <<<"${PASSES}")"
			file="${id}--${j}.${format}"
			if cp -- "${dir}/report-${j}" "${REPORTS_DIR_REAL}/${file}"; then
				jq -nc --arg pass "${id}" --arg file "${file}" --arg n "${n}" --argjson r "$(jq -c ".[${i}].reports[${j}]" <<<"${PASSES}")" \
					'{pass: $pass, name: $r.name, source: $r.source, format: $r.format, file: $file,
					  count: (if $n == "unknown" then null else ($n | tonumber) end)}' >>"${WORK}/reports.jsonl"
			else
				error "pass ${id}: cannot copy a report to REPORTS_DIR ${REPORTS_DIR_REAL}"
			fi
		fi
		echo "${NAME}: pass ${id}: reviewdog ${args[*]}"
		rc=0
		# The token reaches reviewdog alone, as an environment variable of this one command.
		if [[ -n "${RD_TOKEN}" ]]; then
			REVIEWDOG_GITHUB_API_TOKEN="${RD_TOKEN}" reviewdog "${args[@]}" <"${dir}/report-${j}" || rc=$?
		else
			reviewdog "${args[@]}" <"${dir}/report-${j}" || rc=$?
		fi
		if ((rc != 0)); then
			error "pass ${id}: reviewdog exited ${rc} while reporting ${args[0]#-name=}; with -fail-level=none that is a reporting failure (input, API or token), not a finding"
			status=1
		fi
	done
	return "${status}"
}

# ---------------------------------------------------------------------------------------------
# One pass
# ---------------------------------------------------------------------------------------------

# Runs pass index $1. Returns 1 only when the run must stop (the worktree is in recovery).
run_pass() {
	local i="$1" id stage dir hook errors_before="${ERRORS}"
	id="${PASS_IDS[i]}"
	stage="$(jq -r ".[${i}].stage" <<<"${PASSES}")"
	dir="${WORK}/pass-${id}"
	mkdir -p -- "${dir}"
	: >"${dir}/stdout"
	local -a hooks=()
	mapfile -t hooks < <(jq -r ".[${i}].hooks[]" <<<"${PASSES}")

	CURRENT_PASS="${id}"
	STATE=in-pass
	local hook_failed=0 hook_ran=0 pass_exit=0 k
	for k in "${!hooks[@]}"; do
		hook="${hooks[k]}"
		run_hook "${id}" "${stage}" "${hook}" "${dir}" "${k}"
		case "${HOOK_RESULT}" in
		failed)
			hook_failed=1
			hook_ran=1
			;;
		passed) hook_ran=1 ;;
		esac
		if ((HOOK_RC != 0 && pass_exit == 0)); then
			pass_exit="${HOOK_RC}"
		fi
	done
	PASS_EXIT[${id}]="${pass_exit}"
	if ((pass_exit != 0 && FIRST_EXIT == 0)); then
		FIRST_EXIT="${pass_exit}"
	fi
	((hook_ran == 0)) || RAN=true

	# T1: what the hooks left. Without it nothing can be restored.
	if ! snap_take t1; then
		STATE=recovery
		RECOVERY_PASS="${id}"
		RECOVERY_ERROR="the snapshot after the hooks failed: ${SNAP_ERROR}"
		PASS_STATUS[${id}]=error
		return 1
	fi
	if [[ -s "${WORK}/t1.nested" ]] && ! cmp -s "${WORK}/t0.nested" "${WORK}/t1.nested"; then
		warning "pass ${id}: the hooks created a nested repository, which the restore does not cover: $(tr '\0' ' ' <"${WORK}/t1.nested")"
	fi

	local count j
	count="$(jq ".[${i}].reports | length" <<<"${PASSES}")"
	for ((j = 0; j < count; j++)); do
		build_report "${id}" "${i}" "${j}" "${dir}" "${hook_failed}" || true
	done

	# Restore, then verify: the next pass runs only from exactly the original tree.
	if ! snap_restore t0 t1 || { ! snap_same t0 t1 && ! snap_verify t0; }; then
		STATE=recovery
		RECOVERY_PASS="${id}"
		RECOVERY_ERROR="${SNAP_ERROR}"
		PASS_STATUS[${id}]=error
		return 1
	fi
	STATE=idle
	CURRENT_PASS=""
	snap_same t0 t1 || echo "${NAME}: pass ${id}: the worktree was restored and verified"

	post_reports "${id}" "${dir}" "${count}" "${i}" || true

	if ((ERRORS > errors_before)); then
		PASS_STATUS[${id}]=error
	elif ((hook_failed)); then
		PASS_STATUS[${id}]=failed
	elif ((hook_ran)); then
		PASS_STATUS[${id}]=passed
	else
		PASS_STATUS[${id}]=skipped
	fi
	return 0
}

# ---------------------------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------------------------

# The preflight snapshot: T0 for every pass, and the proof that the tree can be restored at all.
if ! snap_init "${WORK}" "${ROOT}" || ! snap_take t0; then
	fail_input "the worktree cannot be snapshotted: ${SNAP_ERROR}"
fi
if [[ -s "${WORK}/t0.nested" ]]; then
	notice "nested repositories are left out of the snapshot and are never passed to a hook: $(tr '\0' ' ' <"${WORK}/t0.nested")"
fi

for i in "${!PASS_IDS[@]}"; do
	run_pass "${i}" || break
done
finish
