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
# Tests pre-commit-hooks.sh: the hooks input is parsed and validated into PASSES (checked with a
# stub run-passes.sh, and with the real one in VALIDATE_ONLY mode). No network, no pre-commit.
#
# Run: bash pre-commit-hooks/pre-commit-hooks.test.sh

# Each check's condition is a single-quoted string that check evaluates after the run, so the
# variables it reads are set by then (SC2016), and some are read only there (SC2034).
# shellcheck disable=SC2016,SC2034

SCRIPT_NAME=pre-commit-hooks.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_DIR="${HERE##*/}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
NL=$'\n'

# A copy of the action next to a stub lib/run-passes.sh that records its environment.
mkdir -p "${WORK}/action/lib" "${WORK}/action/${ACTION_DIR}"
cp "${HERE}/${SCRIPT_NAME}" "${WORK}/action/${ACTION_DIR}/"
cat >"${WORK}/action/lib/run-passes.sh" <<'STUB'
#!/usr/bin/env bash
env | LC_ALL=C sort >"${STUB_ENV}"
printf '%s' "${PASSES:-}" >"${STUB_PASSES}"
echo "stub run-passes"
exit "${STUB_RC:-0}"
STUB
chmod +x "${WORK}/action/lib/run-passes.sh"

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
	if "$@"; then ok "${name}"; else not_ok "${name}" "status ${STATUS}${NL}${LOG}${NL}OUTPUT:${NL}${OUTPUT}"; fi
}

# run [ENV=VALUE...]: runs the copy with the stub. Sets STATUS, LOG, OUTPUT, ENV_SEEN, PASSES_SEEN.
N=0
run() {
	N=$((N + 1))
	local dir="${WORK}/run-${N}"
	mkdir -p "${dir}"
	: >"${dir}/output"
	STATUS=0
	LOG="$(env -i PATH="${PATH}" HOME="${dir}" GITHUB_OUTPUT="${dir}/output" STUB_ENV="${dir}/env" \
		STUB_PASSES="${dir}/passes" "$@" bash "${WORK}/action/${ACTION_DIR}/${SCRIPT_NAME}" 2>&1)" || STATUS=$?
	OUTPUT="$(cat "${dir}/output")"
	ENV_SEEN="$(cat "${dir}/env" 2>/dev/null || true)"
	PASSES_SEEN="$(cat "${dir}/passes" 2>/dev/null || true)"
}
# validate [ENV=VALUE...]: runs the real script of this checkout with the real run-passes.sh in
# VALIDATE_ONLY mode. Sets STATUS and LOG.
validate() {
	STATUS=0
	LOG="$(env -i PATH="${PATH}" HOME="${WORK}" ACTION_NAME="${ACTION_DIR}" VALIDATE_ONLY=true "$@" \
		bash "${HERE}/${SCRIPT_NAME}" 2>&1)" || STATUS=$?
	OUTPUT=""
}
out() { sed -n "s/^$1=//p" <<<"${OUTPUT}"; }

DEFAULT="$(printf '%s\n' check-merge-conflict end-of-file-fixer trailing-whitespace check-yaml check-json check-toml check-added-large-files)"

run HOOKS="${DEFAULT}" FROM_REF=abc
check "the default list becomes one pass at the pre-commit stage with one tree report" \
	eval '[[ ${STATUS} == 0 && "$(jq -c . <<<"${PASSES_SEEN}")" == '"'"'[{"id":"hooks","hooks":["check-merge-conflict","end-of-file-fixer","trailing-whitespace","check-yaml","check-json","check-toml","check-added-large-files"],"stage":"pre-commit","reports":[{"source":"tree","format":"diff","name":"pre-commit-hooks (hooks fixes)"}]}]'"'"' ]]'
check "every other variable reaches run-passes.sh unchanged" eval 'grep -qx "FROM_REF=abc" <<<"${ENV_SEEN}"'
run HOOKS=$'  # core hooks\r\n\n\tend-of-file-fixer  \r\n# detect-private-key\ncheck-yaml' PASSES=ignored
check "blank lines, comment lines, CRs and surrounding spaces are skipped; PASSES from the env is replaced" \
	eval '[[ ${STATUS} == 0 && "$(jq -c ".[0].hooks" <<<"${PASSES_SEEN}")" == "[\"end-of-file-fixer\",\"check-yaml\"]" ]]'
run HOOKS="${DEFAULT}" STUB_RC=1
check "run-passes.sh's exit status is the script's" eval '[[ ${STATUS} == 1 ]]'

refused() { # NAME PATTERN HOOKS
	run HOOKS="$3"
	if [[ ${STATUS} == 2 && -z "${PASSES_SEEN}" && $(out result) == error && $(out ran) == false ]] &&
		grep -q "hooks-exitcode=$" <<<"${OUTPUT}" && grep -q -- "$2" <<<"${LOG}"; then
		ok "$1"
	else
		not_ok "$1 (want exit 2, result=error, no run, a message matching '$2')" "status ${STATUS}${NL}${LOG}${NL}${OUTPUT}"
	fi
}
refused "an empty list is refused" "hooks lists no hook id" ""
refused "a list of comments only is refused" "hooks lists no hook id" $'# a\n  # b\n'
refused "an id that is an option is refused" "line 2 '--all-files' is not a hook id" $'check-yaml\n--all-files'
refused "an inline comment is refused" "is not a hook id" 'check-yaml # yaml'
refused "two ids on one line are refused" "is not a hook id" 'check-yaml check-json'
refused "an id with a shell metacharacter is refused" "is not a hook id" 'check-yaml;id'
refused "an id with an escaped line break is printed escaped, so it cannot inject a workflow command" "line 1 'a%250A::error::x' is not a hook id" 'a%0A::error::x'
refused "a duplicate id is refused" "lists check-yaml more than once" $'check-yaml\ncheck-yaml'
run
check "HOOKS unset is refused" eval '[[ ${STATUS} == 2 && $(out result) == error ]]'

validate HOOKS="${DEFAULT}"
check "the real run-passes.sh accepts the PASSES built from the default list" \
	eval '[[ ${STATUS} == 0 ]] && grep -q "PASSES is valid: 1 pass(es) (hooks)" <<<"${LOG}"'
validate HOOKS=$'check-yaml\nmixed_Case.id-2'
check "the real run-passes.sh accepts every id the parser accepts" eval '[[ ${STATUS} == 0 ]]'

echo
echo "${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
