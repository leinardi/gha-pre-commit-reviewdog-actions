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
# Tests tofu-trivy.sh: the module token reaches git only as step-scoped GIT_CONFIG_* variables,
# checked with real git (`git remote get-url` applies insteadOf rewrites) and a stub
# run-passes.sh. No network, no pre-commit; HOME is a temporary directory, so a global git config
# written by mistake would be seen.
#
# Run: bash tofu-trivy/tofu-trivy.test.sh

# Each check's condition is a single-quoted string that check evaluates after the run, so the
# variables it reads are set by then (SC2016), and some are read only there (SC2034).
# shellcheck disable=SC2016,SC2034

SCRIPT_NAME=tofu-trivy.sh

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

TOKEN=ghs_ABCdef123_-xyz

# get_url URL: what git resolves a remote URL to under the environment run-passes.sh saw.
get_url() {
	local repo="${WORK}/repo-${N}"
	rm -rf "${repo}"
	git init -q "${repo}"
	git -C "${repo}" remote add origin "$1"
	local -a envs=()
	mapfile -t envs < <(grep '^GIT_CONFIG_' <<<"${ENV_SEEN}")
	env -i PATH="${PATH}" HOME="${WORK}/run-${N}" "${envs[@]}" git -C "${repo}" remote get-url origin
}

run GH_MODULE_TOKEN="${TOKEN}" FROM_REF=abc
check "the token is masked in the log" eval 'grep -qxF "::add-mask::${TOKEN}" <<<"${LOG}"'
check "GH_MODULE_TOKEN itself is not passed to run-passes.sh and the hooks" eval '! grep -q "^GH_MODULE_TOKEN=" <<<"${ENV_SEEN}"'
check "four rewrites are exported as GIT_CONFIG_COUNT/KEY/VALUE" eval 'grep -qx "GIT_CONFIG_COUNT=4" <<<"${ENV_SEEN}"'
check "every other variable reaches run-passes.sh unchanged" eval 'grep -qx "FROM_REF=abc" <<<"${ENV_SEEN}"'
for url in ssh://git@github.com/org/mod.git git@github.com:org/mod.git; do
	check "git rewrites ${url} to HTTPS with the token" eval '[[ "$(get_url "'"${url}"'")" == "https://x-access-token:${TOKEN}@github.com/org/mod.git" ]]'
done
check "an HTTPS URL is left alone" eval '[[ "$(get_url https://github.com/org/mod.git)" == https://github.com/org/mod.git ]]'
check "nothing is written to a global git config" eval '[[ ! -e "${WORK}/run-${N}/.gitconfig" && ! -e "${WORK}/run-${N}/.config/git" ]]'

run GH_MODULE_TOKEN="${TOKEN}" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.abbrev GIT_CONFIG_VALUE_0=12
check "entries already in the environment are kept, the new ones appended" \
	eval 'grep -qx "GIT_CONFIG_COUNT=5" <<<"${ENV_SEEN}" && grep -qx "GIT_CONFIG_KEY_0=core.abbrev" <<<"${ENV_SEEN}" && grep -qx "GIT_CONFIG_VALUE_1=ssh://git@github.com/" <<<"${ENV_SEEN}"'

run GH_MODULE_TOKEN=
check "without a token nothing is rewritten and run-passes.sh still runs" \
	eval '[[ ${STATUS} == 0 && "${LOG}" == *"stub run-passes"* ]] && ! grep -q "^GIT_CONFIG_" <<<"${ENV_SEEN}"'
run STUB_RC=1
check "run-passes.sh's exit status is the script's" eval '[[ ${STATUS} == 1 ]]'

for bad in 'ghs_x@evil.example/' $'ghs_x\nmore' 'ghs x'; do
	run GH_MODULE_TOKEN="${bad}"
	check "a token with characters outside a GitHub token's is refused without printing it" \
		eval '[[ ${STATUS} == 2 && -z "${ENV_SEEN}" && $(out result) == error && $(out ran) == false ]] && grep -q "has characters a GitHub token does not have" <<<"${LOG}" && ! grep -qF "${bad}" <<<"${LOG}"'
done
run GH_MODULE_TOKEN="${TOKEN}" GIT_CONFIG_COUNT=$'1\n::error::injected'
check "a GIT_CONFIG_COUNT with a line break cannot inject a workflow command" \
	eval '[[ ${STATUS} == 2 ]] && ! grep -q "^::error::injected" <<<"${LOG}" && grep -qF "1%0A::error::injected" <<<"${LOG}"'
run GH_MODULE_TOKEN="${TOKEN}" GIT_CONFIG_COUNT=x
check "a GIT_CONFIG_COUNT that is not a number is refused" eval '[[ ${STATUS} == 2 && -z "${ENV_SEEN}" && $(out result) == error ]]'

echo
echo "${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
